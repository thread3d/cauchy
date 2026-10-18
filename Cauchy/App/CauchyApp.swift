import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when Settings changes which model answers questions. Every open
    /// window has its own assistant, so this is a broadcast rather than a call.
    static let commitReadingEdits = Notification.Name("CauchyCommitReadingEdits")
    static let assistantPreferencesChanged = Notification.Name("CauchyAssistantPreferencesChanged")
}

@main
struct CauchyApp: App {
    @NSApplicationDelegateAdaptor(SaveLifecycleDelegate.self) private var saveLifecycle
    /// True when the app was launched only to host a test bundle. The unit
    /// tests exercise pure logic, so a reader reopening yesterday's paper and
    /// starting an on-device index behind them is pure interference — enough
    /// of it that the test runner can time out waiting to connect.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Non-nil when launched headlessly as `Cauchy --benchmark-indexing …`.
    private static let benchmarkConfig = ReferenceIndexBenchmark.Config(arguments: CommandLine.arguments)
    private static let isRetrievalProbe = CommandLine.arguments.contains("--probe-retrieval")
    private static let isOCRProbe = CommandLine.arguments.contains("--probe-ocr")
    private static let isVisionProbe = CommandLine.arguments.contains("--probe-vision")
    private static let isMentionProbe = CommandLine.arguments.contains("--probe-mentions")
    private static let isGraphProbe = CommandLine.arguments.contains("--probe-graph")

    init() {
        if let config = Self.benchmarkConfig {
            Task.detached {
                let code = await ReferenceIndexBenchmark.run(config: config)
                exit(code)
            }
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--probe-retrieval"),
                  CommandLine.arguments.indices.contains(flagIndex + 2) {
            let pdfPath = CommandLine.arguments[flagIndex + 1]
            let query = CommandLine.arguments[flagIndex + 2]
            Task.detached {
                exit(await ReferenceIndexBenchmark.runRetrievalProbe(pdfPath: pdfPath, query: query))
            }
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--probe-ocr"),
                  CommandLine.arguments.indices.contains(flagIndex + 2) {
            let pdfPath = CommandLine.arguments[flagIndex + 1]
            let pageNumber = Int(CommandLine.arguments[flagIndex + 2]) ?? 0
            let useFastRecognition = CommandLine.arguments.indices.contains(flagIndex + 3)
                && CommandLine.arguments[flagIndex + 3] == "fast"
            let overlayDirectory: String? = if let outputIndex = CommandLine.arguments.firstIndex(of: "--output"),
                                               CommandLine.arguments.indices.contains(outputIndex + 1) {
                CommandLine.arguments[outputIndex + 1]
            } else {
                nil
            }
            Task.detached {
                exit(await ReferenceIndexBenchmark.runOCRProbe(
                    pdfPath: pdfPath,
                    pageNumber: pageNumber,
                    useFastRecognition: useFastRecognition,
                    jsonOutput: CommandLine.arguments.contains("--json"),
                    overlayDirectory: overlayDirectory
                ))
            }
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--probe-vision"),
                  CommandLine.arguments.indices.contains(flagIndex + 2) {
            let pdfPath = CommandLine.arguments[flagIndex + 1]
            let pageNumber = Int(CommandLine.arguments[flagIndex + 2]) ?? 0
            Task.detached {
                exit(await ReferenceIndexBenchmark.runVisionProbe(pdfPath: pdfPath, pageNumber: pageNumber))
            }
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--probe-mentions") {
            if CommandLine.arguments.indices.contains(flagIndex + 4) {
                let pdfPath = CommandLine.arguments[flagIndex + 1]
                let kind = CommandLine.arguments[flagIndex + 2]
                let number = CommandLine.arguments[flagIndex + 3]
                let definingPage = Int(CommandLine.arguments[flagIndex + 4]) ?? 0
                Task.detached {
                    exit(ReferenceIndexBenchmark.runMentionProbe(
                        pdfPath: pdfPath,
                        kind: kind,
                        number: number,
                        definingPage: definingPage,
                        jsonOutput: CommandLine.arguments.contains("--json")
                    ))
                }
            } else {
                Task.detached {
                    print("ERROR: use --probe-mentions <pdf> <kind> <number> <defining-page>")
                    exit(2)
                }
            }
        } else if let flagIndex = CommandLine.arguments.firstIndex(of: "--probe-graph") {
            if CommandLine.arguments.indices.contains(flagIndex + 2) {
                let pdfPath = CommandLine.arguments[flagIndex + 1]
                let labelsPath = CommandLine.arguments[flagIndex + 2]
                Task.detached {
                    exit(ReferenceIndexBenchmark.runGraphProbe(
                        pdfPath: pdfPath,
                        groundTruthPath: labelsPath,
                        jsonOutput: CommandLine.arguments.contains("--json")
                    ))
                }
            } else {
                Task.detached {
                    print("ERROR: use --probe-graph <pdf> <reference-labels.json> [--json]")
                    exit(2)
                }
            }
        } else if !Self.isHostingTests {
            // Normal GUI launch: discover the local Ollama models, and sweep
            // reference-index caches that no document has touched in months
            // (content-hashed names are never reused).
            Task { @MainActor in
                await OllamaService.shared.refresh()
            }
            Task.detached(priority: .background) {
                ReferenceIndexCacheStore.pruneStaleCaches()
            }
        }
    }

    var body: some Scene {
        // Deliberately without an `id`: an identified WindowGroup presents no
        // window of its own at launch, so a first run — or any run after the
        // saved window state is cleared — came up with a menu bar and nothing
        // else. Unidentified, SwiftUI presents the first window and supplies
        // File ▸ New Window itself.
        WindowGroup {
            if Self.benchmarkConfig != nil || Self.isRetrievalProbe || Self.isOCRProbe || Self.isVisionProbe || Self.isMentionProbe || Self.isGraphProbe {
                ProgressView("Running document probe — see terminal output…")
                    .padding(40)
            } else {
                ReaderWindow()
            }
        }
        .commands { ReaderCommands() }

        Settings {
            SettingsView {
                NotificationCenter.default.post(name: .assistantPreferencesChanged, object: nil)
            }
        }
    }
}

/// One window's worth of reader. The workspace lives here rather than on the
/// App so that a second window is a second document, not a second view of the
/// same one.
private struct ReaderWindow: View {
    @State private var workspace = WorkspaceViewModel()
    @Environment(\.undoManager) private var windowUndoManager

    /// Only the window the app launches with reopens the last document; a
    /// window the reader asked for is a window they want empty.
    @State private var didAttemptRestore = false

    var body: some View {
        ContentView(workspace: workspace)
            .frame(minWidth: 1100, minHeight: 700)
            .background(WindowAccessor { workspace.hostWindow = $0 })
            // Finder/dock open events (double-click, "Open With", dock
            // drops) arrive here; SwiftUI buffers ones that fire before
            // the scene connects. Deliberately the only open handler:
            // an NSApplicationDelegateAdaptor implementing
            // application(_:open:) would ALSO be called, double-opening
            // every file.
            .onOpenURL { url in
                guard url.isFileURL else { return }
                didAttemptRestore = true
                Task {
                    if url.pathExtension.lowercased() == ReadingSessionPackageService.filenameExtension {
                        await workspace.openReadingSession(at: url)
                    } else if url.pathExtension.lowercased() == "pdf" {
                        await workspace.openDocument(at: url)
                    }
                }
            }
            .focusedSceneValue(\.readerWorkspace, workspace)
            .onChange(of: windowUndoManager, initial: true) {
                workspace.hostUndoManager = windowUndoManager
            }
            .onReceive(NotificationCenter.default.publisher(for: .assistantPreferencesChanged)) { _ in
                workspace.refreshReadingAssistant()
            }
            .task {
                guard !didAttemptRestore, Self.claimLaunchRestore() else { return }
                didAttemptRestore = true
                await workspace.restoreLastSession()
            }
    }

    @MainActor private static var launchRestoreClaimed = false

    /// True exactly once per launch, for whichever window comes up first.
    @MainActor private static func claimLaunchRestore() -> Bool {
        guard !launchRestoreClaimed else { return false }
        launchRestoreClaimed = true
        return true
    }
}

@MainActor
final class SaveLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !CauchyApp.isHostingTests else { return .terminateNow }
        NotificationCenter.default.post(name: .commitReadingEdits, object: nil)
        Task {
            do {
                try await DocumentPersistenceService.shared.flushAll()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Your latest changes could not be saved"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Cauchy Open")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
