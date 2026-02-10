import Foundation
import AVFoundation
import Combine

/// Service for capturing audio from the microphone
class AudioCaptureService: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var recordingElapsed: TimeInterval = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AVAudioPCMBuffer?
    private var audioSamples: [Float] = []
    
    // Target sample rate for Parakeet (16kHz)
    private let targetSampleRate: Double = 16000
    
    // Recording time limit (2 minutes)
    let maxRecordingDuration: TimeInterval = 120.0
    private let warningBeforeEnd: TimeInterval = 15.0  // Warn at 1:45
    private var recordingStartTime: Date?
    private var recordingTimer: DispatchSourceTimer?
    private var warningFired = false
    
    // Silence detection: track peak audio level during recording
    private(set) var peakAudioLevel: Float = 0.0
    private let silenceThreshold: Float = 0.02  // Below this = silence
    
    /// True if the recording contained actual speech (peak above silence threshold)
    var hadSpeech: Bool { peakAudioLevel > silenceThreshold }
    
    // Callbacks for time events
    var onTimeWarning: (() -> Void)?   // Called at 1:45
    var onTimeLimit: (() -> Void)?     // Called at 2:00
    var onAudioInterruption: (() -> Void)?  // Called on mic disconnect
    
    // Lock for thread-safe sample access
    private let samplesLock = NSLock()
    
    // Audio engine observer
    private var configObserver: NSObjectProtocol?
    
    // MARK: - Permission
    
    func requestMicrophonePermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    func checkMicrophonePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Recording
    
    func startRecording() throws {
        guard !isRecording else { return }
        
        // Reset samples
        samplesLock.lock()
        audioSamples = []
        samplesLock.unlock()
        
        // Create a new audio engine
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        
        // Get the hardware format - this triggers hardware initialization
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        
        // Verify we have a valid format
        guard hardwareFormat.sampleRate > 0 && hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }
        
        // Use a recording format that's compatible with the hardware
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.invalidFormat
        }
        
        // Calculate buffer size (100ms of audio)
        let bufferSize = AVAudioFrameCount(recordingFormat.sampleRate * 0.1)
        
        // Install tap on input node with the recording format
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: recordingFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, inputSampleRate: recordingFormat.sampleRate)
        }
        
        // Prepare and start with error handling
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.recordingFailed
        }
        
        self.audioEngine = audioEngine
        
        // Start recording timer
        recordingStartTime = Date()
        warningFired = false
        peakAudioLevel = 0.0  // Reset silence detection
        startRecordingTimer()
        observeAudioEngineInterruption()
        
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingElapsed = 0.0
        }
        
        print("✅ Audio recording started at \(recordingFormat.sampleRate)Hz")
    }
    
    func stopRecording() -> AVAudioPCMBuffer? {
        guard isRecording, let audioEngine = audioEngine else {
            return nil
        }
        
        // Stop timer and observers
        stopRecordingTimer()
        removeAudioEngineObserver()
        
        // Remove tap and stop engine
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        self.audioEngine = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.recordingElapsed = 0.0
        }
        
        // Get samples thread-safely
        samplesLock.lock()
        let samples = audioSamples
        audioSamples = []
        samplesLock.unlock()
        
        print("✅ Audio recording stopped, captured \(samples.count) samples, peak=\(String(format: "%.3f", peakAudioLevel))")
        
        // Convert collected samples to buffer at target sample rate
        return createAudioBuffer(from: samples)
    }
    
    // MARK: - Recording Timer
    
    private func startRecordingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, let start = self.recordingStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            self.recordingElapsed = elapsed
            
            // Warning at warningBeforeEnd seconds before limit
            let warningTime = self.maxRecordingDuration - self.warningBeforeEnd
            if elapsed >= warningTime && !self.warningFired {
                self.warningFired = true
                print("⚠️ Recording time warning: \(Int(self.warningBeforeEnd))s remaining")
                self.onTimeWarning?()
            }
            
            // Hard limit
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
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputSampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        
        let channelDataPtr = channelData[0]
        
        // Calculate audio level (RMS)
        var sum: Float = 0
        for i in 0..<frameCount {
            sum += channelDataPtr[i] * channelDataPtr[i]
        }
        let rms = sqrt(sum / Float(frameCount))
        
        // Update audio level on main thread
        let scaledLevel = min(1.0, rms * 50)
        DispatchQueue.main.async {
            self.audioLevel = scaledLevel
        }
        
        // Track peak for silence detection (thread-safe since Float write is atomic on ARM)
        if rms > self.peakAudioLevel {
            self.peakAudioLevel = rms
        }
        
        // Resample to 16kHz if needed
        var newSamples: [Float] = []
        
        if inputSampleRate != targetSampleRate {
            let resampleRatio = targetSampleRate / inputSampleRate
            let resampledCount = Int(Double(frameCount) * resampleRatio)
            
            for i in 0..<resampledCount {
                let sourceIndex = Int(Double(i) / resampleRatio)
                if sourceIndex < frameCount {
                    newSamples.append(channelDataPtr[sourceIndex])
                }
            }
        } else {
            // Already at target sample rate
            for i in 0..<frameCount {
                newSamples.append(channelDataPtr[i])
            }
        }
        
        // Thread-safe append
        samplesLock.lock()
        audioSamples.append(contentsOf: newSamples)
        samplesLock.unlock()
    }
    
    private func createAudioBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        
        // Create format for 16kHz mono float
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        
        buffer.frameLength = frameCount
        
        if let channelData = buffer.floatChannelData {
            for (index, sample) in samples.enumerated() {
                channelData[0][index] = sample
            }
        }
        
        return buffer
    }
    
    // MARK: - Audio Engine Recovery
    
    private func observeAudioEngineInterruption() {
        guard let engine = audioEngine else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            print("⚠️ Audio engine configuration changed (mic disconnected?)")
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

// MARK: - Errors

enum AudioCaptureError: LocalizedError {
    case invalidFormat
    case noPermission
    case recordingFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid audio format - please check your microphone"
        case .noPermission:
            return "Microphone permission denied"
        case .recordingFailed:
            return "Failed to start recording - please check your microphone settings"
        }
    }
}
