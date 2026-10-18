import Foundation

enum ReadingAssistantAvailability: Equatable {
    case available(AssistantConnectorID)
    /// The local Ollama server could not be reached.
    case ollamaNotRunning
    /// Ollama is running but has no chat model installed.
    case ollamaNoModels
    case apiKeyMissing(CloudAPIProvider)
    case cliNotInstalled(AssistantConnectorID)
    case unavailable
}

extension ReadingAssistantAvailability {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var activeProvider: AssistantConnectorID? {
        if case .available(let provider) = self { return provider }
        return nil
    }
}

@MainActor
protocol ReadingAssistantProtocol: AnyObject {
    var provider: AssistantConnectorID { get }
    var availability: ReadingAssistantAvailability { get }
    var isResponding: Bool { get }
    func resetSession(context: ReadingContext)
    func restoreSession(context: ReadingContext, messages: [ThreadMessage])
    /// `retrieval` (PDF source excerpts + passages) reaches the model's prompt but
    /// is never stored in thread history or shown in the chat UI.
    func ask(question: String, retrieval: AskRetrieval, onPartial: ((String) -> Void)?) async throws -> String
}

extension ReadingAssistantProtocol {
    func ask(question: String, onPartial: ((String) -> Void)? = nil) async throws -> String {
        try await ask(question: question, retrieval: .empty, onPartial: onPartial)
    }
}

enum ReadingAssistantError: LocalizedError {
    case notAvailable(ReadingAssistantAvailability)
    case sessionUnavailable
    case sessionBusy
    case languageModel(LanguageModelError)
    case invalidAPIKey(CloudAPIProvider)
    case rateLimited(CloudAPIProvider)
    case network(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let availability):
            switch availability {
            case .available:
                return nil
            case .ollamaNotRunning:
                return "Start Ollama on this Mac (`ollama serve`) to use your local model."
            case .ollamaNoModels:
                return "Install a model in Ollama first, for example `ollama pull llama3.2`."
            case .apiKeyMissing(let provider):
                return "Add your \(provider.vendor) API key in Settings to use Ask."
            case .cliNotInstalled(let provider):
                return "\(provider.connector.name) is not set up. \(provider.connector.setupHint)"
            case .unavailable:
                return "Ask is not available right now."
            }
        case .sessionUnavailable:
            return "Could not start a reading assistant session."
        case .sessionBusy:
            return "The assistant is still responding. Wait for the current answer to finish."
        case .languageModel(let error):
            if case .contextSizeExceeded = error {
                return "The selected passage is too long for the model context window. Try selecting a shorter excerpt."
            }
            return error.localizedDescription
        case .invalidAPIKey(let provider):
            return "The \(provider.vendor) API key is invalid. Check your key in Settings."
        case .rateLimited(let provider):
            return "\(provider.vendor) rate limit reached. Try again in a moment."
        case .network(let message):
            return "Network error: \(message)"
        case .api(let message):
            return message
        }
    }
}
