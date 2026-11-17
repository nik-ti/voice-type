// Checks that repeated Polished takes do not keep growing GPU memory, the cause of the multi-day slowdown.
// Opt in with the same variables as PolishedQualityTests; this loads the real local model.
import XCTest
import MLX
@testable import VoiceType

@MainActor
final class PolishMemoryTests: XCTestCase {
    func testRepeatedPolishingReturnsMemoryToBaseline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICETYPE_POLISH_QUALITY"] == "1",
              let shader = environment["VOICETYPE_METALLIB"] else {
            throw XCTSkip("Opt-in: requires local models and VOICETYPE_METALLIB")
        }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: directory.appendingPathComponent("default.metallib").path,
                                     withDestinationPath: shader)
        let previousDirectory = files.currentDirectoryPath
        XCTAssertTrue(files.changeCurrentDirectoryPath(directory.path))
        defer {
            _ = files.changeCurrentDirectoryPath(previousDirectory)
            try? files.removeItem(at: directory)
        }

        let model = LLMService(polishBudget: .seconds(30))
        model.setEnabled(true)
        defer { model.setEnabled(false) }
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !model.isModelLoaded, model.error == nil, ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.isModelLoaded, model.error ?? "Model loading timed out")
        guard model.isModelLoaded else { return }
        while model.isInferenceBusy { try await Task.sleep(for: .milliseconds(50)) }

        let sentence = "so um we need to check the budget and the deadline before friday and then send it to the client "
        _ = try await model.processPolished(sentence)
        let baseline = Memory.snapshot()

        // Different lengths make differently sized GPU buffers, which is what fills the cache in real use.
        for take in 1...20 {
            let text = String(repeating: sentence, count: take % 7 + 1)
            _ = try await model.processPolished(text)
        }
        let after = Memory.snapshot()
        let megabyte = 1024 * 1024
        let growth = (after.activeMemory + after.cacheMemory) - (baseline.activeMemory + baseline.cacheMemory)
        print("polish_memory baseline_active=\(baseline.activeMemory / megabyte)MB baseline_cache=\(baseline.cacheMemory / megabyte)MB after_active=\(after.activeMemory / megabyte)MB after_cache=\(after.cacheMemory / megabyte)MB growth=\(growth / megabyte)MB")
        XCTAssertLessThan(growth, 300 * megabyte, "GPU memory kept growing across takes")
        XCTAssertLessThan(after.cacheMemory, 300 * megabyte, "Freed GPU buffers are being hoarded")
    }
}
