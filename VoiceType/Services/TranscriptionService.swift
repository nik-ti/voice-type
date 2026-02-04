import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Service for transcribing audio using Parakeet-TDT model via FluidAudio
class TranscriptionService: ObservableObject {
    @Published var isLoaded = false
    @Published var isTranscribing = false
    @Published var loadingProgress: Double = 0.0
    
    #if canImport(FluidAudio)
    private var asrModels: AsrModels?
    private var asrManager: AsrManager?
    #endif
    
    // MARK: - Model Loading
    
    func loadModels() async throws {
        guard !isLoaded else { return }
        
        #if canImport(FluidAudio)
        await MainActor.run {
            self.loadingProgress = 0.1
        }
        
        // Download and load the v3 model (multilingual, supports Russian)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        
        await MainActor.run {
            self.loadingProgress = 0.8
        }
        
        // Initialize ASR manager
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        
        self.asrModels = models
        self.asrManager = manager
        
        await MainActor.run {
            self.loadingProgress = 1.0
            self.isLoaded = true
        }
        
        print("✅ Parakeet-TDT v3 model loaded successfully")
        #else
        // Fallback when FluidAudio is not available (for development/testing)
        print("⚠️ FluidAudio not available - using mock transcription")
        await MainActor.run {
            self.isLoaded = true
        }
        #endif
    }
    
    // MARK: - Transcription
    
    func transcribe(_ audioBuffer: AVAudioPCMBuffer, language: TranscriptionLanguage) async throws -> String {
        await MainActor.run {
            self.isTranscribing = true
        }
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
            }
        }
        
        #if canImport(FluidAudio)
        guard let asrManager = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }
        
        // Convert AVAudioPCMBuffer to [Float] samples
        let samples = extractSamples(from: audioBuffer)
        
        guard !samples.isEmpty else {
            throw TranscriptionError.emptyAudio
        }
        
        // Transcribe using FluidAudio
        // Note: v3 model auto-detects language, but we can hint
        let result = try await asrManager.transcribe(samples)
        
        return result.text
        #else
        // Mock transcription for development
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
        return "[Mock transcription - FluidAudio not linked]"
        #endif
    }
    
    // MARK: - Helper Methods
    
    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        
        let frameCount = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        
        for i in 0..<frameCount {
            samples[i] = channelData[0][i]
        }
        
        return samples
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Transcription model not loaded"
        case .emptyAudio:
            return "No audio to transcribe"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
