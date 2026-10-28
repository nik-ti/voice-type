// Converts explicit sequential spoken labels into a numbered list with a punctuated introduction.
// The parsed items also let validation distinguish layout numbers from factual numbers.
import Foundation

public enum DictationLists {
    public struct List: Sendable {
        public let introduction: String
        public let items: [String]

        public func formatted(transform: (String) -> String = { $0 }) -> String {
            let header = introduction.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:; "))
            let punctuation = header.last.map { "?!".contains($0) } == true ? "" : ":"
            let prefix = header.isEmpty ? "" : header + punctuation + "\n\n"
            return prefix + items.enumerated().map { index, item in
                let edited = transform(item).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(index + 1). \(edited.isEmpty ? item : edited)"
            }.joined(separator: "\n")
        }
    }

    public static func format(_ text: String) -> String { parse(text)?.formatted() ?? text }

    public static func contentForValidation(_ text: String) -> String {
        guard let list = parse(text) else { return text }
        return ([list.introduction] + list.items).joined(separator: " ")
    }

    public static func parse(_ text: String) -> List? {
        if let pattern = writtenPattern,
           let list = makeList(text, matches: pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)), spoken: false) {
            return list
        }
        guard let pattern = spokenPattern else { return nil }
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            return text[..<range.lowerBound].filter { "\"“”«»".contains($0) }.count % 2 == 0
        }
        return makeList(text, matches: matches, spoken: true)
    }

    private static func makeList(_ text: String, matches: [NSTextCheckingResult], spoken: Bool) -> List? {
        guard matches.count >= 2, let first = matches.first, let start = Range(first.range, in: text)?.lowerBound else { return nil }
        let introduction = text[..<start].trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken, !introduction.isEmpty, introduction.range(of: introPattern, options: [.regularExpression, .caseInsensitive]) == nil { return nil }
        var items: [String] = []
        for (index, match) in matches.enumerated() {
            guard let label = Range(match.range(at: 1), in: text),
                  let marker = Range(match.range, in: text), number(String(text[label])) == index + 1 else { return nil }
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: text)?.lowerBound : text.endIndex
            guard let end else { return nil }
            let item = text[marker.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            items.append(item)
        }
        return List(introduction: introduction, items: items)
    }

    private static func number(_ label: String) -> Int? {
        Int(label) ?? numberWords[label.lowercased()]
    }

    private static let numberWords: [String: Int] = {
        let groups = [
            ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"],
            ["один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять"],
            ["первый", "второй", "третий", "четвертый", "пятый", "шестой", "седьмой", "восьмой", "девятый", "десятый"],
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { $0.enumerated().map { ($0.element, $0.offset + 1) } })
    }()
    private static let introPattern = #"\b(?:list|constraints?|requirements?|steps?|rules?|items?|points?|список|ограничения|требования|пункты|шаги|правила)\b"#
    private static let writtenPattern = try? NSRegularExpression(pattern: #"(?m)^\h*([1-9]\d{0,2})[.)]\h+"#)
    private static let spokenPattern: NSRegularExpression? = {
        let labels = numberWords.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try? NSRegularExpression(pattern: #"\b(?:number|номер|пункт)\s+([1-9]\d{0,2}|"# + labels + #")\b\s*[,.:;)—-]?\s*"#, options: .caseInsensitive)
    }()
}
