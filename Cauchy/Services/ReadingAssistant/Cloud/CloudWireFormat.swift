import Foundation
import FoundationModels

/// A conversation reduced to what every vendor's API can express: one system
/// instruction plus alternating text turns. The FoundationModels transcript is
/// flattened into this once, and each wire format renders it into its own JSON
/// shape — so the transcript walk is written once rather than per vendor.
struct CloudPrompt: Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    struct Turn: Sendable {
        let role: Role
        let text: String
        /// Attached to the turn as an inline image. Only ever set on the final
        /// user turn (page vision during reference indexing).
        var imagePNG: Data?
    }

    var instructions: String?
    var turns: [Turn]

    init(instructions: String?, turns: [Turn]) {
        self.instructions = instructions
        self.turns = turns
    }

    /// One-shot prompt, optionally with a page image.
    init(instructions: String, prompt: String, imagePNG: Data? = nil) {
        self.instructions = instructions
        self.turns = [Turn(role: .user, text: prompt, imagePNG: imagePNG)]
    }

    init(transcript: Transcript) {
        var instructions: String?
        var turns: [Turn] = []

        for entry in transcript {
            switch entry {
            case .instructions(let entry):
                instructions = Self.text(from: entry.segments)
            case .prompt(let entry):
                if let text = Self.text(from: entry.segments), !text.isEmpty {
                    turns.append(Turn(role: .user, text: text))
                }
            case .response(let entry):
                if let text = Self.text(from: entry.segments), !text.isEmpty {
                    turns.append(Turn(role: .assistant, text: text))
                }
            case .toolCalls, .toolOutput:
                break // No native tool support in this mapper yet.
            @unknown default:
                break
            }
        }

        self.instructions = instructions
        self.turns = turns
    }

    /// The turn list every vendor will accept: never empty, and never ending on
    /// an assistant turn (the newest APIs reject a trailing assistant message,
    /// which they read as a prefill).
    var sendableTurns: [Turn] {
        var sendable = turns
        while sendable.last?.role == .assistant {
            sendable.removeLast()
        }
        if sendable.isEmpty {
            sendable = [Turn(role: .user, text: turns.first?.text ?? "Continue.")]
        }
        return sendable
    }

    private static func text(from segments: [Transcript.Segment]) -> String? {
        let parts = segments.compactMap { segment -> String? in
            guard case .text(let textSegment) = segment else { return nil }
            return textSegment.content
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined()
    }
}

/// How one vendor's HTTP API is spoken: how a request is addressed and
/// authenticated, how a prompt becomes JSON, and how its SSE stream is read.
///
/// Every implementation streams — the app's whole UI is built on partial
/// answers arriving as they are generated.
protocol CloudWireFormat: Sendable {
    var provider: CloudAPIProvider { get }

    func urlRequest(apiKey: String, modelName: String, prompt: CloudPrompt) throws -> URLRequest

    /// The incremental text carried by one SSE line, or nil for keep-alives,
    /// terminators, and non-text events (reasoning, usage, tool frames).
    func textDelta(fromLine line: String) -> String?

    /// The vendor's own message from an error body, for the >= 400 path.
    func errorMessage(from data: Data) -> String?
}

extension CloudWireFormat {
    /// Every vendor returns errors as `{"error": {"message": ...}}`; the ones
    /// that don't fall back to the raw body.
    func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return nil
    }

    /// The JSON object of a `data:` SSE line, or nil for anything that isn't
    /// one (comments, blank keep-alives, `[DONE]`).
    func dataPayload(fromLine rawLine: String) -> [String: Any]? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.hasPrefix("data:") else { return nil }

        let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !jsonString.isEmpty, jsonString != "[DONE]" else { return nil }

        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
    }

    func makeRequest(url: URL, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

extension CloudAPIProvider {
    var wire: any CloudWireFormat {
        switch self {
        case .anthropic: AnthropicWireFormat()
        case .openai: OpenAIWireFormat()
        case .gemini: GeminiWireFormat()
        }
    }
}

// MARK: - Google Gemini

struct GeminiWireFormat: CloudWireFormat {
    let provider = CloudAPIProvider.gemini

    func urlRequest(apiKey: String, modelName: String, prompt: CloudPrompt) throws -> URLRequest {
        let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse"
        )!

        var contents: [[String: Any]] = []
        for turn in prompt.sendableTurns {
            var parts: [[String: Any]] = []
            if let imagePNG = turn.imagePNG {
                parts.append([
                    "inline_data": [
                        "mime_type": "image/png",
                        "data": imagePNG.base64EncodedString(),
                    ],
                ])
            }
            parts.append(["text": turn.text])
            contents.append([
                "role": turn.role == .user ? "user" : "model",
                "parts": parts,
            ])
        }

        var body: [String: Any] = ["contents": contents]
        if let instructions = prompt.instructions, !instructions.isEmpty {
            body["systemInstruction"] = ["parts": [["text": instructions]]]
        }

        return try makeRequest(url: url, body: body, headers: ["x-goog-api-key": apiKey])
    }

    func textDelta(fromLine line: String) -> String? {
        guard let json = dataPayload(fromLine: line),
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }

        let textParts = parts.compactMap { part -> String? in
            if part["thought"] as? Bool == true { return nil }
            return part["text"] as? String
        }
        guard !textParts.isEmpty else { return nil }
        return textParts.joined()
    }
}

// MARK: - OpenAI

struct OpenAIWireFormat: CloudWireFormat {
    let provider = CloudAPIProvider.openai

    func urlRequest(apiKey: String, modelName: String, prompt: CloudPrompt) throws -> URLRequest {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var messages: [[String: Any]] = []
        if let instructions = prompt.instructions, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        for turn in prompt.sendableTurns {
            let role = turn.role == .user ? "user" : "assistant"
            if let imagePNG = turn.imagePNG {
                messages.append([
                    "role": role,
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,\(imagePNG.base64EncodedString())",
                            ],
                        ],
                        ["type": "text", "text": turn.text],
                    ],
                ])
            } else {
                messages.append(["role": role, "content": turn.text])
            }
        }

        // No temperature or token cap: the reasoning models reject the first
        // outright, and the second differs in name between model families.
        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
        ]

        return try makeRequest(url: url, body: body, headers: ["Authorization": "Bearer \(apiKey)"])
    }

    func textDelta(fromLine line: String) -> String? {
        guard let json = dataPayload(fromLine: line),
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let text = delta["content"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}

// MARK: - Anthropic

struct AnthropicWireFormat: CloudWireFormat {
    let provider = CloudAPIProvider.anthropic

    /// Required by the Messages API, and a hard cap on thinking plus answer.
    /// Generous enough that a long proof is never cut off mid-line.
    private static let maxTokens = 16_000

    func urlRequest(apiKey: String, modelName: String, prompt: CloudPrompt) throws -> URLRequest {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var messages: [[String: Any]] = []
        for turn in prompt.sendableTurns {
            let role = turn.role == .user ? "user" : "assistant"
            if let imagePNG = turn.imagePNG {
                messages.append([
                    "role": role,
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                "data": imagePNG.base64EncodedString(),
                            ],
                        ],
                        ["type": "text", "text": turn.text],
                    ],
                ])
            } else {
                messages.append(["role": role, "content": turn.text])
            }
        }

        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": Self.maxTokens,
            "messages": messages,
            "stream": true,
        ]
        if let instructions = prompt.instructions, !instructions.isEmpty {
            body["system"] = instructions
        }

        return try makeRequest(
            url: url,
            body: body,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ]
        )
    }

    func textDelta(fromLine line: String) -> String? {
        guard let json = dataPayload(fromLine: line),
              json["type"] as? String == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              // Thinking arrives on the same event with a different delta type;
              // it is the model's scratch work, not part of the answer.
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}
