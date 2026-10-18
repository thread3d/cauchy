import Foundation
import PDFKit

/// A text-layer citation after the defining statement. This is an observed
/// mention, not a claim that the later passage logically depends on it.
struct ReferenceMention: Codable, Equatable, Sendable, Identifiable {
    let pageIndex: Int
    let startOffset: Int
    let matchedText: String
    let context: String
    let region: NormalizedRect

    var id: String { "\(pageIndex):\(startOffset)" }
}

struct ReferenceMentionSearchResult: Codable, Equatable, Sendable {
    let mentions: [ReferenceMention]
    let pagesWithoutText: Int
    let unresolvedMatches: Int
    let truncated: Bool
}

struct ReferenceGraphDefinition: Codable, Equatable, Sendable {
    let reference: DetectedReference
    let pageIndex: Int
    /// Fallback only: the graph builder prefers a fresh declaration check in
    /// the exact PDF bytes it is scanning.
    let definingEndOffset: Int?
}

struct ReferenceGraphRecord: Codable, Equatable, Sendable {
    let definition: ReferenceGraphDefinition
    let result: ReferenceMentionSearchResult
}

/// A portable, inspectable snapshot of observed citation edges. It is not a
/// semantic dependency graph: edges prove a printed mention at a page region.
struct ReferenceMentionGraph: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let documentFingerprint: String
    let records: [ReferenceGraphRecord]

    func result(for reference: DetectedReference) -> ReferenceMentionSearchResult? {
        records.first { $0.definition.reference.key == reference.key }?.result
    }
}

enum ReferenceMentionFinder {
    enum SearchError: LocalizedError {
        case documentUnavailable
        case duplicateDefinition

        var errorDescription: String? {
            switch self {
            case .documentUnavailable: "The PDF could not be opened for later-reference search."
            case .duplicateDefinition: "The same reference was defined twice in the graph input."
            }
        }
    }

    /// Open a separate PDFDocument so a background search never races the
    /// reader's live PDFView. The result includes only resolvable page anchors.
    nonisolated static func find(
        documentURL: URL,
        reference: DetectedReference,
        after definingPageIndex: Int,
        definingEndOffset: Int? = nil,
        limit: Int = 30
    ) throws -> ReferenceMentionSearchResult {
        guard let document = PDFDocument(url: documentURL) else {
            throw SearchError.documentUnavailable
        }
        var mentions: [ReferenceMention] = []
        var pagesWithoutText = 0
        var unresolvedMatches = 0
        var truncated = false
        guard definingPageIndex >= 0, definingPageIndex < document.pageCount, limit > 0 else {
            return ReferenceMentionSearchResult(
                mentions: [], pagesWithoutText: 0, unresolvedMatches: 0, truncated: false
            )
        }
        // Prefer a fresh declaration check over an older cached evidence
        // offset. Ambiguous evidence may otherwise point at a later citation
        // and silently hide real same-page mentions before that offset.
        let definitionEnd = declarationEndOffset(
            in: document,
            reference: reference,
            pageIndex: definingPageIndex
        ) ?? definingEndOffset
        let firstPage = definitionEnd == nil ? definingPageIndex + 1 : definingPageIndex

        for pageIndex in firstPage..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex), let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pagesWithoutText += 1
                continue
            }
            if LLMReferenceIndexSupport.isLikelyTableOfContents(text) { continue }
            let candidates = candidateMatches(in: text, for: reference)
            guard !candidates.isEmpty else { continue }

            let equationPositions = LLMReferenceIndexSupport.equationLabelPositions(in: text, on: page)
            let declarations = Set(LLMReferenceIndexSupport.declarationMatches(
                in: text,
                equationLabelX: equationPositions
            ).filter { $0.reference.key == reference.key }
                .map { $0.range.lowerBound.utf16Offset(in: text) })

            for candidate in candidates
                where (pageIndex > definingPageIndex || candidate.startOffset >= (definitionEnd ?? .max))
                    && !declarations.contains(candidate.startOffset) {
                guard let region = ReferenceEvidenceRegionResolver.exactRegion(
                    matchedText: candidate.matchedText,
                    startOffset: candidate.startOffset,
                    endOffset: candidate.endOffset,
                    on: page
                ) else {
                    unresolvedMatches += 1
                    continue
                }
                if mentions.count >= limit {
                    truncated = true
                    break
                }
                mentions.append(ReferenceMention(
                    pageIndex: pageIndex,
                    startOffset: candidate.startOffset,
                    matchedText: candidate.matchedText,
                    context: candidate.context,
                    region: region
                ))
            }
            if truncated { break }
        }
        return ReferenceMentionSearchResult(
            mentions: mentions,
            pagesWithoutText: pagesWithoutText,
            unresolvedMatches: unresolvedMatches,
            truncated: truncated
        )
    }

    /// Build all observed citation edges in one document pass. This is the
    /// format that can travel with a reading session; a per-hover scan remains
    /// available while no graph snapshot is installed in the reader.
    nonisolated static func buildGraph(
        documentURL: URL,
        definitions: [ReferenceGraphDefinition],
        limitPerReference: Int = 200
    ) throws -> ReferenceMentionGraph {
        guard let document = PDFDocument(url: documentURL) else {
            throw SearchError.documentUnavailable
        }
        var byKey: [ReferenceKey: ReferenceGraphDefinition] = [:]
        for definition in definitions {
            guard byKey[definition.reference.key] == nil else {
                throw SearchError.duplicateDefinition
            }
            byKey[definition.reference.key] = definition
        }
        var mentions: [ReferenceKey: [ReferenceMention]] = [:]
        var unresolved: [ReferenceKey: Int] = [:]
        var truncated = Set<ReferenceKey>()
        var pagesWithoutText: [Int] = []

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: pageIndex), let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pagesWithoutText.append(pageIndex)
                continue
            }
            if LLMReferenceIndexSupport.isLikelyTableOfContents(text) { continue }
            let candidates = ReferenceDetector.allReferences(in: text).filter {
                guard let definition = byKey[$0.reference.key] else { return false }
                return pageIndex >= definition.pageIndex
            }
            guard !candidates.isEmpty else { continue }

            let equationPositions = LLMReferenceIndexSupport.equationLabelPositions(in: text, on: page)
            let declarations = LLMReferenceIndexSupport.declarationMatches(
                in: text, equationLabelX: equationPositions
            )
            var declarationStarts: [ReferenceKey: Set<Int>] = [:]
            var declarationEnds: [ReferenceKey: Int] = [:]
            for declaration in declarations {
                let key = declaration.reference.key
                guard byKey[key] != nil else { continue }
                declarationStarts[key, default: []].insert(
                    declaration.range.lowerBound.utf16Offset(in: text)
                )
                if declarationEnds[key] == nil {
                    declarationEnds[key] = declaration.range.upperBound.utf16Offset(in: text)
                }
            }

            for match in candidates {
                let key = match.reference.key
                guard let definition = byKey[key] else { continue }
                let candidate = candidate(from: match, in: text)
                if pageIndex == definition.pageIndex {
                    guard let end = declarationEnds[key] ?? definition.definingEndOffset,
                          candidate.startOffset >= end else { continue }
                }
                if declarationStarts[key]?.contains(candidate.startOffset) == true { continue }
                guard let region = ReferenceEvidenceRegionResolver.exactRegion(
                    matchedText: candidate.matchedText,
                    startOffset: candidate.startOffset,
                    endOffset: candidate.endOffset,
                    on: page
                ) else {
                    unresolved[key, default: 0] += 1
                    continue
                }
                if mentions[key, default: []].count >= max(0, limitPerReference) {
                    truncated.insert(key)
                    continue
                }
                mentions[key, default: []].append(ReferenceMention(
                    pageIndex: pageIndex,
                    startOffset: candidate.startOffset,
                    matchedText: candidate.matchedText,
                    context: candidate.context,
                    region: region
                ))
            }
        }

        let records = byKey.values.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.reference.kind.rawValue != $1.reference.kind.rawValue {
                return $0.reference.kind.rawValue < $1.reference.kind.rawValue
            }
            return $0.reference.number < $1.reference.number
        }.map { definition in
            let key = definition.reference.key
            return ReferenceGraphRecord(
                definition: definition,
                result: ReferenceMentionSearchResult(
                    mentions: mentions[key] ?? [],
                    pagesWithoutText: pagesWithoutText.filter { $0 > definition.pageIndex }.count,
                    unresolvedMatches: unresolved[key] ?? 0,
                    truncated: truncated.contains(key)
                )
            )
        }
        return ReferenceMentionGraph(
            schemaVersion: ReferenceMentionGraph.schemaVersion,
            documentFingerprint: try ReferenceIndexCacheStore.fingerprint(for: documentURL),
            records: records
        )
    }

    private nonisolated static func declarationEndOffset(
        in document: PDFDocument,
        reference: DetectedReference,
        pageIndex: Int
    ) -> Int? {
        guard let page = document.page(at: pageIndex), let text = page.string else { return nil }
        let positions = LLMReferenceIndexSupport.equationLabelPositions(in: text, on: page)
        return LLMReferenceIndexSupport.declarationMatches(
            in: text, equationLabelX: positions
        ).first { $0.reference.key == reference.key }?
            .range.upperBound.utf16Offset(in: text)
    }

    struct Candidate: Equatable {
        let startOffset: Int
        let endOffset: Int
        let matchedText: String
        let context: String
    }

    /// Pure text-layer stage, tested without an AI model or PDF rendering.
    nonisolated static func candidateMatches(
        in text: String,
        for reference: DetectedReference
    ) -> [Candidate] {
        ReferenceDetector.allReferences(in: text)
            .filter { $0.reference.key == reference.key }
            .map { candidate(from: $0, in: text) }
    }

    private nonisolated static func candidate(
        from match: DetectedReferenceMatch,
        in text: String
    ) -> Candidate {
        let lineStart = text[..<match.range.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[match.range.upperBound...].firstIndex(of: "\n")
            ?? text.endIndex
        let line = text[lineStart..<lineEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedText = String(text[match.range])
        var contextStart = lineStart
        if line == matchedText, lineStart > text.startIndex {
            let previousEnd = text.index(before: lineStart)
            contextStart = text[..<previousEnd].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
        }
        let before = text[contextStart..<match.range.lowerBound]
        let after = text[match.range.upperBound..<lineEnd]
        let leading = String(before.suffix(140))
        let trailing = String(after.prefix(140))
        let excerpt = (before.count > 140 ? "…" : "") + leading
            + matchedText + trailing + (after.count > 140 ? "…" : "")
        let context = excerpt.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return Candidate(
            startOffset: match.range.lowerBound.utf16Offset(in: text),
            endOffset: match.range.upperBound.utf16Offset(in: text),
            matchedText: matchedText,
            context: context
        )
    }
}

struct DocumentReferenceIndexSnapshot: Sendable {
    let entries: [ReferenceKey: IndexedReference]
    let pageCount: Int
    let mentionGraph: ReferenceMentionGraph?
    /// Embedding of each entry's searchable text (name + PDF-source excerpt);
    /// nil when the on-device embedding model is unavailable.
    let bodyEmbeddings: [ReferenceKey: [Float]]?

    init(
        entries: [ReferenceKey: IndexedReference],
        pageCount: Int,
        mentionGraph: ReferenceMentionGraph? = nil,
        bodyEmbeddings: [ReferenceKey: [Float]]? = nil
    ) {
        self.entries = entries
        self.pageCount = pageCount
        self.mentionGraph = mentionGraph
        self.bodyEmbeddings = bodyEmbeddings
    }

    /// Computes body embeddings for a finished entry set. Called from the
    /// background build/load path so the main-actor `replace(with:)` stays cheap.
    nonisolated static func computeBodyEmbeddings(
        for entries: [ReferenceKey: IndexedReference]
    ) -> [ReferenceKey: [Float]]? {
        guard let model = SentenceEmbedder.makeModel() else { return nil }
        var result: [ReferenceKey: [Float]] = [:]
        for (key, entry) in entries {
            if let vector = SentenceEmbedder.vector(for: searchableText(for: entry), using: model) {
                result[key] = vector
            }
        }
        return result.isEmpty ? nil : result
    }

    nonisolated static func searchableText(for entry: IndexedReference) -> String {
        let heading = [entry.reference.kind.displayName, entry.name ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return heading + ". " + SentenceEmbedder.plainText(fromLaTeX: entry.groundingBody)
    }
}

/// How the loaded reference index was produced. Surfaced in the Reference
/// panel so a thin or wrong index points at the model that built it — the
/// small local model is the usual culprit, and the fix is a cloud re-index.
struct ReferenceIndexProvenance: Equatable, Sendable {
    /// Matches `PersistedReferenceIndex.builtWith`: "on-device",
    /// "legacy-unknown", or a `CloudAPIProvider` raw value.
    let builtWith: String
    let builtAt: Date
    let entryCount: Int

    var isOnDevice: Bool { builtWith == "on-device" }

    var modelDescription: String {
        if builtWith == "Vision OCR candidates" {
            return "local OCR candidates"
        }
        if builtWith.contains("Vision OCR candidates") {
            let base = builtWith.replacingOccurrences(
                of: " + Vision OCR candidates",
                with: ""
            )
            return "\(base) + local OCR candidates"
        }
        if let provider = CloudAPIProvider(rawValue: builtWith) {
            return provider.vendor
        }
        if builtWith == "on-device" { return "on-device model" }
        return builtWith == "legacy-unknown" ? "an earlier version" : builtWith
    }

    var summary: String {
        let references = entryCount == 1 ? "1 reference" : "\(entryCount) references"
        let day = builtAt.formatted(date: .abbreviated, time: .omitted)
        return "\(references) · \(modelDescription) · \(day)"
    }
}

/// Lookup table for indexed references. Built off-main by
/// LLMReferenceIndexBuilder (which hands over an immutable snapshot), but only
/// ever read and mutated on the main actor (WorkspaceViewModel, PDFCanvasView
/// hover detection, ask-time statement retrieval).
@MainActor
final class DocumentReferenceIndex {
    private var entries: [ReferenceKey: IndexedReference] = [:]
    private var bodyEmbeddings: [ReferenceKey: [Float]] = [:]
    /// Stemmed name-token sets per entry, for "definition of compactness"-style
    /// questions against v4 caches that carry printed names.
    private var termIndex: [(nameStems: Set<String>, key: ReferenceKey)] = []
    /// Stemmed tokens of each entry's searchable text, plus per-stem document
    /// frequency — the lexical body route ("definition of continuity" →
    /// definition-kind entries whose body talks about continuous maps).
    private var bodyStems: [ReferenceKey: Set<String>] = [:]
    private var stemDocumentFrequency: [String: Int] = [:]
    private var mentionGraph: ReferenceMentionGraph?

    func lookup(_ reference: DetectedReference) -> IndexedReference? {
        entries[reference.key]
    }

    var isEmpty: Bool { entries.isEmpty }

    var count: Int { entries.count }

    var allBlocks: [DocumentBlock] {
        entries.values.sorted {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            if $0.reference.kind.rawValue != $1.reference.kind.rawValue {
                return $0.reference.kind.rawValue < $1.reference.kind.rawValue
            }
            return $0.reference.number.localizedStandardCompare($1.reference.number) == .orderedAscending
        }.map(\.documentBlock)
    }

    func laterMentions(for reference: DetectedReference) -> ReferenceMentionSearchResult? {
        mentionGraph?.result(for: reference)
    }

    func replace(with snapshot: DocumentReferenceIndexSnapshot) {
        entries = snapshot.entries
        mentionGraph = snapshot.mentionGraph
        bodyEmbeddings = snapshot.bodyEmbeddings ?? [:]
        termIndex = snapshot.entries.compactMap { key, entry in
            guard let name = entry.name else { return nil }
            let stems = Set(LexicalDocumentIndex.tokenize(name).map(Self.stem))
            guard !stems.isEmpty else { return nil }
            return (nameStems: stems, key: key)
        }

        bodyStems = [:]
        stemDocumentFrequency = [:]
        for (key, entry) in snapshot.entries {
            let text = DocumentReferenceIndexSnapshot.searchableText(for: entry)
            let stems = Set(LexicalDocumentIndex.tokenize(text).map(Self.stem))
            bodyStems[key] = stems
            for stem in stems {
                stemDocumentFrequency[stem, default: 0] += 1
            }
        }
    }

    func clear() {
        entries = [:]
        bodyEmbeddings = [:]
        termIndex = []
        bodyStems = [:]
        stemDocumentFrequency = [:]
        mentionGraph = nil
    }

    /// Crude prefix stem so inflections meet: "continuity"/"continuous" →
    /// "contin", "compactness"/"compact" → "compac".
    nonisolated static func stem(_ token: String) -> String {
        token.count > 6 ? String(token.prefix(6)) : token
    }

    /// Diagnostic (probe CLI): the highest-similarity entries with their raw
    /// cosine scores, ungated.
    func semanticCandidates(for queryVector: [Float], limit: Int) -> [(heading: String, similarity: Double)] {
        bodyEmbeddings
            .map { key, vector in
                (key: key, similarity: SentenceEmbedder.cosineSimilarity(queryVector, vector))
            }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .compactMap { scored in
                entries[scored.key].map { ($0.promptHeading, scored.similarity) }
            }
    }

    // MARK: - Ask-time statement retrieval

    /// Statements explicitly cited ("Definition 3.2", "(4.1)") anywhere in the
    /// given texts, in citation order, deduped.
    func statements(citedIn texts: [String]) -> [IndexedReference] {
        var seen = Set<ReferenceKey>()
        var results: [IndexedReference] = []
        for text in texts {
            for match in ReferenceDetector.allReferences(in: text) {
                let key = match.reference.key
                guard !seen.contains(key), let entry = entries[key] else { continue }
                seen.insert(key)
                results.append(entry)
            }
        }
        return results
    }

    /// Kind keywords a question can name ("the definition of…", "which
    /// theorem…"). Detecting one focuses the lexical body route on that kind.
    private static let kindIntentStems: [String: ReferenceKind] = [
        "define": .definition, "defini": .definition, "defines": .definition,
        "theore": .theorem, "lemma": .lemma, "lemmas": .lemma,
        "propos": .proposition, "coroll": .corollary,
        "exampl": .example, "remark": .remark, "equati": .equation,
        "figure": .figure, "fig": .figure,
    ]

    /// Statements whose printed name appears in the question ("how does this
    /// tie in with the definition of compactness" → Definition 3.2 (Compactness)).
    /// With definitional intent, definitions rank before other kinds.
    func statements(matchingTermsIn question: String) -> [IndexedReference] {
        let questionStems = Set(LexicalDocumentIndex.tokenize(question).map(Self.stem))
        guard !questionStems.isEmpty else { return [] }
        let definitionalIntent = kindFocus(in: questionStems) == .definition

        let matches = termIndex.filter { $0.nameStems.isSubset(of: questionStems) }
        return matches
            .sorted { a, b in
                if definitionalIntent {
                    let aIsDefinition = a.key.kind == .definition
                    let bIsDefinition = b.key.kind == .definition
                    if aIsDefinition != bIsDefinition { return aIsDefinition }
                }
                // More specific (longer) names first.
                return a.nameStems.count > b.nameStems.count
            }
            .compactMap { entries[$0.key] }
    }

    /// Lexical fallback when names are unavailable (migrated caches) or don't
    /// match: score statement bodies by rarity-weighted overlap with the
    /// question's stems, focused on the kind the question names. Ties break
    /// toward earlier pages — the defining occurrence of a term precedes its
    /// uses.
    func statements(lexicallyMatching question: String, limit: Int) -> [IndexedReference] {
        guard !bodyStems.isEmpty, limit > 0 else { return [] }
        let focus = kindFocus(in: Set(LexicalDocumentIndex.tokenize(question).map(Self.stem)))
        // Only mathematical content selects a statement — never the kind word
        // ("definition") or question function words ("how does this tie in…").
        let questionStems = contentStems(of: question)
        guard !questionStems.isEmpty else { return [] }

        // Only stems that actually discriminate: a stem shared by most entries
        // (or by none) says nothing about which statement is meant.
        let dfCeiling = max(3, entries.count / 4)

        var scored: [(key: ReferenceKey, score: Double, pageIndex: Int)] = []
        for (key, stems) in bodyStems {
            if let focus, key.kind != focus { continue }
            var score = 0.0
            for stem in questionStems.intersection(stems) {
                let df = stemDocumentFrequency[stem] ?? 0
                guard df > 0, df <= dfCeiling else { continue }
                score += 1.0 / Double(df)
            }
            if score > 0, let entry = entries[key] {
                scored.append((key, score, entry.pageIndex))
            }
        }

        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.pageIndex < b.pageIndex
            }
            .prefix(limit)
            .compactMap { entries[$0.key] }
    }

    /// Post-stem stopwords: English function words and question-meta verbs.
    /// Chosen to avoid colliding with mathematical vocabulary after 6-char
    /// stemming ("connec"(ted) and "relati"(on) are content; "relate" is not).
    private static let questionStopStems: Set<String> = [
        "how", "does", "do", "did", "what", "which", "why", "when", "where", "who",
        "the", "an", "of", "in", "on", "with", "to", "from", "into", "onto",
        "is", "are", "was", "were", "be", "been", "being",
        "this", "that", "these", "those", "it", "its",
        "and", "or", "not", "as", "at", "by", "for", "about",
        "we", "you", "me", "my", "our", "your",
        "can", "could", "should", "would", "will", "shall", "may", "might", "must",
        "tie", "ties", "tied", "relate", "explain", "tell", "show", "help",
        "please", "here", "there", "used", "use", "using",
        // "mean value" loses one stem here, but question-side "what does it
        // mean" noise outweighs that (bodies keep their own words regardless).
        "mean", "means", "meant",
    ]

    /// Question stems that carry mathematical content: stemmed, minus kind
    /// words and function words.
    private func contentStems(of question: String) -> Set<String> {
        var stems = Set(LexicalDocumentIndex.tokenize(question).map(Self.stem))
        stems.subtract(Self.kindIntentStems.keys)
        stems.subtract(Self.questionStopStems)
        return stems
    }

    private func kindFocus(in questionStems: Set<String>) -> ReferenceKind? {
        for (stem, kind) in Self.kindIntentStems where questionStems.contains(stem) {
            return kind
        }
        return nil
    }

    /// Statements whose body is semantically close to the query embedding.
    /// Contextual-embedding similarities cluster in a narrow band (~0.85–0.91
    /// measured), so gating is adaptive (outliers above the document's own
    /// similarity distribution) AND lexically corroborated: an entry must share
    /// at least one content stem with the question, which keeps off-topic
    /// queries from surfacing whatever happens to rank highest.
    func statements(
        semanticallyMatching queryVector: [Float],
        question: String,
        limit: Int
    ) -> [IndexedReference] {
        guard !bodyEmbeddings.isEmpty, limit > 0 else { return [] }
        let questionStems = contentStems(of: question)
        let scored = bodyEmbeddings.compactMap { key, vector -> (key: ReferenceKey, similarity: Double)? in
            guard let stems = bodyStems[key], !stems.isDisjoint(with: questionStems) else { return nil }
            return (key: key, similarity: SentenceEmbedder.cosineSimilarity(queryVector, vector))
        }
        guard !scored.isEmpty else { return [] }

        let similarities = scored.map(\.similarity)
        let mean = similarities.reduce(0, +) / Double(similarities.count)
        let variance = similarities.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(similarities.count)
        let threshold = scored.count >= 8
            ? max(0.8, mean + 1.5 * variance.squareRoot())
            : 0.88

        return scored
            .filter { $0.similarity >= threshold }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .compactMap { entries[$0.key] }
    }
}
