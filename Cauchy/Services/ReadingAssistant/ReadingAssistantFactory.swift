import Foundation

/// Turns the user's connector + model choice into a live assistant. All the
/// knowledge about *what* each connector is lives in `AssistantConnector`; this
/// only knows how to start one.
@MainActor
enum ReadingAssistantFactory {
    static func makeAssistant() -> any ReadingAssistantProtocol {
        // A CLI may have been installed, or Ollama started, since the last lookup.
        CLIAgentRunner.invalidateBinaryCache()
        OllamaService.shared.refreshIfNeeded()

        let resolved = AssistantPreferences.resolved
        switch resolved.connector.access {
        case .onDevice:
            return localAssistant(resolved: resolved)

        case .cliSignIn:
            return CLIAgentAssistantService(
                connector: resolved.connector.id,
                modelID: resolved.modelID
            )

        case .apiKey(let apiProvider):
            guard let apiKey = KeychainService.loadKey(for: apiProvider) else {
                // `availability` reports the missing key; the composer stays disabled.
                return localAssistant(resolved: resolved)
            }
            return LanguageModelReadingAssistantService(
                model: CloudLanguageModel(
                    provider: apiProvider,
                    apiKey: apiKey,
                    modelName: resolved.modelID
                ),
                provider: resolved.connector.id
            )
        }
    }

    /// The connector answers are currently coming from, after Automatic has
    /// been resolved.
    static var activeConnector: AssistantConnector {
        AssistantPreferences.resolved.connector
    }

    static var availability: ReadingAssistantAvailability {
        activeConnector.availability
    }

    private static func localAssistant(resolved: ResolvedAssistant) -> any ReadingAssistantProtocol {
        let modelName = resolved.modelID
            ?? OllamaCatalog.defaultModelID
            ?? ""
        return LanguageModelReadingAssistantService(
            model: OllamaLanguageModel(modelName: modelName),
            provider: .ollama
        )
    }
}
