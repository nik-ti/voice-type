// Loads the local Polished-mode model and turns raw recognized speech into finished text with it.
// A single worker owns inference through GPU completion, and the wait grows with the length of the take.
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import VoiceTypeCore

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()
    static let modelDisplayName = "Qwen3 8B"
    static let defaultModelConfiguration = LLMRegistry.qwen3_8b_4bit

    /// MLX keeps freed GPU buffers for reuse, and by default that pile may grow to most of the Mac's RAM.
    /// Left alone it reached 17 GB after a week and forced the Mac into swap, slowing every take.
    static let gpuBufferCacheLimit = 128 * 1024 * 1024

    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var isModelLoaded = false
    @Published var error: String?

    private var modelContainer: ModelContainer?
    private let worker = DeadlineWorker<String>()
    /// Only the worker touches this, one take at a time; it is replaced whenever the model is unloaded.
    private var promptCache = InstructionPromptCache()
    var isInferenceBusy: Bool { worker.isBusy }
    private var wantsModel = false
    private var lastModelUse: ContinuousClock.Instant?

    private let modelConfiguration: ModelConfiguration
    private let minimumWait: Duration
    private(set) var lastFallbackReason: String?

    private let chattyPrefixes = [
        "here is the cleaned", "here's the cleaned", "here is the corrected", "here's the corrected",
        "here is the text", "here's the text", "cleaned text:", "corrected text:",
    ]

    init(modelConfiguration: ModelConfiguration? = nil, minimumWait: Duration = .seconds(3)) {
        self.modelConfiguration = modelConfiguration ?? Self.defaultModelConfiguration
        self.minimumWait = minimumWait
        Memory.cacheLimit = Self.gpuBufferCacheLimit
    }

    // MARK: - Model Loading

    func setEnabled(_ enabled: Bool) {
        wantsModel = enabled
        if enabled {
            Task { [weak self] in
                guard let self, self.wantsModel else { return }
                await self.loadModel()
            }
        } else {
            unloadModel()
        }
    }

    private func loadModel() async {
        guard wantsModel, !isModelLoaded, !isLoading else { return }
        isLoading = true
        loadingProgress = 0.0
        error = nil
        do {
            print("🤖 Loading local polish model: \(modelConfiguration.name)…")
            let loaded = try await LLMModelFactory.shared.loadContainer(configuration: modelConfiguration) { progress in
                Task { @MainActor in self.loadingProgress = progress.fractionCompleted }
            }
            guard wantsModel else { isLoading = false; return }
            modelContainer = loaded
            loadingProgress = 1.0
            isModelLoaded = true
            isLoading = false
            print("✅ Local polish model loaded: \(modelConfiguration.name)")
            warmIfNeeded(force: true)
        } catch {
            print("❌ Failed to load LLM: \(error)")
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }

    func unloadModel() {
        wantsModel = false
        worker.cancel()
        modelContainer = nil
        promptCache = InstructionPromptCache()
        isModelLoaded = false
        lastModelUse = nil
    }

    /// Move cold model work into recording time, without a permanent background timer.
    func warmIfNeeded(force: Bool = false) {
        guard let container = modelContainer, !worker.isBusy else { return }
        let now = ContinuousClock.now
        if !force, let lastModelUse, lastModelUse.duration(to: now) < .seconds(60) { return }
        lastModelUse = now
        let promptCache = self.promptCache
        Task {
            guard wantsModel, modelContainer === container else { return }
            // Warmup also reads the instructions once, so the first real take only reads its transcript.
            let output = await worker.run(timeout: .seconds(10)) {
                try await Self.generate(container: container, messages: CleanupInstructions.chat(for: "Hello."),
                                        maxTokens: 1, promptCache: promptCache)
            }
            PipelineTiming.event(output == nil ? "polish_warmup_deferred" : "polish_warmup_complete")
        }
    }

    // MARK: - Polished Mode

    /// Polished mode: the model cleans the raw recognized speech. If it cannot, the Regular-mode text is used.
    func processPolished(_ rawTranscript: String, regularFallback: String) async -> String {
        if let cleaned = await cleanUpWithModel(rawTranscript) {
            PipelineTiming.event("polish_model_result")
            return cleaned
        }
        PipelineTiming.event("polish_fallback_reason=\(lastFallbackReason ?? "unknown")")
        return regularFallback
    }

    /// How long a take may wait for the model: longer dictation needs more time to write out.
    func waitLimit(forWords words: Int) -> Duration {
        min(minimumWait + .milliseconds(50 * words), .seconds(12))
    }

    /// Returns nil when the model is unavailable, busy, late, or returns nothing usable.
    func cleanUpWithModel(_ rawTranscript: String) async -> String? {
        lastFallbackReason = nil
        guard let container = modelContainer else { lastFallbackReason = "model_not_ready"; return nil }
        guard !worker.isBusy else { lastFallbackReason = "worker_busy"; return nil }
        let wordCount = rawTranscript.split(whereSeparator: \.isWhitespace).count
        lastModelUse = ContinuousClock.now
        let promptCache = self.promptCache
        let output = await worker.run(timeout: waitLimit(forWords: wordCount)) {
            try await Self.generate(container: container, messages: CleanupInstructions.chat(for: rawTranscript),
                                    maxTokens: min(1024, max(wordCount * 3 + 24, 64)), promptCache: promptCache)
        }
        guard let output, !Task.isCancelled else {
            lastFallbackReason = Task.isCancelled ? "cancelled" : "deadline_or_generation_error"
            return nil
        }
        let memory = Memory.snapshot()
        PipelineTiming.event("polish_gpu_memory active_mb=\(memory.activeMemory >> 20) cache_mb=\(memory.cacheMemory >> 20)")
        let cleaned = stripModelWrapping(output)
        guard !cleaned.isEmpty else { lastFallbackReason = "empty"; return nil }
        // A reply far longer than the dictation means the model answered instead of cleaning.
        guard cleaned.count <= rawTranscript.count * 2 + 40 else { lastFallbackReason = "answered_instead"; return nil }
        return cleaned
    }

    nonisolated private static func generate(container: ModelContainer, messages: [Chat.Message],
                                             maxTokens: Int, promptCache: InstructionPromptCache) async throws -> String {
        try Task.checkCancellation()
        return try await container.perform { (context: ModelContext) async throws -> String in
            let input = UserInput(chat: messages, additionalContext: ["enable_thinking": false])
            let prepared = try await context.processor.prepare(input: input)
            // Temperature 0: the same dictation always gives the same text. No repetition penalty,
            // because cleanup must repeat the speaker's own words.
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let promptTokens = prepared.text.tokens.asType(.int32).asArray(Int32.self)
            let modelInput: LMInput
            let cache: [KVCache]
            if let reused = promptCache.reusableCache(for: promptTokens) {
                cache = reused.cache
                modelInput = LMInput(tokens: MLXArray(Array(promptTokens[reused.prefixLength...])))
            } else {
                // Tokens shared by two different transcripts are the fixed instructions and examples.
                let probe = try await context.processor.prepare(input: UserInput(
                    chat: CleanupInstructions.chat(for: "x"), additionalContext: ["enable_thinking": false]))
                let probeTokens = probe.text.tokens.asType(.int32).asArray(Int32.self)
                let sharedCount = zip(promptTokens, probeTokens).prefix { $0 == $1 }.count
                cache = context.model.newCache(parameters: parameters)
                promptCache.start(prefix: Array(promptTokens.prefix(sharedCount)), cache: cache)
                modelInput = prepared
            }
            defer {
                MLX.Stream().synchronize()
                promptCache.rewindToPrefix()
                // Return this take's scratch buffers so memory is back at baseline between dictations.
                Memory.clearCache()
            }
            try Task.checkCancellation()
            let iterator = try TokenIterator(input: modelInput, model: context.model, cache: cache, parameters: parameters)
            // Prefill may ignore cancellation; keep the gate closed until it completes.
            try Task.checkCancellation()
            let (stream, generationTask) = MLXLMCommon.generateTask(
                promptTokenCount: modelInput.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: iterator)
            return try await withTaskCancellationHandler {
                var output = ""
                for await event in stream {
                    if Task.isCancelled { generationTask.cancel(); break }
                    if let chunk = event.chunk { output += chunk }
                }
                await generationTask.value
                try Task.checkCancellation()
                return output
            } onCancel: {
                generationTask.cancel()
            }
        }
    }

    /// Removes chat-model wrapping (think blocks, special tokens, "Here is the cleaned text:") but never edits words.
    private func stripModelWrapping(_ rawOutput: String) -> String {
        var cleaned = rawOutput
            .replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<\|.*?\|>|</?transcript>"#, with: "", options: .regularExpression)
            // Models sometimes end lines with Markdown's two-space line break; pasted text should not.
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()
        if let prefix = chattyPrefixes.first(where: { lowered.hasPrefix($0) }),
           let colon = cleaned.firstIndex(of: ":"), cleaned.distance(from: cleaned.startIndex, to: colon) <= prefix.count + 12 {
            cleaned = String(cleaned[cleaned.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}
