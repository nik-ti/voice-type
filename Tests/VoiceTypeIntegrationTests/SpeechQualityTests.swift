// Replays fixed synthetic English/Russian audio through the real local recognizer.
// These checks avoid microphone, clipboard and application focus side effects.
import AVFoundation
import XCTest
import FluidAudio
@testable import VoiceType

@MainActor
final class SpeechQualityTests: XCTestCase {
    func testEnglishAndRussianAudioPreserveInstructions() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICETYPE_SPEECH_QUALITY"] else {
            throw XCTSkip("Opt-in: supply a directory with english.aiff and russian.aiff fixtures")
        }
        let precision: ParakeetEncoderPrecision = ProcessInfo.processInfo.environment["VOICETYPE_SPEECH_ENCODER"] == "original" ? .int8 : .int8V2
        let recognizer = TranscriptionService(encoderPrecision: precision)
        try await recognizer.loadModels()
        let cases = [
            ("english", ["send", "microsoft", "tuesday", "thursday", "adobe", "design"]),
            ("russian", ["отправь", "microsoft", "вторник", "четверг", "если", "не", "пятниц"]),
        ]
        for (name, required) in cases {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: directory).appendingPathComponent("\(name).aiff"))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let started = ContinuousClock.now
            let text = try await recognizer.transcribe(buffer)
            print("SPEECH_QUALITY fixture=\(name) elapsed=\(started.duration(to: .now)) output=\(text)")
            for word in required {
                XCTAssertTrue(text.lowercased().contains(word), "\(name): missing \(word): \(text)")
            }
        }
    }
}
