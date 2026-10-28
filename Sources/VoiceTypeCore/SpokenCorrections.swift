// Resolves adjacent, explicitly retracted numbers and weekdays before grammar editing.
// A closed set of value types avoids interpreting ordinary apologies as replacements.
import Foundation

public enum SpokenCorrections {
    public static func resolve(_ text: String) -> String {
        let numbers = #"[$€£₽]?\d+(?:,\d{3})*(?:\.\d+)?"#
        let days = #"(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|понедельник(?:а|у|ом|е)?|вторник(?:а|у|ом|е)?|сред(?:а|у|ы|е|ой)|четверг(?:а|у|ом|е)?|пятниц(?:а|у|ы|е|ей)|суббот(?:а|у|ы|е|ой)|воскресень(?:е|я|ю|ем))"#
        let repair = #"(?:sorry(?:\s*,?\s*no)?|no|i\s+mean|нет|точнее|вернее)"#
        let preposition = #"(?:on|в|во|на)\s+"#
        var result = text
        for value in [numbers, days] {
            let pattern = #"(?<![\p{L}\p{N}])("# + preposition + ")?(" + value + #")\s*(?:[,—–-]\s*|\s+)"# + repair + #"\b[\s,—–-]*("# + preposition + ")?(" + value + #")(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
                  let whole = Range(match.range, in: result), let newRange = Range(match.range(at: 4), in: result) {
                let oldPrefix = Range(match.range(at: 1), in: result).map { String(result[$0]) } ?? ""
                let newPrefix = Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? oldPrefix
                var replacement = String(result[newRange])
                if let oldRange = Range(match.range(at: 2), in: result),
                   let currency = result[oldRange].first, "$€£₽".contains(currency),
                   replacement.first.map({ !$0.isNumber }) != true {
                    replacement = String(currency) + replacement
                }
                result.replaceSubrange(whole, with: newPrefix + replacement)
            }
        }
        return result
    }
}
