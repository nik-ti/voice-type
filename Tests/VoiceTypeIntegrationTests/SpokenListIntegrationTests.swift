// Checks that explicit spoken lists survive the actual Polished fallback path.
// The model stays unloaded so this does not require weights, microphone access or paste.
import XCTest
import VoiceTypeCore
@testable import VoiceType

@MainActor
final class SpokenListIntegrationTests: XCTestCase {
    func testThreeThingsIntroductionSurvivesTheFullFallbackPath() async throws {
        let input = "We're gonna need three things happen. Number 1, fix the backend. Number 2, install the new model, number 3, rewrite the entire content."
        let recognized = TranscriptNormalizer.normalize(input)
        let model = LLMService()
        let output = try await model.processPolished(model.basicFormat(recognized, language: .english), language: .english)
        XCTAssertTrue(output.contains(":\n\n1. "), output)
        XCTAssertTrue(output.contains("\n2. "), output)
        XCTAssertTrue(output.contains("\n3. "), output)
        for fragment in ["fix the backend", "install the new model", "rewrite the entire content"] {
            XCTAssertTrue(output.lowercased().contains(fragment), output)
        }
        XCTAssertEqual(model.lastFallbackReason, "model_not_ready")
    }

    func testUnavailableModelStillFormatsEveryConstraint() async throws {
        let input = "Here's the list of constraints. Number 1, we have to make sure that the video is not too long. Number 2, we have to make sure proper tests are written beforehand. Number 3, the UI must be mobile friendly."
        let model = LLMService()
        let output = try await model.processPolished(model.basicFormat(input, language: .english), language: .english)
        XCTAssertTrue(output.hasPrefix("Here's the list of constraints:"), output)
        XCTAssertTrue(output.contains("\n1. "), output)
        XCTAssertTrue(output.contains("\n2. "), output)
        XCTAssertTrue(output.contains("\n3. "), output)
        XCTAssertTrue(output.contains("video is not too long"), output)
        XCTAssertTrue(output.contains("proper tests are written beforehand"), output)
        XCTAssertTrue(output.contains("UI must be mobile friendly"), output)
        XCTAssertEqual(model.lastFallbackReason, "model_not_ready")
    }

    func testListSurvivesRecognitionNumberNormalization() async throws {
        let input = "Here's the list of constraints. Number one, Keep the video short. Number two, Write tests first. Number three, Make the UI mobile friendly."
        let recognized = TranscriptNormalizer.normalize(input)
        let model = LLMService()
        let output = try await model.processPolished(model.basicFormat(recognized, language: .english), language: .english)
        XCTAssertTrue(output.hasPrefix("Here's the list of constraints:"), "Normalized: \(recognized); result: \(output)")
        for index in 1...3 { XCTAssertTrue(output.contains("\n\(index). "), output) }
    }
}
