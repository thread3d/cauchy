import AppKit
import Foundation
import PDFKit

/// Headless benchmark of on-device reference indexing, invoked with
/// `Cauchy --benchmark-indexing <pdf> [--ground-truth labels.json] [--pages N] [--output <dir>] [--source-only]`.
/// Runs the production per-page extraction path on evenly spaced sample pages,
/// compares it with two deterministic baselines and optional hand-labelled
/// truth, writes report.md + report.json, and exits without normal UI interaction.
enum ReferenceIndexBenchmark {
    struct Config {
        let pdfURL: URL
        let sampleSize: Int
        let outputDirectory: URL?
        let groundTruthURL: URL?
        let sourceOnly: Bool

        /// Returns nil when the arguments don't request benchmark mode.
        init?(arguments: [String]) {
            guard let flagIndex = arguments.firstIndex(of: "--benchmark-indexing"),
                  arguments.indices.contains(flagIndex + 1) else {
                return nil
            }
            pdfURL = URL(fileURLWithPath: (arguments[flagIndex + 1] as NSString).expandingTildeInPath)
            sourceOnly = arguments.contains("--source-only")

            let groundTruthURL: URL?
            if let truthIndex = arguments.firstIndex(of: "--ground-truth"),
               arguments.indices.contains(truthIndex + 1) {
                groundTruthURL = URL(
                    fileURLWithPath: (arguments[truthIndex + 1] as NSString).expandingTildeInPath
                )
            } else {
                groundTruthURL = nil
            }
            self.groundTruthURL = groundTruthURL

            // A labelled run evaluates every labelled page by default. An
            // explicit --pages value can still cap a quick iteration.
            var pages = groundTruthURL == nil ? 12 : .max
            if let pagesIndex = arguments.firstIndex(of: "--pages"),
               arguments.indices.contains(pagesIndex + 1),
               let parsed = Int(arguments[pagesIndex + 1]), parsed > 0 {
                pages = parsed
            }
            sampleSize = pages

            if let outIndex = arguments.firstIndex(of: "--output"),
               arguments.indices.contains(outIndex + 1) {
                outputDirectory = URL(fileURLWithPath: (arguments[outIndex + 1] as NSString).expandingTildeInPath)
            } else {
                outputDirectory = nil
            }
        }
    }

    struct GroundTruth: Codable, Equatable {
        let schemaVersion: Int
        let document: String?
        /// Optional focused slice. Extraction still runs normally; precision,
        /// recall, and failure-atlas comparisons use only these kinds.
        let evaluatedKinds: [String]?
        let pages: [GroundTruthPage]
    }

    struct GroundTruthPage: Codable, Equatable {
        /// One-based PDF page number, matching what the reader displays.
        let pageNumber: Int
        let references: [BenchmarkReference]
        let notes: String?

        init(pageNumber: Int, references: [BenchmarkReference], notes: String? = nil) {
            self.pageNumber = pageNumber
            self.references = references
            self.notes = notes
        }
    }

    struct BenchmarkReference: Codable, Hashable, Equatable {
        let kind: String
        let number: String

        init(kind: String, number: String) {
            self.kind = kind.lowercased()
            self.number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        init(_ key: ReferenceKey) {
            self.init(kind: key.kind.rawValue, number: key.number)
        }

        var displayName: String { "\(kind) \(number)" }
    }

    struct EvaluationMetrics: Codable, Equatable {
        let system: String
        let truePositives: Int
        let falsePositives: Int
        let falseNegatives: Int
        let precision: Double
        let recall: Double
        let f1: Double
        let negativePages: Int
        let correctAbstentions: Int
        let falsePositivePages: Int
        let positivePages: Int
        let missedPositivePages: Int
    }

    struct FailureAtlasEntry: Codable, Equatable {
        let pageNumber: Int
        let category: String
        let details: String
    }

    /// Local report data for checking transcription fidelity against the exact
    /// PDF text. Kept out of the compact Markdown summary because source pages
    /// can be lengthy and their redistribution rights vary.
    struct ReferenceAudit: Codable, Equatable {
        let reference: String
        let contentOrigin: ReferenceContentOrigin
        let formattedBody: String
        let sourceExcerpt: String?
        let evidenceStatus: ReferenceGroundingStatus?
        let occurrenceCount: Int?
        let startOffset: Int?
        let endOffset: Int?
        let matchStartOffset: Int?
        let matchEndOffset: Int?
        let pageRegion: NormalizedRect?

        init(_ entry: IndexedReference, page: PDFPage? = nil) {
            reference = entry.reference.displayName
            contentOrigin = entry.contentOrigin
            formattedBody = entry.formattedBody
            sourceExcerpt = entry.evidence?.sourceExcerpt
            evidenceStatus = entry.evidence?.status
            occurrenceCount = entry.evidence?.occurrenceCount
            startOffset = entry.evidence?.startOffset
            endOffset = entry.evidence?.endOffset
            matchStartOffset = entry.evidence?.matchStartOffset
            matchEndOffset = entry.evidence?.matchEndOffset
            pageRegion = if let evidence = entry.evidence, let page {
                ReferenceEvidenceRegionResolver.exactRegion(for: evidence, on: page)
            } else {
                nil
            }
        }
    }

    struct PageReport: Codable {
        let pageNumber: Int
        let pageTextCharacters: Int
        let succeeded: Bool
        let error: String?
        let parsedCount: Int
        let modelAcceptedCount: Int
        let sourceFallbackCount: Int
        let keptCount: Int
        let seconds: Double
        let disposition: String
        let references: [String]
        let cacheMatched: [String]
        let cacheMissed: [String]
        let cacheExtra: [String]
        let detectorBaseline: [String]
        let declarationBaseline: [String]
        let expectedReferences: [String]?
        let supportedEvidenceCount: Int
        let uncertainEvidenceCount: Int
        let referenceAudit: [ReferenceAudit]
    }

    struct Summary: Codable {
        let pdfPath: String
        let indexingMode: String
        let pageCount: Int
        let sampledPages: Int
        let succeededPages: Int
        let failedPages: Int
        let emptyTextPages: Int
        let tableOfContentsPages: Int
        let noReferenceMentionPages: Int
        let noLikelyDeclarationPages: Int
        let modelInvokedPages: Int
        let totalParsed: Int
        let totalModelAccepted: Int
        let totalSourceFallbacks: Int
        let totalKept: Int
        let anchoredReferences: Int
        let unanchoredReferences: Int
        let modelAcceptanceRate: Double?
        let meanSecondsPerPage: Double
        let medianSecondsPerPage: Double
        let p95SecondsPerPage: Double
        let maxSecondsPerPage: Double
        let meanSecondsPerModelPage: Double
        let projectedFullBookMinutes: Double
        let cacheComparisonAvailable: Bool
        let cacheMatched: Int
        let cacheMissed: Int
        let cacheExtra: Int
        let recallVsCache: Double?
        let groundTruthPath: String?
        let evaluatedKinds: [String]?
        let evaluations: [EvaluationMetrics]
        let failureAtlas: [FailureAtlasEntry]
    }

    /// Deliberately nonisolated: the PDFDocument is created and consumed
    /// entirely off the main actor, matching LLMReferenceIndexBuilder.build.
    nonisolated static func run(config: Config) async -> Int32 {
        print("Cauchy reference-indexing benchmark (\(config.sourceOnly ? "source-only" : "Ollama model"))")
        print("PDF: \(config.pdfURL.path)")

        if !config.sourceOnly {
            await OllamaService.shared.refresh()
            switch OllamaCatalog.availability {
            case .available:
                break
            case .ollamaNotRunning:
                print("ERROR: Ollama is not running. Start it with `ollama serve`.")
                return 1
            case .ollamaNoModels:
                print("ERROR: Ollama has no chat model installed. Pull one with `ollama pull`.")
                return 1
            default:
                print("ERROR: Ollama is unavailable.")
                return 1
            }
        }

        guard let document = PDFDocument(url: config.pdfURL) else {
            print("ERROR: could not open PDF at \(config.pdfURL.path)")
            return 1
        }
        let pageCount = document.pageCount
        let groundTruth: GroundTruth?
        if let groundTruthURL = config.groundTruthURL {
            do {
                groundTruth = try loadGroundTruth(
                    from: groundTruthURL,
                    pageCount: pageCount,
                    documentURL: config.pdfURL
                )
                print("Ground truth: \(groundTruthURL.path) (\(groundTruth?.pages.count ?? 0) labelled pages)")
            } catch {
                print("ERROR: invalid ground truth: \(error.localizedDescription)")
                return 2
            }
        } else {
            groundTruth = nil
        }

        let cachedByPage = loadCacheEntriesByPage(for: config.pdfURL)
        if cachedByPage == nil {
            print("No existing reference-index cache found — running without comparison baseline.")
        } else {
            print("Found existing cache — comparing per page (note: the cache keeps one page per reference key, so per-page match counts are approximate).")
        }

        let sampled: [Int]
        if let groundTruth {
            sampled = Array(
                groundTruth.pages
                    .map { $0.pageNumber - 1 }
                    .sorted()
                    .prefix(config.sampleSize)
            )
            print("Pages: \(pageCount); evaluating \(sampled.count) labelled pages.")
        } else {
            let sampleCount = min(config.sampleSize, pageCount)
            var evenlySpaced: [Int] = []
            for i in 0..<sampleCount {
                let index = Int((Double(i) + 0.5) * Double(pageCount) / Double(sampleCount))
                if !evenlySpaced.contains(index) { evenlySpaced.append(index) }
            }
            sampled = evenlySpaced
            print("Pages: \(pageCount); sampling \(sampled.count) evenly spaced pages.")
        }

        let truthByPage = Dictionary(
            uniqueKeysWithValues: (groundTruth?.pages ?? []).map {
                ($0.pageNumber - 1, Set($0.references))
            }
        )

        var reports: [PageReport] = []
        var model: any LanguageModel = OllamaLanguageModel(modelName: "")
        if !config.sourceOnly {
            guard let modelID = OllamaCatalog.defaultModelID else {
                print("ERROR: no local Ollama model is selected.")
                return 1
            }
            model = OllamaLanguageModel(modelName: modelID)
        }

        for pageIndex in sampled {
            let started = Date()
            let sourceText = document.page(at: pageIndex)?.string ?? ""
            let detector = detectorBaseline(in: sourceText)
            let declaration = declarationBaseline(in: sourceText)
            let expected = truthByPage[pageIndex]?.map(\.displayName).sorted()
            do {
                let result: LLMReferenceIndexBuilder.SinglePageResult
                if config.sourceOnly {
                    result = LLMReferenceIndexBuilder.indexSinglePageFromSource(
                        from: document,
                        pageIndex: pageIndex
                    )
                } else {
                    result = try await LLMReferenceIndexBuilder.indexSinglePage(
                        from: document,
                        pageIndex: pageIndex,
                        model: model
                    )
                }
                let seconds = Date().timeIntervalSince(started)
                let found = result.entries.keys.map(display).sorted()
                let cached = (cachedByPage?[pageIndex] ?? []).map(display).sorted()
                let matched = found.filter(cached.contains)
                let supported = result.entries.values.filter { $0.evidence?.status == .supported }.count
                let uncertain = result.entries.values.filter { $0.evidence?.status == .uncertain }.count
                let report = PageReport(
                    pageNumber: pageIndex + 1,
                    pageTextCharacters: result.pageTextCharacters,
                    succeeded: true,
                    error: nil,
                    parsedCount: result.parsedCount,
                    modelAcceptedCount: result.modelAcceptedCount,
                    sourceFallbackCount: result.sourceFallbackCount,
                    keptCount: result.entries.count,
                    seconds: seconds,
                    disposition: result.disposition.rawValue,
                    references: found,
                    cacheMatched: matched,
                    cacheMissed: cached.filter { !found.contains($0) },
                    cacheExtra: found.filter { !cached.contains($0) },
                    detectorBaseline: detector.map(\.displayName).sorted(),
                    declarationBaseline: declaration.map(\.displayName).sorted(),
                    expectedReferences: expected,
                    supportedEvidenceCount: supported,
                    uncertainEvidenceCount: uncertain,
                    referenceAudit: result.entries.values
                        .map { ReferenceAudit($0, page: document.page(at: pageIndex)) }
                        .sorted { $0.reference < $1.reference }
                )
                reports.append(report)
                print(String(format: "  p.%-4d %5.1fs  model %2d/%2d, source %2d, total %2d  %@",
                             pageIndex + 1, seconds, result.modelAcceptedCount, result.parsedCount,
                             result.sourceFallbackCount, result.entries.count,
                             found.joined(separator: ", ")))
            } catch {
                let seconds = Date().timeIntervalSince(started)
                reports.append(PageReport(
                    pageNumber: pageIndex + 1,
                    pageTextCharacters: 0,
                    succeeded: false,
                    error: String(describing: error),
                    parsedCount: 0,
                    modelAcceptedCount: 0,
                    sourceFallbackCount: 0,
                    keptCount: 0,
                    seconds: seconds,
                    disposition: "failed",
                    references: [],
                    cacheMatched: [],
                    cacheMissed: (cachedByPage?[pageIndex] ?? []).map(display).sorted(),
                    cacheExtra: [],
                    detectorBaseline: detector.map(\.displayName).sorted(),
                    declarationBaseline: declaration.map(\.displayName).sorted(),
                    expectedReferences: expected,
                    supportedEvidenceCount: 0,
                    uncertainEvidenceCount: 0,
                    referenceAudit: []
                ))
                print("  p.\(pageIndex + 1)  FAILED after \(String(format: "%.1f", seconds))s: \(error)")
            }
        }

        let summary = makeSummary(
            config: config,
            pageCount: pageCount,
            reports: reports,
            hasCache: cachedByPage != nil,
            groundTruthURL: config.groundTruthURL,
            evaluatedKinds: groundTruth?.evaluatedKinds
        )
        var wroteReport = true
        do {
            let directory = try writeReports(summary: summary, pages: reports, config: config)
            print("\nReport written to \(directory.path)")
        } catch {
            print("ERROR: could not write report files: \(error)")
            wroteReport = false
        }
        printSummary(summary)
        return wroteReport && reports.allSatisfy(\.succeeded) ? 0 : 1
    }

    /// `Cauchy --probe-retrieval <pdf> <query>`: builds the lexical index and
    /// prints the passages an ask would retrieve — a headless check of the
    /// retrieval pipeline.
    /// Prints exactly what ask-time retrieval would feed the assistant for the
    /// query: PDF source excerpts (with the route that surfaced each) and fused
    /// passages. Excerpts come from the on-disk reference cache only — the
    /// probe never spends model calls indexing.
    nonisolated static func runRetrievalProbe(pdfPath: String, query: String) async -> Int32 {
        let url = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        guard let index = LexicalDocumentIndex.build(documentURL: url) else {
            print("ERROR: could not build lexical index for \(url.path)")
            return 1
        }

        var snapshot: DocumentReferenceIndexSnapshot?
        if let fingerprint = try? ReferenceIndexCacheStore.fingerprint(for: url),
           let cached = try? ReferenceIndexCacheStore.load(fingerprint: fingerprint) {
            let entries = cached.asSnapshot(pageCount: 0).entries
            snapshot = DocumentReferenceIndexSnapshot(
                entries: entries,
                pageCount: 0,
                bodyEmbeddings: DocumentReferenceIndexSnapshot.computeBodyEmbeddings(for: entries)
            )
        }

        let (retrieval, candidates) = await MainActor.run { () -> (AskRetrieval, [(heading: String, similarity: Double)]) in
            let referenceIndex = DocumentReferenceIndex()
            if let snapshot {
                referenceIndex.replace(with: snapshot)
            }
            let retrieval = AskContextRetriever.retrieve(
                question: query,
                selectedText: "",
                surroundingText: "",
                pageIndex: nil,
                referenceIndex: referenceIndex,
                documentIndex: index,
                passageLimit: 5
            )
            let candidates = SentenceEmbedder.queryVector(for: query)
                .map { referenceIndex.semanticCandidates(for: $0, limit: 5) } ?? []
            return (retrieval, candidates)
        }

        print("Query: \(query)")
        if snapshot == nil {
            print("(no reference-index cache for this PDF — statements unavailable; open it in Cauchy once to index it)")
        }
        print("\nPDF source excerpts (\(retrieval.statements.count)):")
        for (statement, route) in zip(retrieval.statements, retrieval.statementRoutes) {
            print("\n[\(route)] \(statement.prefix(500))")
        }
        if !candidates.isEmpty {
            print("\nTop semantic statement candidates (raw cosine, before gating):")
            for candidate in candidates {
                print(String(format: "  %.4f  %@", candidate.similarity, candidate.heading))
            }
        }
        print("\nFused passages (\(retrieval.passages.count)):")
        let sourceDocument = PDFDocument(url: url)
        for (i, record) in retrieval.passageRecords.enumerated() {
            print("\n#\(i + 1) \(record.text.prefix(400))")
            if let source = record.location,
               let page = sourceDocument?.page(at: source.pageIndex),
               let region = ReferenceEvidenceRegionResolver.exactRegion(
                   matchedText: source.matchedText,
                   startOffset: source.startOffset,
                   endOffset: source.endOffset,
                   on: page
               ) {
                print(String(
                    format: "   exact PDF text region: p.%d x=%.3f y=%.3f w=%.3f h=%.3f",
                    source.pageIndex + 1,
                    Double(region.x), Double(region.y),
                    Double(region.width), Double(region.height)
                ))
            } else {
                print("   exact PDF text region: unresolved")
            }
        }
        return 0
    }

    /// `Cauchy --probe-mentions <pdf> <kind> <number> <defining-page>`:
    /// inspect local citation edges without launching the reader or a model.
    nonisolated static func runMentionProbe(
        pdfPath: String,
        kind: String,
        number: String,
        definingPage: Int,
        jsonOutput: Bool = false
    ) -> Int32 {
        guard let referenceKind = ReferenceKind(rawValue: kind.lowercased()),
              definingPage > 0 else {
            print("ERROR: use --probe-mentions <pdf> <kind> <number> <defining-page>")
            return 2
        }
        let url = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        do {
            let result = try ReferenceMentionFinder.find(
                documentURL: url,
                reference: DetectedReference(kind: referenceKind, number: number),
                after: definingPage - 1
            )
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                return 0
            }
            for mention in result.mentions {
                print(String(format: "p.%-4d x=%.3f y=%.3f  %@",
                             mention.pageIndex + 1,
                             Double(mention.region.x), Double(mention.region.y),
                             mention.context))
            }
            print("\(result.mentions.count) anchored later mention(s); \(result.unresolvedMatches) unlocated; \(result.pagesWithoutText) page(s) without searchable text.")
            return 0
        } catch {
            print("ERROR: \(error.localizedDescription)")
            return 1
        }
    }

    /// `Cauchy --probe-graph <pdf> <reference-labels.json> [--json]` builds
    /// all labelled nodes' later citation edges in one pass over the PDF.
    nonisolated static func runGraphProbe(
        pdfPath: String,
        groundTruthPath: String,
        jsonOutput: Bool = false
    ) -> Int32 {
        let pdfURL = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        let truthURL = URL(fileURLWithPath: (groundTruthPath as NSString).expandingTildeInPath)
        guard let document = PDFDocument(url: pdfURL) else {
            print("ERROR: could not open PDF at \(pdfURL.path)")
            return 1
        }
        do {
            let truth = try loadGroundTruth(
                from: truthURL,
                pageCount: document.pageCount,
                documentURL: pdfURL
            )
            let definitions = truth.pages.flatMap { page in
                page.references.compactMap { reference -> ReferenceGraphDefinition? in
                    guard let kind = ReferenceKind(rawValue: reference.kind) else { return nil }
                    return ReferenceGraphDefinition(
                        reference: DetectedReference(kind: kind, number: reference.number),
                        pageIndex: page.pageNumber - 1,
                        definingEndOffset: nil
                    )
                }
            }
            let graph = try ReferenceMentionFinder.buildGraph(
                documentURL: pdfURL,
                definitions: definitions
            )
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(graph), as: UTF8.self))
            } else {
                for record in graph.records where !record.result.mentions.isEmpty {
                    let pages = record.result.mentions.map { String($0.pageIndex + 1) }
                        .joined(separator: ", ")
                    print("\(record.definition.reference.displayName): p. \(pages)")
                }
                print("\(graph.records.count) nodes; \(graph.records.reduce(0) { $0 + $1.result.mentions.count }) anchored edges; SHA-256 \(graph.documentFingerprint)")
            }
            return 0
        } catch {
            print("ERROR: \(error.localizedDescription)")
            return 2
        }
    }

    /// Exercises the app's existing local Vision OCR runtime on one PDF page.
    /// This is diagnostic only: it does not treat OCR text as verified source
    /// evidence or silently enable scanned-page indexing.
    nonisolated static func runOCRProbe(
        pdfPath: String,
        pageNumber: Int,
        useFastRecognition: Bool,
        jsonOutput: Bool = false,
        overlayDirectory: String? = nil
    ) async -> Int32 {
        let url = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        guard let document = PDFDocument(url: url),
              pageNumber > 0, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1),
              let image = PDFRegionRenderer.renderFullPage(page) else {
            print("ERROR: could not render page \(pageNumber) from \(url.path)")
            return 1
        }
        do {
            let result = try await OCRService.shared.recognizeText(
                in: image,
                useFastRecognition: useFastRecognition
            )
            let candidates = OCRReferenceCandidateDetector.candidates(in: result)
            if let overlayDirectory {
                let directory = URL(fileURLWithPath: overlayDirectory, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                for (index, candidate) in candidates.enumerated() {
                    guard let rendered = PDFRegionRenderer.render(
                        page: page,
                        bounds: ReferenceEvidenceRegionResolver.contextRegion(for: candidate.region),
                        highlight: candidate.region.cgRect(in: page.bounds(for: .mediaBox))
                    ) else { continue }
                    let filename = String(format: "%02d-%@-%@.png",
                                          index + 1, candidate.kind, candidate.number)
                    try PDFRegionRenderer.saveThumbnail(
                        rendered,
                        to: directory.appendingPathComponent(filename)
                    )
                }
            }
            if jsonOutput {
                struct Report: Codable {
                    let pageNumber: Int
                    let mode: String
                    let characterCount: Int
                    let candidates: [OCRReferenceCandidate]
                }
                let report = Report(
                    pageNumber: pageNumber,
                    mode: useFastRecognition ? "fast" : "accurate",
                    characterCount: result.rawText.count,
                    candidates: candidates
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
                return 0
            }
            print("\(useFastRecognition ? "Fast" : "Accurate") OCR page \(pageNumber) (\(result.rawText.count) characters):")
            print(result.rawText)
            print("\nAnchored declaration candidates:")
            if candidates.isEmpty {
                print("(none)")
            } else {
                for candidate in candidates {
                    print("\(candidate.kind) \(candidate.number) · confidence \(String(format: "%.3f", candidate.confidence))")
                }
            }
            return 0
        } catch {
            print("ERROR: \(useFastRecognition ? "fast" : "accurate") on-device OCR failed: \(error)")
            return 2
        }
    }

    /// Diagnostic image-only extraction check. It never populates the trusted
    /// reference index; the image model's output needs independent labels and
    /// resolvable page-region evidence before it can be used in production.
    @MainActor
    static func runVisionProbe(pdfPath: String, pageNumber: Int) async -> Int32 {
        let url = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        guard let document = PDFDocument(url: url),
              pageNumber > 0, pageNumber <= document.pageCount,
              document.page(at: pageNumber - 1) != nil else {
            print("ERROR: could not read page \(pageNumber) from \(url.path)")
            return 1
        }
        await OllamaService.shared.refresh()
        guard case .available = OllamaCatalog.availability else {
            print("ERROR: Ollama is not running or has no model installed")
            return 2
        }
        guard let modelID = OllamaCatalog.visionModelID else {
            print("ERROR: no installed Ollama model reports vision support")
            return 2
        }
        guard let page = document.page(at: pageNumber - 1),
              let image = PDFRegionRenderer.renderFullPage(page),
              let png = pngData(from: image) else {
            print("ERROR: could not render page \(pageNumber) from \(url.path)")
            return 1
        }

        do {
            let answer = try await OllamaClient.text(
                model: modelID,
                prompt: CloudPrompt(
                    instructions: "Read the supplied page image. Do not invent text that is not visible.",
                    prompt: "List only numbered definitions, theorems, lemmas, propositions, corollaries, examples, remarks, and displayed equations that are introduced on this page. Exclude citations. One KIND NUMBER per line. If uncertain, say uncertain.",
                    imagePNG: png
                )
            )
            print("Vision page \(pageNumber) (\(modelID)):")
            print(answer)
            return 0
        } catch {
            print("ERROR: Ollama image understanding failed: \(error.localizedDescription)")
            return 3
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - Helpers

    private static func display(_ key: ReferenceKey) -> String {
        "\(key.kind.rawValue) \(key.number)"
    }

    enum GroundTruthError: LocalizedError {
        case unsupportedSchema(Int)
        case pageOutOfRange(Int)
        case duplicatePage(Int)
        case unknownKind(String, Int)
        case duplicateReference(String, Int)
        case invalidEvaluatedKinds
        case documentMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                "Unsupported ground-truth schema version \(version); expected 1."
            case .pageOutOfRange(let page):
                "Labelled page \(page) is outside this PDF."
            case .duplicatePage(let page):
                "Page \(page) appears more than once in ground truth."
            case .unknownKind(let kind, let page):
                "Unknown reference kind '\(kind)' on page \(page)."
            case .duplicateReference(let reference, let page):
                "Duplicate reference '\(reference)' on page \(page)."
            case .invalidEvaluatedKinds:
                "evaluatedKinds must contain distinct, known reference kinds and include every labelled reference kind."
            case .documentMismatch(let expected, let actual):
                "Ground truth belongs to SHA-256 \(expected), but this PDF is \(actual)."
            }
        }
    }

    static func loadGroundTruth(
        from url: URL,
        pageCount: Int,
        documentURL: URL? = nil
    ) throws -> GroundTruth {
        let truth = try JSONDecoder().decode(GroundTruth.self, from: Data(contentsOf: url))
        guard truth.schemaVersion == 1 else {
            throw GroundTruthError.unsupportedSchema(truth.schemaVersion)
        }
        if let kinds = truth.evaluatedKinds {
            guard !kinds.isEmpty,
                  Set(kinds).count == kinds.count,
                  kinds.allSatisfy({ ReferenceKind(rawValue: $0) != nil }),
                  truth.pages.flatMap(\.references).allSatisfy({ kinds.contains($0.kind) }) else {
                throw GroundTruthError.invalidEvaluatedKinds
            }
        }
        if let documentURL,
           let expected = truth.document?
            .split(separator: ";")
            .first(where: { $0.hasPrefix("sha256:") })?
            .dropFirst("sha256:".count) {
            let actual = try ReferenceIndexCacheStore.fingerprint(for: documentURL)
            guard String(expected).lowercased() == actual else {
                throw GroundTruthError.documentMismatch(expected: String(expected), actual: actual)
            }
        }
        var seenPages = Set<Int>()
        for page in truth.pages {
            guard (1...pageCount).contains(page.pageNumber) else {
                throw GroundTruthError.pageOutOfRange(page.pageNumber)
            }
            guard seenPages.insert(page.pageNumber).inserted else {
                throw GroundTruthError.duplicatePage(page.pageNumber)
            }
            var seenReferences = Set<BenchmarkReference>()
            for reference in page.references {
                guard ReferenceKind(rawValue: reference.kind) != nil else {
                    throw GroundTruthError.unknownKind(reference.kind, page.pageNumber)
                }
                guard seenReferences.insert(reference).inserted else {
                    throw GroundTruthError.duplicateReference(reference.displayName, page.pageNumber)
                }
            }
        }
        return truth
    }

    /// High-recall baseline: every syntactic mention, including citations.
    static func detectorBaseline(in sourceText: String) -> Set<BenchmarkReference> {
        Set(ReferenceDetector.allReferences(in: sourceText).map { BenchmarkReference($0.reference.key) })
    }

    /// No-model declaration heuristic. Named results are accepted when the
    /// heading begins a line; numbered equations require strong equation-like
    /// symbols on the numbered line or in a preceding display. It is deliberately
    /// simple and reproducible, providing
    /// a useful precision-oriented baseline rather than pretending to be truth.
    static func declarationBaseline(in sourceText: String) -> Set<BenchmarkReference> {
        Set(LLMReferenceIndexSupport.declarationMatches(in: sourceText).map {
            BenchmarkReference($0.reference.key)
        })
    }

    static func evaluate(
        system: String,
        predictionsByPage: [Int: Set<BenchmarkReference>],
        truthByPage: [Int: Set<BenchmarkReference>],
        pageIndices: [Int]
    ) -> EvaluationMetrics {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var negativePages = 0
        var correctAbstentions = 0
        var falsePositivePages = 0
        var positivePages = 0
        var missedPositivePages = 0

        for pageIndex in pageIndices {
            let truth = truthByPage[pageIndex] ?? []
            let predictions = predictionsByPage[pageIndex] ?? []
            truePositives += predictions.intersection(truth).count
            falsePositives += predictions.subtracting(truth).count
            falseNegatives += truth.subtracting(predictions).count

            if truth.isEmpty {
                negativePages += 1
                if predictions.isEmpty { correctAbstentions += 1 }
                else { falsePositivePages += 1 }
            } else {
                positivePages += 1
                if predictions.isEmpty { missedPositivePages += 1 }
            }
        }

        let precisionDenominator = truePositives + falsePositives
        let recallDenominator = truePositives + falseNegatives
        let precision = precisionDenominator == 0 ? 1 : Double(truePositives) / Double(precisionDenominator)
        let recall = recallDenominator == 0 ? 1 : Double(truePositives) / Double(recallDenominator)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        return EvaluationMetrics(
            system: system,
            truePositives: truePositives,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives,
            precision: precision,
            recall: recall,
            f1: f1,
            negativePages: negativePages,
            correctAbstentions: correctAbstentions,
            falsePositivePages: falsePositivePages,
            positivePages: positivePages,
            missedPositivePages: missedPositivePages
        )
    }

    private static func loadCacheEntriesByPage(for url: URL) -> [Int: [ReferenceKey]]? {
        guard let fingerprint = try? ReferenceIndexCacheStore.fingerprint(for: url),
              let cached = try? ReferenceIndexCacheStore.load(fingerprint: fingerprint) else {
            return nil
        }
        var byPage: [Int: [ReferenceKey]] = [:]
        for entry in cached.entries {
            guard let kind = ReferenceKind(rawValue: entry.kind) else { continue }
            byPage[entry.pageIndex, default: []].append(ReferenceKey(kind: kind, number: entry.number))
        }
        return byPage
    }

    private static func makeSummary(
        config: Config,
        pageCount: Int,
        reports: [PageReport],
        hasCache: Bool,
        groundTruthURL: URL?,
        evaluatedKinds: [String]?
    ) -> Summary {
        let succeeded = reports.filter(\.succeeded)
        let processed = succeeded.filter {
            $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.processed.rawValue ||
                $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.contextOverflowSourceFallback.rawValue
        }
        let totalParsed = reports.reduce(0) { $0 + $1.parsedCount }
        let totalModelAccepted = reports.reduce(0) { $0 + $1.modelAcceptedCount }
        let totalSourceFallbacks = reports.reduce(0) { $0 + $1.sourceFallbackCount }
        let totalKept = reports.reduce(0) { $0 + $1.keptCount }
        let anchoredReferences = reports.reduce(0) { count, report in
            count + report.referenceAudit.filter { $0.pageRegion != nil }.count
        }
        let durations = succeeded.map(\.seconds).sorted()
        let modelDurations = processed.map(\.seconds).sorted()
        let meanSeconds = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        let meanModelSeconds = modelDurations.isEmpty
            ? 0
            : modelDurations.reduce(0, +) / Double(modelDurations.count)
        let matched = reports.reduce(0) { $0 + $1.cacheMatched.count }
        let missed = reports.reduce(0) { $0 + $1.cacheMissed.count }
        let extra = reports.reduce(0) { $0 + $1.cacheExtra.count }
        let pageIndices = reports.map { $0.pageNumber - 1 }
        let truthByPage: [Int: Set<BenchmarkReference>] = Dictionary(
            uniqueKeysWithValues: reports.compactMap { report in
                report.expectedReferences.map { expected in
                    (
                        report.pageNumber - 1,
                        Set(expected.compactMap(parseDisplayReference))
                    )
                }
            }
        )
        let evaluations: [EvaluationMetrics]
        if groundTruthURL != nil {
            let allowedKinds = evaluatedKinds.map(Set.init)
            func scoped(_ values: [String]) -> Set<BenchmarkReference> {
                Set(values.compactMap(parseDisplayReference).filter {
                    allowedKinds?.contains($0.kind) ?? true
                })
            }
            let current = Dictionary(uniqueKeysWithValues: reports.map {
                ($0.pageNumber - 1, scoped($0.references))
            })
            let detector = Dictionary(uniqueKeysWithValues: reports.map {
                ($0.pageNumber - 1, scoped($0.detectorBaseline))
            })
            let declaration = Dictionary(uniqueKeysWithValues: reports.map {
                ($0.pageNumber - 1, scoped($0.declarationBaseline))
            })
            evaluations = [
                evaluate(system: config.sourceOnly ? "Source-only extractor" : "Cauchy production extractor", predictionsByPage: current, truthByPage: truthByPage, pageIndices: pageIndices),
                evaluate(system: "All syntactic mentions", predictionsByPage: detector, truthByPage: truthByPage, pageIndices: pageIndices),
                evaluate(system: "Declaration heuristic", predictionsByPage: declaration, truthByPage: truthByPage, pageIndices: pageIndices),
            ]
        } else {
            evaluations = []
        }

        let failureAtlas = makeFailureAtlas(reports: reports, evaluatedKinds: evaluatedKinds)

        return Summary(
            pdfPath: config.pdfURL.path,
            indexingMode: config.sourceOnly ? "source-only" : "Ollama model",
            pageCount: pageCount,
            sampledPages: reports.count,
            succeededPages: succeeded.count,
            failedPages: reports.count - succeeded.count,
            emptyTextPages: succeeded.filter { $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.emptyText.rawValue }.count,
            tableOfContentsPages: succeeded.filter { $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.likelyTableOfContents.rawValue }.count,
            noReferenceMentionPages: succeeded.filter { $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.noReferenceMentions.rawValue }.count,
            noLikelyDeclarationPages: succeeded.filter { $0.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.noLikelyDeclarations.rawValue }.count,
            modelInvokedPages: processed.count,
            totalParsed: totalParsed,
            totalModelAccepted: totalModelAccepted,
            totalSourceFallbacks: totalSourceFallbacks,
            totalKept: totalKept,
            anchoredReferences: anchoredReferences,
            unanchoredReferences: totalKept - anchoredReferences,
            modelAcceptanceRate: totalParsed > 0
                ? Double(totalModelAccepted) / Double(totalParsed)
                : nil,
            meanSecondsPerPage: meanSeconds,
            medianSecondsPerPage: percentile(0.5, in: durations),
            p95SecondsPerPage: percentile(0.95, in: durations),
            maxSecondsPerPage: durations.last ?? 0,
            meanSecondsPerModelPage: meanModelSeconds,
            projectedFullBookMinutes: meanSeconds * Double(pageCount)
                / Double(LLMReferenceIndexBuilder.maxConcurrentPagesOnDevice) / 60,
            cacheComparisonAvailable: hasCache,
            cacheMatched: matched,
            cacheMissed: missed,
            cacheExtra: extra,
            recallVsCache: hasCache && (matched + missed) > 0
                ? Double(matched) / Double(matched + missed)
                : nil,
            groundTruthPath: groundTruthURL?.path,
            evaluatedKinds: evaluatedKinds,
            evaluations: evaluations,
            failureAtlas: failureAtlas
        )
    }

    private static func parseDisplayReference(_ display: String) -> BenchmarkReference? {
        guard let separator = display.firstIndex(of: " ") else { return nil }
        return BenchmarkReference(
            kind: String(display[..<separator]),
            number: String(display[display.index(after: separator)...])
        )
    }

    private static func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sortedValues[lower] }
        let fraction = position - Double(lower)
        return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * fraction
    }

    private static func makeFailureAtlas(
        reports: [PageReport],
        evaluatedKinds: [String]?
    ) -> [FailureAtlasEntry] {
        var failures: [FailureAtlasEntry] = []
        for report in reports {
            let scopedAudit = report.referenceAudit.filter { audit in
                guard let evaluatedKinds else { return true }
                return parseDisplayReference(audit.reference).map {
                    evaluatedKinds.contains($0.kind)
                } ?? false
            }
            if !report.succeeded {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "extraction_failed",
                    details: report.error ?? "Unknown extraction error"
                ))
            }
            if let expected = report.expectedReferences {
                let predictedSet = Set(report.references.filter { display in
                    guard let evaluatedKinds else { return true }
                    return parseDisplayReference(display).map { evaluatedKinds.contains($0.kind) } ?? false
                })
                let expectedSet = Set(expected)
                let falsePositives = predictedSet.subtracting(expectedSet).sorted()
                let falseNegatives = expectedSet.subtracting(predictedSet).sorted()
                if !falsePositives.isEmpty {
                    failures.append(FailureAtlasEntry(
                        pageNumber: report.pageNumber,
                        category: "false_positive",
                        details: falsePositives.joined(separator: ", ")
                    ))
                }
                if !falseNegatives.isEmpty {
                    failures.append(FailureAtlasEntry(
                        pageNumber: report.pageNumber,
                        category: "false_negative",
                        details: falseNegatives.joined(separator: ", ")
                    ))
                }
            }
            if report.parsedCount > report.modelAcceptedCount {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "rejected_by_validation",
                    details: "\(report.parsedCount - report.modelAcceptedCount) model result(s) not retained after declaration, grounding, formatting, or deduplication checks"
                ))
            }
            if report.disposition == LLMReferenceIndexBuilder.SinglePageResult.Disposition.contextOverflowSourceFallback.rawValue {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "model_context_overflow",
                    details: "On-device formatting exceeded its context window; Cauchy retained source-backed declaration fallbacks instead"
                ))
            }
            let ocrCandidateCount = scopedAudit.filter {
                $0.contentOrigin == .ocrCandidate
            }.count
            let ambiguousTextEvidenceCount = scopedAudit.filter {
                $0.evidenceStatus == .uncertain && $0.contentOrigin != .ocrCandidate
            }.count
            if ocrCandidateCount > 0 {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "unverified_ocr_candidate",
                    details: "\(ocrCandidateCount) region-anchored OCR candidate(s) require page verification and are excluded from answer grounding"
                ))
            }
            if ambiguousTextEvidenceCount > 0 {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "ambiguous_evidence",
                    details: "\(ambiguousTextEvidenceCount) accepted reference(s) have multiple matching source occurrences"
                ))
            }
            let unanchored = scopedAudit.filter { $0.pageRegion == nil }
            if !unanchored.isEmpty {
                failures.append(FailureAtlasEntry(
                    pageNumber: report.pageNumber,
                    category: "unresolved_page_region",
                    details: unanchored.map(\.reference).joined(separator: ", ")
                ))
            }
        }
        return failures
    }

    private static func projectedDuration(_ minutes: Double) -> String {
        minutes > 0 && minutes < 1 ? "<1 min" : String(format: "%.0f min", minutes)
    }

    private static func printSummary(_ s: Summary) {
        print("""

        ── Summary ─────────────────────────────────────────
        Sampled pages:        \(s.sampledPages) of \(s.pageCount)
        Skipped before model: \(s.emptyTextPages) empty, \(s.tableOfContentsPages) contents, \(s.noReferenceMentionPages) without mentions, \(s.noLikelyDeclarationPages) citation-only
        Model invoked:        \(s.modelInvokedPages) pages (mean \(String(format: "%.1fs", s.meanSecondsPerModelPage)))
        Succeeded / failed:   \(s.succeededPages) / \(s.failedPages)
        Model outputs:        \(s.totalParsed)
        Model accepted:       \(s.totalModelAccepted) (\(s.modelAcceptanceRate.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"))
        Source fallbacks:     \(s.totalSourceFallbacks)
        Total references:     \(s.totalKept)
        Page regions:         \(s.anchoredReferences) located / \(s.unanchoredReferences) unresolved
        End-to-end latency:   median \(String(format: "%.1fs", s.medianSecondsPerPage)), p95 \(String(format: "%.1fs", s.p95SecondsPerPage)), max \(String(format: "%.1fs", s.maxSecondsPerPage))
        Mean time per page:   \(String(format: "%.1fs", s.meanSecondsPerPage)) (including skips)
        Projected full book:  \(projectedDuration(s.projectedFullBookMinutes)) (at concurrency \(LLMReferenceIndexBuilder.maxConcurrentPagesOnDevice))
        """)
        if s.cacheComparisonAvailable {
            let recall = s.recallVsCache.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
            print("""
            Vs existing cache:    matched \(s.cacheMatched), missed \(s.cacheMissed), extra \(s.cacheExtra) (recall \(recall))
            """)
        }
        if !s.evaluations.isEmpty {
            print("\n── Labelled evaluation ─────────────────────────────")
            if let kinds = s.evaluatedKinds {
                print("Evaluated kinds: \(kinds.joined(separator: ", ")) (other extracted kinds excluded from scoring)")
            }
            for metric in s.evaluations {
                print(String(
                    format: "%-29@  P %.1f%%  R %.1f%%  F1 %.1f%%  TP %d FP %d FN %d",
                    metric.system as NSString,
                    metric.precision * 100,
                    metric.recall * 100,
                    metric.f1 * 100,
                    metric.truePositives,
                    metric.falsePositives,
                    metric.falseNegatives
                ))
            }
            print("Failure atlas entries: \(s.failureAtlas.count)")
        }
    }

    private static func writeReports(summary: Summary, pages: [PageReport], config: Config) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = config.outputDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cauchy/benchmarks/\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct FullReport: Codable {
            let summary: Summary
            let pages: [PageReport]
        }
        try encoder.encode(FullReport(summary: summary, pages: pages))
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)

        var md = """
        # Reference Indexing Benchmark (\(summary.indexingMode))

        PDF: `\(summary.pdfPath)` (\(summary.pageCount) pages)

        Evaluated kinds: \(summary.evaluatedKinds?.joined(separator: ", ") ?? "all")

        | Page | Disposition | Chars | Time | Model accepted | Source fallbacks | Total | Evidence | References | Expected |
        |-----:|-------------|------:|-----:|---------------:|-----------------:|------:|----------|------------|----------|

        """
        for page in pages {
            let refs = page.references.isEmpty ? "—" : page.references.joined(separator: ", ")
            let expected = page.expectedReferences?.isEmpty == false
                ? page.expectedReferences!.joined(separator: ", ")
                : "—"
            let status = page.succeeded ? String(format: "%.1fs", page.seconds) : "FAIL"
            let evidence = "\(page.supportedEvidenceCount) supported / \(page.uncertainEvidenceCount) uncertain"
            md += "| \(page.pageNumber) | \(page.disposition) | \(page.pageTextCharacters) | \(status) | \(page.modelAcceptedCount)/\(page.parsedCount) | \(page.sourceFallbackCount) | \(page.keptCount) | \(evidence) | \(refs) | \(expected) |\n"
        }
        md += """

        - Succeeded/failed pages: \(summary.succeededPages)/\(summary.failedPages)
        - Skipped before model: \(summary.emptyTextPages) empty text, \(summary.tableOfContentsPages) likely contents, \(summary.noReferenceMentionPages) without reference mentions, \(summary.noLikelyDeclarationPages) citation-only pages
        - Model invoked on \(summary.modelInvokedPages) pages; mean model-invoked page time: \(String(format: "%.1fs", summary.meanSecondsPerModelPage))
        - Model acceptance rate: \(summary.modelAcceptanceRate.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"); source fallbacks: \(summary.totalSourceFallbacks)
        - Original-page regions: \(summary.anchoredReferences) located / \(summary.unanchoredReferences) unresolved
        - End-to-end page latency including skips: median \(String(format: "%.1fs", summary.medianSecondsPerPage)), p95 \(String(format: "%.1fs", summary.p95SecondsPerPage)), max \(String(format: "%.1fs", summary.maxSecondsPerPage))
        - Mean seconds/page including skips: \(String(format: "%.1f", summary.meanSecondsPerPage)); projected full book at this corpus mix: \(projectedDuration(summary.projectedFullBookMinutes))
        """
        if summary.cacheComparisonAvailable {
            let recall = summary.recallVsCache.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
            md += "\n- Vs cache: matched \(summary.cacheMatched), missed \(summary.cacheMissed), extra \(summary.cacheExtra) (recall \(recall))\n"
        }
        if !summary.evaluations.isEmpty {
            md += """

            ## Labelled evaluation

            | System | Precision | Recall | F1 | TP | FP | FN | Correct abstentions | Missed positive pages |
            |--------|----------:|-------:|---:|---:|---:|---:|--------------------:|----------------------:|

            """
            for metric in summary.evaluations {
                md += "| \(metric.system) | \(percent(metric.precision)) | \(percent(metric.recall)) | \(percent(metric.f1)) | \(metric.truePositives) | \(metric.falsePositives) | \(metric.falseNegatives) | \(metric.correctAbstentions)/\(metric.negativePages) | \(metric.missedPositivePages)/\(metric.positivePages) |\n"
            }

            md += """

            ## Failure atlas

            """
            if summary.failureAtlas.isEmpty {
                md += "No extraction, grounding, or labelled accuracy failures on the evaluated pages.\n"
            } else {
                for failure in summary.failureAtlas {
                    md += "- **Page \(failure.pageNumber) · \(failure.category):** \(failure.details)\n"
                }
            }

            md += """

            ## Baseline predictions

            | Page | All syntactic mentions | Declaration heuristic |
            |-----:|------------------------|-----------------------|

            """
            for page in pages {
                let detector = page.detectorBaseline.isEmpty ? "—" : page.detectorBaseline.joined(separator: ", ")
                let declaration = page.declarationBaseline.isEmpty ? "—" : page.declarationBaseline.joined(separator: ", ")
                md += "| \(page.pageNumber) | \(detector) | \(declaration) |\n"
            }
        }
        for page in pages where page.error != nil {
            md += "\n**Page \(page.pageNumber) error:** \(page.error!)\n"
        }
        try md.data(using: .utf8)?
            .write(to: directory.appendingPathComponent("report.md"), options: .atomic)
        return directory
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
