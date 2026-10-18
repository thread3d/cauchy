import Foundation

/// The reference-index jobs that need a cloud provider directly rather than
/// the shared text path: page extraction with vision, and the two repair
/// passes. All three vendors accept an inline PNG, so any BYOK key can drive a
/// vision re-index.
struct CloudReferenceIndexClient: Sendable {
    let provider: CloudAPIProvider
    let apiKey: String
    let modelName: String

    init(provider: CloudAPIProvider, apiKey: String, modelName: String) {
        self.provider = provider
        self.apiKey = apiKey
        self.modelName = modelName
    }

    init(model: CloudLanguageModel) {
        self.init(provider: model.provider, apiKey: model.apiKey, modelName: model.modelName)
    }

    func indexPage(imagePNG: Data, pageText: String, pageIndex: Int) async throws -> String {
        try await send(
            CloudPrompt(
                instructions: ReferenceIndexPromptBuilder.visionInstructions,
                prompt: ReferenceIndexPromptBuilder.visionUserPrompt(
                    pageText: pageText,
                    pageIndex: pageIndex
                ),
                imagePNG: imagePNG
            )
        )
    }

    func repairJSON(previousOutput: String) async throws -> String {
        try await send(
            CloudPrompt(
                instructions: ReferenceIndexPromptBuilder.instructions,
                prompt: ReferenceIndexPromptBuilder.jsonRepairPrompt(previousOutput: previousOutput)
            )
        )
    }

    func repairLaTeX(previousOutput: String) async throws -> String {
        try await send(
            CloudPrompt(
                instructions: ReadingPromptBuilder.latexRepairInstructions(),
                prompt: ReadingPromptBuilder.latexRepairPrompt(previousOutput: previousOutput)
            )
        )
    }

    private func send(_ prompt: CloudPrompt) async throws -> String {
        try await CloudStreamingClient.text(
            provider: provider,
            apiKey: apiKey,
            modelName: modelName,
            prompt: prompt
        )
    }
}
