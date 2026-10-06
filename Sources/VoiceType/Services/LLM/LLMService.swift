// Loads the local polish model and bounds how long dictation waits for it.
// A single worker owns inference through GPU completion, including after a timeout.
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import VoiceTypeCore

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()

    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var isModelLoaded = false
    @Published var error: String?

    private var modelContainer: ModelContainer?
    private let worker = DeadlineWorker<String>()
    var isInferenceBusy: Bool { worker.isBusy }
    private var wantsModel = false
    private var lastModelUse: ContinuousClock.Instant?

    /// Qwen3 0.6B — ~350 MB, multilingual, fast enough for dictation cleanup.
    private let modelConfiguration = LLMRegistry.qwen3_0_6b_4bit
    private let llmTimeoutSeconds: UInt64 = 2
    private let minWordOverlapRatio: Double = 0.6

    private let systemPrompt = """
    You clean voice-dictation transcripts. Output ONLY the cleaned text.

    Rules:
    - Remove filler and hesitation (um, uh, like as filler, you know, I mean, kinda, sort of, типа, короче, ну, как бы).
    - Fix punctuation, capitalization, and obvious grammar.
    - Keep the speaker's words and meaning. Do not rephrase, summarize, or add content.
    - Keep digits and currency as written ($5,000 not "five thousand dollars").
    - Write percentages as 50% with no space before %.
    - Keep existing line breaks unless they are clearly wrong.
    - If they listed things, use a short bullet list.
    - Do not explain, greet, or wrap the answer in quotes.

    Examples:
    Input: um so like i need to schedule a meeting for next tuesday at 3pm you know
    Output: I need to schedule a meeting for next Tuesday at 3 PM.

    Input: we went to the store and um bought some stuff or whatever and then came home
    Output: We went to the store and bought some stuff, and then came home.

    Input: эм ну я хотел типа сказать что встреча завтра короче
    Output: Я хотел сказать, что встреча завтра.

    Input: the chance of rain is 50 % tomorrow
    Output: The chance of rain is 50% tomorrow.
    """

    private let chattyPrefixes = [
        "here is the corrected", "here's the corrected",
        "here is the fixed", "here's the fixed",
        "here is your", "here's your", "here you go",
        "the corrected text is", "the corrected version",
        "corrected text:", "corrected version:", "corrected:",
        "sure,", "sure!", "sure.",
        "of course,", "of course!", "of course.",
        "certainly,", "certainly!", "certainly.",
        "alright,", "okay,", "no problem,",
        "i've corrected", "i have corrected",
        "let me fix", "let me correct",
    ]

    private init() {}

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
            print("🤖 Loading Qwen3 0.6B from HuggingFace (~350MB)…")
            let loaded = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    self.loadingProgress = progress.fractionCompleted
                }
            }
            guard wantsModel else { isLoading = false; return }
            modelContainer = loaded
            loadingProgress = 1.0
            isModelLoaded = true
            isLoading = false
            print("✅ Qwen3 0.6B loaded")
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
        isModelLoaded = false
        lastModelUse = nil
    }

    /// Move cold model work into recording time, without a permanent background timer.
    func warmIfNeeded(force: Bool = false) {
        guard let container = modelContainer, !worker.isBusy else { return }
        let now = ContinuousClock.now
        if !force, let lastModelUse, lastModelUse.duration(to: now) < .seconds(60) { return }
        lastModelUse = now
        Task {
            guard wantsModel, modelContainer === container else { return }
            let output = await worker.run(timeout: .seconds(2)) {
                try await Self.generate(container: container, text: "Hello.", system: "Correct punctuation. Output only the text.", maxTokens: 1)
            }
            PipelineTiming.event(output == nil ? "polish_warmup_deferred" : "polish_warmup_complete")
        }
    }

    // MARK: - Regular Mode

    func basicFormat(_ text: String, language: TextCleanupService.Language = .mixed) -> String {
        TextCleanupService.basicFormat(text, language: language)
    }

    // MARK: - Polished Mode

    func processPolished(_ text: String, language: TextCleanupService.Language = .mixed) async throws -> String {

        var result = TextCleanupService.removeHesitations(text, language: language)
        result = TextCleanupService.collapseFalseStarts(result)


        if let llmResult = await callLLMWithGuardrails(text: result) {
            result = TextCleanupService.polishPostPass(llmResult)
            PipelineTiming.event("polish_model_result")
        } else {
            result = TextCleanupService.applyGrammarRules(result)
            result = TextCleanupService.basicFormat(result, language: language)
            PipelineTiming.event("polish_rules_fallback")
        }

        return result
    }

    private func callLLMWithGuardrails(text: String) async -> String? {
        guard let container = modelContainer else { return nil }

        let wordCount = text.split(separator: " ").count
        // Short takes are already cleaned by rules. The model mostly adds wait.
        if wordCount <= 8 {
            return TextCleanupService.basicFormat(text)
        }

        let prompt = systemPrompt
        lastModelUse = ContinuousClock.now
        let output = await worker.run(timeout: .seconds(llmTimeoutSeconds)) {
            try await Self.generate(container: container, text: text, system: prompt,
                                    maxTokens: min(512, max(wordCount * 3 + 16, 48)))
        }
        guard let output, !Task.isCancelled else { return nil }
        return applyGuardrails(rawOutput: output, originalText: text)
    }

    nonisolated private static func generate(container: ModelContainer, text: String,
                                             system: String, maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        return try await container.perform { (context: ModelContext) async throws -> String in
            defer { MLX.Stream().synchronize() }
            try Task.checkCancellation()
            let input = UserInput(chat: [.system(system), .user("/no_think\n\(text)")],
                                  additionalContext: ["enable_thinking": false])
            let prepared = try await context.processor.prepare(input: input)
            try Task.checkCancellation()
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0,
                                                topP: 0.9, repetitionPenalty: 1.08,
                                                repetitionContextSize: 32)
            let iterator = try TokenIterator(input: prepared, model: context.model,
                                             parameters: parameters)
            // Prefill may ignore cancellation; keep the gate closed until it completes.
            try Task.checkCancellation()
            let (stream, generationTask) = MLXLMCommon.generateTask(
                promptTokenCount: prepared.text.tokens.size,
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

    // MARK: - Guardrails

    private func applyGuardrails(rawOutput: String, originalText: String) -> String? {
        var cleaned = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = stripThinkTags(cleaned)

        if let regex = try? NSRegularExpression(pattern: #"<\|.*?\|>"#, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        cleaned = removeEmojis(from: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        let lowered = cleaned.lowercased()
        for prefix in chattyPrefixes {
            if lowered.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.hasPrefix(":") || cleaned.hasPrefix("-") || cleaned.hasPrefix("—") {
                    cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }

        if let newlineRange = cleaned.range(of: "\n\n") {
            let head = String(cleaned[..<newlineRange.lowerBound])
            if TextCleanupService.preservesEnding(head, of: originalText) {
                cleaned = head
            }
        }

        if cleaned.isEmpty { return nil }
        if cleaned.count > originalText.count * 3 {
            print("🚫 Output too long, rejecting")
            return nil
        }
        if cleaned.count < originalText.count / 4 {
            print("🚫 Output too short, rejecting")
            return nil
        }
        if !isValidCorrection(input: originalText, output: cleaned) {
            print("🚫 Word overlap too low, rejecting")
            return nil
        }
        if !TextCleanupService.preservesEnding(cleaned, of: originalText) {
            print("🚫 Ending dropped, rejecting")
            return nil
        }

        if !cleaned.isEmpty {
            cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        if !cleaned.hasSuffix(".") && !cleaned.hasSuffix("!") && !cleaned.hasSuffix("?") && !cleaned.contains("\n-") {
            cleaned += "."
        }
        return cleaned
    }

    private func stripThinkTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>"#, options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValidCorrection(input: String, output: String) -> Bool {
        func tokenize(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: .punctuationCharacters).joined()
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }
        }

        let inputSet = Set(tokenize(input))
        let outputSet = Set(tokenize(output))
        guard !inputSet.isEmpty && !outputSet.isEmpty else { return false }

        let preserved = inputSet.intersection(outputSet).count
        let preservationRatio = Double(preserved) / Double(inputSet.count)
        let faithful = outputSet.intersection(inputSet).count
        let faithfulnessRatio = Double(faithful) / Double(outputSet.count)

        print("📊 Preservation: \(String(format: "%.0f", preservationRatio * 100))% | Faithfulness: \(String(format: "%.0f", faithfulnessRatio * 100))%")
        return preservationRatio >= minWordOverlapRatio && faithfulnessRatio >= minWordOverlapRatio
    }

    private func removeEmojis(from text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            let value = scalar.value
            let emojiRanges: [ClosedRange<UInt32>] = [
                0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
                0x1F1E0...0x1F1FF, 0x2600...0x26FF, 0x2700...0x27BF,
                0xFE00...0xFE0F, 0x1F900...0x1F9FF, 0x1FA00...0x1FA6F,
                0x1FA70...0x1FAFF,
            ]
            return !emojiRanges.contains { $0.contains(value) }
        })
    }
}
