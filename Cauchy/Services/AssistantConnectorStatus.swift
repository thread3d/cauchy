import Foundation

/// Whether a connector can actually answer a question on this Mac right now.
enum ConnectorStatus: Equatable {
    /// Usable. The string is a short badge ("Installed", "On-device").
    case ready(String)
    /// One user action away. The string tells them which.
    case needsSetup(String)
    /// Not usable on this machine, and not because of anything they skipped.
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var badge: String {
        switch self {
        case .ready(let text): text
        case .needsSetup: "Set up"
        case .unavailable: "Unavailable"
        }
    }

    /// The sentence shown under an unusable connector, nil when it works.
    var hint: String? {
        switch self {
        case .ready: nil
        case .needsSetup(let text), .unavailable(let text): text
        }
    }

    /// Two or three words for a disabled menu row, nil when the connector
    /// works. The full instructions live in Settings.
    var shortNote: String? {
        switch self {
        case .ready: nil
        case .needsSetup: "not set up"
        case .unavailable: "unavailable"
        }
    }
}

extension AssistantConnector {
    /// Live availability, resolved the same way for the picker, Settings and
    /// the assistant factory.
    @MainActor
    var availability: ReadingAssistantAvailability {
        switch access {
        case .onDevice:
            // Covers paths that did not go through the launch refresh (headless
            // probes, a window restored before Ollama started). The task hops
            // off the main actor, so it is safe from a view body.
            OllamaService.shared.refreshIfNeeded()
            return OllamaService.shared.availability
        case .cliSignIn(let binary, _, _):
            return CLIAgentRunner.locateBinary(named: binary) == nil
                ? .cliNotInstalled(id)
                : .available(id)
        case .apiKey(let provider):
            return LanguageModelReadingAssistantService.availability(for: provider)
        }
    }

    @MainActor
    var status: ConnectorStatus {
        switch availability {
        case .available:
            switch access {
            case .onDevice: return .ready("Local")
            // The binary is there; whether the user is still signed in only
            // surfaces when an answer actually fails.
            case .cliSignIn: return .ready("Installed")
            case .apiKey: return .ready("Key saved")
            }
        case .cliNotInstalled, .apiKeyMissing, .ollamaNotRunning, .ollamaNoModels:
            return .needsSetup(setupHint)
        case .unavailable:
            return .unavailable("Not available right now.")
        }
    }

    @MainActor
    var isReady: Bool { status.isReady }

    /// Where the binary was found, for the Settings diagnostics line.
    @MainActor
    var resolvedBinaryURL: URL? {
        binaryName.flatMap(CLIAgentRunner.locateBinary(named:))
    }
}
