import XCTest
@testable import Cauchy

/// The local provider must survive both the Ollama wire format and installs
/// whose stored selection predates the switch from Apple Intelligence.
final class OllamaServiceTests: XCTestCase {
    func testCatalogDecodingDerivesTiersAndVisionSupport() throws {
        let json = """
        {
          "models": [
            {
              "name": "qwen3.8:27b",
              "details": { "parameter_size": "27.3B", "quantization_level": "Q4_K_M" },
              "capabilities": ["completion", "vision", "tools", "thinking"]
            },
            {
              "name": "tiny:latest",
              "details": { "parameter_size": "3B", "quantization_level": "Q4_0" },
              "capabilities": ["completion"]
            },
            {
              "name": "embed:latest",
              "details": { "parameter_size": "137M", "quantization_level": "F16" },
              "capabilities": ["embedding"]
            }
          ]
        }
        """

        let models = try OllamaClient.decodeInstalledModels(Data(json.utf8))

        XCTAssertEqual(models.map(\.id), ["qwen3.8:27b", "tiny:latest", "embed:latest"])
        XCTAssertEqual(models[0].tier, .balanced)
        XCTAssertEqual(models[1].tier, .fast)
        XCTAssertTrue(models[0].supportsVision)
        XCTAssertFalse(models[1].supportsVision)
        XCTAssertFalse(models[2].supportsCompletion)
        XCTAssertEqual(models[0].assistantModel.blurb, "27.3B · Q4_K_M · vision")
    }

    func testStoredAppleSelectionStillReadsAsOllama() {
        XCTAssertEqual(AssistantConnectorID(rawValue: "onDevice"), .ollama)
        XCTAssertEqual(AssistantConnectorID.ollama.rawValue, "onDevice")
        XCTAssertEqual(
            AssistantConnectorID.ollama.connector.name,
            "Ollama"
        )
    }

    @MainActor
    func testLiveOllamaServerListsAndAnswersWhenAvailable() async throws {
        await OllamaService.shared.refresh()

        guard OllamaService.shared.availability.isAvailable else {
            throw XCTSkip("Ollama is not running on this Mac; skipping the live check.")
        }
        XCTAssertFalse(OllamaCatalog.models.isEmpty)

        let connector = AssistantConnector.for(.ollama)
        XCTAssertTrue(connector.hasModelChoice)
        XCTAssertEqual(connector.status.isReady, true)
        XCTAssertNotNil(AssistantPreferences.localModel())

        guard let modelID = OllamaCatalog.defaultModelID else {
            XCTFail("Ollama is available but reported no model.")
            return
        }

        let session = ReadingLanguageModelSession(
            model: OllamaLanguageModel(modelName: modelID),
            instructions: "Reply with exactly the word OK and nothing else."
        )
        let response = try await session.respond(to: "Say OK")
        XCTAssertFalse(
            response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Ollama returned an empty answer for \(modelID)."
        )
    }
}
