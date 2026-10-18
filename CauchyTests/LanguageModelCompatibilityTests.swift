import FoundationModels
import XCTest
@testable import Cauchy

/// The macOS 26 port replaces the FoundationModels session's custom-model
/// support with `ReadingLanguageModelSession`. These tests pin the two
/// behaviours the BYOK and CLI paths rely on: deltas surface as accumulated
/// snapshots, and a restored transcript is replayed with the new question.
@MainActor
final class LanguageModelCompatibilityTests: XCTestCase {
    private actor PromptRecorder {
        private var recorded: [CloudPrompt] = []

        func record(_ prompt: CloudPrompt) {
            recorded.append(prompt)
        }

        func last() -> CloudPrompt? {
            recorded.last
        }
    }

    private struct ScriptedLanguageModel: LanguageModel {
        let chunks: [String]
        var recorder: PromptRecorder? = nil

        func streamResponse(
            to prompt: CloudPrompt,
            onDelta: @Sendable (String) async -> Void
        ) async throws {
            if let recorder {
                await recorder.record(prompt)
            }
            for chunk in chunks {
                await onDelta(chunk)
            }
        }
    }

    func testCustomModelDeltasSurfaceAsAccumulatedSnapshots() async throws {
        let session = ReadingLanguageModelSession(
            model: ScriptedLanguageModel(chunks: ["The ", "answer ", "is 2."]),
            instructions: "Be brief."
        )

        let response = try await session.respond(to: "What is 1 + 1?")

        XCTAssertEqual(response.content, "The answer is 2.")
    }

    func testRestoredTranscriptReachesACustomModelWithTheNewQuestion() async throws {
        let recorder = PromptRecorder()
        let session = ReadingLanguageModelSession(
            model: ScriptedLanguageModel(chunks: ["Second answer."], recorder: recorder),
            transcript: Transcript(entries: [
                .instructions(Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: "System rules"))],
                    toolDefinitions: []
                )),
                .prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: "First question?"))]
                )),
                .response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: "First answer."))]
                )),
            ])
        )

        _ = try await session.respond(to: "Second question?")

        let prompt = await recorder.last()
        XCTAssertEqual(prompt?.instructions, "System rules")
        XCTAssertEqual(prompt?.turns.map(\.text), [
            "First question?",
            "First answer.",
            "Second question?",
        ])
    }

    func testLanguageModelErrorKeepsItsDescription() {
        XCTAssertEqual(
            LanguageModelError.contextSizeExceeded.localizedDescription,
            "The prompt exceeds the model's context window."
        )
        XCTAssertEqual(
            LanguageModelError.other("provider said no").localizedDescription,
            "provider said no"
        )
    }
}
