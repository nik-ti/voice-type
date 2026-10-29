// Replays fixed synthetic English/Russian and technical audio through the real local recognizer.
// These checks avoid microphone, clipboard and application focus side effects.
import AVFoundation
import XCTest
import FluidAudio
@testable import VoiceType

@MainActor
final class SpeechQualityTests: XCTestCase {
    func testTechnicalEnglishWithExplicitRecognitionLanguage() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOICETYPE_SPEECH_QUALITY"] else {
            throw XCTSkip("Opt-in: supply a directory with technical.aiff")
        }
        let recognizer = TranscriptionService()
        try await recognizer.loadModels()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: directory).appendingPathComponent("technical.aiff"))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        for language in [DictationLanguage.automatic, .english] {
            let text = try await recognizer.transcribe(buffer, language: language)
            print("TECHNICAL_SPEECH language=\(language.rawValue) output=\(text)")
            XCTAssertTrue(text.lowercased().contains("spec.py"), text)
            XCTAssertTrue(text.lowercased().contains("file"), text)
            if language == .english {
                XCTAssertFalse(text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, text)
            }
        }
    }

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
