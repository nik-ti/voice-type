// Protects duration phrases before native written-number normalization can mistake them for ordinals.
// The native engine still handles other text and converts each protected number on its own.
import Foundation
import NaturalLanguage
import FluidAudio

enum TranscriptNormalizer {
    static func normalize(_ text: String) -> String {
        let normalizer = TextNormalizer.shared
        guard let regex = durationPattern else { return normalizer.normalizeSentence(text) }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var masked = text
        var restore: [String: String] = [:]
        // FluidAudio uses BMP private-use markers internally; use a separate plane.
        var sentinel = UInt32(0xF0000)
        let occupied = Set(text.unicodeScalars.map(\.value))
        func nextMarker() -> String? {
            while sentinel <= 0xFFFFD {
                let value = sentinel
                sentinel += 1
                if occupied.contains(value) { continue }
                if let scalar = UnicodeScalar(value) { return String(scalar) }
            }
            return nil
        }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  let written = writtenDuration(match, in: text, tagger: tagger) else { continue }
            guard let marker = nextMarker() else { break }
            restore[marker] = written
            masked.replaceSubrange(range, with: marker)
        }
        // Do not let the native engine's own markers overwrite literal input characters.
        for value in occupied where (0xE000...0xF8FF).contains(value) {
            guard let scalar = UnicodeScalar(value), let marker = nextMarker() else { break }
            let original = String(scalar)
            restore[marker] = original
            masked = masked.replacingOccurrences(of: original, with: marker)
        }
        var result = normalizer.normalizeSentence(masked)
        for (marker, duration) in restore { result = result.replacingOccurrences(of: marker, with: duration) }
        return result
    }

    private static func writtenDuration(_ match: NSTextCheckingResult, in text: String, tagger: NLTagger) -> String? {
        guard let range = Range(match.range, in: text), let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let number = String(text[numberRange]).lowercased().replacingOccurrences(of: "-", with: " ")
        let unit = String(text[unitRange]).lowercased()
        guard !isAmbiguousOrdinal(number: number, unit: unit) else { return nil }
        let value = TextNormalizer.shared.normalize(number)
        guard value.range(of: #"^\d+(?:,\d{3})*(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        let compound = !unit.hasSuffix("s") && (text[range].contains("-") || followedByNoun(text, after: range.upperBound, tagger: tagger))
        return value + (compound ? "-" : " ") + unit
    }

    private static func isAmbiguousOrdinal(number: String, unit: String) -> Bool {
        guard unit == "second", !number.contains(where: \.isNumber), let last = number.lowercased().split(separator: " ").last else { return false }
        return ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "and"].contains(String(last))
    }

    private static func followedByNoun(_ text: String, after index: String.Index, tagger: NLTagger) -> Bool {
        guard let next = text[index...].firstIndex(where: { !$0.isWhitespace }) else { return false }
        return tagger.tag(at: next, unit: .word, scheme: .lexicalClass).0 == .noun
    }

    private static let durationPattern: NSRegularExpression? = {
        let first = "zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million"
        let wordNumber = "(?:" + first + ")(?:[ -]+(?:" + first + "|and|point))*"
        let number = #"(?:\d+(?:,\d{3})*(?:\.\d+)?|"# + wordNumber + ")"
        return try? NSRegularExpression(pattern: #"\b("# + number + #")[ -]+(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\b"#, options: .caseInsensitive)
    }()
}
