import Foundation

/// A BYOK provider dressed as a `LanguageModel`, so everything built on
/// `ReadingLanguageModelSession` — chat, reference indexing, thread titles —
/// works the same whether the answer comes from this Mac or from a vendor's
/// API. (The macOS 26 SDK's `LanguageModelSession` cannot host a custom model,
/// hence the app-level protocol in `LanguageModelCompatibility.swift`.)
struct CloudLanguageModel: LanguageModel {
    let provider: CloudAPIProvider
    let apiKey: String
    let modelName: String

    init(provider: CloudAPIProvider, apiKey: String, modelName: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.modelName = modelName ?? provider.defaultModelID
    }

    func streamResponse(
        to prompt: CloudPrompt,
        onDelta: @Sendable (String) async -> Void
    ) async throws {
        try await CloudStreamingClient.stream(
            provider: provider,
            apiKey: apiKey,
            modelName: modelName,
            prompt: prompt,
            onDelta: onDelta
        )
    }
}
