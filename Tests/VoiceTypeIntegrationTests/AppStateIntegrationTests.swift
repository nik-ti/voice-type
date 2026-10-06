// Runs the real app coordinator against a controllable microphone and in-memory history.
// Clipboard writes are captured so these checks never type into the user's applications.
import AVFoundation
import XCTest
@testable import VoiceType

private final class TestMicrophone: AudioCaptureService {
    var permissionDelay: UInt64 = 0
    var stopped = false
    var onStart: () -> Void = {}
    override func requestMicrophonePermission() async -> Bool {
        try? await Task.sleep(nanoseconds: permissionDelay)
        return true
    }
    @MainActor override func startRecording() async throws {
        onStart()
        isRecording = true
    }
    override func stopRecording() -> AVAudioPCMBuffer? {
        stopped = true
        guard isRecording else { return nil }
        isRecording = false
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 160)!
        buffer.frameLength = 160
        return buffer
    }
}

private final class TestRecognizer: TranscriptionService {
    override func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String { "I feel ill today" }
}

private final class TestHistory: PersistenceService {
    var shouldFail = false
    var fetches = 0
    var beforeSave: () -> Void = {}
    override func saveTranscription(_ transcription: Transcription) throws {
        beforeSave()
        if shouldFail { throw PersistenceError.insertFailed }
        try super.saveTranscription(transcription)
    }
    override func fetchTranscriptions(searchText: String? = nil) -> [Transcription] {
        fetches += 1
        return super.fetchTranscriptions(searchText: searchText)
    }
}

@MainActor
final class AppStateIntegrationTests: XCTestCase {
    func testEarlyReleaseCleansUpRealCoordinator() async {
        let microphone = TestMicrophone()
        microphone.permissionDelay = 100_000_000
        let state = makeState(microphone: microphone, history: TestHistory(databasePath: ":memory:")) { _ in 1 }
        XCTAssertTrue(state.startListening())
        XCTAssertTrue(state.isStarting)
        await state.stopListeningAndTranscribe()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(state.isListening)
        XCTAssertFalse(state.isStarting)
        XCTAssertFalse(microphone.isRecording)
        XCTAssertTrue(microphone.stopped)
        state.shutdown()
    }

    func testDeliverySurvivesHistoryFailureAndDoesNotReloadHistory() async {
        let microphone = TestMicrophone()
        let history = TestHistory(databasePath: ":memory:")
        history.shouldFail = true
        var delivered: [String] = []
        history.beforeSave = { XCTAssertEqual(delivered, ["I feel ill today."]) }
        let state = makeState(microphone: microphone, history: history) { delivered.append($0); return 1 }
        XCTAssertTrue(state.startListening())
        for _ in 0..<100 where !state.isListening { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.isListening)
        await state.stopListeningAndTranscribe()
        XCTAssertEqual(delivered, ["I feel ill today."])
        XCTAssertEqual(history.fetches, 1)
        XCTAssertTrue(state.errorMessage?.contains("history") == true)
        XCTAssertFalse(state.isTranscribing)
        state.shutdown()
    }

    func testInputChangeFinishesAndDeliversCapturedTake() async {
        let microphone = TestMicrophone()
        var delivered: [String] = []
        let state = makeState(microphone: microphone, history: TestHistory(databasePath: ":memory:")) {
            delivered.append($0); return 1
        }
        let delegate = AppDelegate()
        delegate.setupRecordingCallbacks()
        XCTAssertTrue(state.startListening())
        for _ in 0..<100 where !state.isListening { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.isListening)
        microphone.onAudioInterruption?()
        for _ in 0..<100 where delivered.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(delivered, ["I feel ill today."])
        XCTAssertFalse(state.isListening)
        XCTAssertFalse(microphone.isRecording)
        state.shutdown()
    }

    func testAcceptedRecordingPlaysStartAndStopCues() async {
        let microphone = TestMicrophone()
        var starts = 0
        var stops = 0
        var events: [String] = []
        microphone.onStart = { events.append("recording") }
        let state = makeState(
            microphone: microphone,
            history: TestHistory(databasePath: ":memory:"),
            clipboard: { _ in 1 },
            startCue: { starts += 1; events.append("cue") },
            stopCue: { stops += 1 }
        )

        XCTAssertTrue(state.startListening())
        for _ in 0..<100 where !state.isListening { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(events, ["recording", "cue"])
        await state.stopListeningAndTranscribe()
        XCTAssertEqual(stops, 1)
        state.shutdown()
    }

    private func makeState(microphone: TestMicrophone, history: TestHistory,
                           clipboard: @escaping (String) -> Int,
                           startCue: @escaping () -> Void = {},
                           stopCue: @escaping () -> Void = {}) -> AppState {
        let suite = "VoiceTypeTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "autoPaste")
        preferences.set(false, forKey: "isPolishedMode")
        let state = AppState(audioCaptureService: microphone, transcriptionService: TestRecognizer(),
                             persistenceService: history, preferences: preferences, clipboardWriter: clipboard,
                             startCue: startCue, stopCue: stopCue)
        state.isModelLoaded = true
        return state
    }
}
