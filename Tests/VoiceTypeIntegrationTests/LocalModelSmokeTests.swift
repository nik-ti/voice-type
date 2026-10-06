// Opt-in integration check for the installed on-device models and release Metal library.
// It uses synthetic audio supplied by the caller, never the microphone or clipboard.
import AVFoundation
import XCTest
@testable import VoiceType

@MainActor
final class LocalModelSmokeTests: XCTestCase {
    func testInstalledModelsAndPolishBudget() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VOICETYPE_MODEL_SMOKE"] == "1",
              let shader = environment["VOICETYPE_METALLIB"],
              let audio = environment["VOICETYPE_SMOKE_AUDIO"] else {
            throw XCTSkip("Opt-in: requires local models, a release Metal library and synthetic audio")
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

        let recognizer = TranscriptionService()
        try await recognizer.loadModels()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        for _ in 0..<2 {
            let started = ContinuousClock.now
            let result = try await recognizer.transcribe(buffer)
            XCTAssertTrue(result.lowercased().contains("meeting notes"))
            print("MODEL_SMOKE speech_seconds=\(started.duration(to: .now))")
        }

        let model = LLMService.shared
        model.setEnabled(true)
        defer { model.setEnabled(false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !model.isModelLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.isModelLoaded, model.error ?? "Model loading timed out")
        guard model.isModelLoaded else { return }
        let warmupDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while model.isInferenceBusy, ContinuousClock.now < warmupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isInferenceBusy, "Warmup failed to drain")
        for _ in 0..<3 {
            let drainDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while model.isInferenceBusy, ContinuousClock.now < drainDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(model.isInferenceBusy)
            let started = ContinuousClock.now
            let result = try await model.processPolished(
                "Please send the meeting notes tomorrow morning and include the project timeline.", language: .english)
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .milliseconds(2500))
            XCTAssertTrue(result.lowercased().contains("meeting notes"))
            XCTAssertTrue(result.lowercased().contains("project timeline"))
            print("MODEL_SMOKE polish_seconds=\(elapsed)")
        }
    }
}
