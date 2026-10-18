import Foundation

/// One model the local Ollama server reports as installed.
struct OllamaInstalledModel: Identifiable, Hashable, Sendable {
    /// The name sent to `/api/chat`, tag included (`qwen3.8:27b`).
    let id: String
    let parameterSize: String?
    let quantization: String?
    let capabilities: Set<String>

    /// Older Ollama versions omit `capabilities`; those models are assumed to
    /// be chat models, which is the only kind Cauchy can use.
    var supportsCompletion: Bool {
        capabilities.isEmpty || capabilities.contains("completion")
    }

    var supportsVision: Bool {
        capabilities.contains("vision")
    }

    /// Ollama's `:cloud` models are proxied to a remote host. They still answer
    /// through the local API, but they are not local inference, so the app
    /// prefers a truly local model when one is installed.
    var isCloudBacked: Bool {
        id.lowercased().hasSuffix(":cloud")
    }

    var tier: ModelTier {
        Self.tier(for: parameterSize)
    }

    var blurb: String {
        [parameterSize, quantization, supportsVision ? "vision" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var assistantModel: AssistantModel {
        AssistantModel(id: id, name: id, tier: tier, blurb: blurb)
    }

    /// Parameter counts decide the speed↔depth rung. A missing or malformed
    /// size lands in the middle rather than pretending to know.
    private static func tier(for parameterSize: String?) -> ModelTier {
        guard let parameterSize else { return .balanced }
        let trimmed = parameterSize.trimmingCharacters(in: .whitespaces)
        guard let suffix = trimmed.last,
              let value = Double(trimmed.dropLast()), value > 0
        else { return .balanced }

        // Ollama reports billions ("27.3B") and, for tiny models, millions ("350M").
        let billions = suffix.uppercased() == "M" ? value / 1_000 : value
        if billions < 8 { return .fast }
        if billions < 32 { return .balanced }
        return .max
    }
}

enum OllamaError: LocalizedError {
    case notRunning
    case http(Int, String)
    case server(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Ollama isn't running on this Mac. Start it with `ollama serve`."
        case .http(let status, let message):
            return "Ollama returned HTTP \(status): \(message)"
        case .server(let message):
            return "Ollama: \(message)"
        case .emptyResponse:
            return "Ollama returned an empty response."
        }
    }
}

/// The one place Cauchy talks to the local Ollama daemon. Chat, reference
/// indexing, thread titles, and the vision probe all go through here.
enum OllamaClient {
    /// Ollama's own variable: `host:port`, optionally with a scheme. A bare
    /// value gets `http://`, the default matches `ollama serve`.
    static var baseURL: URL {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["OLLAMA_HOST"] ?? environment["OLLAMA_BASE_URL"] ?? "127.0.0.1:11434"
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, !value.contains("://") {
            value = "http://" + value
        }
        if value.hasSuffix("/") { value.removeLast() }
        return URL(string: value) ?? URL(string: "http://127.0.0.1:11434")!
    }

    static var chatURL: URL { baseURL.appending(path: "api/chat") }
    static var tagsURL: URL { baseURL.appending(path: "api/tags") }

    // MARK: - Catalog

    /// `GET /api/tags` with a short timeout: availability checks should not
    /// hang a picker or a Settings row.
    static func installedModels(timeout: TimeInterval = 3) async throws -> [OllamaInstalledModel] {
        var request = URLRequest(url: tagsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OllamaError.server("Invalid response from \(baseURL.absoluteString).")
            }
            guard http.statusCode == 200 else {
                throw OllamaError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
            return try decodeInstalledModels(data)
        } catch let error as OllamaError {
            throw error
        } catch is URLError {
            throw OllamaError.notRunning
        }
    }

    /// Decoded separately so the catalog mapping can be tested without a server.
    static func decodeInstalledModels(_ data: Data) throws -> [OllamaInstalledModel] {
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models.map { model in
            OllamaInstalledModel(
                id: model.name,
                parameterSize: model.details?.parameterSize,
                quantization: model.details?.quantizationLevel,
                capabilities: Set(model.capabilities ?? [])
            )
        }
    }

    // MARK: - Generation

    /// Streams one chat completion, calling `onDelta` with each text fragment.
    static func stream(
        model: String,
        prompt: CloudPrompt,
        onDelta: @Sendable (String) async -> Void
    ) async throws {
        guard !model.isEmpty else {
            throw OllamaError.server("No local model is selected.")
        }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A local model on CPU can take minutes for a long page; streaming
        // keeps the UI alive, and the timeout only guards a stalled socket.
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(model: model, prompt: prompt))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.server("Invalid response from \(baseURL.absoluteString).")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OllamaError.http(http.statusCode, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let decoder = JSONDecoder()
        var sawContent = false
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let chunk = try? decoder.decode(ChatChunk.self, from: Data(trimmed.utf8)) else {
                continue
            }
            if let message = chunk.error {
                throw Self.error(fromServerMessage: message)
            }
            if let content = chunk.message?.content, !content.isEmpty {
                sawContent = true
                await onDelta(content)
            }
            if chunk.done == true { break }
        }

        guard sawContent else { throw OllamaError.emptyResponse }
    }

    /// Streams to completion and returns the whole answer, for jobs with no UI.
    static func text(model: String, prompt: CloudPrompt) async throws -> String {
        let accumulator = TextAccumulator()
        try await stream(model: model, prompt: prompt) { delta in
            await accumulator.append(delta)
        }
        return await accumulator.value().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wire format

    private static func payload(model: String, prompt: CloudPrompt) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let instructions = prompt.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        for turn in prompt.sendableTurns {
            var message: [String: Any] = [
                "role": turn.role == .user ? "user" : "assistant",
                "content": turn.text,
            ]
            if let image = turn.imagePNG {
                message["images"] = [image.base64EncodedString()]
            }
            messages.append(message)
        }

        return [
            "model": model,
            "messages": messages,
            "stream": true,
            // Thinking models otherwise spend the whole reply in `thinking`
            // and leave `content` empty. Ollama ignores the flag elsewhere.
            "think": false,
            // Ollama's default window is 4k tokens; a reference-index page plus
            // its instructions does not fit, and truncation would silently drop
            // the very statements being extracted.
            "options": ["num_ctx": 8_192],
        ]
    }

    private static func error(fromServerMessage message: String) -> Error {
        let lowered = message.lowercased()
        if lowered.contains("context") &&
            (lowered.contains("length") || lowered.contains("window") || lowered.contains("exceed")) {
            return LanguageModelError.contextSizeExceeded
        }
        if lowered.contains("not found") || lowered.contains("no such model") {
            return OllamaError.server("\(message) — pull it with `ollama pull <model>`.")
        }
        return OllamaError.server(message)
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let parameterSize: String?
                let quantizationLevel: String?

                enum CodingKeys: String, CodingKey {
                    case parameterSize = "parameter_size"
                    case quantizationLevel = "quantization_level"
                }
            }

            let name: String
            let details: Details?
            let capabilities: [String]?
        }

        let models: [Model]
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
        let error: String?
        let done: Bool?
    }
}

private actor TextAccumulator {
    private var text = ""

    func append(_ delta: String) {
        text += delta
    }

    func value() -> String {
        text
    }
}

/// A local Ollama model dressed as the app's `LanguageModel`, so chat,
/// reference indexing, and thread titles share one code path.
struct OllamaLanguageModel: LanguageModel {
    let modelName: String

    func streamResponse(
        to prompt: CloudPrompt,
        onDelta: @Sendable (String) async -> Void
    ) async throws {
        try await OllamaClient.stream(model: modelName, prompt: prompt, onDelta: onDelta)
    }
}
