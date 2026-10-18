import AppKit
import PDFKit
import XCTest
@testable import Cauchy

final class AssistantResponseValidatorTests: XCTestCase {
    func testEvidenceBoundaryParsesAndHidesValidTrailer() {
        let parsed = AssistantAnswerBoundary.parse("A claim from the notes.\n\n[[CAUCHY_BASIS: PDF]]")

        XCTAssertEqual(parsed.content, "A claim from the notes.")
        XCTAssertEqual(parsed.basis, .pdf)
    }

    func testEvidenceBoundaryDoesNotTrustInvalidOrMissingTrailer() {
        let invalid = AssistantAnswerBoundary.parse("A claim.\n[[CAUCHY_BASIS: MAYBE]]")
        let missing = AssistantAnswerBoundary.parse("A claim.")

        XCTAssertEqual(invalid.content, "A claim.")
        XCTAssertEqual(invalid.basis, .unverified)
        XCTAssertEqual(missing.content, "A claim.")
        XCTAssertEqual(missing.basis, .unverified)
    }

    func testStreamingEvidenceBoundaryNeverShowsControlMarker() {
        XCTAssertEqual(
            AssistantAnswerBoundary.displayContent("A claim.\n[[CAUCHY_BASIS: MI"),
            "A claim."
        )
    }

    func testLegacyThreadMessageDecodesWithoutEvidenceMetadata() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","content":"legacy","createdAt":0}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let message = try decoder.decode(ThreadMessage.self, from: data)

        XCTAssertEqual(message.content, "legacy")
        XCTAssertNil(message.answerEvidence)
    }

    func testAnswerSourceLocationSurvivesWorkspaceEncoding() throws {
        let anchor = AnswerSourceAnchor(
            label: "Theorem 2.1",
            pageIndex: 6,
            region: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            sourceID: "R1"
        )
        let message = ThreadMessage(
            role: .assistant,
            content: "An answer.",
            answerEvidence: AnswerEvidence(
                basis: .pdf,
                sourcePages: [7],
                referencedStatementCount: 1,
                retrievedPassageCount: 0,
                providerID: "onDevice",
                sourceAnchors: [anchor],
                citationStatus: .idsResolve,
                citedSourceIDs: ["R1"],
                declaredBasis: .pdf
            )
        )

        let decoded = try JSONDecoder().decode(ThreadMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.answerEvidence?.sourceAnchors, [anchor])
        XCTAssertEqual(decoded.answerEvidence?.citationStatus, .idsResolve)
        XCTAssertEqual(decoded.answerEvidence?.citedSourceIDs, ["R1"])
    }

    func testPreviouslySavedAnswerEvidenceDecodesWithoutSourceLocations() throws {
        let data = Data(#"{"basis":"pdf","sourcePages":[2],"referencedStatementCount":1,"retrievedPassageCount":0,"providerID":"onDevice"}"#.utf8)

        let evidence = try JSONDecoder().decode(AnswerEvidence.self, from: data)

        XCTAssertNil(evidence.sourceAnchors)
        XCTAssertNil(evidence.citationStatus)
        XCTAssertEqual(evidence.sourcePages, [2])
    }

    func testReadingPromptRequiresAnExplicitEvidenceBoundary() {
        let prompt = ReadingPromptBuilder.instructions(for: ReadingContext(
            documentTitle: "Notes",
            selectedText: "A statement",
            surroundingText: "Nearby proof",
            retrievedPassages: []
        ))

        XCTAssertTrue(prompt.contains("[[CAUCHY_BASIS: PDF]]"))
        XCTAssertTrue(prompt.contains("[[CAUCHY_BASIS: MIXED]]"))
        XCTAssertTrue(prompt.contains("[[CAUCHY_BASIS: INSUFFICIENT]]"))
        XCTAssertTrue(prompt.contains("do not guess"))
        XCTAssertTrue(prompt.contains("immediately after each material claim"))
    }

    func testCitationAuditChecksOnlyIDsActuallyResolvedByCauchy() {
        let sources = [AnswerSourceAnchor(
            label: "Selected passage",
            pageIndex: 0,
            region: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
            sourceID: "S1"
        )]

        XCTAssertEqual(AnswerCitationAudit.evaluate("A PDF claim. [S1]", sources: sources).status, .idsResolve)
        XCTAssertEqual(AnswerCitationAudit.evaluate("A claim. [P2]", sources: sources).status, .invalidID)
        XCTAssertEqual(AnswerCitationAudit.evaluate("A claim.", sources: sources).status, .noResolvableCitation)
        XCTAssertEqual(AnswerCitationAudit.evaluate(
            "A claim from the page. [S1]\n\nA second uncited claim from the page.",
            sources: sources
        ).status, .uncitedPassage)
        XCTAssertEqual(AnswerCitationAudit.evaluate(
            "1. The first result\n\nA claim from the page. [S1]",
            sources: sources
        ).status, .idsResolve)
        XCTAssertEqual(AnswerCitationAudit.evaluate(
            "Points:\n- First claim. [S1]\n- Second claim.",
            sources: sources
        ).status, .uncitedPassage)
        XCTAssertEqual(AnswerCitationAudit.evaluate("A claim. [s1] [S1]", sources: sources).citedSourceIDs, ["S1"])
    }

    func testPromptCatalogListsOnlyResolvedSourceIDs() {
        let source = AnswerSourceAnchor(
            label: "Theorem 1.2",
            pageIndex: 4,
            region: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
            sourceID: "R1"
        )
        let block = ReadingPromptBuilder.citableSourcesBlock([source])

        XCTAssertTrue(block?.contains("[R1] Theorem 1.2, PDF p. 5") == true)
        XCTAssertNil(ReadingPromptBuilder.citableSourcesBlock([]))
    }

    @MainActor
    func testThreadPersistsCleanAnswerAndAuditableBasis() async throws {
        let viewModel = SelectionThreadViewModel(assistant: EvidenceBoundaryAssistantStub())
        viewModel.updateSelection(
            TextSelectionContext(
                pageIndex: 4,
                selectedText: "A statement",
                surroundingText: "Nearby proof",
                fingerprint: "fixture",
                bounds: nil,
                lines: nil
            ),
            documentTitle: "Notes",
            existingHighlights: []
        )

        try await viewModel.sendMessage("Why?", documentTitle: "Notes") { _ in }
        let answer = try XCTUnwrap(viewModel.activeThread?.messages.last)

        XCTAssertEqual(answer.content, "Because the supplied statement says so.")
        XCTAssertEqual(answer.answerEvidence?.basis, .unverified)
        XCTAssertEqual(answer.answerEvidence?.declaredBasis, .pdf)
        XCTAssertEqual(answer.answerEvidence?.citationStatus, .noResolvableCitation)
        XCTAssertEqual(answer.answerEvidence?.sourcePages, [5])
        XCTAssertEqual(answer.answerEvidence?.providerID, AssistantConnectorID.ollama.rawValue)
    }

    @MainActor
    func testOutsideKnowledgeAnswerKeepsMixedBoundaryWithoutPDFCitation() async throws {
        let assistant = EvidenceBoundaryAssistantStub(
            response: "The standard account goes beyond this excerpt.\n[[CAUCHY_BASIS: MIXED]]"
        )
        let viewModel = SelectionThreadViewModel(assistant: assistant)
        viewModel.updateSelection(
            TextSelectionContext(
                pageIndex: 0,
                selectedText: "A short excerpt",
                surroundingText: "",
                fingerprint: "fixture",
                bounds: nil,
                lines: nil
            ),
            documentTitle: "Notes",
            existingHighlights: []
        )

        try await viewModel.sendMessage("Explain", documentTitle: "Notes") { _ in }

        XCTAssertEqual(viewModel.activeThread?.messages.last?.answerEvidence?.basis, .mixed)
        XCTAssertEqual(viewModel.activeThread?.messages.last?.answerEvidence?.citationStatus, .noResolvableCitation)
    }

    @MainActor
    func testThreadDoesNotAcceptSelectedRegionWithoutMatchingPDFText() async throws {
        let viewModel = SelectionThreadViewModel(assistant: EvidenceBoundaryAssistantStub())
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        viewModel.pdfDocument = document
        let region = NormalizedRect(x: 0.15, y: 0.4, width: 0.2, height: 0.05)
        viewModel.updateSelection(
            TextSelectionContext(
                pageIndex: 0,
                selectedText: "A statement",
                surroundingText: "Nearby proof",
                fingerprint: "fixture",
                bounds: region,
                lines: nil
            ),
            documentTitle: "Notes",
            existingHighlights: []
        )

        try await viewModel.sendMessage("Why?", documentTitle: "Notes") { _ in }
        XCTAssertEqual(viewModel.activeThread?.messages.last?.answerEvidence?.sourceAnchors, [])
        XCTAssertEqual(viewModel.activeThread?.messages.last?.answerEvidence?.basis, .unverified)
    }

    @MainActor
    func testAnswerProvenanceOmitsPassageDroppedFromModelPrompt() async throws {
        let assistant = EvidenceBoundaryAssistantStub()
        let viewModel = SelectionThreadViewModel(assistant: assistant)
        viewModel.documentIndex = LongPassageIndexStub()
        viewModel.updateSelection(
            TextSelectionContext(
                pageIndex: 4,
                selectedText: "A statement",
                surroundingText: "Nearby proof",
                fingerprint: "fixture",
                bounds: nil,
                lines: nil
            ),
            documentTitle: "Notes",
            existingHighlights: []
        )

        try await viewModel.sendMessage("Why?", documentTitle: "Notes") { _ in }
        let evidence = try XCTUnwrap(viewModel.activeThread?.messages.last?.answerEvidence)

        XCTAssertEqual(assistant.lastRetrieval?.passages.count, 2)
        XCTAssertEqual(evidence.sourcePages, [5, 9, 10])
        XCTAssertEqual(evidence.retrievedPassageCount, 2)
    }

    func testAcceptsProperlyDelimitedReply() {
        let text = """
        Since $f$ is continuous, for any $\\epsilon > 0$ there exists $\\delta > 0$ such that
        $$|f(x) - f(a)| \\leq \\frac{\\epsilon}{2}$$
        """
        XCTAssertTrue(AssistantResponseValidator.isDisplayReady(text))
    }

    func testRejectsBareFractionOutsideDelimiters() {
        let text = "We have |f(x) - f(a)| \\leq \\frac{\\epsilon}{2} as needed."
        XCTAssertTrue(AssistantResponseValidator.hasUndelimitedLaTeX(text))
        XCTAssertFalse(AssistantResponseValidator.isDisplayReady(text))
    }

    func testNormalizerConvertsParenDelimiters() {
        let raw = "Note that \\(x \\in X\\) and \\[\\frac{a}{b}\\]"
        let normalized = AssistantResponseNormalizer.normalize(raw)
        XCTAssertTrue(normalized.contains("$x \\in X$"))
        XCTAssertTrue(normalized.contains("$$\\frac{a}{b}$$"))
    }

    func testNormalizerWrapsBareTriangleInequalityLine() {
        let raw = """
        \\left| (f+g)(x) - (f+g)(a) \\right| = \\left| (f(x) - f(a)) + (g(x) - g(a)) \\right|\\leq \\left| f(x) - f(a) \\right| + \\left| g(x) - g(a) \\right|< \\frac{\\epsilon}{2} + \\frac{\\epsilon}{2} = \\epsilon
        """
        let normalized = AssistantResponseNormalizer.normalize(raw)
        XCTAssertTrue(normalized.contains("$$"))
        XCTAssertTrue(normalized.contains("\\left|"))
        XCTAssertFalse(AssistantResponseValidator.hasUndelimitedLaTeX(normalized))
        XCTAssertTrue(AssistantResponseValidator.isDisplayReady(normalized))
    }

    func testParserRendersWrappedTriangleInequality() {
        let raw = """
        \\left| (f+g)(x) - (f+g)(a) \\right| = \\left| (f(x) - f(a)) + (g(x) - g(a)) \\right|\\leq \\left| f(x) - f(a) \\right| + \\left| g(x) - g(a) \\right|< \\frac{\\epsilon}{2} + \\frac{\\epsilon}{2} = \\epsilon
        """
        let segments = MessageContentParser.parse(raw)
        XCTAssertTrue(segments.contains { segment in
            if case .displayMath(let latex) = segment {
                return latex.contains("\\left|") && latex.contains("\\frac{\\epsilon}{2}")
            }
            return false
        })
    }

    func testBlocksKeepSentenceTogetherAcrossSoftLineBreak() {
        let content = "Case 1: If $\\lambda = 0$, then $0 \\cdot f$\nis the constant zero function."
        let segments = MessageContentParser.parse(content)
        let blocks = MessageContentParser.blocks(from: segments)

        XCTAssertEqual(blocks.count, 1)
        guard case .inlineLine(let line) = blocks[0] else {
            return XCTFail("Expected a single inline line block")
        }

        let text = line.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertTrue(text.contains("then"))
        XCTAssertTrue(text.contains("is the constant zero function"))
    }

    func testLemmaStyleInlineLineProducesFlowTokens() {
        let content = "Let $X$ be a metric space, and let $Y \\subseteq X$ be a subset, considering the metric induced from $X$."
        let segments = MessageContentParser.parse(content)
        let blocks = MessageContentParser.blocks(from: segments)

        XCTAssertEqual(blocks.count, 1)
        guard case .inlineLine(let line) = blocks[0] else {
            return XCTFail("Expected a single inline line block")
        }

        let flowTokens = MessageContentParser.flowTokens(from: line)
        XCTAssertGreaterThan(flowTokens.count, 5)

        let mathCount = flowTokens.filter {
            if case .inlineMath = $0 { return true }
            return false
        }.count
        XCTAssertEqual(mathCount, 3)

        let text = flowTokens.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined()

        XCTAssertTrue(text.contains("Let"))
        XCTAssertTrue(text.contains("metric induced from"))
    }
}

@MainActor
private final class EvidenceBoundaryAssistantStub: ReadingAssistantProtocol {
    let provider = AssistantConnectorID.ollama
    let availability = ReadingAssistantAvailability.available(.ollama)
    var isResponding = false
    var lastRetrieval: AskRetrieval?
    let response: String

    init(response: String = "Because the supplied statement says so.\n[[CAUCHY_BASIS: PDF]]") {
        self.response = response
    }

    func resetSession(context: ReadingContext) {}
    func restoreSession(context: ReadingContext, messages: [ThreadMessage]) {}

    func ask(
        question: String,
        retrieval: AskRetrieval,
        onPartial: ((String) -> Void)?
    ) async throws -> String {
        lastRetrieval = retrieval
        onPartial?("Because the supplied statement says so.\n[[CAUCHY_BASIS: P")
        return response
    }
}

private struct LongPassageIndexStub: DocumentIndexProtocol {
    func passages(matching query: String, limit: Int, excludingPage: Int?) -> [String] {
        (9...11).map { page in "[p. \(page)] " + String(repeating: "a", count: 500) }
    }
}
