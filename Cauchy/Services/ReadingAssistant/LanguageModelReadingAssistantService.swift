import Foundation
import FoundationModels

/// The reading assistant backed by a local Ollama model or a BYOK provider.
/// Both are stateless per request, so `ReadingLanguageModelSession` replays the
/// transcript as a single prompt.
@MainActor
final class LanguageModelReadingAssistantService: ReadingAssistantProtocol {
    let provider: AssistantConnectorID

    private let model: any LanguageModel
    private var session: ReadingLanguageModelSession?

    init(model: any LanguageModel, provider: AssistantConnectorID) {
        self.model = model
        self.provider = provider
    }

    static func availability(for apiProvider: CloudAPIProvider) -> ReadingAssistantAvailability {
        KeychainService.hasKey(for: apiProvider)
            ? .available(apiProvider.connectorID)
            : .apiKeyMissing(apiProvider)
    }

    var availability: ReadingAssistantAvailability {
        guard let apiProvider = provider.connector.apiProvider else {
            return OllamaService.shared.availability
        }
        return Self.availability(for: apiProvider)
    }

    private var isAvailable: Bool {
        if let apiProvider = provider.connector.apiProvider {
            return KeychainService.hasKey(for: apiProvider)
        }
        return OllamaService.shared.availability.isAvailable
    }

    var isResponding: Bool {
        session?.isResponding ?? false
    }

    func resetSession(context: ReadingContext) {
        session = ReadingLanguageModelSession(
            model: model,
            instructions: ReadingPromptBuilder.instructions(for: context, provider: provider)
        )
    }

    func restoreSession(context: ReadingContext, messages: [ThreadMessage]) {
        let instructionText = ReadingPromptBuilder.instructions(for: context, provider: provider)
        let instructionsEntry = Transcript.Entry.instructions(
            Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructionText))],
                toolDefinitions: []
            )
        )

        var entries: [Transcript.Entry] = [instructionsEntry]
        for message in messages {
            switch message.role {
            case .user:
                entries.append(.prompt(
                    Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: message.content))])
                ))
            case .assistant:
                entries.append(.response(
                    Transcript.Response(
                        assetIDs: [],
                        segments: [.text(Transcript.TextSegment(content: message.content))]
                    )
                ))
            }
        }

        session = ReadingLanguageModelSession(model: model, transcript: Transcript(entries: entries))
    }

    func ask(
        question: String,
        retrieval: AskRetrieval,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        guard isAvailable else {
            throw ReadingAssistantError.notAvailable(availability)
        }
        guard let session else {
            throw ReadingAssistantError.sessionUnavailable
        }
        guard !session.isResponding else {
            throw ReadingAssistantError.sessionBusy
        }

        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Retrieval rides the per-turn prompt (sessions fix their instructions
        // at reset/restore time). Exact statements come first and get priority
        // budget; both budgets stay small enough for the local window.
        var prompt = trimmed
        let budgets = ReadingPromptBuilder.evidenceBudgets(for: provider)
        var blocks: [String] = []
        if let block = ReadingPromptBuilder.referencedStatementsBlock(retrieval.statements, characterBudget: budgets.statements) {
            blocks.append(block)
        }
        if let block = ReadingPromptBuilder.retrievedPassagesBlock(retrieval.passages, characterBudget: budgets.passages) {
            blocks.append(block)
        }
        if let block = ReadingPromptBuilder.citableSourcesBlock(retrieval.citableSources) {
            blocks.append(block)
        }
        if !blocks.isEmpty {
            prompt = blocks.joined(separator: "\n\n") + "\n\nQUESTION: " + trimmed
        }

        do {
            let stream = session.streamResponse(to: prompt)
            var accumulated = ""
            for try await snapshot in stream {
                accumulated = snapshot.content
                onPartial?(AssistantResponseNormalizer.normalize(accumulated))
            }

            let normalized = AssistantResponseNormalizer.normalize(accumulated)
            let final = try await ensureDisplayReady(normalized, onPartial: onPartial)
            onPartial?(final)
            return final
        } catch let error as CloudAPIError {
            throw Self.mapCloudError(error)
        } catch let error as OllamaError {
            if case .notRunning = error {
                throw ReadingAssistantError.notAvailable(.ollamaNotRunning)
            }
            throw ReadingAssistantError.network(error.localizedDescription)
        } catch let error as LanguageModelError {
            throw ReadingAssistantError.languageModel(error)
        }
    }

    private func ensureDisplayReady(
        _ text: String,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        guard !AssistantResponseValidator.isDisplayReady(text) else { return text }

        let repairSession = ReadingLanguageModelSession(
            model: model,
            instructions: ReadingPromptBuilder.latexRepairInstructions()
        )
        let stream = repairSession.streamResponse(
            to: ReadingPromptBuilder.latexRepairPrompt(previousOutput: text)
        )

        var repaired = ""
        for try await snapshot in stream {
            repaired = snapshot.content
            onPartial?(AssistantResponseNormalizer.normalize(repaired))
        }

        let normalized = AssistantResponseNormalizer.normalize(repaired)
        return AssistantResponseValidator.isDisplayReady(normalized) ? normalized : text
    }

    static func mapCloudError(_ error: CloudAPIError) -> ReadingAssistantError {
        switch error {
        case .invalidAPIKey(let provider):
            return .invalidAPIKey(provider)
        case .rateLimited(let provider):
            return .rateLimited(provider)
        case .network(let message):
            return .network(message)
        case .api(let message):
            return .api(message)
        }
    }
}
