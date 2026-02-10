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
    private var audioConverter: AudioConverter?
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
        
        // Initialize AudioConverter for proper format conversion (16kHz mono Float32)
        self.audioConverter = AudioConverter()
        
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
        print("🔊 TranscriptionService.transcribe called")
        print("📊 Input buffer: \(audioBuffer.frameLength) frames at \(audioBuffer.format.sampleRate)Hz, \(audioBuffer.format.channelCount) channels")
        
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
            print("❌ ASR Manager not initialized")
            throw TranscriptionError.modelNotLoaded
        }
        
        guard let audioConverter = audioConverter else {
            print("❌ AudioConverter not initialized")
            throw TranscriptionError.modelNotLoaded
        }
        
        // Validate buffer before conversion
        guard audioBuffer.frameLength > 0 else {
            print("❌ Audio buffer is empty")
            throw TranscriptionError.emptyAudio
        }
        
        guard audioBuffer.format.sampleRate > 0 && audioBuffer.format.channelCount > 0 else {
            print("❌ Invalid audio format: sampleRate=\(audioBuffer.format.sampleRate), channels=\(audioBuffer.format.channelCount)")
            throw TranscriptionError.invalidFormat
        }
        
        // Use AudioConverter to ensure proper 16kHz mono Float32 format
        // This is CRITICAL - manual extraction can cause "empty transcripts" per FluidAudio docs
        print("🔄 Converting audio to 16kHz mono Float32...")
        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(audioBuffer)
        } catch {
            print("❌ Audio conversion failed: \(error.localizedDescription)")
            throw TranscriptionError.conversionFailed(error.localizedDescription)
        }
        
        print("📊 Converted to \(samples.count) samples at 16kHz mono")
        
        guard !samples.isEmpty else {
            print("❌ No samples after conversion")
            throw TranscriptionError.emptyAudio
        }
        
        // Transcribe using FluidAudio
        print("🔄 Calling FluidAudio asrManager.transcribe with \(samples.count) samples...")
        let result = try await asrManager.transcribe(samples)
        
        print("✅ FluidAudio returned: '\(result.text)'")
        return result.text
        #else
        // Mock transcription for development
        print("⚠️ FluidAudio not available - using mock")
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 second delay
        return "[Mock transcription - FluidAudio not linked]"
        #endif
    }
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case emptyAudio
    case invalidFormat
    case conversionFailed(String)
    case transcriptionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Transcription model not loaded"
        case .emptyAudio:
            return "No audio to transcribe"
        case .invalidFormat:
            return "Invalid audio format"
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
