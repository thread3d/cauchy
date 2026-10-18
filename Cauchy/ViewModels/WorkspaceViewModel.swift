import AppKit
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

private let invertPageColorsKey = "reading.invertPageColors"

@MainActor
@Observable
final class WorkspaceViewModel: Equatable {
    /// Identity, not contents: `focusedSceneValue` needs to tell one window's
    /// workspace from another's, and comparing two live reading sessions field
    /// by field would mean nothing.
    nonisolated static func == (lhs: WorkspaceViewModel, rhs: WorkspaceViewModel) -> Bool {
        lhs === rhs
    }

    var workspace: DocumentWorkspace?
    var pdfDocument: PDFDocument?
    var bookmarkData: Data?

    var contextPanelVisible = true
    var sidebarVisible = true
    var sidebarContentMode: SidebarContentMode = .thumbnails
    var pdfPageLayoutMode: PDFPageLayoutMode = .continuousScroll

    /// Latest one-shot command for the PDF view; consumed by the representable
    /// when `pdfViewCommandRevision` changes.
    private(set) var pdfViewCommand: PDFViewCommand?
    private(set) var pdfViewCommandRevision: UUID?

    /// Night-reading mode: inverts page luminance while roughly preserving hue.
    /// App-level preference, not per-workspace.
    var invertPageColors = UserDefaults.standard.bool(forKey: invertPageColorsKey) {
        didSet {
            UserDefaults.standard.set(invertPageColors, forKey: invertPageColorsKey)
        }
    }

    var selectionModeActive = false
    var showOCRResult = false
    var ocrResult: OCRResult?
    var ocrPreviewImage: CGImage?
    var isProcessingOCR = false
    var errorMessage: String?

    var viewportCoordinator = ViewportCoordinator()
    let pageThumbnailCache = PageThumbnailCache()
    var highlightStore = HighlightStore()
    var contextEngine = ContextEngineViewModel()
    var selectionThread = SelectionThreadViewModel()
    var referenceIndex = DocumentReferenceIndex()
    var find = PDFFindModel()
    var isIndexingReferences = false
    var referenceIndexProgress: Double = 0
    var referenceIndexError: String?
    /// Non-blocking notice for a partially failed index (hover still works
    /// with what was indexed; the failed pages retry next open).
    var referenceIndexWarning: String?
    /// What built the loaded index, for the Reference panel footer. nil until
    /// a build finishes (or while one is running).
    var referenceIndexProvenance: ReferenceIndexProvenance?

    /// The window's own undo manager, handed down from the view layer. Using
    /// the window's rather than a private one is what puts these steps behind
    /// the standard Edit ▸ Undo item — and what leaves text fields their own
    /// undo while they have focus, since the field editor answers first.
    var hostUndoManager: UndoManager?
    /// The window this workspace is being read in, so a duplicate open can
    /// bring it forward instead of opening the document twice.
    weak var hostWindow: NSWindow?
    /// Stands in before a window has handed one down (and in previews), so
    /// registration never has to be conditional.
    private let fallbackUndoManager = UndoManager()

    var undoManager: UndoManager { hostUndoManager ?? fallbackUndoManager }

    let persistence = DocumentPersistenceService.shared
    private var securityScopedURL: URL?
    private var referenceIndexTask: Task<Void, Never>?
    private var referenceRebuildID: UUID?
    private var lexicalIndexTask: Task<Void, Never>?
    /// The in-flight Ask, retained so the user can stop it. Cancelling it
    /// terminates the CLI child process / cloud stream.
    private var askTask: Task<Void, Never>?
    /// Thread-naming jobs in flight, keyed by highlight, so a follow-up
    /// question doesn't start a second one for the same thread and closing the
    /// document cancels them all.
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    /// Names threads that predate this document being opened, one at a time in
    /// the background.
    private var titleBackfillTask: Task<Void, Never>?

    init() {
        find.currentPageProvider = { [weak self] in
            self?.viewportCoordinator.viewport.pageIndex ?? 0
        }
        // Same long-lived instance across documents (cleared/refilled per open),
        // so wiring once is enough.
        selectionThread.referenceIndex = referenceIndex
    }

    var documentTitle: String {
        workspace?.documentURL.deletingPathExtension().lastPathComponent ?? "No Document"
    }

    var windowTitle: String {
        pdfDocument != nil ? documentTitle : "Cauchy"
    }

    var pageCount: Int {
        pdfDocument?.pageCount ?? 0
    }

    var currentPage: Int {
        viewportCoordinator.viewport.pageIndex + 1
    }

    /// A live text selection that hasn't been saved as a highlight yet — what
    /// Reading ▸ Highlight Selection acts on.
    var canSaveTextSelection: Bool {
        guard let thread = selectionThread.activeThread else { return false }
        return !thread.isPersisted
    }

    var readingAssistantAvailability: ReadingAssistantAvailability {
        ReadingAssistantFactory.availability
    }

    func refreshReadingAssistant() {
        selectionThread.reloadAssistant(documentTitle: documentTitle)
    }

    var contextPanelWidth: CGFloat {
        get { workspace?.contextPanelWidth ?? 380 }
        set {
            workspace?.contextPanelWidth = min(640, max(300, newValue))
            persistWorkspace()
        }
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openDocument(at: url) }
    }

    func openDocument(at url: URL) async {
        await openDocument(at: url, selecting: nil)
    }

    /// `selecting` scrolls to and opens one highlight once the document is up —
    /// how a library-wide search result gets the reader to the thing they
    /// searched for rather than to page one.
    func openDocument(at url: URL, selecting highlightID: UUID?) async {
        await openDocument(at: url, selecting: highlightID, adopting: nil)
    }

    /// `adopting` re-homes an existing saved workspace onto a new file path —
    /// the relocation case, where the reader has just pointed the app at a PDF
    /// that moved and expects to find their highlights still on it.
    func openDocument(
        at url: URL,
        selecting highlightID: UUID?,
        adopting adopted: PersistedWorkspace?
    ) async {
        // One document, one window. Opening a PDF a second time — from Finder,
        // from Recents, from a search result — belongs in the window that
        // already has it, not in a second reader saving over the same file.
        if let existing = OpenDocumentRegistry.shared.holder(of: url), existing !== self {
            existing.hostWindow?.makeKeyAndOrderFront(nil)
            if let highlightID {
                existing.selectHighlight(id: highlightID)
            }
            // A window macOS opened just to receive this file has nothing in
            // it; leaving it behind as an empty dashboard is worse than
            // closing it.
            if pdfDocument == nil, workspace == nil {
                hostWindow?.close()
            }
            return
        }

        stopSecurityScopedAccess()
        // An ask still streaming from the previous document would otherwise
        // persist its answer as a highlight on the new one.
        stopThreadMessage()
        cancelThreadTitleWork()
        pageThumbnailCache.removeAll()

        var persisted = adopted
        if persisted == nil {
            persisted = try? await persistence.loadWorkspace(for: url)
        }

        var resolvedURL = url
        if adopted == nil, let bookmark = persisted?.bookmarkData,
           let bookmarkURL = try? persistence.resolveBookmark(bookmark) {
            resolvedURL = bookmarkURL
        } else {
            _ = url.startAccessingSecurityScopedResource()
        }
        securityScopedURL = resolvedURL

        guard let document = PDFDocument(url: resolvedURL) else {
            stopSecurityScopedAccess()
            // A PDF that has been moved or renamed since it was last read is
            // the ordinary case here, not a corrupt file — so offer to point
            // the app at it again rather than dead-ending on an alert.
            if !FileManager.default.fileExists(atPath: resolvedURL.path),
               let relocated = promptToLocate(missing: resolvedURL) {
                await openDocument(at: relocated, selecting: highlightID, adopting: persisted)
            } else {
                errorMessage = "Could not open “\(url.lastPathComponent)”. The file may have been moved, renamed, or damaged."
            }
            return
        }

        // Undo steps close over highlights of the document that produced them;
        // carrying them into the next one would re-add a highlight where it
        // never existed.
        undoManager.removeAllActions()

        pdfDocument = document
        selectionThread.pdfDocument = document
        OpenDocumentRegistry.shared.claim(resolvedURL, by: self)
        find.attach(to: document)
        bookmarkData = try? persistence.createBookmark(for: resolvedURL)

        let isNewDocument: Bool
        if let persisted {
            isNewDocument = false
            workspace = persisted.workspace
            workspace?.documentURL = resolvedURL
            workspace?.lastOpenedAt = Date()
            viewportCoordinator.viewport = persisted.workspace.primaryViewport
            highlightStore.load(from: persisted.workspace)
            // A relocated document needs the bookmark just minted for its new
            // path, never the stale one that pointed at where it used to be.
            if adopted == nil, let bookmark = persisted.bookmarkData {
                bookmarkData = bookmark
            }
        } else {
            isNewDocument = true
            workspace = DocumentWorkspace(documentURL: resolvedURL)
            highlightStore.highlights = []
        }

        contextEngine.reset()
        selectionThread.activeThread = nil
        workspace?.lastOpenedAt = Date()
        applyRestoredViewport(isNewDocument: isNewDocument)
        syncHighlightAnnotations()
        buildReferenceIndex(for: resolvedURL)
        buildLexicalIndex(for: resolvedURL)
        backfillThreadTitles()
        generateDashboardPreviewIfNeeded(documentURL: resolvedURL)
        persistWorkspace()

        if let highlightID, let highlight = highlightStore.highlights.first(where: { $0.id == highlightID }) {
            selectHighlight(highlight)
        }
    }

    /// Asks the reader where a document went. Returns nil if they cancel or
    /// pick something that isn't a readable PDF.
    private func promptToLocate(missing url: URL) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Can’t find “\(url.lastPathComponent)”"
        alert.informativeText = "It isn’t at \(url.deletingLastPathComponent().path) any more. Locate it to keep this document’s highlights and conversations."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Locate “\(url.lastPathComponent)”"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func closeDocument() {
        if workspace != nil {
            persistWorkspace()
        }

        undoManager.removeAllActions()
        OpenDocumentRegistry.shared.release(by: self)

        stopSecurityScopedAccess()
        pdfDocument = nil
        selectionThread.pdfDocument = nil
        workspace = nil
        bookmarkData = nil

        pageThumbnailCache.removeAll()
        highlightStore.highlights.removeAll()
        referenceIndex.clear()
        // stopSecurityScopedAccess() cancelled any in-flight index build, and a
        // cancelled build never runs its completion — so the flags have to be
        // cleared here or indexing state (and the menu items gated on it)
        // stays stuck from the closed document.
        isIndexingReferences = false
        referenceIndexProgress = 0
        referenceIndexError = nil
        referenceIndexWarning = nil
        referenceIndexProvenance = nil
        stopThreadMessage()
        cancelThreadTitleWork()
        lexicalIndexTask?.cancel()
        lexicalIndexTask = nil
        selectionThread.documentIndex = nil
        find.attach(to: nil)
        selectionThread.activeThread = nil
        contextEngine.reset()
        viewportCoordinator = ViewportCoordinator()
        
        selectionModeActive = false
        showOCRResult = false
        ocrResult = nil
        ocrPreviewImage = nil
        errorMessage = nil
        isProcessingOCR = false
    }

    func handleSelection(_ capture: SelectionCapture) {
        highlightStore.pendingRegionCapture = capture
        selectionModeActive = false
    }

    func handleTextSelection(_ context: TextSelectionContext?) {
        if let context, !context.selectedText.isEmpty {
            selectionThread.updateSelection(
                context,
                documentTitle: documentTitle,
                existingHighlights: highlightStore.highlights
            )
            if let match = highlightStore.findMatchingHighlight(for: context) {
                selectHighlight(match)
            } else {
                highlightStore.selectedHighlightID = nil
                contextEngine.showComposeDraft(context)
            }
        } else if case .list = contextEngine.route {
            selectionThread.updateSelection(
                nil,
                documentTitle: documentTitle,
                existingHighlights: highlightStore.highlights
            )
        }
    }

    func handleDetectedBlock(_ block: DocumentBlock?) {
        guard let block else { return }

        if contextEngine.passiveBlock?.reference.key == block.reference.key {
            return
        }

        contextEngine.showReferencePreview(block: block)
    }

    func navigateToReference(_ block: DocumentBlock) {
        viewportCoordinator.navigateToPage(block.pageIndex)
    }

    func showHighlightList() {
        contextEngine.showList()
        highlightStore.selectedHighlightID = nil
        syncHighlightAnnotations()
    }

    /// Deletes a highlight — and, with it, the whole conversation hanging off
    /// it. A thread that has been asked something is minutes of work, so it is
    /// confirmed before it goes; either way the delete is undoable.
    func deleteHighlight(_ highlight: Highlight, confirm: Bool = true) {
        if confirm, !highlight.messages.isEmpty, !confirmDelete(highlight) { return }

        highlightStore.remove(highlight)
        if case .detail(highlight.id) = contextEngine.route {
            contextEngine.showList()
        }
        if highlightStore.selectedHighlightID == highlight.id {
            highlightStore.selectedHighlightID = nil
        }
        // The thread panel is still showing what was just deleted; drop it so
        // an Ask cannot resurrect the highlight through upsertFromThread.
        if selectionThread.activeThread?.anchorID == highlight.id {
            selectionThread.activeThread = nil
        }
        syncHighlightAnnotations()
        persistWorkspace()

        registerUndo("Delete Highlight") { $0.restoreHighlight(highlight) }
    }

    /// Puts a deleted highlight back exactly as it was, conversation included,
    /// and re-arms redo.
    private func restoreHighlight(_ highlight: Highlight) {
        guard !highlightStore.highlights.contains(where: { $0.id == highlight.id }) else { return }
        highlightStore.add(highlight)
        syncHighlightAnnotations()
        persistWorkspace()

        registerUndo("Delete Highlight") { $0.deleteHighlight(highlight, confirm: false) }
    }

    private func confirmDelete(_ highlight: Highlight) -> Bool {
        let count = highlight.messages.count
        let messages = count == 1 ? "1 message" : "\(count) messages"
        let alert = NSAlert()
        alert.messageText = "Delete “\(highlight.displayName)”?"
        alert.informativeText = "Its conversation (\(messages)) is deleted with it. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Notes and colour

    /// The reader's own note on a highlight, kept apart from the conversation.
    func setNote(_ note: String?, for id: UUID) {
        guard var highlight = highlightStore.highlights.first(where: { $0.id == id }) else { return }
        let cleaned = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = (cleaned?.isEmpty ?? true) ? nil : cleaned
        guard newValue != highlight.note else { return }

        let previous = highlight.note
        highlight.note = newValue
        highlight.updatedAt = Date()
        highlightStore.update(highlight)
        persistWorkspace()

        registerUndo(previous == nil ? "Add Note" : "Edit Note") { $0.setNote(previous, for: id) }
    }

    func setColor(_ color: HighlightColor, for id: UUID) {
        guard var highlight = highlightStore.highlights.first(where: { $0.id == id }),
              highlight.color != color else { return }

        let previous = highlight.color
        highlight.color = color
        highlightStore.update(highlight)
        syncHighlightAnnotations()
        persistWorkspace()

        registerUndo("Change Highlight Colour") { $0.setColor(previous, for: id) }
    }

    // MARK: - Undo

    /// Registers one undoable step. The handler runs on whichever thread calls
    /// `undo()`, which for a menu command is always the main one.
    private func registerUndo(
        _ actionName: String,
        _ undo: @escaping @MainActor @Sendable (WorkspaceViewModel) -> Void
    ) {
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { undo(target) }
        }
        undoManager.setActionName(actionName)
    }

    func saveTextSelectionAsHighlight() {
        guard var thread = selectionThread.activeThread else { return }
        thread.isPersisted = true
        selectionThread.activeThread = thread
        
        let highlight = highlightStore.upsertFromThread(thread)
        selectHighlight(highlight)
        persistWorkspace()
        nameThreadIfNeeded(highlight)
    }

    func saveRegionAsHighlight() async {
        guard let capture = highlightStore.pendingRegionCapture else { return }

        var selectedText = ""
        if let document = pdfDocument,
           let page = document.page(at: capture.pageIndex) {
            selectedText = PDFTextExtractor.extractText(from: page, bounds: capture.bounds)
            if selectedText.isEmpty,
               let image = PDFRegionRenderer.render(page: page, bounds: capture.bounds),
               let ocrText = try? await OCRService.shared.recognizeText(in: image).rawText {
                selectedText = ocrText
            }
        }

        // A region with no text behind it has nothing to name itself by, so it
        // keeps its placeholder rather than asking a model to invent a subject.
        let hasText = !selectedText.isEmpty
        if !hasText {
            selectedText = "Region on page \(capture.pageIndex + 1)"
        }

        let highlight = Highlight(
            pageIndex: capture.pageIndex,
            bounds: capture.bounds,
            selectedText: selectedText,
            surroundingText: selectedText,
            messages: selectionThread.currentMessagesForSave()
        )
        highlightStore.add(highlight)
        highlightStore.pendingRegionCapture = nil
        selectHighlight(highlight)
        persistWorkspace()
        if hasText {
            nameThreadIfNeeded(highlight)
        }
    }

    func selectHighlight(_ highlight: Highlight) {
        contextPanelVisible = true
        highlightStore.selectedHighlightID = highlight.id
        contextEngine.showDetail(highlight.id)
        selectionThread.restoreThread(from: highlight, documentTitle: documentTitle)
        navigateToHighlight(highlight)
        syncHighlightAnnotations()
    }

    func selectHighlight(id: UUID) {
        guard let highlight = highlightStore.highlights.first(where: { $0.id == id }) else { return }
        selectHighlight(highlight)
    }

    func navigateToHighlight(_ highlight: Highlight) {
        viewportCoordinator.navigateToHighlight(highlight)
    }

    func runOCR(on capture: SelectionCapture) async {
        guard let document = pdfDocument,
              let page = document.page(at: capture.pageIndex),
              let image = PDFRegionRenderer.render(page: page, bounds: capture.bounds) else {
            errorMessage = "Could not render selection for OCR."
            return
        }

        isProcessingOCR = true
        defer { isProcessingOCR = false }

        do {
            let result = try await OCRService.shared.recognizeText(in: image)
            ocrResult = result
            ocrPreviewImage = image
            showOCRResult = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyLatexToClipboard() {
        guard let latex = ocrResult?.latexSnippet else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latex, forType: .string)
    }

    /// Starts an Ask and retains the task so `stopThreadMessage()` can stop it.
    /// The user's message stays in the thread if the answer is stopped, so
    /// nothing they typed is lost.
    func sendThreadMessage(_ question: String) {
        askTask?.cancel()
        askTask = Task { [weak self] in
            guard let self else { return }
            defer { self.askTask = nil }
            do {
                try await self.selectionThread.sendMessage(question, documentTitle: self.documentTitle) { [weak self] thread in
                    guard let self else { return }
                    let highlight = self.highlightStore.upsertFromThread(thread)
                    self.highlightStore.selectedHighlightID = highlight.id
                    self.contextEngine.showDetail(highlight.id)
                    self.syncHighlightAnnotations()
                    self.persistWorkspace()
                    self.nameThreadIfNeeded(highlight)
                }
            } catch {
                // A stopped ask is a deliberate user action, not a failure —
                // the provider may surface it as CancellationError or as its
                // own "process terminated" error, so check the task too.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Stops the in-flight Ask (terminating the CLI child process or cloud
    /// stream) and returns the unanswered question so the composer can restore
    /// it. Safe to call when nothing is running.
    @discardableResult
    func stopThreadMessage() -> String? {
        guard askTask != nil else { return nil }
        askTask?.cancel()
        askTask = nil
        return selectionThread.discardUnansweredQuestion()
    }

    // MARK: - Thread names

    /// Asks the model for a name once a thread has its first answer, or as soon
    /// as a highlight is saved with nothing asked about it. Silent and
    /// best-effort: a thread that can't be named keeps showing the question it
    /// started with, which is what the list did before.
    private func nameThreadIfNeeded(_ highlight: Highlight) {
        guard highlight.title == nil,
              Self.isReadyToName(highlight),
              titleTasks[highlight.id] == nil,
              ThreadTitleGenerator.isAvailable else { return }
        startNaming(highlight)
    }

    /// A thread is worth naming once it has an answer, or when it has no
    /// conversation at all — a highlight the reader only saved. A thread whose
    /// question is still in flight is left alone: the answer names it in a
    /// moment, and naming it twice would rewrite the row under the reader.
    private static func isReadyToName(_ highlight: Highlight) -> Bool {
        highlight.messages.isEmpty || highlight.messages.contains { $0.role == .assistant }
    }

    /// Re-names a thread from scratch — the menu escape hatch for a title that
    /// came out wrong, and the only way to rename one whose first attempt
    /// happened while no model was available.
    func regenerateThreadTitle(for highlight: Highlight) {
        guard titleTasks[highlight.id] == nil else { return }
        guard ThreadTitleGenerator.isAvailable else {
            errorMessage = "Naming a thread needs Ollama or an API key."
            return
        }
        startNaming(highlight)
    }

    private func startNaming(_ highlight: Highlight) {
        let id = highlight.id
        titleTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.titleTasks[id] = nil }

            // Read the thread fresh: an answer may have landed since.
            guard let current = self.highlightStore.highlights.first(where: { $0.id == id }) else { return }
            let title = await ThreadTitleGenerator.generate(
                selectedText: current.selectedText,
                surroundingText: current.surroundingText,
                messages: current.messages
            )
            guard !Task.isCancelled, let title else { return }
            self.applyThreadTitle(title, to: id)
        }
    }

    private func applyThreadTitle(_ title: String, to id: UUID) {
        guard var highlight = highlightStore.highlights.first(where: { $0.id == id }) else { return }
        highlight.title = title
        // Deliberately not touching `updatedAt`: naming is bookkeeping, and
        // letting it bump the timestamp would reshuffle the list under the
        // reader seconds after they asked something.
        highlightStore.update(highlight)
        persistWorkspace()
    }

    /// Names threads carried over from previous sessions, one at a time so a
    /// document with a long history doesn't fire dozens of model calls at once.
    /// Capped: the oldest unnamed threads keep their fallback names rather than
    /// turning an open into a long background job.
    private func backfillThreadTitles() {
        titleBackfillTask?.cancel()
        guard ThreadTitleGenerator.isAvailable else { return }

        let pending = highlightStore.highlights
            .filter { $0.title == nil && Self.isReadyToName($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(30)
            .map(\.id)
        guard !pending.isEmpty else { return }

        titleBackfillTask = Task { [weak self] in
            for id in pending {
                guard let self, !Task.isCancelled else { return }
                guard let highlight = self.highlightStore.highlights.first(where: { $0.id == id }),
                      highlight.title == nil,
                      self.titleTasks[id] == nil else { continue }
                let title = await ThreadTitleGenerator.generate(
                    selectedText: highlight.selectedText,
                    surroundingText: highlight.surroundingText,
                    messages: highlight.messages
                )
                guard !Task.isCancelled else { return }
                if let title {
                    self.applyThreadTitle(title, to: id)
                }
            }
        }
    }

    private func cancelThreadTitleWork() {
        titleBackfillTask?.cancel()
        titleBackfillTask = nil
        for task in titleTasks.values {
            task.cancel()
        }
        titleTasks.removeAll()
    }

    func syncHighlightAnnotations() {
        guard let document = pdfDocument else { return }
        HighlightAnnotationService.sync(
            document: document,
            highlights: highlightStore.highlights,
            activeID: highlightStore.selectedHighlightID
        )
    }

    func zoomIn() { adjustZoom(by: 1.25) }
    func zoomOut() { adjustZoom(by: 0.8) }

    func goBack() { sendPDFViewCommand(.goBack) }
    func goForward() { sendPDFViewCommand(.goForward) }
    func printDocument() { sendPDFViewCommand(.print) }

    /// Discards the current document's cached reference index and re-runs
    /// extraction — e.g. after an indexing-quality upgrade, or when a cache
    /// predates reference names.
    ///
    /// Explicit choices use the selected connector and model. With no choice,
    /// the normal on-device-first policy applies.
    func rebuildReferenceIndex(connectorID: AssistantConnectorID? = nil, modelID: String? = nil) {
        guard let url = workspace?.documentURL else { return }

        var forcedModel: (any LanguageModel)?
        var modelDescription: String?
        if let connectorID {
            let connector = connectorID.connector
            guard connector.isReady else {
                referenceIndexError = "Set up \(connector.name) in Settings before indexing."
                return
            }
            let choice = modelID.map(ModelChoice.model) ?? connector.defaultChoice
            let chosenModelID: String?
            if case .model(let id) = choice { chosenModelID = id } else { chosenModelID = nil }
            modelDescription = connector.label(for: choice)
            switch connector.access {
            case .onDevice:
                guard let local = AssistantPreferences.localModel(named: chosenModelID) else {
                    referenceIndexError = "Start Ollama and install a local model before indexing."
                    return
                }
                forcedModel = local
                modelDescription = "Ollama · \(connector.label(for: choice))"
            case .apiKey(let provider):
                guard let key = KeychainService.loadKey(for: provider) else {
                    referenceIndexError = "Add your \(provider.vendor) API key in Settings."
                    return
                }
                forcedModel = CloudLanguageModel(provider: provider, apiKey: key, modelName: chosenModelID)
                modelDescription = "\(connector.vendor) \(connector.label(for: choice))"
            case .cliSignIn:
                forcedModel = CLIIndexLanguageModel(connectorID: connectorID, modelID: chosenModelID)
                modelDescription = "\(connector.name) · \(connector.label(for: choice))"
            }
        }

        referenceIndexTask?.cancel()
        let rebuildID = UUID()
        referenceRebuildID = rebuildID
        Task {
            await Task.detached(priority: .utility) {
                ReferenceIndexCacheStore.removeCache(for: url)
            }.value
            guard referenceRebuildID == rebuildID, workspace?.documentURL == url else { return }
            buildReferenceIndex(for: url, forcedModel: forcedModel, modelDescription: modelDescription)
        }
    }

    /// Deletes every document's cached reference index (after confirmation);
    /// each re-indexes on its next open. The open document rebuilds now.
    func resetAllReferenceIndexes() {
        let alert = NSAlert()
        alert.messageText = "Reset All Reference Indexes?"
        alert.informativeText = "Cached theorem/definition indexes for all documents will be deleted and rebuilt the next time each document is opened. Re-indexing runs in the background and uses the local Ollama model (or a saved API key)."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        referenceIndexTask?.cancel()
        let currentURL = workspace?.documentURL
        Task {
            await Task.detached(priority: .utility) {
                ReferenceIndexCacheStore.removeAllCaches()
            }.value
            if let currentURL {
                buildReferenceIndex(for: currentURL)
            }
        }
    }

    private func sendPDFViewCommand(_ command: PDFViewCommand) {
        guard pdfDocument != nil else { return }
        pdfViewCommand = command
        pdfViewCommandRevision = UUID()
    }

    func zoomToActualSize() {
        var state = viewportCoordinator.viewport
        state.scaleFactor = 1.0
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func toggleContextPanel() {
        contextPanelVisible.toggle()
        zoomToFitWidth()
    }

    func zoomToFitWidth() {
        var state = viewportCoordinator.viewport
        state.scaleFactor = -1
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func goToNextPage() {
        guard let document = pdfDocument else { return }
        var state = viewportCoordinator.viewport
        state.pageIndex = min(state.pageIndex + 1, document.pageCount - 1)
        state.visibleRectNormalized = nil
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func goToPreviousPage() {
        var state = viewportCoordinator.viewport
        state.pageIndex = max(state.pageIndex - 1, 0)
        state.visibleRectNormalized = nil
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func presentFindBar() {
        guard pdfDocument != nil else { return }
        find.present()
    }

    func presentGoToPagePanel() {
        guard let document = pdfDocument else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Page"
        alert.informativeText = "Enter a page number (1–\(document.pageCount))"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "\(viewportCoordinator.viewport.pageIndex + 1)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let page = Int(input.stringValue.trimmingCharacters(in: .whitespaces)) {
            goToPage(page)
        }
    }

    func goToPage(_ page: Int) {
        guard let document = pdfDocument,
              page >= 1, page <= document.pageCount else { return }
        var state = viewportCoordinator.viewport
        state.pageIndex = page - 1
        state.visibleRectNormalized = nil
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    /// Follow a citation edge to the printed location, retaining enough
    /// surrounding page to read the sentence rather than zooming to a glyph.
    func goToReferenceMention(_ mention: ReferenceMention) {
        guard let document = pdfDocument,
              mention.pageIndex >= 0,
              mention.pageIndex < document.pageCount else { return }
        var state = viewportCoordinator.viewport
        state.pageIndex = mention.pageIndex
        state.visibleRectNormalized = ReferenceEvidenceRegionResolver.contextRegion(for: mention.region)
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    /// Open a source location retained with an answer. The region is an
    /// inspectable input, not an automatically verified citation for its prose.
    func goToAnswerSource(_ source: AnswerSourceAnchor) {
        guard let document = pdfDocument,
              source.pageIndex >= 0,
              source.pageIndex < document.pageCount else { return }
        let region = source.region
        guard region.x.isFinite, region.y.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.x >= 0, region.y >= 0,
              region.width > 0, region.height > 0,
              region.x + region.width <= 1,
              region.y + region.height <= 1 else { return }
        var state = viewportCoordinator.viewport
        state.pageIndex = source.pageIndex
        state.visibleRectNormalized = ReferenceEvidenceRegionResolver.contextRegion(for: region)
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func navigateToDestination(_ destination: PDFDestination) {
        guard let document = pdfDocument,
              let page = destination.page else { return }
        let pageIndex = document.index(for: page)
        var state = viewportCoordinator.viewport
        state.pageIndex = max(0, pageIndex)
        let point = destination.point
        let pageBounds = CoordinateMapper.pageBounds(for: page)
        state.visibleRectNormalized = NormalizedRect.from(
            cgRect: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
            pageBounds: pageBounds
        )
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    func persistWorkspace() {
        guard var ws = workspace else { return }
        ws.primaryViewport = viewportCoordinator.viewport
        highlightStore.exportToWorkspace(&ws)
        workspace = ws
        persistence.scheduleSave(ws, bookmarkData: bookmarkData) { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = "Could not save workspace: \(error.localizedDescription)"
            }
        }
    }

    /// Renders the first page to thumbnails/preview.png once per workspace so
    /// the dashboard can show recents without reopening every PDF. Uses its own
    /// PDFDocument instance so background drawing never races the live PDFView.
    private func generateDashboardPreviewIfNeeded(documentURL: URL) {
        guard let workspaceID = workspace?.id else { return }
        let previewURL = persistence.thumbnailURL(workspaceID: workspaceID, filename: "preview.png")
        guard !FileManager.default.fileExists(atPath: previewURL.path) else { return }

        Task.detached(priority: .background) {
            guard let document = PDFDocument(url: documentURL),
                  let page = document.page(at: 0),
                  let image = PDFRegionRenderer.renderFullPage(page, maxDimension: 600)
            else { return }
            try? FileManager.default.createDirectory(
                at: previewURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? PDFRegionRenderer.saveThumbnail(image, to: previewURL)
        }
    }

    private func applyRestoredViewport(isNewDocument: Bool) {
        if isNewDocument || viewportCoordinator.viewport.scaleFactor < 0.15 {
            var fitState = viewportCoordinator.viewport
            fitState.scaleFactor = -1
            fitState.visibleRectNormalized = nil
            viewportCoordinator.applyProgrammaticViewport(fitState)
        } else {
            viewportCoordinator.applyProgrammaticViewport(viewportCoordinator.viewport)
        }
    }

    private func adjustZoom(by factor: CGFloat) {
        var state = viewportCoordinator.viewport
        let currentScale = state.scaleFactor > 0 ? state.scaleFactor : 1.0
        state.scaleFactor = max(0.1, min(10.0, currentScale * factor))
        viewportCoordinator.applyProgrammaticViewport(state)
    }

    /// An explicit model skips the default availability check because the
    /// caller has already resolved a ready connector.
    private func buildReferenceIndex(
        for url: URL,
        forcedModel: (any LanguageModel)? = nil,
        modelDescription: String? = nil
    ) {
        referenceIndexTask?.cancel()
        referenceIndex.clear()
        referenceIndexError = nil
        referenceIndexWarning = nil
        referenceIndexProvenance = nil
        isIndexingReferences = true
        referenceIndexProgress = 0

        // Indexing prefers the local Ollama model; a cloud key is only a
        // fallback when Ollama is unavailable. Independent of which provider
        // answers chat questions. Availability is resolved inside the task:
        // the launch discovery may still be in flight when a restored document
        // opens, and deciding early would show a spurious failure.
        referenceIndexTask = Task {
            // Give the UI a moment to show the indexing state, preventing
            // SwiftUI from missing the state change if the cache load is instantaneous.
            try? await Task.sleep(for: .milliseconds(150))

            var resolvedModel = forcedModel
            if resolvedModel == nil {
                await OllamaService.shared.refresh()
                let availability = referenceIndexingAvailability
                guard availability.isAvailable else {
                    await MainActor.run {
                        isIndexingReferences = false
                        referenceIndexError = referenceIndexUnavailableMessage(for: availability)
                    }
                    return
                }
                resolvedModel = referenceIndexModel()
            }
            guard let model = resolvedModel else {
                await MainActor.run {
                    isIndexingReferences = false
                    referenceIndexError = "Reference indexing is unavailable right now."
                }
                return
            }

            do {
                let outcome = try await LLMReferenceIndexBuilder.build(
                    documentURL: url,
                    model: model,
                    modelDescription: modelDescription
                ) { completed, total in
                    Task { @MainActor in
                        self.referenceIndexProgress = total > 0 ? Double(completed) / Double(total) : 1
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    referenceIndex.replace(with: outcome.snapshot)
                    isIndexingReferences = false
                    referenceIndexProgress = 1
                    referenceIndexError = nil
                    referenceIndexProvenance = ReferenceIndexProvenance(
                        builtWith: outcome.builtWith,
                        builtAt: outcome.builtAt,
                        entryCount: referenceIndex.count
                    )
                    let failedCount = outcome.failedPageIndices.count
                    referenceIndexWarning = failedCount == 0 ? nil :
                        "\(failedCount) page\(failedCount == 1 ? "" : "s") could not be indexed — they'll be retried next time this document is opened."
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    referenceIndex.clear()
                    isIndexingReferences = false
                    referenceIndexProgress = 0
                    referenceIndexProvenance = nil
                    referenceIndexError = error.localizedDescription
                }
            }
        }
    }

    /// Builds the BM25 retrieval index in the background; asks sent before it
    /// finishes simply run without retrieved passages.
    private func buildLexicalIndex(for url: URL) {
        lexicalIndexTask?.cancel()
        selectionThread.documentIndex = nil
        lexicalIndexTask = Task.detached(priority: .utility) { [weak self] in
            guard let index = LexicalDocumentIndex.build(documentURL: url),
                  !Task.isCancelled else { return }
            await MainActor.run {
                self?.selectionThread.documentIndex = index
            }
        }
    }

    private var referenceIndexingAvailability: ReadingAssistantAvailability {
        let local = OllamaService.shared.availability
        if local.isAvailable {
            return local
        }
        if let provider = AssistantPreferences.activeCloudProvider {
            return .available(provider.connectorID)
        }
        return local
    }

    private func referenceIndexModel() -> any LanguageModel {
        if let model = AssistantPreferences.localModel() {
            return model
        }
        if let model = AssistantPreferences.activeCloudModel() {
            return model
        }
        return OllamaLanguageModel(modelName: OllamaCatalog.defaultModelID ?? "")
    }

    private func referenceIndexUnavailableMessage(for availability: ReadingAssistantAvailability) -> String {
        switch availability {
        case .available:
            "Reference indexing is unavailable."
        case .ollamaNotRunning:
            "Reference indexing unavailable — start Ollama on this Mac."
        case .ollamaNoModels:
            "Reference indexing unavailable — install a model in Ollama."
        case .apiKeyMissing(let provider):
            "Reference indexing unavailable — add your \(provider.vendor) API key in Settings."
        case .cliNotInstalled:
            "Reference indexing unavailable — add an API key or start Ollama."
        case .unavailable:
            "Reference indexing unavailable — add an API key or start Ollama."
        }
    }

    private func stopSecurityScopedAccess() {
        referenceIndexTask?.cancel()
        referenceIndexTask = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}
