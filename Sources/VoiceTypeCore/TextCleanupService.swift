import Foundation
import NaturalLanguage

/// Deterministic Regular-mode cleanup: hesitations, false starts, and light formatting.
///
/// Ambiguous fillers (`like`, `actually`, `типа`) are left for Polished mode.
/// This is language-aware so English `um` is not stripped from languages where
/// that syllable is a real word.
public enum TextCleanupService {
    public enum Language: String, Sendable {
        case english
        case russian
        case mixed
    }

    /// Full Regular-mode pass: hesitations → false starts → contractions/caps/punctuation.
    public static func basicFormat(_ text: String, language: Language = .mixed) -> String {
        guard !text.isEmpty else { return text }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripModelTokens(result)
        result = removeHesitations(result, language: language)
        result = collapseFalseStarts(result)
        result = restoreContractions(result)
        result = capitalizePronounI(result)
        result = collapseRepeatedWords(result)
        result = expandAbbreviations(result)
        result = collapseWhitespace(result)
        result = capitalizeSentences(result)
        result = applyPunctuationRules(result)
        result = applyCapitalizationRules(result)
        result = polishPostPass(result)
        result = restoreSmallCardinals(result)
        result = ensureTerminalPunctuation(result)
        return result
    }

    /// Number/percent glue that keeps line breaks. Safe to run after the LLM.
    public static func polishPostPass(_ text: String) -> String {
        let source = text.contains("\n") ? stripModelTokens(text) : SpokenNumberFormatter.rewrite(stripModelTokens(text))
        return restoreSmallCardinals(formatNumbers(source))
    }

    /// ITN turns "one" into "1" even in "the one thing". A lone 0–9 stays a
    /// word unless it is a time, a label ("chapter 1"), or a measured quantity.
    public static func restoreSmallCardinals(_ text: String) -> String {
        // Never introduce English number words into another language or a mixed take.
        guard !text.unicodeScalars.contains(where: { (0x0400...0x052F).contains($0.value) }) else { return text }
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        let labels: Set<String> = [
            "chapter", "page", "step", "version", "no", "no.", "number", "#", "option", "item", "part",
        ]
        let units: Set<String> = [
            "am", "pm", "a.m.", "p.m.", "percent", "%",
            "dollar", "dollars", "cent", "cents", "usd",
            "minute", "minutes", "min", "mins", "hour", "hours", "hr", "hrs",
            "second", "seconds", "sec", "secs", "day", "days", "week", "weeks",
            "month", "months", "year", "years", "mile", "miles", "km", "kg", "lb", "lbs",
            "people", "person", "times", "o'clock",
        ]
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for i in tokens.indices {
            let raw = tokens[i]
            let core = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            guard core.count == 1, let digit = Int(core), (0...9).contains(digit) else { continue }
            let prev = i > 0 ? tokens[i - 1].trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")).lowercased() : ""
            let next = i + 1 < tokens.count
                ? tokens[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")).lowercased()
                : ""
            if labels.contains(prev) || units.contains(next) || units.contains(prev) { continue }
            let suffix = String(raw.dropFirst(core.count))
            tokens[i] = words[digit] + suffix
        }
        return tokens.joined(separator: " ")
    }

    /// True when the cleaned text still contains the ending of the original.
    /// One missing word is allowed (a filler or a small grammar fix).
    public static func preservesEnding(_ output: String, of input: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: .punctuationCharacters).joined()
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 1 }
        }
        let tail = Array(words(input).suffix(6))
        guard tail.count >= 3 else { return true }
        let out = words(output)
        let found = tail.filter { out.contains($0) }.count
        return found >= tail.count - 1
    }

    /// Parakeet prints `<unk>` when it wants a quote or a symbol it has no token for.
    public static func stripModelTokens(_ text: String) -> String {
        var result = text
        let tokens = ["<unk>", "</s>", "<s>", "<pad>", "<|unk|>", "�"]
        for token in tokens {
            result = result.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        return result.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    /// True hesitation sounds only. Safe for Regular mode.
    public static func removeHesitations(_ text: String, language: Language = .mixed) -> String {
        var result = text
        var patterns: [String] = []

        if language != .russian {
            patterns += [
                #"\buh+h*\b(?![- ]huh\b)"#,
                #"\bum+m*\b"#,
                #"\bhmm+\b"#,
                #"\bmm+\b"#,
                #"\berm?\b"#,
                #"\bah+\b"#,
                #"\beh+\b"#,
            ]
        }

        if language != .english {
            patterns += [
                #"\bэм+\b"#,
                #"\bээ+\b"#,
                #"\bе+м+\b"#,
                #"\bммм+\b"#,
                #"\bааа+\b"#,
                #"\bа+м+\b"#,
            ]
        }

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        result = collapseWhitespace(result)
        result = result.replacingOccurrences(of: #"\s*,\s*,+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^\s*,\s*"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "I was I was going" → "I was going". Collapses repeated 1–3 word phrases.
    public static func collapseFalseStarts(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\b(?!had\s+had\b)((?:\S+\s+){0,2}\S+)\s+\1\b"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
            }
        }
        return collapseWhitespace(result)
    }

    // MARK: - Formatting helpers

    public static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func restoreContractions(_ text: String) -> String {
        var result = text
        let contractionFixes: [(String, String)] = [
            (#"\bdont\b"#, "don't"),
            (#"\bcant\b"#, "can't"),
            (#"\bwont\b"#, "won't"),
            (#"\bwouldnt\b"#, "wouldn't"),
            (#"\bshouldnt\b"#, "shouldn't"),
            (#"\bcouldnt\b"#, "couldn't"),
            (#"\bdoesnt\b"#, "doesn't"),
            (#"\bdidnt\b"#, "didn't"),
            (#"\bisnt\b"#, "isn't"),
            (#"\barent\b"#, "aren't"),
            (#"\bwasnt\b"#, "wasn't"),
            (#"\bwerent\b"#, "weren't"),
            (#"\bhavent\b"#, "haven't"),
            (#"\bhasnt\b"#, "hasn't"),
            (#"\bhadnt\b"#, "hadn't"),
            (#"\bthats\b"#, "that's"),
            (#"\bwhats\b"#, "what's"),
            (#"\bheres\b"#, "here's"),
            (#"\btheres\b"#, "there's"),
            (#"\blets\b"#, "let's"),
            (#"\bim\b"#, "I'm"),
            (#"\bive\b"#, "I've"),
            (#"\byoure\b"#, "you're"),
            (#"\btheyre\b"#, "they're"),
        ]
        for (pattern, replacement) in contractionFixes {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        return result
    }

    static func capitalizePronounI(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"\bi\b"#, options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "I")
        }
        if let regex = try? NSRegularExpression(pattern: #"\bi('m|'ve|'ll|'d)\b"#, options: []) {
            let mutableResult = NSMutableString(string: result)
            let range = NSRange(location: 0, length: mutableResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let matchStr = mutableResult.substring(with: match.range)
                mutableResult.replaceCharacters(in: match.range, with: "I" + matchStr.dropFirst())
            }
            result = mutableResult as String
        }
        return result
    }

    static func collapseRepeatedWords(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?!had\s+had\b)(\w+)\s+\1\b"#, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }

    static func expandAbbreviations(_ text: String) -> String {
        var result = text
        let abbreviations: [(String, String)] = [
            (#"\bmr\b\.?"#, "Mr."),
            (#"\bmrs\b\.?"#, "Mrs."),
            (#"\bdr\b\.?"#, "Dr."),
            (#"\bms\b\.?"#, "Ms."),
            (#"\bsr\b\.?"#, "Sr."),
            (#"\bsra\b\.?"#, "Sra."),
            (#"\bsrta\b\.?"#, "Srta."),
        ]
        for (pattern, replacement) in abbreviations {
            if let regex = try? NSRegularExpression(pattern: "(?<=\\s|^)" + pattern + "(?=\\s|$)", options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        let russianAbbreviations: [(String, String)] = [
            (#"\bт д\b"#, "т.д."),
            (#"\bт е\b"#, "т.е."),
            (#"\bт к\b"#, "т.к."),
            (#"\bт п\b"#, "т.п."),
        ]
        for (pattern, replacement) in russianAbbreviations {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        return result
    }

    static func capitalizeSentences(_ text: String) -> String {
        var result = text
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        if let regex = try? NSRegularExpression(pattern: #"([.!?])\s+(\p{Ll})"#, options: []) {
            let mutableResult = NSMutableString(string: result)
            let nsResult = result as NSString
            let range = NSRange(location: 0, length: nsResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 2 else { return }
                let letter = nsResult.substring(with: match.range(at: 2)).uppercased()
                mutableResult.replaceCharacters(in: match.range(at: 2), with: letter)
            }
            result = mutableResult as String
        }
        return result
    }

    static func applyPunctuationRules(_ text: String) -> String {
        var result = text
        let introWords = ["however", "therefore", "meanwhile", "furthermore", "moreover", "additionally", "consequently"]
        for word in introWords {
            result = result.replacingOccurrences(
                of: "(^|\\. )(\(word))\\s+(?!,)",
                with: "$1$2, ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: #"\s+([,.:;!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([,.:;])([A-Za-zА-Яа-я])"#, with: "$1 $2", options: .regularExpression)
        return result
    }

    static func applyCapitalizationRules(_ text: String) -> String {
        var result = text
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for day in days {
            result = result.replacingOccurrences(
                of: "\\b\(day)\\b",
                with: day.capitalized,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let months = ["january", "february", "march", "april", "may", "june",
                      "july", "august", "september", "october", "november", "december"]
        for month in months {
            result = result.replacingOccurrences(
                of: "\\b\(month)\\b",
                with: month.capitalized,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
        return result
    }

    static func formatNumbers(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"(\d{1,2}):?(\d{2})?\s*(am|pm)"#, options: .caseInsensitive) {
            let mutableResult = NSMutableString(string: result)
            let range = NSRange(location: 0, length: mutableResult.length)
            regex.enumerateMatches(in: result, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let hour = mutableResult.substring(with: match.range(at: 1))
                let minutes = match.range(at: 2).location != NSNotFound ? ":" + mutableResult.substring(with: match.range(at: 2)) : ""
                let period = mutableResult.substring(with: match.range(at: 3)).uppercased()
                mutableResult.replaceCharacters(in: match.range, with: "\(hour)\(minutes) \(period)")
            }
            result = mutableResult as String
        }
        // ITN and some locales emit "50 %"; English dictation should be "50%".
        for space in ["\u{00A0}", "\u{202F}", "\u{2009}"] {
            result = result.replacingOccurrences(of: space, with: " ")
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s+%"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1%")
        }
        if let regex = try? NSRegularExpression(
            pattern: #"(\d+(?:[.,]\d+)?)\s*(percent|percentage|per\s*cent|процентов|процента|проценты|процент)\b"#,
            options: .caseInsensitive
        ) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1%")
        }
        return result
    }

    static func ensureTerminalPunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }
        if !result.hasSuffix(".") && !result.hasSuffix("!") && !result.hasSuffix("?") {
            result += "."
        }
        return result
    }

    /// Rule-based contraction expansion used as LLM fallback.
    public static func applyGrammarRules(_ text: String) -> String {
        var result = text
        let contractions = [
            #"\bdo not\b"#: "don't",
            #"\bdoes not\b"#: "doesn't",
            #"\bdid not\b"#: "didn't",
            #"\bcan not\b"#: "can't",
            #"\bcannot\b"#: "can't",
            #"\bwill not\b"#: "won't",
            #"\bwould not\b"#: "wouldn't",
            #"\bshould not\b"#: "shouldn't",
            #"\bcould not\b"#: "couldn't",
            #"\bI am\b"#: "I'm",
            #"\bI have\b"#: "I've",
            #"\bI will\b"#: "I'll",
            #"\bI would\b"#: "I'd",
            #"\byou are\b"#: "you're",
            #"\bwe are\b"#: "we're",
            #"\bthey are\b"#: "they're",
            #"\bit is\b"#: "it's",
            #"\bthat is\b"#: "that's",
            #"\bwhat is\b"#: "what's",
            #"\bwhere is\b"#: "where's",
            #"\bhow is\b"#: "how's",
            #"\blet us\b"#: "let's",
        ]
        for (pattern, replacement) in contractions {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
            }
        }
        return collapseWhitespace(result)
    }

    // MARK: - Language detection

    public struct DetectedLanguage: Sendable, Equatable {
        public let code: String
        public let cleanupLanguage: Language

        public init(code: String, cleanupLanguage: Language) {
            self.code = code
            self.cleanupLanguage = cleanupLanguage
        }
    }

    /// Guess the spoken language from transcribed text. Mixed EN+RU is common
    /// for bilingual dictation, so script mixing wins over a single-label guess.
    public static func detectLanguage(from text: String) -> DetectedLanguage {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            if (0x0400...0x04FF).contains(scalar.value) {
                cyrillic += 1
            } else {
                latin += 1
            }
        }

        let letters = max(cyrillic + latin, 1)
        let cyrillicShare = Double(cyrillic) / Double(letters)
        let latinShare = Double(latin) / Double(letters)
        if cyrillic >= 3 && latin >= 3 && cyrillicShare >= 0.2 && latinShare >= 0.2 {
            return DetectedLanguage(code: "mixed", cleanupLanguage: .mixed)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage {
            switch dominant {
            case .english:
                return DetectedLanguage(code: "en", cleanupLanguage: .english)
            case .russian, .ukrainian, .bulgarian:
                return DetectedLanguage(code: dominant.rawValue, cleanupLanguage: .russian)
            default:
                return DetectedLanguage(code: dominant.rawValue, cleanupLanguage: .mixed)
            }
        }

        if cyrillicShare >= 0.3 {
            return DetectedLanguage(code: "ru", cleanupLanguage: .russian)
        }
        return DetectedLanguage(code: "en", cleanupLanguage: .english)
    }
}
