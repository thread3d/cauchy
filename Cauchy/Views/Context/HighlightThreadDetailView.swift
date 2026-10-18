import SwiftUI

struct HighlightThreadDetailView: View {
    @Bindable var workspace: WorkspaceViewModel
    var onBack: () -> Void

    @State private var question = ""

    private var thread: SelectionThread? {
        workspace.selectionThread.activeThread
    }

    var body: some View {
        GeometryReader { geometry in
            ConversationPanel(
                selectedText: thread?.selectedText,
                messages: thread?.messages ?? [],
                streamingText: thread?.streamingAssistantText,
                isResponding: workspace.selectionThread.isResponding,
                isAskAvailable: workspace.readingAssistantAvailability.isAvailable,
                unavailabilityMessage: unavailabilityMessage,
                panelWidth: geometry.size.width,
                question: $question,
                onSend: { sendQuestion() },
                onStop: {
                    if let unanswered = workspace.stopThreadMessage() {
                        question = unanswered
                    }
                },
                onModelChange: { workspace.refreshReadingAssistant() },
                onOpenSource: { workspace.goToAnswerSource($0) },
                header: { header }
            )
        }
    }

    /// Floats over the conversation. Nothing here is a surface: the glass
    /// belongs to the controls — the back button and, when it is there, the
    /// save button — while the title simply lies over the progressive blur the
    /// scroll edge effect draws where the messages pass underneath. A glass
    /// slab behind the whole row reads as one enormous button, which is both
    /// wrong and a lie about what is clickable.
    private var header: some View {
        headerRow
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            GlassIconButton(
                systemName: "chevron.left",
                accessibilityLabel: "Back",
                action: onBack
            )

            // The thread's name, the same one the list shows — a header reading
            // "Highlight" told the reader nothing they didn't already know from
            // the tab above it.
            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let pageIndex = thread?.pageIndex {
                    Text("Page \(pageIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // A label, not a control. Without this the row's empty space is
            // still a hit target and the header behaves like one wide button.
            .allowsHitTesting(false)

            Spacer(minLength: 6)

            if let id = savedHighlightID, let highlight = savedHighlight {
                Menu {
                    HighlightColorMenu(current: highlight.color) { colour in
                        workspace.setColor(colour, for: id)
                    }
                    Divider()
                    Button("Copy as Markdown") {
                        workspace.copyThreadAsMarkdown(highlight)
                    }
                    Divider()
                    Button("Delete Highlight", role: .destructive) {
                        workspace.deleteHighlight(highlight)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .accessibilityLabel("Highlight options")
            }

            if thread?.isPersisted == false {
                Button("Save as Highlight") {
                    workspace.saveTextSelectionAsHighlight()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
        }
    }

    /// The saved highlight this thread belongs to, if it has been saved at all.
    private var savedHighlight: Highlight? {
        guard let anchorID = thread?.anchorID else { return nil }
        return workspace.highlightStore.highlights.first { $0.id == anchorID }
    }

    private var savedHighlightID: UUID? { savedHighlight?.id }

    /// The saved thread's name when there is one; a draft selection has no
    /// highlight behind it yet, so it is named by its passage.
    private var headerTitle: String {
        guard let thread else { return "Highlight" }
        if let saved = workspace.highlightStore.highlights.first(where: { $0.id == thread.anchorID }) {
            return saved.displayName
        }
        return Highlight.title(from: thread.selectedText)
    }

    private var unavailabilityMessage: String? {
        guard !workspace.readingAssistantAvailability.isAvailable else { return nil }
        switch workspace.readingAssistantAvailability {
        case .ollamaNotRunning:
            return "Start Ollama on this Mac to ask questions with your local model."
        case .ollamaNoModels:
            return "Install a model in Ollama (for example `ollama pull llama3.2`) to ask questions."
        case .apiKeyMissing(let provider):
            return "Add your \(provider.vendor) API key in Settings to ask questions."
        case .cliNotInstalled(let provider):
            return "\(provider.connector.name) is not set up. \(provider.connector.setupHint)"
        default:
            return "Ask is unavailable right now."
        }
    }

    private func sendQuestion() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace.sendThreadMessage(trimmed)
        question = ""
    }
}
