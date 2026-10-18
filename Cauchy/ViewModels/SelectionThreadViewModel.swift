import Foundation
import Observation
import PDFKit

@MainActor
@Observable
final class SelectionThreadViewModel {
    var activeThread: SelectionThread?
    var isResponding = false

    /// Built on first use, not at init. Making one reads the user's connector
    /// choice and, for a BYOK provider, their Keychain — and a workspace is
    /// constructed while its window is being put on screen, so doing it eagerly
    /// blocks the first window behind a Keychain call (and, when the binary's
    /// signature has changed, behind an authorization prompt).
    private var loadedAssistant: (any ReadingAssistantProtocol)?

    private var assistant: any ReadingAssistantProtocol {
        if let loadedAssistant { return loadedAssistant }
        let made = ReadingAssistantFactory.makeAssistant()
        loadedAssistant = made
        return made
    }
    /// Injected by WorkspaceViewModel once the background build finishes; nil
    /// until then (asks simply run without retrieved passages).
    var documentIndex: (any DocumentIndexProtocol)?
    /// The workspace's reference index — exact statements of numbered
    /// definitions/theorems, injected into asks as ground truth. Wired once by
    /// WorkspaceViewModel (the same instance is cleared/refilled per document).
    var referenceIndex: DocumentReferenceIndex?
    /// The current document is used only to revalidate exact source locations
    /// before they are saved with a reply.
    var pdfDocument: PDFDocument?

    /// `assistant` is for tests and previews; production leaves it nil so the
    /// real one is made the first time it is actually needed.
    init(assistant: (any ReadingAssistantProtocol)? = nil) {
        self.loadedAssistant = assistant
    }

    var hasSelection: Bool {
        activeThread != nil && !(activeThread?.selectedText.isEmpty ?? true)
    }

    /// Swaps in the newly selected provider. The active thread's session is
    /// restored onto the new assistant so a mid-thread provider change keeps
    /// the passage context instead of falling back to a generic prompt.
    func reloadAssistant(documentTitle: String? = nil) {
        loadedAssistant = ReadingAssistantFactory.makeAssistant()
        guard let thread = activeThread, let documentTitle else { return }
        let readingContext = ReadingContextBuilder.from(
            anchor: thread.anchor,
            documentTitle: documentTitle,
            index: documentIndex
        )
        assistant.restoreSession(context: readingContext, messages: thread.messages)
    }

    func updateSelection(
        _ context: TextSelectionContext?,
        documentTitle: String,
        existingHighlights: [Highlight]
    ) {
        guard let context, !context.selectedText.isEmpty else {
            activeThread = nil
            return
        }

        if let current = activeThread,
           current.pageIndex == context.pageIndex && current.selectedText == context.selectedText {
            activeThread?.selectedText = context.selectedText
            activeThread?.surroundingText = context.surroundingText
            activeThread?.bounds = context.bounds
            activeThread?.lines = context.lines
            return
        }

        if let existing = existingHighlights.first(where: {
            $0.pageIndex == context.pageIndex && $0.selectedText == context.selectedText
        }) {
            restoreThread(from: existing, documentTitle: documentTitle)
            activeThread?.bounds = context.bounds ?? existing.bounds
            activeThread?.lines = context.lines ?? existing.lines
            activeThread?.surroundingText = context.surroundingText
            return
        }

        let anchorID = UUID()
        activeThread = SelectionThread(
            anchorID: anchorID,
            pageIndex: context.pageIndex,
            selectedText: context.selectedText,
            surroundingText: context.surroundingText,
            bounds: context.bounds,
            lines: context.lines,
            messages: [],
            isPersisted: false
        )

        let readingContext = ReadingContextBuilder.from(
            anchor: activeThread!.anchor,
            documentTitle: documentTitle,
            index: documentIndex
        )
        assistant.resetSession(context: readingContext)
    }

    func restoreThread(from highlight: Highlight, documentTitle: String) {
        activeThread = SelectionThread(
            anchorID: highlight.id,
            pageIndex: highlight.pageIndex,
            selectedText: highlight.selectedText,
            surroundingText: highlight.surroundingText,
            bounds: highlight.bounds,
            lines: highlight.lines,
            messages: highlight.messages,
            isPersisted: true
        )

        let readingContext = ReadingContextBuilder.from(
            anchor: highlight.anchor,
            documentTitle: documentTitle,
            index: documentIndex
        )
        assistant.restoreSession(context: readingContext, messages: highlight.messages)
    }

    func sendMessage(
        _ question: String,
        documentTitle: String,
        onPersist: (SelectionThread) -> Void
    ) async throws {
        guard var thread = activeThread else { return }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        thread.messages.append(ThreadMessage(role: .user, content: trimmed))
        thread.streamingAssistantText = ""
        activeThread = thread

        // Freeze answer provenance before the async call. A model-picker
        // change while tokens are streaming must not relabel this reply as if
        // the newly selected connector had produced it.
        let answeringAssistant = assistant
        let answerProvider = answeringAssistant.provider
        let answerModelID: String? = switch AssistantPreferences.modelChoice(for: answerProvider) {
        case .model(let id): id
        case .connectorDefault: nil
        }

        let coalescer = StreamingTextCoalescer()
        coalescer.onFlush = { [weak self] partial in
            self?.activeThread?.streamingAssistantText = AssistantAnswerBoundary.displayContent(partial)
        }

        isResponding = true
        defer {
            coalescer.cancel()
            isResponding = false
            activeThread?.streamingAssistantText = nil
        }

        // Retrieval happens now — at ask time — because the query needs the
        // question; the session context predates it.
        var retrieval = retrieveContext(
            question: trimmed,
            thread: thread,
            provider: answerProvider
        ).clippedForPrompt(provider: answerProvider)
        let sourceAnchors = resolvedSourceAnchors(thread: thread, retrieval: retrieval)
        retrieval.citableSources = sourceAnchors

        // onPartial already runs on the main actor (ReadingAssistantProtocol is
        // @MainActor); the coalescer keeps re-renders at ~12/s instead of per token.
        let assistantText = try await answeringAssistant.ask(question: trimmed, retrieval: retrieval) { partial in
            coalescer.submit(partial)
        }
        let parsed = AssistantAnswerBoundary.parse(assistantText)
        let citationAudit = AnswerCitationAudit.evaluate(parsed.content, sources: sourceAnchors)
        let acceptedBasis: AnswerBasis = parsed.basis == .pdf && citationAudit.status != .idsResolve
            ? .unverified : parsed.basis
        let pages = Array(Set([thread.pageIndex + 1] + retrieval.sourcePageNumbers)).sorted()
        let evidence = AnswerEvidence(
            basis: acceptedBasis,
            sourcePages: pages,
            referencedStatementCount: retrieval.statements.count,
            retrievedPassageCount: retrieval.passages.count,
            providerID: answerProvider.rawValue,
            modelID: answerModelID,
            sourceAnchors: sourceAnchors,
            citationStatus: citationAudit.status,
            citedSourceIDs: citationAudit.citedSourceIDs,
            declaredBasis: parsed.basis
        )
        thread.messages.append(ThreadMessage(
            role: .assistant,
            content: parsed.content,
            answerEvidence: evidence
        ))
        thread.isPersisted = true
        activeThread = thread
        onPersist(thread)
    }

    func currentMessagesForSave() -> [ThreadMessage] {
        activeThread?.messages ?? []
    }

    /// Pops the trailing user message when an ask was stopped before it was
    /// answered, and returns its text so the composer can offer it back.
    /// Providers only record a turn once it completes, so leaving the orphan
    /// visible would show history the model will never see.
    func discardUnansweredQuestion() -> String? {
        guard var thread = activeThread,
              let last = thread.messages.last,
              last.role == .user else { return nil }
        thread.messages.removeLast()
        activeThread = thread
        return last.content
    }

    private func retrieveContext(
        question: String,
        thread: SelectionThread,
        provider: AssistantConnectorID
    ) -> AskRetrieval {
        AskContextRetriever.retrieve(
            question: question,
            selectedText: thread.selectedText,
            surroundingText: thread.surroundingText,
            pageIndex: thread.pageIndex,
            referenceIndex: referenceIndex,
            documentIndex: documentIndex,
            // A local Ollama model may run with a small window; cloud/CLI
            // providers can take more.
            passageLimit: provider == .ollama ? 3 : 5
        )
    }

    private func resolvedSourceAnchors(
        thread: SelectionThread,
        retrieval: AskRetrieval
    ) -> [AnswerSourceAnchor] {
        guard let document = pdfDocument else { return [] }
        var anchors: [AnswerSourceAnchor] = []
        if let page = document.page(at: thread.pageIndex),
           let pageText = page.string,
           let source = LexicalDocumentIndex.sourceLocation(
               for: thread.selectedText,
               in: pageText,
               pageIndex: thread.pageIndex,
               after: 0
           ),
           let region = ReferenceEvidenceRegionResolver.exactRegion(
               matchedText: source.matchedText,
               startOffset: source.startOffset,
               endOffset: source.endOffset,
               on: page
           ) {
            anchors.append(AnswerSourceAnchor(
                label: "Selected passage",
                pageIndex: thread.pageIndex,
                region: region,
                sourceID: "S1"
            ))
        }
        for (index, entry) in retrieval.statementReferences.enumerated() {
            guard let source = entry.evidence,
                  source.effectiveSource == .pdfText,
                  let page = document.page(at: entry.pageIndex),
                  let region = ReferenceEvidenceRegionResolver.exactRegion(for: source, on: page)
            else { continue }
            anchors.append(AnswerSourceAnchor(
                label: entry.reference.displayName,
                pageIndex: entry.pageIndex,
                region: region,
                sourceID: "R\(index + 1)"
            ))
        }
        for (index, record) in retrieval.passageRecords.enumerated() {
            guard let source = record.location,
                  let page = document.page(at: source.pageIndex),
                  let region = ReferenceEvidenceRegionResolver.exactRegion(
                      matchedText: source.matchedText,
                      startOffset: source.startOffset,
                      endOffset: source.endOffset,
                      on: page
                  ) else { continue }
            anchors.append(AnswerSourceAnchor(
                label: "Retrieved passage",
                pageIndex: source.pageIndex,
                region: region,
                sourceID: "P\(index + 1)"
            ))
        }
        return anchors
    }

}
