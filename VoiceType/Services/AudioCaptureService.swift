import Foundation
import AVFoundation
import Combine

/// Service for capturing audio from the microphone
class AudioCaptureService: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: AVAudioPCMBuffer?
    private var audioSamples: [Float] = []
    
    // Target sample rate for Parakeet (16kHz)
    private let targetSampleRate: Double = 16000
    
    // Lock for thread-safe sample access
    private let samplesLock = NSLock()
    
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
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
        
        print("✅ Audio recording started at \(recordingFormat.sampleRate)Hz")
    }
    
    func stopRecording() -> AVAudioPCMBuffer? {
        guard isRecording, let audioEngine = audioEngine else {
            return nil
        }
        
        // Remove tap and stop engine
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        self.audioEngine = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }
        
        // Get samples thread-safely
        samplesLock.lock()
        let samples = audioSamples
        audioSamples = []
        samplesLock.unlock()
        
        print("✅ Audio recording stopped, captured \(samples.count) samples")
        
        // Convert collected samples to buffer at target sample rate
        return createAudioBuffer(from: samples)
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
        DispatchQueue.main.async {
            self.audioLevel = min(1.0, rms * 10) // Scale for visualization
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
