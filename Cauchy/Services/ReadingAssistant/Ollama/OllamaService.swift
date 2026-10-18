import Foundation
import Observation

/// A lock-protected snapshot of the local catalog, readable from any isolation
/// domain. The UI reads `models` while `OllamaService` owns refreshing it.
enum OllamaCatalog {
    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var installed: [OllamaInstalledModel] = []
        private var models: [AssistantModel] = []
        private var availability: ReadingAssistantAvailability = .ollamaNotRunning

        func update(
            installed: [OllamaInstalledModel],
            availability: ReadingAssistantAvailability
        ) {
            lock.withLock {
                self.installed = installed
                self.models = installed.map(\.assistantModel)
                self.availability = availability
            }
        }

        var installedModels: [OllamaInstalledModel] {
            lock.withLock { installed }
        }

        var assistantModels: [AssistantModel] {
            lock.withLock { models }
        }

        var currentAvailability: ReadingAssistantAvailability {
            lock.withLock { availability }
        }
    }

    private static let snapshot = Snapshot()

    static var installedModels: [OllamaInstalledModel] { snapshot.installedModels }
    static var models: [AssistantModel] { snapshot.assistantModels }
    static var availability: ReadingAssistantAvailability { snapshot.currentAvailability }

    /// The model a fresh install should use: the balanced rung, falling back to
    /// whatever the server lists first.
    static var defaultModelID: String? {
        let all = models
        // Models are sorted local-first, so this only lands on a `:cloud`
        // model when nothing local is installed.
        if let balanced = all.first(where: { $0.tier == .balanced }) {
            return balanced.id
        }
        return all.first?.id
    }

    /// The first installed model that can read page images, for the vision probe.
    static var visionModelID: String? {
        let candidates = installedModels.filter { $0.supportsCompletion && $0.supportsVision }
        // Prefer the model Ask already uses when it can see images, so the
        // probe and the index describe the same model.
        if let preferred = defaultModelID,
           candidates.contains(where: { $0.id == preferred }) {
            return preferred
        }
        return (candidates.first(where: { !$0.isCloudBacked }) ?? candidates.first)?.id
    }

    static func apply(
        installed: [OllamaInstalledModel],
        availability: ReadingAssistantAvailability
    ) {
        snapshot.update(installed: installed, availability: availability)
    }
}

/// Owns the local Ollama connection: it refreshes the model catalog, publishes
/// availability to the UI, and gives the rest of the app a cached answer.
@MainActor
@Observable
final class OllamaService {
    static let shared = OllamaService()

    private(set) var availability: ReadingAssistantAvailability = .ollamaNotRunning
    private(set) var models: [AssistantModel] = []
    /// Bumped after every refresh so views that list models re-render.
    private(set) var revision = 0

    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var isRefreshing = false

    private init() {}

    /// Refreshes at most once per window. Safe to call from view bodies: the
    /// network work hops off the main actor in a task.
    func refreshIfNeeded(maxAge: TimeInterval = 15) {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { await self.performRefresh() }
    }

    /// Forces a refresh, e.g. after the user starts Ollama or pulls a model.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await performRefresh()
    }

    private func performRefresh() async {
        defer {
            isRefreshing = false
            lastRefresh = Date()
            revision += 1
        }

        do {
            let installed = try await OllamaClient.installedModels()
            let chatModels = installed
                .filter(\.supportsCompletion)
                .sorted { lhs, rhs in
                    if lhs.isCloudBacked != rhs.isCloudBacked {
                        return !lhs.isCloudBacked
                    }
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
            let refreshedAvailability: ReadingAssistantAvailability = chatModels.isEmpty
                ? .ollamaNoModels
                : .available(.ollama)

            OllamaCatalog.apply(installed: chatModels, availability: refreshedAvailability)
            models = chatModels.map(\.assistantModel)
            availability = refreshedAvailability
        } catch {
            OllamaCatalog.apply(installed: [], availability: .ollamaNotRunning)
            models = []
            availability = .ollamaNotRunning
        }
    }
}
