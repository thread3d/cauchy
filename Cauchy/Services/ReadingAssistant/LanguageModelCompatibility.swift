import Foundation
import FoundationModels

// MARK: - Model abstraction

/// The small generation surface Cauchy needs. Ollama, BYOK, and CLI models all
/// conform to it, and `ReadingLanguageModelSession` replays a transcript into
/// whichever one is selected.
///
/// (The macOS 27 FoundationModels SDK lets custom models plug into
/// `LanguageModelSession` directly; the macOS 26 SDK does not, and Cauchy no
/// longer depends on the system model, so this is all the abstraction it needs.)
protocol LanguageModel: Sendable {
    /// Streams one response, invoking `onDelta` with each newly generated
    /// fragment of text.
    func streamResponse(
        to prompt: CloudPrompt,
        onDelta: @Sendable (String) async -> Void
    ) async throws
}

// MARK: - Errors

/// The error vocabulary shared by local and remote providers. Ollama maps its
/// context-window failures onto `.contextSizeExceeded` so page-level indexing
/// can split and retry.
enum LanguageModelError: LocalizedError, Equatable {
    case contextSizeExceeded
    case rateLimited
    case guardrailViolation
    case refusal
    case other(String)

    var errorDescription: String? {
        switch self {
        case .contextSizeExceeded:
            return "The prompt exceeds the model's context window."
        case .rateLimited:
            return "The model is rate limited. Try again in a moment."
        case .guardrailViolation:
            return "The model declined to answer this request."
        case .refusal:
            return "The model refused to answer this request."
        case .other(let message):
            return message
        }
    }
}

// MARK: - Session

/// A provider-agnostic stand-in for `LanguageModelSession`. Every supported
/// provider is stateless per request, so the session replays its instructions
/// and transcript as one `CloudPrompt`.
@MainActor
final class ReadingLanguageModelSession {
    struct Snapshot: Sendable {
        let content: String
    }

    struct Response<Content> {
        let content: Content
    }

    private let model: any LanguageModel
    private let instructions: String?
    private let transcript: Transcript?
    private var requestsInFlight = 0

    init(model: any LanguageModel, instructions: String) {
        self.model = model
        self.instructions = instructions
        self.transcript = nil
    }

    init(model: any LanguageModel, transcript: Transcript) {
        self.model = model
        self.instructions = nil
        self.transcript = transcript
    }

    var isResponding: Bool {
        requestsInFlight > 0
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<Snapshot, Error> {
        let cloudPrompt = makePrompt(for: prompt)
        // Count the request before returning the stream so a second ask cannot
        // pass the `isResponding` guard in the frame between asking and running.
        requestsInFlight += 1
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                defer { requestsInFlight -= 1 }

                let accumulator = ResponseAccumulator()
                do {
                    try await model.streamResponse(to: cloudPrompt) { delta in
                        let content = await accumulator.append(delta)
                        continuation.yield(Snapshot(content: content))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func respond(to prompt: String) async throws -> Response<String> {
        var content = ""
        for try await snapshot in streamResponse(to: prompt) {
            content = snapshot.content
        }
        return Response(content: content)
    }

    private func makePrompt(for text: String) -> CloudPrompt {
        if let transcript {
            var prompt = CloudPrompt(transcript: transcript)
            prompt.turns.append(CloudPrompt.Turn(role: .user, text: text))
            return prompt
        }
        return CloudPrompt(instructions: instructions ?? "", prompt: text)
    }
}

/// Serializes the fragments a network/CLI model emits into whole snapshots.
private actor ResponseAccumulator {
    private var text = ""

    func append(_ delta: String) -> String {
        text += delta
        return text
    }
}
