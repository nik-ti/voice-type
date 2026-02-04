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
        
        audioSamples = []
        
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Verify we have a valid format
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.invalidFormat
        }
        
        // Calculate buffer size (100ms of audio)
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.1)
        
        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, inputFormat: inputFormat)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        self.audioEngine = audioEngine
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
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
        
        // Convert collected samples to buffer at target sample rate
        return createAudioBuffer(from: audioSamples)
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frameCount = Int(buffer.frameLength)
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
        let inputSampleRate = inputFormat.sampleRate
        if inputSampleRate != targetSampleRate {
            let resampleRatio = targetSampleRate / inputSampleRate
            let resampledCount = Int(Double(frameCount) * resampleRatio)
            
            for i in 0..<resampledCount {
                let sourceIndex = Int(Double(i) / resampleRatio)
                if sourceIndex < frameCount {
                    audioSamples.append(channelDataPtr[sourceIndex])
                }
            }
        } else {
            // Already at target sample rate
            for i in 0..<frameCount {
                audioSamples.append(channelDataPtr[i])
            }
        }
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
            return "Invalid audio format"
        case .noPermission:
            return "Microphone permission denied"
        case .recordingFailed:
            return "Failed to start recording"
        }
    }
}
