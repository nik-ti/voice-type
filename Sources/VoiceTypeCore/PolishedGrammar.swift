// Repairs a narrow, unambiguous English compound-subject error before model editing.
// Names are captured from the dictation; object phrases and other grammar stay with the editor.
import Foundation

public enum PolishedGrammar {
    public static func repairCompoundSubjects(_ text: String) -> String {
        let pattern = #"(^|[.!?]\s+)(me|him|her|us|them)\s+and\s+([\p{L}][\p{L}'’-]*)\s+(was|were|is|are|has|have)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let prefix = Range(match.range(at: 1), in: result),
                  let pronoun = Range(match.range(at: 2), in: result),
                  let name = Range(match.range(at: 3), in: result), let verb = Range(match.range(at: 4), in: result) else { continue }
            let plural: String
            switch result[verb].lowercased() {
            case "was", "were": plural = "were"
            case "is", "are": plural = "are"
            default: plural = "have"
            }
            let subject: String
            switch result[pronoun].lowercased() {
            case "me": subject = "\(result[name]) and I"
            case "him": subject = "He and \(result[name])"
            case "her": subject = "She and \(result[name])"
            case "us": subject = "We and \(result[name])"
            default: subject = "They and \(result[name])"
            }
            let replacement = "\(result[prefix])\(subject) \(plural)"
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
}
