// Checks local grammar edits against the dictated instructions and measurable facts.
// Explicit single-value repairs affect validation only; this never writes a transcript itself.
import Foundation
import NaturalLanguage

public enum PolishValidator {
    public enum Rejection: String, Sendable {
        case empty, tooLong, tooShort, numbersChanged, datesChanged
        case negationChanged, conditionChanged, beginningLost, wordLoss, endingLost
        case namesChanged, filenamesChanged, unbalancedQuotes
    }

    public static func rejection(input: String, output: String) -> Rejection? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        if output.count > input.count * 3 { return .tooLong }
        if output.count < input.count / 4 { return .tooShort }

        let reference = SpokenCorrections.resolve(input)
        if let rejection = factRejection(reference: reference, output: output) { return rejection }
        let before = words(reference)
        let after = words(output)
        if let rejection = languageRejection(reference: reference, before: before, after: after) { return rejection }
        return boundaryRejection(before: before, after: after)
    }

    private static func factRejection(reference: String, output: String) -> Rejection? {
        if numbers(reference) != numbers(output) { return .numbersChanged }
        if filenames(reference) != filenames(output) { return .filenamesChanged }
        let quotationMarks = output.filter { "\"“”«»".contains($0) }
        if quotationMarks.count % 2 != 0 {
            let singleInchMark = quotationMarks.count == 1 && output.range(of: #"\d[\"”]"#, options: .regularExpression) != nil
            if !singleInchMark { return .unbalancedQuotes }
        }
        return nil
    }

    private static func languageRejection(reference: String, before: [String], after: [String]) -> Rejection? {
        if days(before) != days(after) { return .datesChanged }
        if counts(before.filter(negations.contains)) != counts(after.filter(negations.contains)) { return .negationChanged }
        if counts(before.filter(conditions.contains)) != counts(after.filter(conditions.contains)) { return .conditionChanged }
        if !names(reference).isSubset(of: Set(after)) { return .namesChanged }
        return nil
    }

    private static func boundaryRejection(before: [String], after: [String]) -> Rejection? {
        let source = before.filter { !fillers.contains($0) }
        let edited = after.filter { !fillers.contains($0) }
        guard !source.isEmpty, !edited.isEmpty else { return .wordLoss }
        if let anchor = source.first, !edited.prefix(8).contains(anchor) { return .beginningLost }

        let originalWords = Set(source)
        let editedWords = Set(edited)
        let shared = Double(originalWords.intersection(editedWords).count)
        if shared / Double(originalWords.count) < 0.6 || shared / Double(editedWords.count) < 0.6 { return .wordLoss }

        let tail = Array(source.suffix(6))
        let ending = edited.suffix(12)
        if tail.count >= 3, tail.filter({ ending.contains($0) }).count < tail.count - 1 { return .endingLost }
        return nil
    }

    private static func numbers(_ text: String) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:([$€£₽])\s*)?([-+]?\d+(?:,\d{3})*(?:\.\d+)?)(?:\s*(%))?"#) else { return [:] }
        let values = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 2), in: text) else { return nil }
            let digits = text[range].replacingOccurrences(of: ",", with: "")
            let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX"))?.description ?? digits
            let currency = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            let percent = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            return currency + value + percent
        }
        return counts(values)
    }

    private static func words(_ text: String) -> [String] {
        var expanded = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for (short, full) in [("won't", "will not"), ("can't", "can not"), ("shan't", "shall not")] {
            expanded = expanded.replacingOccurrences(of: "\\b\(short)\\b", with: full, options: .regularExpression)
        }
        expanded = expanded.replacingOccurrences(of: "n't\\b", with: " not", options: .regularExpression)
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = expanded
        var tokens: [String] = []
        tagger.enumerateTags(in: expanded.startIndex..<expanded.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = (tag?.rawValue ?? String(expanded[range])).lowercased()
                .trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).inverted)
            if !word.isEmpty { tokens.append(word == "me" ? "i" : word) }
            return true
        }
        return tokens
    }

    private static func counts(_ words: [String]) -> [String: Int] {
        words.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func filenames(_ text: String) -> [String: Int] {
        counts(DictationTerms.filenames(in: text))
    }

    private static func names(_ text: String) -> Set<String> {
        var text = text
        for filename in DictationTerms.filenames(in: text) { text = text.replacingOccurrences(of: filename, with: " ") }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var recognized: Set<String> = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                recognized.formUnion(words(String(text[range])))
            }
            return true
        }
        guard let regex = try? NSRegularExpression(pattern: #"\b[\p{Lu}][\p{L}\d_'’-]+\b"#) else { return [] }
        let midSentence = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let previous = prefix.last, !".!?…".contains(previous) else { return nil }
            return String(text[range])
        }
        return recognized.union(midSentence.flatMap(words))
    }

    private static func days(_ words: [String]) -> [String: Int] {
        counts(words.compactMap { weekday[$0] })
    }

    private static let fillers: Set<String> = ["um", "uh", "hmm", "so", "well", "oh", "like", "please", "sorry", "эм", "ээ", "ну", "вот"]
    private static let negations: Set<String> = ["not", "no", "never", "не", "нет", "никогда"]
    private static let conditions: Set<String> = ["if", "unless", "если"]
    private static let weekday: [String: String] = {
        let groups = [
            ["monday", "понедельник", "понедельника", "понедельнику", "понедельником", "понедельнике"],
            ["tuesday", "вторник", "вторника", "вторнику", "вторником", "вторнике"],
            ["wednesday", "среда", "среду", "среды", "среде", "средой"],
            ["thursday", "четверг", "четверга", "четвергу", "четвергом", "четверге"],
            ["friday", "пятница", "пятницу", "пятницы", "пятнице", "пятницей"],
            ["saturday", "суббота", "субботу", "субботы", "субботе", "субботой"],
            ["sunday", "воскресенье", "воскресенья", "воскресенью", "воскресеньем"],
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { group in group.map { ($0, group[0]) } })
    }()
}
