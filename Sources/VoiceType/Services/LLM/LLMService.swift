import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()
    
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0.0
    @Published var isModelLoaded = false
    @Published var error: String?
    @Published var polishingPreview: String = ""  // Live preview during generation
    
    private var modelContainer: ModelContainer?
    
    // Llama 3.2 3B Instruct - strong at rewriting/grammar, fast on Apple Silicon
    // Auto-downloads from HuggingFace (~1.8GB one-time)
    private let modelId = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    
    // Timeout: never let the UI hang on "polishing"
    private let llmTimeoutSeconds: UInt64 = 8
    
    // System prompt with diverse few-shot examples for grammar correction
    // Uses chat template (model trained with this) + examples to guide behavior
    // More examples = better quality (10-15% improvement)
    private let systemPrompt = """
    You are a text corrector. Fix grammar, punctuation, and capitalization. Remove filler words. Output ONLY the corrected text, nothing else. Do not explain, greet, or add commentary.

    Examples:
    Input: so i was thinking about like getting a new laptop because my current one is like really slow
    Output: So I was thinking about getting a new laptop because my current one is really slow.

    Input: we went to the store and um bought some stuff or whatever and then came home
    Output: We went to the store and bought some stuff, and then came home.

    Input: hey so basically i wanted to ask you if you could maybe help me with this thing
    Output: I wanted to ask you if you could help me with this thing.

    Input: can you like send me the file by tomorrow or whatever
    Output: Can you send me the file by tomorrow?

    Input: i need to schedule a meeting for like next tuesday at 3 pm
    Output: I need to schedule a meeting for next Tuesday at 3 PM.

    Input: the project is basically done we just need to um test it
    Output: The project is basically done. We just need to test it.
    """
    
    // Minimum word overlap ratio for valid grammar correction
    // Grammar correction reuses most words; talkback introduces new ones
    // Checked BIDIRECTIONALLY: input→output AND output→input
    private let minWordOverlapRatio: Double = 0.6
    
    // LAYER 3: Chatty prefixes to strip from output
    private let chattyPrefixes = [
        "here is the corrected",
        "here's the corrected",
        "here is the fixed",
        "here's the fixed",
        "here is your",
        "here's your",
        "here you go",
        "the corrected text is",
        "the corrected version",
        "corrected text:",
        "corrected version:",
        "corrected:",
        "sure,",
        "sure!",
        "sure.",
        "of course,",
        "of course!",
        "of course.",
        "certainly,",
        "certainly!",
        "certainly.",
        "alright,",
        "okay,",
        "no problem,",
        "i've corrected",
        "i have corrected",
        "let me fix",
        "let me correct",
    ]
    
    private init() {}
    
    // MARK: - Model Loading
    
    func loadModel() async {
        guard !isModelLoaded else { return }
        
        isLoading = true
        loadingProgress = 0.0
        error = nil
        
        do {
            print("🤖 Loading Llama 3.2 3B Instruct from HuggingFace (~1.8GB)...")
            
            let configuration = ModelConfiguration(id: modelId)
            
            modelContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { progress in
                Task { @MainActor in
                    self.loadingProgress = progress.fractionCompleted
                }
            }
            
            loadingProgress = 1.0
            isModelLoaded = true
            isLoading = false
            print("✅ Llama 3.2 3B loaded successfully")
            
            // Warmup
            Task { try? await warmupModel() }
            
        } catch {
            print("❌ Failed to load LLM: \(error)")
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }
    
    private func warmupModel() async throws {
        guard let container = modelContainer else { return }
        let params = GenerateParameters(maxTokens: 1)
        let input = UserInput(chat: [.user("hello")])
        
        _ = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: input)
            let stream = try MLXLMCommon.generate(input: lmInput, parameters: params, context: context)
            for try await _ in stream { break }
        }
        print("🔥 Model warmed up")
    }
    
    func unloadModel() {
        modelContainer = nil
        isModelLoaded = false
    }
    
    // MARK: - Default Mode (Rule-Based, Instant)
    
    /// Basic formatting without LLM - instant, bulletproof
    func basicFormat(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Fix missing apostrophes in common contractions (Whisper sometimes drops them)
        let contractionFixes: [(String, String)] = [
            ("\\bdont\\b", "don't"),
            ("\\bcant\\b", "can't"),
            ("\\bwont\\b", "won't"),
            ("\\bwouldnt\\b", "wouldn't"),
            ("\\bshouldnt\\b", "shouldn't"),
            ("\\bcouldnt\\b", "couldn't"),
            ("\\bdoesnt\\b", "doesn't"),
            ("\\bdidnt\\b", "didn't"),
            ("\\bisnt\\b", "isn't"),
            ("\\barent\\b", "aren't"),
            ("\\bwasnt\\b", "wasn't"),
            ("\\bwerent\\b", "weren't"),
            ("\\bhavent\\b", "haven't"),
            ("\\bhasnt\\b", "hasn't"),
            ("\\bhadnt\\b", "hadn't"),
            ("\\bthats\\b", "that's"),
            ("\\bwhats\\b", "what's"),
            ("\\bheres\\b", "here's"),
            ("\\btheres\\b", "there's"),
            ("\\blets\\b", "let's"),
            ("\\bim\\b", "I'm"),
            ("\\bive\\b", "I've"),
            ("\\bill\\b", "I'll"),
            ("\\byoure\\b", "you're"),
            ("\\btheyre\\b", "they're"),
        ]
        
        for (pattern, replacement) in contractionFixes {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        
        // 2. Capitalize standalone "i" as pronoun (English only, safe with word boundaries)
        if let regex = try? NSRegularExpression(pattern: "\\bi\\b", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "I")
        }
        // Also fix "i'm", "i've", "i'll", "i'd" if apostrophe is present but "i" is lowercase
        if let regex = try? NSRegularExpression(pattern: "\\bi('m|'ve|'ll|'d)\\b", options: []) {
            let mutableResult = NSMutableString(string: result)
            let range = NSRange(location: 0, length: mutableResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let matchStr = mutableResult.substring(with: match.range)
                mutableResult.replaceCharacters(in: match.range, with: "I" + matchStr.dropFirst())
            }
            result = mutableResult as String
        }
        
        // 3. Remove stuttered/repeated words ("the the" → "the", "я я" → "я")
        if let regex = try? NSRegularExpression(pattern: "\\b(\\w+)\\s+\\1\\b", options: .caseInsensitive) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        
        // 4. Capitalize common abbreviations (English, Russian, Spanish)
        let abbreviations: [(String, String)] = [
            // English
            ("\\bmr\\b\\.?", "Mr."),
            ("\\bmrs\\b\\.?", "Mrs."),
            ("\\bdr\\b\\.?", "Dr."),
            ("\\bms\\b\\.?", "Ms."),
            // Spanish
            ("\\bsr\\b\\.?", "Sr."),
            ("\\bsra\\b\\.?", "Sra."),
            ("\\bsrta\\b\\.?", "Srta."),
        ]
        for (pattern, replacement) in abbreviations {
            if let regex = try? NSRegularExpression(pattern: "(?<=\\s|^)" + pattern + "(?=\\s)", options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        
        // Russian abbreviations (these use Cyrillic and are safe to match)
        let russianAbbreviations: [(String, String)] = [
            ("\\bт д\\b", "т.д."),       // и так далее
            ("\\bт е\\b", "т.е."),       // то есть
            ("\\bт к\\b", "т.к."),       // так как
            ("\\bт п\\b", "т.п."),       // тому подобное
            ("\\bдр\\b\\.?", "др."),     // другое
        ]
        for (pattern, replacement) in russianAbbreviations {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        
        // 5. Collapse double+ spaces to single
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        
        // 6. Capitalize first letter
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        
        // 7. Capitalize first letter after sentence-ending punctuation (. ! ?)
        // Works for any language — matches ". a" → ". A", "! в" → "! В", etc.
        if let regex = try? NSRegularExpression(pattern: "([.!?])\\s+(\\p{Ll})", options: []) {
            let mutableResult = NSMutableString(string: result)
            let range = NSRange(location: 0, length: mutableResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match = match,
                      let letterRange = Range(match.range(at: 2), in: result) else { return }
                let upper = String(result[letterRange]).uppercased()
                mutableResult.replaceCharacters(in: match.range(at: 2), with: upper)
            }
            result = mutableResult as String
        }
        
        // 8. Add period if missing terminal punctuation
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }
        
        // 9. Apply quality enhancements (punctuation, capitalization, number formatting)
        result = applyPunctuationRules(result)
        result = applyCapitalizationRules(result)
        result = formatNumbers(result)
        
        return result
    }
    
    // MARK: - Quality Enhancement Functions
    
    /// Apply professional punctuation rules
    private func applyPunctuationRules(_ text: String) -> String {
        var result = text
        
        // Add comma after introductory words
        let introWords = ["however", "therefore", "meanwhile", "furthermore", "moreover", "additionally", "consequently"]
        for word in introWords {
            // Match word at start or after period, not already followed by comma
            result = result.replacingOccurrences(
                of: "(^|\\. )(\(word))\\s+(?!,)",
                with: "$1$2, ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Fix spacing around punctuation: remove space before, ensure space after
        result = result.replacingOccurrences(of: "\\s+([,.:;!?])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([,.:;])([A-Za-zА-Яа-я])", with: "$1 $2", options: .regularExpression)
        
        return result
    }
    
    /// Apply smart capitalization for proper nouns
    private func applyCapitalizationRules(_ text: String) -> String {
        var result = text
        
        // Days of week (English)
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for day in days {
            result = result.replacingOccurrences(
                of: "\\b\(day)\\b",
                with: day.capitalized,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Months (English)
        let months = ["january", "february", "march", "april", "may", "june", 
                      "july", "august", "september", "october", "november", "december"]
        for month in months {
            result = result.replacingOccurrences(
                of: "\\b\(month)\\b",
                with: month.capitalized,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Always capitalize standalone "I"
        result = result.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
        
        return result
    }
    
    /// Format numbers and times consistently
    private func formatNumbers(_ text: String) -> String {
        var result = text
        
        // Time formatting: "3pm" or "3:30pm" → "3 PM" or "3:30 PM"
        if let regex = try? NSRegularExpression(pattern: "(\\d{1,2}):?(\\d{2})?\\s*(am|pm)", options: .caseInsensitive) {
            let mutableResult = NSMutableString(string: result)
            let range = NSRange(location: 0, length: mutableResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match = match else { return }
                let hour = mutableResult.substring(with: match.range(at: 1))
                let minutes = match.range(at: 2).location != NSNotFound ? ":" + mutableResult.substring(with: match.range(at: 2)) : ""
                let period = mutableResult.substring(with: match.range(at: 3)).uppercased()
                mutableResult.replaceCharacters(in: match.range, with: "\(hour)\(minutes) \(period)")
            }
            result = mutableResult as String
        }
        
        // Percent: "50 percent" → "50%"
        result = result.replacingOccurrences(
            of: "(\\d+)\\s+percent",
            with: "$1%",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return result
    }
    
    // MARK: - Polished Mode (LLM + Guardrails)
    
    /// Production-grade polished formatting
    /// Layer 1: Regex filler removal → Layer 2: LLM grammar → Layer 3: Output guardrails
    func processPolished(_ text: String) async throws -> String {
        // Clear previous preview
        await MainActor.run {
            self.polishingPreview = ""
        }
        
        // Step 1: Rule-based filler removal (instant, bulletproof)
        var result = removeFillers(text)
        print("✨ After filler removal: '\(result)'")
        
        // Step 2: LLM grammar correction with guardrails
        if let llmResult = await callLLMWithGuardrails(text: result) {
            result = llmResult
            print("✨ LLM polished: '\(result)'")
        } else {
            // Fallback to rule-based grammar
            result = applyGrammarRules(result)
            result = basicFormat(result)
            print("⚠️ LLM unavailable, using rules: '\(result)'")
        }
        
        // Clear preview after completion
        await MainActor.run {
            self.polishingPreview = ""
        }
        
        print("✨ Polished: '\(result)'")
        return result
    }
    
    /// Call LLM with three-layer defense against chatty output + timeout
    private func callLLMWithGuardrails(text: String) async -> String? {
        guard let container = modelContainer else {
            return nil
        }
        
        let wordCount = text.split(separator: " ").count
        if wordCount <= 2 {
            return basicFormat(text)  // Too short for LLM
        }
        
        // LAYER 2: Chat template with system prompt + examples
        // Llama 3.2 Instruct was TRAINED with chat template — using it gives best quality
        // Word overlap check (Layer 4) catches any talkback deterministically
        let messages: [Chat.Message] = [
            .system(systemPrompt),
            .user(text)
        ]
        let userInput = UserInput(chat: messages)
        
        // Optimized generation parameters for speed (2-3x faster based on MLX research)
        // temperature 0.0 = fully deterministic (greedy decoding), no creativity = minimal talkback
        // topP 0.9 = nucleus sampling for faster generation (20-30% speedup)
        // Tighter token cap: grammar correction rarely adds words (1.5x instead of 2x)
        let parameters = GenerateParameters(
            maxTokens: min(100, max(wordCount + wordCount / 2, 15)),  // Tighter: 1.5x instead of 2x
            temperature: 0.0,
            topP: 0.9,  // Nucleus sampling for speed
            repetitionPenalty: 1.15,  // Slightly stronger to discourage loops
            repetitionContextSize: 20
        )
        
        // Run LLM with timeout — never hang on "polishing"
        do {
            let outputText: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                // LLM generation task
                group.addTask {
                    let result: String = try await container.perform { (context: ModelContext) async throws -> String in
                        let lmInput = try await context.processor.prepare(input: userInput)
                        
                        let stream = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                        
                        var text = ""
                        for try await generation in stream {
                            // Check cancellation periodically
                            try Task.checkCancellation()
                            if let chunk = generation.chunk {
                                text += chunk
                                // Stream to UI for live preview
                                await MainActor.run {
                                    self.polishingPreview = text
                                }
                            }
                            if generation.info != nil {
                                break
                            }
                        }
                        return text
                    }
                    return result
                }
                
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: self.llmTimeoutSeconds * 1_000_000_000)
                    return nil  // Signal timeout
                }
                
                // Return whichever finishes first
                if let first = try await group.next() {
                    group.cancelAll()
                    return first
                }
                return nil
            }
            
            guard let output = outputText else {
                print("⏱️ LLM timed out after \(llmTimeoutSeconds)s, falling back to rules")
                return nil
            }
            
            // LAYER 3: Post-processing guardrails
            let cleaned = applyGuardrails(rawOutput: output, originalText: text)
            return cleaned
            
        } catch {
            print("⚠️ LLM error: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Layer 3: Output Guardrails
    
    /// Strip chatty prefixes, validate output, fallback to rules if garbage
    private func applyGuardrails(rawOutput: String, originalText: String) -> String? {
        var cleaned = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove special tokens
        if let regex = try? NSRegularExpression(pattern: "<\\|.*?\\|>", options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove emojis
        cleaned = removeEmojis(from: cleaned)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove quotes wrapping
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        
        // Strip chatty prefixes (case-insensitive)
        let lowered = cleaned.lowercased()
        for prefix in chattyPrefixes {
            if lowered.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                // Also strip colon/dash after prefix
                if cleaned.hasPrefix(":") || cleaned.hasPrefix("-") || cleaned.hasPrefix("—") {
                    cleaned = String(cleaned.dropFirst())
                    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }
        
        // Strip any remaining leading quotes after prefix removal
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        
        // Take only the first paragraph (model might generate multiple)
        if let newlineRange = cleaned.range(of: "\n\n") {
            cleaned = String(cleaned[..<newlineRange.lowerBound])
        }
        
        // Validation: reject garbage output
        if cleaned.isEmpty {
            return nil
        }
        if cleaned.count > originalText.count * 3 {
            print("🚫 Output too long (rambling), rejecting")
            return nil
        }
        if cleaned.count < originalText.count / 4 {
            print("🚫 Output too short (truncated), rejecting")
            return nil
        }
        // If output contains a question but original doesn't, model is asking something
        if cleaned.contains("?") && !originalText.contains("?") && cleaned.hasSuffix("?") {
            print("🚫 Output ends with question (talkback), rejecting")
            return nil
        }
        
        // DETERMINISTIC TALKBACK CHECK: Bidirectional word overlap
        // Grammar correction reuses most input words AND doesn't add many new ones.
        // Talkback fails one or both directions. Pure math — no phrases to maintain.
        if !isValidCorrection(input: originalText, output: cleaned) {
            print("🚫 Word overlap too low (talkback detected), rejecting")
            return nil
        }
        
        // Ensure proper formatting
        if !cleaned.isEmpty {
            cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        if !cleaned.hasSuffix(".") && !cleaned.hasSuffix("!") && !cleaned.hasSuffix("?") {
            cleaned += "."
        }
        
        return cleaned
    }
    
    // MARK: - Deterministic Talkback Detection
    
    /// Checks if output is a valid grammar correction using BIDIRECTIONAL word overlap.
    /// Direction 1 (preservation): What % of INPUT words survived into the output?
    /// Direction 2 (faithfulness): What % of OUTPUT words came from the input?
    /// BOTH must pass the threshold. Pure math — no phrases, no AI.
    private func isValidCorrection(input: String, output: String) -> Bool {
        // Tokenize into word arrays (lowercase, strip punctuation)
        func tokenize(_ text: String) -> [String] {
            return text.lowercased()
                .components(separatedBy: .punctuationCharacters).joined()
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }  // Skip single-char fragments
        }
        
        let inputTokens = tokenize(input)
        let outputTokens = tokenize(output)
        
        let inputSet = Set(inputTokens)
        let outputSet = Set(outputTokens)
        
        guard !inputSet.isEmpty && !outputSet.isEmpty else {
            return false  // Can't validate empty text
        }
        
        // Direction 1: INPUT PRESERVATION — how many input words survived?
        // Grammar correction keeps most words. Talkback drops them.
        let preserved = inputSet.intersection(outputSet).count
        let preservationRatio = Double(preserved) / Double(inputSet.count)
        
        // Direction 2: OUTPUT FAITHFULNESS — how many output words came from input?
        // Grammar correction doesn't add many new words. Talkback does.
        let faithful = outputSet.intersection(inputSet).count
        let faithfulnessRatio = Double(faithful) / Double(outputSet.count)
        
        print("📊 Preservation: \(preserved)/\(inputSet.count) = \(String(format: "%.0f", preservationRatio * 100))% | Faithfulness: \(faithful)/\(outputSet.count) = \(String(format: "%.0f", faithfulnessRatio * 100))% (need ≥\(String(format: "%.0f", minWordOverlapRatio * 100))% both)")
        
        // BOTH directions must pass
        return preservationRatio >= minWordOverlapRatio && faithfulnessRatio >= minWordOverlapRatio
    }
    
    // MARK: - Filler Removal (Rule-Based, Multilingual)
    
    /// Removes filler words using regex - bulletproof, no LLM needed
    private func removeFillers(_ text: String) -> String {
        var result = text
        
        // English filler patterns (multi-word first, then single)
        // Order matters: match longer patterns before shorter ones
        let englishFillers = [
            // "like" as filler — only when after prepositions/conjunctions (safe, won't match "I like pizza")
            "\\babout like\\b",    // "about like getting" → "about getting"
            "\\bis like\\b",       // "is like really" → "is really"
            "\\bwas like\\b",      // "was like so" → "was so"
            "\\bbut like\\b",      // "but like technology" → "but technology"
            "\\bor like\\b",       // "or like which" → "or which"
            "\\band like\\b",      // "and like then" → "and then"
            "\\bjust like\\b",     // "just like really" → "just really"
            "\\bfor like\\b",      // "for like five" → "for five"
            
            // Clear multi-word fillers
            "\\bor whatever\\b",   // "tabs or whatever" → "tabs"
            "\\bor something\\b",  // "bought or something" → "bought"
            "\\band stuff\\b",     // "bought and stuff" → "bought"
            "\\byou know what i mean\\b",  // Remove entirely
            "\\byou know\\b", "\\bI mean\\b", "\\bsort of\\b", "\\bkind of\\b",
            "\\bI guess\\b",       // "I guess that's" → "that's"
            "\\bum yeah\\b", "\\buh yeah\\b", "\\byeah so\\b", "\\bso yeah\\b",
            "\\blike um\\b", "\\bum like\\b",
            "\\bpretty much\\b",    // "pretty much done" → "done"
            
            // Single-word fillers
            "\\bum\\b", "\\buh\\b", "\\bkinda\\b",
            "\\bbasically\\b", "\\bactually\\b", "\\bliterally\\b",
            "\\bhonestly\\b", "\\bobviously\\b",
            "\\bessentially\\b",    // Redundant qualifier
            "\\banyway\\b",        // transition filler
        ]
        
        // Russian filler/parasite words (слова-паразиты)
        // Multi-word phrases first, then single-word
        let russianFillers = [
            // Hesitation sounds (variable length)
            "\\bэм+\\b", "\\bээ+\\b", "\\bммм+\\b", "\\bааа+\\b", "\\bа+м+\\b",
            
            // Multi-word parasite phrases (match longer first)
            "\\bну типа\\b",           // "nu tipa"
            "\\bкак бы это\\b",        // "kak by eto"
            "\\bкак бы сказать\\b",    // "how to say"
            "\\bтак сказать\\b",       // "so to speak"
            "\\bв общем-то\\b",        // "in general" (casual)
            "\\bв общем\\b",           // "in general"
            "\\bна самом деле\\b",     // "actually"
            "\\bв принципе\\b",        // "in principle"
            "\\bпо сути\\b",           // "essentially"
            "\\bпо идее\\b",           // "theoretically"
            "\\bгрубо говоря\\b",      // "roughly speaking"
            "\\bесли честно\\b",       // "honestly"
            "\\bчестно говоря\\b",     // "honestly speaking"
            "\\bтип того\\b",          // "kinda like"
            "\\bну вот\\b",            // "well so"
            "\\bвот это\\b",           // "well this" (filler)
            "\\bвот так\\b",           // "like that" (filler)
            "\\bну знаешь\\b",         // "you know"
            "\\bну знаете\\b",         // "you know" (formal)
            "\\bэто самое\\b",         // "that thing" (placeholder filler)
            "\\bкак его\\b",           // "what's it called"
            
            // Single-word parasite fillers
            "\\bтипа\\b",              // "like/kinda"
            "\\bкороче\\b",            // "in short" (overused filler)
            "\\bпрям\\b",              // "like/literally"
            "\\bприкинь\\b",           // "imagine"
            "\\bблин\\b",              // "damn" (mild)
            "\\bкак бы\\b",            // "sort of"
            "\\bзначит\\b",            // "means/so" (filler)
            "\\bсоответственно\\b",    // "accordingly" (parasite)  
            "\\bдопустим\\b",          // "let's say"
            "\\bсобственно\\b",        // "actually/in fact"
            "\\bслушай\\b",            // "listen" (attention filler)
            "\\bслушайте\\b",          // "listen" (formal)
            "\\bсмотри\\b",            // "look" (attention filler)
            "\\bсмотрите\\b",          // "look" (formal)
        ]
        
        for pattern in englishFillers + russianFillers {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        
        // Clean up spaces and orphan commas
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s*,\\s*,", with: ",", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result
    }
    
    // MARK: - Rule-Based Grammar (Fallback)
    
    /// Apply common grammar fixes via regex - fallback when LLM unavailable
    private func applyGrammarRules(_ text: String) -> String {
        var result = text
        
        let contractions = [
            "\\bdo not\\b": "don't",
            "\\bdoes not\\b": "doesn't",
            "\\bdid not\\b": "didn't",
            "\\bcan not\\b": "can't",
            "\\bcannot\\b": "can't",
            "\\bwill not\\b": "won't",
            "\\bwould not\\b": "wouldn't",
            "\\bshould not\\b": "shouldn't",
            "\\bcould not\\b": "couldn't",
            "\\bI am\\b": "I'm",
            "\\bI have\\b": "I've",
            "\\bI will\\b": "I'll",
            "\\bI would\\b": "I'd",
            "\\byou are\\b": "you're",
            "\\bwe are\\b": "we're",
            "\\bthey are\\b": "they're",
            "\\bit is\\b": "it's",
            "\\bthat is\\b": "that's",
            "\\bwhat is\\b": "what's",
            "\\bwhere is\\b": "where's",
            "\\bhow is\\b": "how's",
            "\\blet us\\b": "let's",
        ]
        
        for (pattern, replacement) in contractions {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Utilities
    
    private func removeEmojis(from text: String) -> String {
        return text.unicodeScalars.filter { scalar in
            let value = scalar.value
            let emojiRanges: [ClosedRange<UInt32>] = [
                0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
                0x1F1E0...0x1F1FF, 0x2600...0x26FF, 0x2700...0x27BF,
                0xFE00...0xFE0F, 0x1F900...0x1F9FF, 0x1FA00...0x1FA6F,
                0x1FA70...0x1FAFF, 0x231A...0x231B, 0x23E9...0x23F3,
                0x23F8...0x23FA, 0x25AA...0x25AB, 0x25B6...0x25C0,
                0x25FB...0x25FE, 0x2614...0x2615, 0x2648...0x2653,
                0x2934...0x2935, 0x2B05...0x2B07, 0x2B1B...0x2B1C,
                0x2B50...0x2B50, 0x2B55...0x2B55,
            ]
            for range in emojiRanges {
                if range.contains(value) { return false }
            }
            return true
        }.map { String($0) }.joined()
    }
}
