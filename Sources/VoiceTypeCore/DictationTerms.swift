// Restores spoken filename syntax, explicit quotation boundaries and known technical spellings.
// Ordinary prose stays untouched unless it contains a recognized dictation convention.
import Foundation

public enum DictationTerms {
    private static let extensions = "md|txt|json|yaml|yml|csv|tsv|py|js|ts|tsx|jsx|html|css|pdf|docx|xlsx|swift|sh"

    public static func normalize(_ text: String) -> String {
        let text = spokenQuotes(text)
        let pattern = #"\b([\p{L}\p{N}_-]+)\s*(?:\.\s*|\s+(?:dot|точка)\s+)("# + extensions + #")\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let stemRange = Range(match.range(at: 1), in: text),
                  let extensionRange = Range(match.range(at: 2), in: text) else { continue }
            var stem = String(text[stemRange])
            let suffix = text[extensionRange].lowercased()
            switch (stem.lowercased(), suffix) {
            case ("cloud", "md"), ("claude", "md"): stem = "CLAUDE"
            case ("readme", "md"): stem = "README"
            case ("agents", "md"): stem = "AGENTS"
            default: break
            }
            var replacementRange = match.range
            let end = NSMaxRange(match.range)
            let source = text as NSString
            if stem == "CLAUDE", source.substring(with: match.range).contains(" "),
               end < source.length, source.substring(with: NSRange(location: end, length: 1)) == "." {
                replacementRange.length += 1
            }
            if let range = Range(replacementRange, in: result) { result.replaceSubrange(range, with: "\(stem).\(suffix)") }
        }
        if result.hasSuffix("."), isStandaloneFilename(String(result.dropLast())) { result.removeLast() }
        return result
    }

    public static func isStandaloneFilename(_ text: String) -> Bool {
        text.range(of: #"^[\p{L}\p{N}_./\\-]+\.(?:"# + extensions + ")$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func filenames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[\p{L}\p{N}_-]+\.(?:"# + extensions + #")\b"#, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func spokenQuotes(_ text: String) -> String {
        let patterns = [
            (#"\b(?:open quote|quote)\s+([\s\S]+?)\s+(?:end quote|close quote|unquote)\b"#, "\"$1\""),
            (#"\b(?:открыть кавычки|открывающая кавычка)\s+([\s\S]+?)\s+(?:закрыть кавычки|закрывающая кавычка)\b"#, "«$1»"),
        ]
        return patterns.reduce(text) { result, pair in
            result.replacingOccurrences(of: pair.0, with: pair.1, options: [.regularExpression, .caseInsensitive])
        }
    }
}
