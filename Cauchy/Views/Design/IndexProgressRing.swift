import SwiftUI

/// Determinate ring for reference-index progress.
///
/// The stock `ProgressView(value:)` with `.circular` renders on macOS as a
/// filled disc whose intrinsic size overflows the toolbar's glass capsule — it
/// reads as a stray blue dot rather than progress. Drawing the ring directly
/// keeps it on the same size grid as the toolbar's icon buttons and lets the
/// arc animate smoothly as pages complete.
struct IndexProgressRing: View {
    let progress: Double
    var diameter: CGFloat = 15
    var lineWidth: CGFloat = 2

    /// A hair of arc even at 0%, so the ring never looks like an empty circle
    /// during the first pages of a long document.
    private var trim: Double {
        min(max(progress, 0.03), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: trim)
                .stroke(
                    .tint,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.3), value: trim)
        .accessibilityLabel("Indexing references")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// The re-index actions, shared by the toolbar status pill and the Reference
/// panel's control so the two cannot drift apart.
struct ReferenceIndexMenuItems: View {
    @Bindable var workspace: WorkspaceViewModel

    var body: some View {
        let _ = OllamaService.shared.revision

        Button("Rebuild automatically") {
            workspace.rebuildReferenceIndex()
        }

        Divider()

        ForEach(AssistantConnector.primary + AssistantConnector.advanced) { connector in
            let title = connector.status.shortNote.map { "\(connector.name) — \($0)" }
                ?? connector.name
            if connector.hasModelChoice {
                Menu(title) {
                    ForEach(connector.models) { model in
                        Button(model.name) {
                            workspace.rebuildReferenceIndex(
                                connectorID: connector.id,
                                modelID: model.id
                            )
                        }
                    }
                }
                .disabled(!connector.isReady)
            } else {
                Button(title) {
                    workspace.rebuildReferenceIndex(connectorID: connector.id)
                }
                .disabled(!connector.isReady)
            }
        }
        .task { OllamaService.shared.refreshIfNeeded() }
    }
}
