import Foundation
import PDFKit

enum ReferenceIndexBuildError: LocalizedError {
    case documentUnavailable
    case noExtractableText
    case unparseableResponse

    var errorDescription: String? {
        switch self {
        case .documentUnavailable:
            "Could not read the PDF for reference indexing."
        case .noExtractableText:
            "This PDF has no searchable text, and local OCR found no reliable numbered reference labels. Inspect the original pages instead."
        case .unparseableResponse:
            "The model's response could not be parsed."
        }
    }
}

struct LLMPageReferenceResponse: Codable, Equatable {
    struct Item: Codable, Equatable {
        let kind: String
        let number: String
        let formattedBody: String
        let name: String?

        init(kind: String, number: String, formattedBody: String, name: String? = nil) {
            self.kind = kind
            self.number = number
            self.formattedBody = formattedBody
            self.name = name
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case number
            case formattedBody = "formatted_body"
            case name
        }
    }

    let references: [Item]
}

enum LLMReferenceIndexResponseParser {
    static func parse(_ raw: String) throws -> LLMPageReferenceResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = candidateJSONStrings(from: trimmed)

        var lastError: Error?
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            do {
                return try JSONDecoder().decode(LLMPageReferenceResponse.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ParserError.noJSONObjectFound
    }

    enum ParserError: Error {
        case noJSONObjectFound
    }

    private static func candidateJSONStrings(from text: String) -> [String] {
        var candidates: [String] = []
        if text.hasPrefix("{") {
            candidates.append(text)
        }

        // Find balanced JSON objects rather than greedily taking everything
        // between the first and last brace. This tolerates prose, fenced JSON,
        // braces inside strings, and a model emitting a corrected second object.
        var objectStart: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in text.indices {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                continue
            }

            if character == "\"" {
                isInString = true
            } else if character == "{" {
                if depth == 0 { objectStart = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let end = text.index(after: index)
                    candidates.append(String(text[start..<end]))
                    objectStart = nil
                }
            }
        }

        let normalized = AssistantResponseNormalizer.normalize(text)
        if normalized != text, normalized.hasPrefix("{") {
            candidates.append(normalized)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }
}

struct PageIndexPayload: Sendable {
    /// Verbatim PDF text used for auditable evidence excerpts.
    let sourceText: String
    /// Normalized text sent to the model and used for defensive grounding.
    let pageText: String
    let pageImagePNG: Data?
    /// Original-page horizontal positions of syntactic equation labels, keyed
    /// by UTF-16 offset in `sourceText`. PDF geometry distinguishes a printed
    /// right-margin equation number from an inline cite or proof-step number.
    let equationLabelX: [Int: Double]
}

enum LLMReferenceIndexSupport {
    static func equationLabelPositions(in sourceText: String, on page: PDFPage) -> [Int: Double] {
        guard page.string == sourceText else { return [:] }
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0 else { return [:] }
        var positions: [Int: Double] = [:]
        for match in ReferenceDetector.allReferences(in: sourceText)
            where match.reference.kind == .equation {
            let start = match.range.lowerBound.utf16Offset(in: sourceText)
            let end = match.range.upperBound.utf16Offset(in: sourceText)
            guard let selection = page.selection(for: NSRange(location: start, length: end - start)) else {
                continue
            }
            let rect = selection.bounds(for: page)
            guard !rect.isEmpty, pageBounds.contains(rect) else { continue }
            positions[start] = Double((rect.minX - pageBounds.minX) / pageBounds.width)
        }
        return positions
    }

    static func preprocessPageText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return LaTeXFormatter.format(trimmed)
    }

    static func shouldUseVision(cloudVisionAvailable: Bool, pageImagePNG: Data?) -> Bool {
        cloudVisionAvailable && pageImagePNG != nil
    }

    /// Scanners sometimes leave only a page number or short watermark in the
    /// PDF text layer. Treat that as image-only unless the text already
    /// contains a declaration Cauchy can ground exactly.
    static func shouldUseOCRFallback(
        sourceText: String,
        equationLabelX: [Int: Double] = [:]
    ) -> Bool {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard trimmed.utf16.count < 80 else { return false }
        return declarationMatches(in: sourceText, equationLabelX: equationLabelX).isEmpty
    }

    /// Table-of-contents pages list every "Definition 6.1"-style heading with a
    /// page number and no body; models (the on-device one especially) extract
    /// them as real references. Detect such pages structurally and skip the
    /// model call entirely.
    static func isLikelyTableOfContents(_ pageText: String) -> Bool {
        let lines = pageText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 5 else { return false }

        let headerWords: Set<String> = ["contents", "table of contents", "index"]
        if lines.prefix(3).contains(where: { headerWords.contains($0.lowercased()) }) {
            return true
        }

        // "6.1. Compact spaces . . . . 34" — dot leaders or a numbered heading
        // that ends in a bare page number.
        let tocLike = lines.filter { line in
            line.range(of: #"(\.\s*){3,}\d+$"#, options: .regularExpression) != nil ||
                line.range(of: #"^\d+(\.\d+)*\.?\s+\D.*\s\d{1,3}$"#, options: .regularExpression) != nil
        }.count
        return tocLike >= 8 || Double(tocLike) / Double(lines.count) >= 0.4
    }

    /// Returns display-ready body, optionally using one repaired candidate.
    static func finalizeReferenceBody(normalized: String, repaired: String?) -> String? {
        if !ReferenceFormattingHeuristics.hasDanglingMathEnding(normalized),
           ReferenceFormattingHeuristics.isMostlyValidLaTeX(normalized) {
            return normalized
        }

        guard let repaired else { return nil }
        let fixed = AssistantResponseNormalizer.normalize(repaired)
        guard !fixed.isEmpty,
              !ReferenceFormattingHeuristics.hasDanglingMathEnding(fixed),
              ReferenceFormattingHeuristics.isMostlyValidLaTeX(fixed) else {
            return nil
        }
        return fixed
    }

    static func merge(
        _ indexed: IndexedReference,
        into results: inout [ReferenceKey: IndexedReference]
    ) {
        let key = indexed.reference.key
        if let existing = results[key] {
            // A later citation or proof discussion must not displace the
            // original statement merely because its transcription is longer.
            if indexed.pageIndex < existing.pageIndex ||
                (indexed.pageIndex == existing.pageIndex && indexed.formattedBody.count > existing.formattedBody.count) {
                results[key] = indexed
            }
        } else {
            results[key] = indexed
        }
    }

    /// Model output is allowed into the index only when its type and number
    /// occur in the source page. This is deliberately stricter than the prompt:
    /// prompts reduce hallucinations, while this check prevents storing them.
    static func isGrounded(kind: ReferenceKind, number: String, in pageText: String) -> Bool {
        ReferenceDetector.allReferences(in: pageText).contains {
            $0.reference.kind == kind && $0.reference.number == number
        }
    }

    static func groundedName(_ name: String?, in pageText: String) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return pageText.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == nil
            ? nil
            : trimmed
    }

    /// Deterministic declaration candidates used as a guardrail around the
    /// model. A model may format a statement, but it may not promote an ordinary
    /// citation into the index. Named declarations require heading punctuation;
    /// equations require equation-like content on the numbered line, or in the
    /// preceding display when the PDF extractor puts the number on its own line.
    static func declarationMatches(
        in sourceText: String,
        equationLabelX: [Int: Double] = [:]
    ) -> [DetectedReferenceMatch] {
        ReferenceDetector.allReferences(in: sourceText).filter { match in
            let afterEnd = sourceText.index(
                match.range.upperBound,
                offsetBy: 180,
                limitedBy: sourceText.endIndex
            ) ?? sourceText.endIndex
            let beforeStart = sourceText.index(
                match.range.lowerBound,
                offsetBy: -180,
                limitedBy: sourceText.startIndex
            ) ?? sourceText.startIndex
            let after = sourceText[match.range.upperBound..<afterEnd]
            let before = sourceText[beforeStart..<match.range.lowerBound]
            let nextCharacter = after.first(where: { !$0.isWhitespace })
            let lineStart = before.lastIndex(of: "\n").map { before.index(after: $0) }
                ?? before.startIndex
            let prefix = before[lineStart...].trimmingCharacters(in: .whitespacesAndNewlines)

            if match.reference.kind == .figure {
                // A caption is a line-start label followed by a separator and
                // title. "Fig. 2a." or "Figure 3a shows..." is a panel cite.
                guard prefix.isEmpty,
                      sourceText[match.range].last?.isNumber == true else { return false }
                let lineEnd = after.firstIndex(of: "\n") ?? after.endIndex
                let remainder = after[..<lineEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = remainder.first,
                      "|:.–—".contains(separator) else { return false }
                let title = remainder.dropFirst()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title.count >= 8 && title.contains(where: \.isLetter)
            }

            if match.reference.kind != .equation {
                guard prefix.isEmpty else { return false }
                return nextCharacter == "." || nextCharacter == ":" || nextCharacter == "("
            }

            let lineEnd = after.firstIndex(of: "\n") ?? after.endIndex
            let suffix = after[..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let matchOffset = match.range.lowerBound.utf16Offset(in: sourceText)
            let labelX = equationLabelX[matchOffset]
            let citationWords = ["by", "see", "using", "from", "equation", "eq."]
            let lowerPrefix = prefix.lowercased()
            if citationWords.contains(where: { lowerPrefix.hasSuffix($0) }) { return false }

            // A printed equation label is separated from the expression. Do
            // not reinterpret function arguments or evaluations such as γ₁(0)
            // merely because the surrounding line also contains an equals sign.
            if let precedingCharacter = sourceText[..<match.range.lowerBound].last,
               !precedingCharacter.isWhitespace {
                return false
            }

            // Numbered proof steps such as "(1) f ∈ W" can look like an
            // equation in the text layer, but their printed numbers begin in
            // the body of the page with the expression to their right. Keep
            // genuinely left-labelled displays (near the page margin) and
            // right-labelled displays eligible.
            if Int(match.reference.number) != nil, let labelX,
               labelX > 0.20, labelX < 0.70, !suffix.isEmpty {
                return false
            }

            // Operators such as a bare hyphen are too common in prose and
            // bibliographies. These stronger signals distinguish a display
            // equation from citation years such as “(2019)”.
            let mathSignals = ["=", "≤", "≥", "≠", "≈", "∈", "∉", "⊂", "⊆", "→", "⇒", "∑", "∂", "√", "∞", "∫"]
            // PDF text can place a genuine label after its formula on the
            // same line, or on a line of its own. Do not borrow math symbols
            // from neighbouring lines to legitimize an inline citation near
            // the right margin (e.g. "the IVP (1.1)" before a formula).
            let nearbyDisplay: String
            if prefix.isEmpty, suffix.isEmpty {
                nearbyDisplay = String(before.suffix(180)) + String(after.prefix(180))
            } else {
                nearbyDisplay = prefix + suffix
            }
            let displayOperators = ["=", "≤", "≥", "≠", "≈", "⇒", "∑", "∫"]
            if let labelX, labelX >= 0.78,
               displayOperators.contains(where: nearbyDisplay.contains) {
                return true
            }
            if prefix.isEmpty, !suffix.isEmpty,
               mathSignals.contains(where: suffix.contains) {
                return true
            }
            if suffix.isEmpty {
                let recentPrefix = String(prefix.suffix(80))
                let labelMath = ["=", "≤", "≥", "≠", "≈", "⇒", "∑", "∫"]
                if prefix.split(whereSeparator: \.isWhitespace).count <= 10,
                   labelMath.contains(where: recentPrefix.contains) {
                    return true
                }
            }

            let matchedText = sourceText[match.range]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fullLineStart = sourceText[..<match.range.lowerBound].lastIndex(of: "\n")
                .map { sourceText.index(after: $0) } ?? sourceText.startIndex
            let fullLineEnd = sourceText[match.range.upperBound...].firstIndex(of: "\n")
                ?? sourceText.endIndex
            let fullLine = sourceText[fullLineStart..<fullLineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard fullLine == matchedText else { return false }

            let displayStart = sourceText.index(
                match.range.lowerBound,
                offsetBy: -600,
                limitedBy: sourceText.startIndex
            ) ?? sourceText.startIndex
            let precedingDisplay = sourceText[displayStart..<match.range.lowerBound]
            return mathSignals.contains(where: precedingDisplay.contains)
        }
    }

    static func isLikelyDeclaration(
        _ reference: DetectedReference,
        in sourceText: String,
        equationLabelX: [Int: Double] = [:]
    ) -> Bool {
        declarationMatches(in: sourceText, equationLabelX: equationLabelX).contains {
            $0.reference == reference
        }
    }

    /// A lossless fallback body for a syntactically strong named declaration
    /// the model omitted or formatted invalidly. It ends before the next strong
    /// heading or proof and is intentionally plain PDF text rather than guessed
    /// LaTeX. A faithful Unicode statement is preferable to a missing one.
    static func fallbackBody(
        for match: DetectedReferenceMatch,
        in sourceText: String,
        maximumCharacters: Int = 1_600
    ) -> String? {
        let hardEnd = sourceText.index(
            match.range.upperBound,
            offsetBy: maximumCharacters,
            limitedBy: sourceText.endIndex
        ) ?? sourceText.endIndex
        var end = hardEnd

        if let next = declarationMatches(in: sourceText).first(where: {
            $0.reference.kind != .equation &&
                $0.range.lowerBound > match.range.lowerBound && $0.range.lowerBound < end
        }) {
            end = next.range.lowerBound
        }
        if let section = nextSectionHeading(in: sourceText, range: match.range.upperBound..<end) {
            end = section
        }
        for marker in ["Proof.", "\nRemark."] {
            if let boundary = sourceText.range(
                of: marker,
                options: [.caseInsensitive],
                range: match.range.upperBound..<end
            ) {
                end = boundary.lowerBound
            }
        }

        var body = String(sourceText[match.range.upperBound..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(".") || body.hasPrefix(":") {
            body.removeFirst()
        }
        body = ReferenceFormattingHeuristics.lightClean(body)
        return body.isEmpty ? nil : body
    }

    /// A PDF text layer has no heading styles, but a standalone dotted section
    /// number followed by a title is a useful stopping boundary for a source
    /// fallback. Without it, the final declaration in a section can absorb
    /// unrelated text from the next section.
    private static func nextSectionHeading(
        in text: String,
        range: Range<String.Index>
    ) -> String.Index? {
        text.range(
            of: #"(?m)^[ \t]*\d+(?:\.\d+)+\.?[ \t]+[A-Z][^\n]*$"#,
            options: .regularExpression,
            range: range
        )?.lowerBound
    }

    static func addNamedDeclarationFallbacks(
        sourceText: String,
        pageIndex: Int,
        equationLabelX: [Int: Double] = [:],
        to results: inout [ReferenceKey: IndexedReference]
    ) {
        for match in declarationMatches(in: sourceText, equationLabelX: equationLabelX)
            where match.reference.kind != .equation && match.reference.kind != .figure &&
                results[match.reference.key] == nil {
            guard let evidence = evidence(
                for: match.reference,
                in: sourceText,
                equationLabelX: equationLabelX
            ),
                  let body = fallbackBody(for: match, in: sourceText) else {
                continue
            }
            let indexed = IndexedReference(
                reference: match.reference,
                formattedBody: body,
                pageIndex: pageIndex,
                evidence: evidence,
                contentOrigin: .sourceFallback
            )
            merge(indexed, into: &results)
        }
    }

    /// A figure's full visual content cannot be recovered faithfully from the
    /// PDF text stream. Store only its printed caption heading as searchable
    /// text and an exact label anchor; the original page remains the image.
    static func addFigureCaptionFallbacks(
        sourceText: String,
        pageIndex: Int,
        to results: inout [ReferenceKey: IndexedReference]
    ) {
        let captions = declarationMatches(in: sourceText).filter { $0.reference.kind == .figure }
        for match in captions where results[match.reference.key] == nil {
            var captionEnd = sourceText[match.range.upperBound...].firstIndex(of: "\n")
                ?? sourceText.endIndex
            // A short title can wrap in single-column notes. Continue only
            // through immediately following lowercase lines, and stop once
            // the printed first sentence ends. Two-column captions can have
            // interleaved prose; never try to reconstruct their full body.
            for _ in 0..<2 {
                guard !sourceText[match.range.upperBound..<captionEnd].contains("."),
                      captionEnd < sourceText.endIndex else { break }
                let nextStart = sourceText.index(after: captionEnd)
                let nextEnd = sourceText[nextStart...].firstIndex(of: "\n")
                    ?? sourceText.endIndex
                let nextLine = sourceText[nextStart..<nextEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let first = nextLine.first, first.isLowercase,
                      nextLine.count <= 180 else { break }
                captionEnd = nextEnd
            }
            let heading = String(sourceText[match.range.lowerBound..<captionEnd])
            let titleText = sourceText[match.range.upperBound..<captionEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .dropFirst()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(titleText.prefix(while: { $0 != "." }))
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !title.isEmpty else { continue }
            let matchingCaptions = captions.filter { $0.reference.key == match.reference.key }
            let evidence = ReferenceEvidence(
                status: matchingCaptions.count == 1 ? .supported : .uncertain,
                sourceExcerpt: heading,
                matchedText: String(sourceText[match.range]),
                occurrenceCount: ReferenceDetector.allReferences(in: sourceText)
                    .filter { $0.reference.key == match.reference.key }.count,
                startOffset: match.range.lowerBound.utf16Offset(in: sourceText),
                endOffset: captionEnd.utf16Offset(in: sourceText),
                matchStartOffset: match.range.lowerBound.utf16Offset(in: sourceText),
                matchEndOffset: match.range.upperBound.utf16Offset(in: sourceText)
            )
            merge(IndexedReference(
                reference: match.reference,
                formattedBody: title,
                pageIndex: pageIndex,
                name: title,
                evidence: evidence,
                contentOrigin: .sourceFallback
            ), into: &results)
        }
    }

    /// A conservative fallback for a numbered display equation that the model
    /// omitted or failed to format. The body is derived only from the verbatim
    /// evidence window, so the index remains useful without inventing notation.
    static func addEquationDeclarationFallbacks(
        sourceText: String,
        pageIndex: Int,
        equationLabelX: [Int: Double] = [:],
        to results: inout [ReferenceKey: IndexedReference]
    ) {
        for match in declarationMatches(in: sourceText, equationLabelX: equationLabelX)
            where match.reference.kind == .equation && results[match.reference.key] == nil {
            guard let evidence = evidence(
                for: match.reference,
                in: sourceText,
                equationLabelX: equationLabelX
            ) else {
                continue
            }
            let body = ReferenceFormattingHeuristics.lightClean(evidence.sourceExcerpt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let indexed = IndexedReference(
                reference: match.reference,
                formattedBody: body,
                pageIndex: pageIndex,
                evidence: evidence,
                contentOrigin: .sourceFallback
            )
            merge(indexed, into: &results)
        }
    }

    static func sourceDeclarationFallbacks(
        sourceText: String,
        pageIndex: Int,
        equationLabelX: [Int: Double] = [:]
    ) -> [ReferenceKey: IndexedReference] {
        var results: [ReferenceKey: IndexedReference] = [:]
        addNamedDeclarationFallbacks(
            sourceText: sourceText,
            pageIndex: pageIndex,
            equationLabelX: equationLabelX,
            to: &results
        )
        addEquationDeclarationFallbacks(
            sourceText: sourceText,
            pageIndex: pageIndex,
            equationLabelX: equationLabelX,
            to: &results
        )
        addFigureCaptionFallbacks(sourceText: sourceText, pageIndex: pageIndex, to: &results)
        return results
    }

    /// Keeps on-device prompts centred on source-backed declarations instead
    /// of sending an entire dense page full of citations and figure labels.
    /// The asymmetric windows preserve the statement after a named heading and
    /// the formula before a right-aligned equation number.
    static func declarationContextChunks(
        pageText: String,
        sourceText: String,
        equationLabelX: [Int: Double] = [:],
        maximumCharacters: Int = 2_800
    ) -> [String] {
        let declaredKeys = Set(declarationMatches(
            in: sourceText,
            equationLabelX: equationLabelX
        ).filter { $0.reference.kind != .figure }.map(\.reference.key))
        guard !declaredKeys.isEmpty else { return [] }

        let normalizedDeclarations = declarationMatches(in: pageText).filter {
            declaredKeys.contains($0.reference.key)
        }
        let candidates: [DetectedReferenceMatch]
        if normalizedDeclarations.isEmpty {
            candidates = ReferenceDetector.allReferences(in: pageText).filter {
                declaredKeys.contains($0.reference.key)
            }
        } else {
            candidates = normalizedDeclarations
        }
        guard !candidates.isEmpty else {
            return ReferenceIndexPromptBuilder.pageTextChunks(
                pageText,
                maxCharacters: maximumCharacters,
                overlapCharacters: 240
            )
        }

        var ranges: [Range<String.Index>] = candidates.map { match in
            let before = match.reference.kind == .equation ? 1_200 : 180
            let after = match.reference.kind == .equation ? 500 : 1_800
            let start = pageText.index(
                match.range.lowerBound,
                offsetBy: -before,
                limitedBy: pageText.startIndex
            ) ?? pageText.startIndex
            let end = pageText.index(
                match.range.upperBound,
                offsetBy: after,
                limitedBy: pageText.endIndex
            ) ?? pageText.endIndex
            return start..<end
        }.sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        ranges.removeAll(keepingCapacity: false)

        return merged.flatMap { range in
            ReferenceIndexPromptBuilder.pageTextChunks(
                String(pageText[range]),
                maxCharacters: maximumCharacters,
                overlapCharacters: 240
            )
        }
    }

    /// Finds the strongest source occurrence for a model-produced reference and
    /// retains a verbatim excerpt around it. Unsupported results return nil and
    /// are rejected before they can enter the index.
    static func evidence(
        for reference: DetectedReference,
        in sourceText: String,
        equationLabelX: [Int: Double] = [:],
        maximumExcerptCharacters: Int = 1_200
    ) -> ReferenceEvidence? {
        let matches = ReferenceDetector.allReferences(in: sourceText).filter {
            $0.reference == reference
        }
        guard !matches.isEmpty else { return nil }

        let ranked = matches.enumerated().map { index, match in
            let offset = match.range.lowerBound.utf16Offset(in: sourceText)
            let x = equationLabelX[offset]
            let geometryBonus = reference.kind == .equation &&
                (x.map { $0 >= 0.78 || $0 <= 0.18 } ?? false) ? 8 : 0
            return (index: index, match: match,
                    score: evidenceScore(for: match, in: sourceText) + geometryBonus)
        }
        let chosen = ranked.max {
            if $0.score == $1.score { return $0.index > $1.index }
            return $0.score < $1.score
        }!.match

        var excerptRange = evidenceExcerptRange(
            around: chosen.range,
            in: sourceText,
            maximumCharacters: maximumExcerptCharacters
        )
        if reference.kind == .equation {
            let lineStart = sourceText[..<chosen.range.lowerBound].lastIndex(of: "\n")
                .map { sourceText.index(after: $0) } ?? sourceText.startIndex
            let lineEnd = sourceText[chosen.range.upperBound...].firstIndex(of: "\n")
                ?? sourceText.endIndex
            let fullLine = sourceText[lineStart..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let beforeLabel = sourceText[excerptRange.lowerBound..<chosen.range.lowerBound]
            let afterLabel = sourceText[chosen.range.upperBound..<excerptRange.upperBound]
            let strongMath = ["=", "≤", "≥", "≠", "≈", "⇒", "∑", "∫"]
            if fullLine == String(sourceText[chosen.range]),
               !strongMath.contains(where: beforeLabel.contains),
               !strongMath.contains(where: afterLabel.contains) {
                // PDFKit sometimes emits a right-margin label *after* the
                // formula and then only a footer. Keep the preceding display
                // rather than exposing a preview containing just "(1.17)".
                let scanStart = sourceText.index(
                    chosen.range.lowerBound,
                    offsetBy: -max(160, maximumExcerptCharacters / 5),
                    limitedBy: sourceText.startIndex
                ) ?? sourceText.startIndex
                let preceding = sourceText[scanStart..<chosen.range.lowerBound]
                if strongMath.contains(where: preceding.contains) {
                    let expandedStart = preceding.firstIndex(of: "\n")
                        .map { sourceText.index(after: $0) } ?? scanStart
                    excerptRange = expandedStart..<excerptRange.upperBound
                }
            }
        }
        return ReferenceEvidence(
            status: matches.count == 1 ? .supported : .uncertain,
            sourceExcerpt: String(sourceText[excerptRange]),
            matchedText: String(sourceText[chosen.range]),
            occurrenceCount: matches.count,
            startOffset: excerptRange.lowerBound.utf16Offset(in: sourceText),
            endOffset: excerptRange.upperBound.utf16Offset(in: sourceText),
            matchStartOffset: chosen.range.lowerBound.utf16Offset(in: sourceText),
            matchEndOffset: chosen.range.upperBound.utf16Offset(in: sourceText)
        )
    }

    /// Declaration-like occurrences win over citations such as “by Theorem 2”.
    /// This does not silently claim certainty: multiple matches are still
    /// surfaced as `.uncertain` even when one is the best preview candidate.
    private static func evidenceScore(
        for match: DetectedReferenceMatch,
        in text: String
    ) -> Int {
        let lineStart = text[..<match.range.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let prefix = text[lineStart..<match.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var score = prefix.isEmpty ? 4 : 0
        if match.reference.kind != .equation { score += 2 }
        let citationMarkers = ["by ", "see ", "using ", "from ", "proof of ", "apply ", "in "]
        if citationMarkers.contains(where: { prefix.hasSuffix($0.trimmingCharacters(in: .whitespaces)) }) {
            score -= 4
        }

        let tailEnd = text.index(
            match.range.upperBound,
            offsetBy: 80,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let tail = text[match.range.upperBound..<tailEnd]
        if tail.contains(".") || tail.contains(":") { score += 1 }
        return score
    }

    private static func evidenceExcerptRange(
        around matchRange: Range<String.Index>,
        in text: String,
        maximumCharacters: Int
    ) -> Range<String.Index> {
        let budget = max(160, maximumCharacters)
        let before = budget / 5
        let after = budget - before
        var start = text.index(
            matchRange.lowerBound,
            offsetBy: -before,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        var end = text.index(
            matchRange.upperBound,
            offsetBy: after,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        // Prefer paragraph boundaries without truncating a hard-wrapped PDF
        // statement at its first line. The result remains byte-for-byte PDF
        // text: no model cleanup or synthetic ellipsis is introduced.
        if start != text.startIndex {
            let search = start..<matchRange.lowerBound
            start = text.range(of: "\n\n", options: .backwards, range: search)?.upperBound
                ?? text.range(of: "\n", options: .backwards, range: search)?.upperBound
                ?? start
        }
        if end != text.endIndex {
            let search = matchRange.upperBound..<end
            end = text.range(of: "\n\n", range: search)?.lowerBound
                ?? end
        }
        if let next = declarationMatches(in: text).first(where: {
            $0.reference.kind != .equation &&
                $0.range.lowerBound > matchRange.lowerBound && $0.range.lowerBound < end
        }) {
            end = next.range.lowerBound
        }
        if let section = nextSectionHeading(in: text, range: matchRange.upperBound..<end) {
            end = section
        }
        return start..<end
    }
}

enum LLMReferenceIndexBuilder {
    static let maxConcurrentPages = 4
    /// The system serializes on-device inference anyway; extra in-flight
    /// requests only queue up and risk timeouts.
    static let maxConcurrentPagesOnDevice = 1

    private struct ModelHandle: Sendable {
        let model: any LanguageModel
        let cloudVision: CloudReferenceIndexClient?
    }

    struct BuildOutcome: Sendable {
        let snapshot: DocumentReferenceIndexSnapshot
        /// Pages that still failed after retries; persisted so the next open
        /// re-indexes only these.
        let failedPageIndices: [Int]
        /// Which model family the entries came from, and when — surfaced in the
        /// Reference panel so a weak index is attributable to its builder.
        let builtWith: String
        let builtAt: Date
    }

    nonisolated static func build(
        documentURL: URL,
        model: any LanguageModel,
        modelDescription: String? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> BuildOutcome {
        let fingerprint = try ReferenceIndexCacheStore.fingerprint(for: documentURL)

        guard let document = PDFDocument(url: documentURL) else {
            throw ReferenceIndexBuildError.documentUnavailable
        }
        let pageCount = document.pageCount

        let cached = try? ReferenceIndexCacheStore.load(fingerprint: fingerprint)
        if let cached, cached.failedPageIndices.isEmpty {
            let entries = cached.asSnapshot(pageCount: pageCount).entries
            let mentionGraph = mentionGraph(
                documentURL: documentURL,
                fingerprint: fingerprint,
                entries: entries
            )
            let snapshot = DocumentReferenceIndexSnapshot(
                entries: entries,
                pageCount: pageCount,
                mentionGraph: mentionGraph,
                bodyEmbeddings: DocumentReferenceIndexSnapshot.computeBodyEmbeddings(for: entries)
            )
            return BuildOutcome(
                snapshot: snapshot,
                failedPageIndices: [],
                builtWith: cached.builtWith,
                builtAt: cached.builtAt
            )
        }

        // Vision (and its per-page PNG rendering) only when the chosen model is
        // actually a cloud one — a saved API key alone must not spend API calls
        // when indexing runs on-device.
        let cloudModel = model as? CloudLanguageModel
        let cloudVision = cloudModel.map(CloudReferenceIndexClient.init(model:))

        let modelHandle = ModelHandle(model: model, cloudVision: cloudVision)

        // A cache with failed pages seeds the result and narrows the work to
        // just those pages; provenance stays with the original bulk build.
        var merged: [ReferenceKey: IndexedReference] = [:]
        var pagesToProcess = Array(0..<pageCount)
        var builtWith = modelDescription ?? modelLabel(for: model)
        if let cached {
            merged = cached.asSnapshot(pageCount: pageCount).entries
            pagesToProcess = cached.failedPageIndices.filter { $0 < pageCount }
            builtWith = cached.builtWith
        }

        let concurrency = (model is OllamaLanguageModel || model is CLIIndexLanguageModel)
            ? maxConcurrentPagesOnDevice
            : maxConcurrentPages

        var failed: [Int] = []
        var completedCount = 0
        var hasExtractableText = false
        var hasOCRCandidates = false

        for batchStart in stride(from: 0, to: pagesToProcess.count, by: concurrency) {
            let batchEnd = min(batchStart + concurrency, pagesToProcess.count)
            try await withThrowingTaskGroup(of: (Int, [ReferenceKey: IndexedReference]?).self) { group in
                for pageIndex in pagesToProcess[batchStart..<batchEnd] {
                    let payload = pagePayload(from: document, pageIndex: pageIndex, cloudVision: cloudVision)
                    if LLMReferenceIndexSupport.shouldUseOCRFallback(
                        sourceText: payload.sourceText,
                        equationLabelX: payload.equationLabelX
                    ) {
                        do {
                            let entries = try await ocrCandidateEntries(
                                from: document,
                                pageIndex: pageIndex
                            )
                            if !entries.isEmpty { hasOCRCandidates = true }
                            for entry in entries.values {
                                LLMReferenceIndexSupport.merge(entry, into: &merged)
                            }
                            completedCount += 1
                            progress?(completedCount, pagesToProcess.count)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failed.append(pageIndex)
                            completedCount += 1
                            progress?(completedCount, pagesToProcess.count)
                        }
                        continue
                    } else {
                        hasExtractableText = true
                    }
                    group.addTask {
                        do {
                            let entries = try await processPageWithRetry(
                                payload: payload,
                                pageIndex: pageIndex,
                                modelHandle: modelHandle
                            )
                            return (pageIndex, entries)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (pageIndex, nil)
                        }
                    }
                }

                for try await (pageIndex, entries) in group {
                    completedCount += 1
                    progress?(completedCount, pagesToProcess.count)
                    guard let entries else {
                        failed.append(pageIndex)
                        continue
                    }
                    for entry in entries.values {
                        LLMReferenceIndexSupport.merge(entry, into: &merged)
                    }
                }
            }
        }

        // A blank scan must not be cached as a successful empty index. OCR
        // candidates are enough to support visibly uncertain navigation, but
        // they remain excluded from answer grounding and portable evidence.
        if cached == nil, pageCount > 0, !hasExtractableText, !hasOCRCandidates {
            throw ReferenceIndexBuildError.noExtractableText
        }
        if hasOCRCandidates, !builtWith.contains("Vision OCR") {
            builtWith = hasExtractableText
                ? "\(builtWith) + Vision OCR candidates"
                : "Vision OCR candidates"
        }

        let mentionGraph = failed.isEmpty ? mentionGraph(
            documentURL: documentURL,
            fingerprint: fingerprint,
            entries: merged
        ) : nil
        let snapshot = DocumentReferenceIndexSnapshot(
            entries: merged,
            pageCount: pageCount,
            mentionGraph: mentionGraph,
            bodyEmbeddings: DocumentReferenceIndexSnapshot.computeBodyEmbeddings(for: merged)
        )
        failed.sort()

        // A mostly-failed fresh run points at a systemic outage — don't bake
        // it into the cache; the next open retries the whole document.
        let failureRate = pagesToProcess.isEmpty ? 0 : Double(failed.count) / Double(pagesToProcess.count)
        let builtAt = Date()
        if cached != nil || failureRate <= 0.5 {
            let persisted = PersistedReferenceIndex(
                documentFingerprint: fingerprint,
                builtAt: builtAt,
                entries: merged,
                builtWith: builtWith,
                failedPageIndices: failed
            )
            try? ReferenceIndexCacheStore.save(persisted)
        }
        return BuildOutcome(
            snapshot: snapshot,
            failedPageIndices: failed,
            builtWith: builtWith,
            builtAt: builtAt
        )
    }

    /// Local OCR is a navigation fallback only. It emits conservative heading
    /// labels with page regions and never calls a language model or fabricates
    /// a clean statement from corrupted OCR prose.
    nonisolated private static func ocrCandidateEntries(
        from document: PDFDocument,
        pageIndex: Int
    ) async throws -> [ReferenceKey: IndexedReference] {
        try Task.checkCancellation()
        guard let page = document.page(at: pageIndex),
              let image = PDFRegionRenderer.renderFullPage(page) else { return [:] }
        let result = try await OCRService.shared.recognizeText(
            in: image,
            useFastRecognition: true
        )
        var entries: [ReferenceKey: IndexedReference] = [:]
        for candidate in OCRReferenceCandidateDetector.candidates(in: result) {
            guard let indexed = candidate.indexedReference(pageIndex: pageIndex) else { continue }
            LLMReferenceIndexSupport.merge(indexed, into: &entries)
        }
        return entries
    }

    /// Graph generation is deterministic and local. A graph is reused only
    /// when its nodes still match the current reference cache exactly.
    nonisolated private static func mentionGraph(
        documentURL: URL,
        fingerprint: String,
        entries: [ReferenceKey: IndexedReference]
    ) -> ReferenceMentionGraph? {
        let expected = Set(entries.map { key, entry in
            "\(key.kind.rawValue):\(key.number):\(entry.pageIndex)"
        })
        if let cached = try? ReferenceIndexCacheStore.loadGraph(fingerprint: fingerprint),
           Set(cached.records.map {
               "\($0.definition.reference.kind.rawValue):\($0.definition.reference.number):\($0.definition.pageIndex)"
           }) == expected {
            return cached
        }
        let definitions = entries.values.map {
            ReferenceGraphDefinition(
                reference: $0.reference,
                pageIndex: $0.pageIndex,
                definingEndOffset: $0.evidence?.textLayerMatchEndOffset
            )
        }
        guard let graph = try? ReferenceMentionFinder.buildGraph(
            documentURL: documentURL,
            definitions: definitions
        ) else { return nil }
        try? ReferenceIndexCacheStore.saveGraph(graph)
        return graph
    }

    /// Retries transient per-page failures with backoff; rate limits wait
    /// longer. Context overflow is never retried — splitting already handled
    /// it, and a repeat attempt cannot do better.
    nonisolated private static func processPageWithRetry(
        payload: PageIndexPayload,
        pageIndex: Int,
        modelHandle: ModelHandle
    ) async throws -> [ReferenceKey: IndexedReference] {
        var attempt = 1
        while true {
            do {
                return try await processPage(payload: payload, pageIndex: pageIndex, modelHandle: modelHandle)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < 3, !isContextOverflow(error) else { throw error }
                let rateLimited = if let cloud = error as? CloudAPIError,
                                     case .rateLimited = cloud { true } else { false }
                let base: Double = rateLimited ? (attempt == 1 ? 5 : 15) : (attempt == 1 ? 1 : 4)
                try await Task.sleep(for: .seconds(base + Double.random(in: 0...0.5)))
                attempt += 1
            }
        }
    }

    nonisolated private static func pagePayload(
        from document: PDFDocument,
        pageIndex: Int,
        cloudVision: CloudReferenceIndexClient?
    ) -> PageIndexPayload {
        guard let page = document.page(at: pageIndex) else {
            return PageIndexPayload(
                sourceText: "", pageText: "", pageImagePNG: nil,
                equationLabelX: [:]
            )
        }

        let rawText = fullPageText(from: page)
        let pageText = LLMReferenceIndexSupport.preprocessPageText(rawText)
        let equationLabelX = LLMReferenceIndexSupport.equationLabelPositions(in: rawText, on: page)

        var pageImagePNG: Data?
        if cloudVision != nil,
           let image = PDFRegionRenderer.renderFullPage(page),
           let png = PDFRegionRenderer.pngData(from: image) {
            pageImagePNG = png
        }

        return PageIndexPayload(
            sourceText: rawText, pageText: pageText, pageImagePNG: pageImagePNG,
            equationLabelX: equationLabelX
        )
    }

    nonisolated private static func processPage(
        payload: PageIndexPayload,
        pageIndex: Int,
        modelHandle: ModelHandle
    ) async throws -> [ReferenceKey: IndexedReference] {
        let trimmedPageText = payload.pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPageText.isEmpty,
              !LLMReferenceIndexSupport.isLikelyTableOfContents(trimmedPageText),
              !ReferenceDetector.allReferences(in: trimmedPageText).isEmpty else {
            return [:]
        }
        guard !LLMReferenceIndexSupport.declarationMatches(
            in: payload.sourceText,
            equationLabelX: payload.equationLabelX
        ).isEmpty else {
            return [:]
        }

        if LLMReferenceIndexSupport.declarationMatches(
            in: payload.sourceText, equationLabelX: payload.equationLabelX
        ).allSatisfy({ $0.reference.kind == .figure }) {
            return LLMReferenceIndexSupport.sourceDeclarationFallbacks(
                sourceText: payload.sourceText,
                pageIndex: pageIndex,
                equationLabelX: payload.equationLabelX
            )
        }

        let parsed: LLMPageReferenceResponse
        do {
            parsed = try await extractPageReferences(
                payload: payload,
                pageIndex: pageIndex,
                modelHandle: modelHandle
            )
        } catch where isContextOverflow(error) {
            return LLMReferenceIndexSupport.sourceDeclarationFallbacks(
                sourceText: payload.sourceText,
                pageIndex: pageIndex,
                equationLabelX: payload.equationLabelX
            )
        }
        return await finalizeItems(
            parsed,
            pageText: trimmedPageText,
            sourceText: payload.sourceText,
            pageIndex: pageIndex,
            equationLabelX: payload.equationLabelX,
            modelHandle: modelHandle
        )
    }

    /// Normalizes, repairs, and validates the extracted items into indexable
    /// entries, dropping any whose LaTeX cannot be made display-ready.
    nonisolated private static func finalizeItems(
        _ parsed: LLMPageReferenceResponse,
        pageText: String,
        sourceText: String,
        pageIndex: Int,
        equationLabelX: [Int: Double],
        modelHandle: ModelHandle
    ) async -> [ReferenceKey: IndexedReference] {
        var results: [ReferenceKey: IndexedReference] = [:]
        for item in parsed.references {
            let trimmedBody = item.formattedBody.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else { continue }
            let kindName = item.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let kind = ReferenceKind(rawValue: kindName) else { continue }
            if kind == .figure { continue } // Captions come only from exact source text.
            let number = item.number.trimmingCharacters(in: .whitespacesAndNewlines)
            guard LLMReferenceIndexSupport.isGrounded(kind: kind, number: number, in: pageText) else {
                continue
            }
            let reference = DetectedReference(kind: kind, number: number)
            guard LLMReferenceIndexSupport.isLikelyDeclaration(
                reference, in: sourceText, equationLabelX: equationLabelX
            ) else {
                continue
            }
            guard let evidence = LLMReferenceIndexSupport.evidence(
                for: reference,
                in: sourceText,
                equationLabelX: equationLabelX
            ) else {
                continue
            }

            let normalized = AssistantResponseNormalizer.normalize(trimmedBody)
            guard !normalized.isEmpty else { continue }

            let repaired = await repairLaTeXOnceIfNeeded(normalized, modelHandle: modelHandle)
            guard let formattedBody = LLMReferenceIndexSupport.finalizeReferenceBody(
                normalized: normalized,
                repaired: repaired
            ) else {
                continue
            }

            let indexed = IndexedReference(
                reference: reference,
                formattedBody: formattedBody,
                pageIndex: pageIndex,
                name: LLMReferenceIndexSupport.groundedName(item.name, in: pageText),
                evidence: evidence
            )
            LLMReferenceIndexSupport.merge(indexed, into: &results)
        }

        LLMReferenceIndexSupport.addNamedDeclarationFallbacks(
            sourceText: sourceText,
            pageIndex: pageIndex,
            equationLabelX: equationLabelX,
            to: &results
        )
        LLMReferenceIndexSupport.addEquationDeclarationFallbacks(
            sourceText: sourceText,
            pageIndex: pageIndex,
            equationLabelX: equationLabelX,
            to: &results
        )
        LLMReferenceIndexSupport.addFigureCaptionFallbacks(
            sourceText: sourceText,
            pageIndex: pageIndex,
            to: &results
        )

        return results
    }

    // MARK: - Benchmark support

    struct SinglePageResult: Sendable {
        enum Disposition: String, Sendable {
            case processed
            case sourceOnly = "source_only"
            case figureCaptionsFromSource = "figure_captions_from_source"
            case emptyText = "empty_text"
            case ocrCandidates = "ocr_candidates"
            case likelyTableOfContents = "likely_table_of_contents"
            case noReferenceMentions = "no_reference_mentions"
            case noLikelyDeclarations = "no_likely_declarations"
            case contextOverflowSourceFallback = "context_overflow_source_fallback"
        }

        /// References the model returned before validation/repair.
        let parsedCount: Int
        /// Model transcriptions that survived all deterministic checks.
        let modelAcceptedCount: Int
        /// Strong declarations retained as cleaned PDF text because the model
        /// omitted them, returned unusable formatting, or exceeded its context.
        let sourceFallbackCount: Int
        let entries: [ReferenceKey: IndexedReference]
        let pageTextCharacters: Int
        let disposition: Disposition
    }

    /// Runs the same source-backed declaration fallback without model inference.
    /// Kept separate from the production mode so the labelled corpus can measure
    /// whether the model adds reliable recall before changing reader behaviour.
    nonisolated static func indexSinglePageFromSource(
        from document: PDFDocument,
        pageIndex: Int
    ) -> SinglePageResult {
        let payload = pagePayload(from: document, pageIndex: pageIndex, cloudVision: nil)
        let trimmed = payload.pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let disposition: SinglePageResult.Disposition
        let entries: [ReferenceKey: IndexedReference]
        if trimmed.isEmpty {
            disposition = .emptyText
            entries = [:]
        } else if LLMReferenceIndexSupport.isLikelyTableOfContents(trimmed) {
            disposition = .likelyTableOfContents
            entries = [:]
        } else if ReferenceDetector.allReferences(in: trimmed).isEmpty {
            disposition = .noReferenceMentions
            entries = [:]
        } else if LLMReferenceIndexSupport.declarationMatches(
            in: payload.sourceText,
            equationLabelX: payload.equationLabelX
        ).isEmpty {
            disposition = .noLikelyDeclarations
            entries = [:]
        } else {
            disposition = .sourceOnly
            entries = LLMReferenceIndexSupport.sourceDeclarationFallbacks(
                sourceText: payload.sourceText,
                pageIndex: pageIndex,
                equationLabelX: payload.equationLabelX
            )
        }
        return SinglePageResult(
            parsedCount: 0,
            modelAcceptedCount: 0,
            sourceFallbackCount: entries.count,
            entries: entries,
            pageTextCharacters: trimmed.count,
            disposition: disposition
        )
    }

    /// Runs the exact production extraction path for one page — used by the
    /// headless indexing benchmark. Errors propagate with full detail instead
    /// of being swallowed like in the bulk build.
    nonisolated static func indexSinglePage(
        from document: PDFDocument,
        pageIndex: Int,
        model: any LanguageModel
    ) async throws -> SinglePageResult {
        let handle = ModelHandle(model: model, cloudVision: nil)
        let payload = pagePayload(from: document, pageIndex: pageIndex, cloudVision: nil)
        let trimmed = payload.pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        if LLMReferenceIndexSupport.shouldUseOCRFallback(
            sourceText: payload.sourceText,
            equationLabelX: payload.equationLabelX
        ) {
            let entries = try await ocrCandidateEntries(from: document, pageIndex: pageIndex)
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: 0,
                entries: entries,
                pageTextCharacters: 0,
                disposition: entries.isEmpty ? .emptyText : .ocrCandidates
            )
        }
        if LLMReferenceIndexSupport.isLikelyTableOfContents(trimmed) {
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: 0,
                entries: [:],
                pageTextCharacters: trimmed.count,
                disposition: .likelyTableOfContents
            )
        }
        if ReferenceDetector.allReferences(in: trimmed).isEmpty {
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: 0,
                entries: [:],
                pageTextCharacters: trimmed.count,
                disposition: .noReferenceMentions
            )
        }
        if LLMReferenceIndexSupport.declarationMatches(
            in: payload.sourceText,
            equationLabelX: payload.equationLabelX
        ).isEmpty {
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: 0,
                entries: [:],
                pageTextCharacters: trimmed.count,
                disposition: .noLikelyDeclarations
            )
        }

        if LLMReferenceIndexSupport.declarationMatches(
            in: payload.sourceText, equationLabelX: payload.equationLabelX
        ).allSatisfy({ $0.reference.kind == .figure }) {
            let entries = LLMReferenceIndexSupport.sourceDeclarationFallbacks(
                sourceText: payload.sourceText,
                pageIndex: pageIndex,
                equationLabelX: payload.equationLabelX
            )
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: entries.count,
                entries: entries,
                pageTextCharacters: trimmed.count,
                disposition: .figureCaptionsFromSource
            )
        }

        let parsed: LLMPageReferenceResponse
        do {
            parsed = try await extractPageReferences(
                payload: payload,
                pageIndex: pageIndex,
                modelHandle: handle
            )
        } catch where isContextOverflow(error) {
            let entries = LLMReferenceIndexSupport.sourceDeclarationFallbacks(
                sourceText: payload.sourceText,
                pageIndex: pageIndex,
                equationLabelX: payload.equationLabelX
            )
            return SinglePageResult(
                parsedCount: 0,
                modelAcceptedCount: 0,
                sourceFallbackCount: entries.count,
                entries: entries,
                pageTextCharacters: trimmed.count,
                disposition: .contextOverflowSourceFallback
            )
        }
        let entries = await finalizeItems(
            parsed,
            pageText: trimmed,
            sourceText: payload.sourceText,
            pageIndex: pageIndex,
            equationLabelX: payload.equationLabelX,
            modelHandle: handle
        )
        return SinglePageResult(
            parsedCount: parsed.references.count,
            modelAcceptedCount: entries.values.filter { $0.contentOrigin == .modelTranscription }.count,
            sourceFallbackCount: entries.values.filter { $0.contentOrigin == .sourceFallback }.count,
            entries: entries,
            pageTextCharacters: trimmed.count,
            disposition: .processed
        )
    }

    /// Every model now takes the raw-JSON text path, with the same parse and
    /// repair passes the cloud providers use. Ollama reports a context-window
    /// error the same way, so the split-and-retry logic below still applies.
    nonisolated private static func extractPageReferences(
        payload: PageIndexPayload,
        pageIndex: Int,
        modelHandle: ModelHandle
    ) async throws -> LLMPageReferenceResponse {
        let rawResponse = try await requestPageExtraction(
            payload: payload,
            pageIndex: pageIndex,
            modelHandle: modelHandle
        )
        guard let parsed = await parsePageResponse(rawResponse, modelHandle: modelHandle) else {
            throw ReferenceIndexBuildError.unparseableResponse
        }
        return parsed
    }

    nonisolated private static func isContextOverflow(_ error: Error) -> Bool {
        if let error = error as? LanguageModelError, case .contextSizeExceeded = error {
            return true
        }
        return false
    }

    nonisolated private static func modelLabel(for model: any LanguageModel) -> String {
        if let ollama = model as? OllamaLanguageModel {
            return "Ollama · \(ollama.modelName)"
        }
        if let cloud = model as? CloudLanguageModel {
            return cloud.provider.rawValue
        }
        if model is CLIIndexLanguageModel {
            return "CLI"
        }
        return "on-device"
    }

    /// Splits at the paragraph (or line) break closest to the midpoint so a
    /// reference statement isn't cut mid-sentence more than necessary.
    nonisolated static func splitNearMidpoint(_ text: String) -> (String, String) {
        let target = text.count / 2

        for separator in ["\n\n", "\n"] {
            var best: (index: String.Index, distance: Int)?
            var searchStart = text.startIndex
            while let range = text.range(of: separator, range: searchStart..<text.endIndex) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                let distance = abs(offset - target)
                if best == nil || distance < best!.distance {
                    best = (range.upperBound, distance)
                }
                searchStart = range.upperBound
            }
            // Only take a break point that lands in the middle half of the
            // text, so neither side ends up trivially small.
            if let best, best.distance <= text.count / 4 {
                return (String(text[..<best.index]), String(text[best.index...]))
            }
        }

        let midpoint = text.index(text.startIndex, offsetBy: target)
        return (String(text[..<midpoint]), String(text[midpoint...]))
    }

    nonisolated private static func parsePageResponse(
        _ rawResponse: String,
        modelHandle: ModelHandle
    ) async -> LLMPageReferenceResponse? {
        if let parsed = try? LLMReferenceIndexResponseParser.parse(rawResponse) {
            return parsed
        }

        do {
            let repaired = try await requestJSONRepair(
                previousOutput: rawResponse,
                modelHandle: modelHandle
            )
            return try? LLMReferenceIndexResponseParser.parse(repaired)
        } catch {
            return nil
        }
    }

    nonisolated private static func repairLaTeXOnceIfNeeded(
        _ normalized: String,
        modelHandle: ModelHandle
    ) async -> String? {
        guard !ReferenceFormattingHeuristics.isMostlyValidLaTeX(normalized) else {
            return nil
        }

        do {
            return try await requestLaTeXRepair(
                previousOutput: normalized,
                modelHandle: modelHandle
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func requestPageExtraction(
        payload: PageIndexPayload,
        pageIndex: Int,
        modelHandle: ModelHandle
    ) async throws -> String {
        if LLMReferenceIndexSupport.shouldUseVision(
            cloudVisionAvailable: modelHandle.cloudVision != nil,
            pageImagePNG: payload.pageImagePNG
        ),
           let cloudVision = modelHandle.cloudVision,
           let imagePNG = payload.pageImagePNG {
            return try await cloudVision.indexPage(
                imagePNG: imagePNG,
                pageText: payload.pageText,
                pageIndex: pageIndex
            )
        }

        let chunks = ReferenceIndexPromptBuilder.pageTextChunks(
            payload.pageText,
            maxCharacters: ReferenceIndexPromptBuilder.maxPageCharacters
        )
        var references: [LLMPageReferenceResponse.Item] = []
        for chunk in chunks {
            let raw = try await requestTextPageExtraction(
                pageText: chunk,
                pageIndex: pageIndex,
                modelHandle: modelHandle
            )
            guard let parsed = await parsePageResponse(raw, modelHandle: modelHandle) else {
                throw ReferenceIndexBuildError.unparseableResponse
            }
            references.append(contentsOf: parsed.references)
        }
        let encoded = try JSONEncoder().encode(LLMPageReferenceResponse(references: references))
        return String(decoding: encoded, as: UTF8.self)
    }

    @MainActor
    private static func requestTextPageExtraction(
        pageText: String,
        pageIndex: Int,
        modelHandle: ModelHandle
    ) async throws -> String {
        let session = ReadingLanguageModelSession(
            model: modelHandle.model,
            instructions: ReferenceIndexPromptBuilder.instructions
        )
        let prompt = ReferenceIndexPromptBuilder.userPrompt(pageText: pageText, pageIndex: pageIndex)
        return try await streamResponse(session: session, prompt: prompt)
    }

    nonisolated private static func requestJSONRepair(
        previousOutput: String,
        modelHandle: ModelHandle
    ) async throws -> String {
        if let cloudVision = modelHandle.cloudVision {
            return try await cloudVision.repairJSON(previousOutput: previousOutput)
        }

        return try await requestTextJSONRepair(
            previousOutput: previousOutput,
            modelHandle: modelHandle
        )
    }

    @MainActor
    private static func requestTextJSONRepair(
        previousOutput: String,
        modelHandle: ModelHandle
    ) async throws -> String {
        let session = ReadingLanguageModelSession(
            model: modelHandle.model,
            instructions: ReferenceIndexPromptBuilder.instructions
        )
        let prompt = ReferenceIndexPromptBuilder.jsonRepairPrompt(previousOutput: previousOutput)
        return try await streamResponse(session: session, prompt: prompt)
    }

    nonisolated private static func requestLaTeXRepair(
        previousOutput: String,
        modelHandle: ModelHandle
    ) async throws -> String {
        if let cloudVision = modelHandle.cloudVision {
            return try await cloudVision.repairLaTeX(previousOutput: previousOutput)
        }

        return try await requestTextLaTeXRepair(
            previousOutput: previousOutput,
            modelHandle: modelHandle
        )
    }

    @MainActor
    private static func requestTextLaTeXRepair(
        previousOutput: String,
        modelHandle: ModelHandle
    ) async throws -> String {
        let session = ReadingLanguageModelSession(
            model: modelHandle.model,
            instructions: ReadingPromptBuilder.latexRepairInstructions()
        )
        let prompt = ReadingPromptBuilder.latexRepairPrompt(previousOutput: previousOutput)
        return try await streamResponse(session: session, prompt: prompt)
    }

    @MainActor
    private static func streamResponse(session: ReadingLanguageModelSession, prompt: String) async throws -> String {
        let stream = session.streamResponse(to: prompt)
        var accumulated = ""
        for try await snapshot in stream {
            accumulated = snapshot.content
        }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func fullPageText(from page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        return page.selection(for: bounds)?.string ?? ""
    }
}
