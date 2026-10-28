// Adds conservative paragraph breaks when a long edited take remains one block.
// Sentence boundaries and topic cues affect layout only, never the dictated words.
import Foundation
import NaturalLanguage

public enum DictationParagraphs {
    public static func format(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        if text.contains("\n"), !text.contains("\n\n"),
           text.range(of: #"(?m)^\s*(?:[-*•]\s+|\d+[.)]\s+)"#, options: .regularExpression) == nil {
            text = text.replacingOccurrences(of: "\n", with: " ")
        }
        guard !text.contains("\n"), text.split(whereSeparator: \.isWhitespace).count >= 70 else { return text }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var paragraphs: [String] = []
        var current = ""
        var sentenceCount = 0
        var quoted = false
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = sentence.lowercased()
            let newTopic = topicCues.contains { lower.hasPrefix($0) }
            if !quoted, !current.isEmpty, newTopic || sentenceCount >= 4 {
                paragraphs.append(current)
                current = ""
                sentenceCount = 0
            }
            current += (current.isEmpty ? "" : " ") + sentence
            sentenceCount += 1
            if sentence.filter({ "\"“”«»".contains($0) }).count % 2 != 0 { quoted.toggle() }
            return true
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static let topicCues = ["also,", "additionally,", "separately,", "finally,", "one last thing", "oh, and one last thing", "кроме того", "ещё один момент", "напоследок"]
}
