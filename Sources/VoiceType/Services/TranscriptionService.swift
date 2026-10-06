// Runs on-device speech recognition and reports stage timings without logging dictated text.
// Full recordings are retained so quiet beginnings and endings are not trimmed away.
import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Speech-to-text via FluidAudio Parakeet TDT v3 (25 European languages,
/// auto-detected).
class TranscriptionService: ObservableObject {
    @Published var isLoaded = false
    @Published var isTranscribing = false
    @Published var loadingProgress: Double = 0.0
    @Published var loadingStatus: String = "Loading speech model…"

#if canImport(FluidAudio)
    private var asrManager: AsrManager?
    private var audioConverter: AudioConverter?
#endif

    func loadModels() async throws {
        guard !isLoaded else { return }

#if canImport(FluidAudio)
        await MainActor.run {
            self.loadingProgress = 0.05
            self.loadingStatus = "Preparing audio…"
        }

        audioConverter = AudioConverter()

        await MainActor.run {
            self.loadingProgress = 0.2
            self.loadingStatus = "Loading speech model…"
        }

        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { [weak self] progress in
            Task { @MainActor in
                self?.loadingProgress = 0.2 + progress.fractionCompleted * 0.75
                self?.loadingStatus = "Loading speech model…"
            }
        })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager

        await MainActor.run {
            self.loadingProgress = 1.0
            self.loadingStatus = "Ready"
            self.isLoaded = true
        }
        print("✅ Parakeet TDT v3 loaded")
#else
        await MainActor.run { self.isLoaded = true }
#endif
    }

    func transcribe(_ audioBuffer: AVAudioPCMBuffer) async throws -> String {
        print("🔊 TranscriptionService.transcribe called (auto language)")
        print("📊 Input buffer: \(audioBuffer.frameLength) frames at \(audioBuffer.format.sampleRate)Hz")

        await MainActor.run { self.isTranscribing = true }
        defer {
            Task { @MainActor in self.isTranscribing = false }
        }

#if canImport(FluidAudio)
        guard let audioConverter, let asrManager else { throw TranscriptionError.modelNotLoaded }
        guard audioBuffer.frameLength > 0 else { throw TranscriptionError.emptyAudio }
        guard audioBuffer.format.sampleRate > 0 && audioBuffer.format.channelCount > 0 else {
            throw TranscriptionError.invalidFormat
        }

        var timing = PipelineTiming()
        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(audioBuffer)
        } catch {
            throw TranscriptionError.conversionFailed(error.localizedDescription)
        }
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }
        print("📊 Converted to \(samples.count) samples at 16kHz mono")

        timing.mark("audio_conversion")
        let speechSamples = samples

        print("🔄 TDT v3 transcribe (\(speechSamples.count) samples)…")
        var decoderState = try TdtDecoderState()
        let result = try await asrManager.transcribe(
            speechSamples,
            decoderState: &decoderState,
            language: nil
        )
        timing.mark("speech_recognition")
        let written = TextNormalizer.shared.normalizeSentence(result.text)
        timing.mark("normalization")
        return written
#else
        return "[Mock transcription - FluidAudio not linked]"
#endif
    }

}

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
