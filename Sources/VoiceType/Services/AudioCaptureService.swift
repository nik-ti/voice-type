import Foundation
import AVFoundation
import Combine
import VoiceTypeCore

/// Captures microphone audio at the hardware sample rate. Format conversion
/// to 16 kHz happens later in TranscriptionService via FluidAudio's AudioConverter.
class AudioCaptureService: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingElapsed: TimeInterval = 0.0

    private var audioEngine: AVAudioEngine?
    private let recordingBuffer = AudioRecordingBuffer()

    let maxRecordingDuration: TimeInterval = 120.0
    private let warningBeforeEnd: TimeInterval = 15.0
    private var recordingStartTime: Date?
    private var recordingTimer: DispatchSourceTimer?
    private var warningFired = false

    var peakAudioLevel: Float { recordingBuffer.peakLevel }
    private let silenceThreshold: Float = 0.008
    var hadSpeech: Bool { peakAudioLevel > silenceThreshold }

    var onTimeWarning: (() -> Void)?
    var onTimeLimit: (() -> Void)?
    var onAudioInterruption: (() -> Void)?

    private var configObserver: NSObjectProtocol?
    private var isBluetoothInput = false

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func checkMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Recording

    @MainActor
    func startRecording() async throws {
        guard !isRecording else { return }
        try Task.checkCancellation()

        // AVAudioEngine follows the system input. Changing the system device for
        // every take races Core Audio's property listeners during teardown.
        let input = AudioDeviceManager.defaultInputDevice()
        isBluetoothInput = input?.isBluetooth ?? false
        print("🎤 Input: \(input?.displayName ?? "system default")")

        let maxAttempts = isBluetoothInput ? 4 : 2
        var lastError: Error = AudioCaptureError.recordingFailed

        for attempt in 1...maxAttempts {
            do {
                try Task.checkCancellation()
                try attemptStartRecording()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delayMs = isBluetoothInput ? UInt64(400 * attempt) : 400
                    print("⚠️ Recording start attempt \(attempt) failed (\(error.localizedDescription)). Retrying in \(delayMs)ms…")
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
            }
        }

        throw lastError
    }

    private func attemptStartRecording() throws {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        print("🎤 Hardware format: \(hardwareFormat.sampleRate)Hz, \(hardwareFormat.channelCount) ch")

        guard hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }

        let captureID = recordingBuffer.begin(sampleRate: hardwareFormat.sampleRate)

        // Use the hardware format as-is. Asking for a different channel count
        // is a common way to get a silent tap on macOS.
        let bufferSize = AVAudioFrameCount(max(hardwareFormat.sampleRate * 0.1, 512))
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, sessionID: captureID)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.recordingFailed
        }

        self.audioEngine = audioEngine

        if !isRecording {
            recordingStartTime = Date()
            warningFired = false
            startRecordingTimer()
            if Thread.isMainThread {
                isRecording = true
                recordingElapsed = 0.0
            } else {
                DispatchQueue.main.sync {
                    self.isRecording = true
                    self.recordingElapsed = 0.0
                }
            }
        }

        observeAudioEngineInterruption()
        print("✅ Audio recording started at \(hardwareFormat.sampleRate)Hz")
    }

    func stopRecording() -> AVAudioPCMBuffer? {
        guard isRecording, let audioEngine else { return nil }

        stopRecordingTimer()
        removeAudioEngineObserver()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
        isRecording = false
        audioLevel = 0.0
        recordingElapsed = 0.0

        return recordingBuffer.take()
    }

    // MARK: - Recording Timer

    private func startRecordingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let start = self.recordingStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.recordingElapsed = elapsed

            let warningTime = self.maxRecordingDuration - self.warningBeforeEnd
            if elapsed >= warningTime && !self.warningFired {
                self.warningFired = true
                print("⚠️ Recording time warning: \(Int(self.warningBeforeEnd))s remaining")
                self.onTimeWarning?()
            }

            if elapsed >= self.maxRecordingDuration {
                print("⏱️ Recording time limit reached (\(Int(self.maxRecordingDuration))s)")
                self.onTimeLimit?()
            }
        }
        timer.resume()
        self.recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.cancel()
        recordingTimer = nil
        recordingStartTime = nil
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, sessionID: UUID) {
        guard let rms = recordingBuffer.append(buffer, sessionID: sessionID) else { return }
        let level = min(1.0, rms * 50)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.audioLevel = level
        }
    }

    // MARK: - Audio Engine Recovery

    private func observeAudioEngineInterruption() {
        guard let engine = audioEngine else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            // Preserve the take at its original sample rate. Restarting and joining
            // differently clocked audio can duplicate or distort the recording.
            self.removeAudioEngineObserver()
            self.onAudioInterruption?()
        }
    }

    private func removeAudioEngineObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidFormat
    case noPermission
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid audio format — the microphone may still be switching. Try again."
        case .noPermission:
            return "Microphone permission denied"
        case .recordingFailed:
            return "Failed to start recording — check your microphone in Preferences"
        }
    }
}
