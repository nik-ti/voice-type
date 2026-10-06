import Foundation

/// Turns spoken numbers and money into digits and symbols.
///
/// "five thousand dollars" → "$5,000". Lone words like "one" in "one of us"
/// are left alone so we don't rewrite ordinary English/Russian.
public enum SpokenNumberFormatter {
    public static func rewrite(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let words = tokenize(text)
        guard !words.isEmpty else { return text }
        var i = 0
        var out: [String] = []
        while i < words.count {
            if let parsed = parseNumberPhrase(words, start: i) {
                out.append(parsed.written)
                i = parsed.nextIndex
            } else {
                out.append(words[i].display)
                i += 1
            }
        }
        return TextCleanupService.collapseWhitespace(out.joined(separator: " "))
    }

    // MARK: - Tokenize (keeps trailing punctuation on a side channel)

    fileprivate struct Word {
        let core: String
        let display: String
        let trailing: String
        var lower: String { core.lowercased() }
    }

    private static func tokenize(_ text: String) -> [Word] {
        text.split(whereSeparator: { $0.isWhitespace }).map { raw in
            let s = String(raw)
            var core = s
            var trailing = ""
            while let last = core.last, ".,!?;:".contains(last) {
                trailing = String(last) + trailing
                core.removeLast()
            }
            return Word(core: core, display: s, trailing: trailing)
        }
    }

    private struct Parsed {
        let written: String
        let nextIndex: Int
    }

    private static func parseNumberPhrase(_ words: [Word], start: Int) -> Parsed? {
        guard start < words.count else { return nil }
        if let english = parseEnglish(words, start: start) { return english }
        if let russian = parseRussian(words, start: start) { return russian }
        return nil
    }

    // MARK: - English

    private static let enOnes: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let enTeens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let enTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let enCurrency: [String: String] = [
        "dollar": "$", "dollars": "$", "buck": "$", "bucks": "$", "usd": "$",
        "euro": "€", "euros": "€",
        "pound": "£", "pounds": "£", "gbp": "£",
        "yen": "¥",
        "ruble": "₽", "rubles": "₽", "rouble": "₽", "roubles": "₽",
    ]

    private static func parseEnglish(_ words: [Word], start: Int) -> Parsed? {
        var i = start
        let leadingA = words[i].lower == "a" || words[i].lower == "an"
        if leadingA {
            guard i + 1 < words.count else { return nil }
            let next = words[i + 1].lower
            guard next == "hundred" || next == "thousand" || next == "million" || next == "billion" else {
                return nil
            }
        }

        guard let (value, consumed) = readEnglishNumber(words, start: i, allowBareSmall: true) else {
            return nil
        }
        i += consumed
        var trailing = words[i - 1].trailing

        var symbol: String?
        var asPercent = false
        if i < words.count, let sym = enCurrency[words[i].lower] {
            symbol = sym
            trailing = words[i].trailing
            i += 1
            if i < words.count, words[i].lower == "and",
               i + 1 < words.count,
               let (centsVal, centCount) = readEnglishNumber(words, start: i + 1, allowBareSmall: true) {
                let afterCents = i + 1 + centCount
                if afterCents < words.count,
                   words[afterCents].lower == "cent" || words[afterCents].lower == "cents" {
                    trailing = words[afterCents].trailing
                    let written = formatMoney(symbol: sym, major: value, cents: centsVal) + trailing
                    return Parsed(written: written, nextIndex: afterCents + 1)
                }
            }
        } else if i < words.count, isEnglishPercent(words, at: i) {
            asPercent = true
            if words[i].lower == "per" {
                trailing = words[i + 1].trailing
                i += 2
            } else {
                trailing = words[i].trailing
                i += 1
            }
        }

        let tokenCount = i - start
        let usedScale = (start..<i).contains { idx in
            ["hundred", "thousand", "million", "billion"].contains(words[idx].lower)
        }
        if symbol == nil && !asPercent && tokenCount < 2 && !usedScale && !leadingA {
            return nil
        }

        if asPercent {
            return Parsed(written: formatCardinal(value) + "%" + trailing, nextIndex: i)
        }
        let written = (symbol.map { formatMoney(symbol: $0, major: value, cents: nil) } ?? formatCardinal(value)) + trailing
        return Parsed(written: written, nextIndex: i)
    }

    private static func isEnglishNumberWord(_ word: String) -> Bool {
        enOnes[word] != nil || enTeens[word] != nil || enTens[word] != nil
            || word == "hundred" || word == "thousand" || word == "million" || word == "billion"
    }

    private static func isEnglishPercent(_ words: [Word], at i: Int) -> Bool {
        let w = words[i].lower
        if w == "percent" || w == "percentage" { return true }
        return w == "per" && i + 1 < words.count && words[i + 1].lower == "cent"
    }

    private static func readEnglishNumber(_ words: [Word], start: Int, allowBareSmall: Bool) -> (Int, Int)? {
        var i = start
        var total = 0
        var current = 0
        var consumed = 0

        if i < words.count, words[i].lower == "a" || words[i].lower == "an" {
            current = 1
            i += 1
            consumed += 1
        }

        while i < words.count {
            let w = words[i].lower
            // "one hundred and five", not "one and that's it".
            if w == "and", i + 1 < words.count, isEnglishNumberWord(words[i + 1].lower) {
                i += 1
                consumed += 1
                continue
            }
            if let n = enOnes[w] ?? enTeens[w] {
                current += n
                i += 1
                consumed += 1
                continue
            }
            if let n = enTens[w] {
                current += n
                i += 1
                consumed += 1
                continue
            }
            if w == "hundred" {
                if current == 0 { current = 1 }
                current *= 100
                i += 1
                consumed += 1
                continue
            }
            if w == "thousand" {
                if current == 0 { current = 1 }
                total += current * 1_000
                current = 0
                i += 1
                consumed += 1
                continue
            }
            if w == "million" {
                if current == 0 { current = 1 }
                total += current * 1_000_000
                current = 0
                i += 1
                consumed += 1
                continue
            }
            if w == "billion" {
                if current == 0 { current = 1 }
                total += current * 1_000_000_000
                current = 0
                i += 1
                consumed += 1
                continue
            }
            break
        }

        total += current
        if consumed == 0 { return nil }
        if !allowBareSmall && consumed == 1 && total < 20 && start < words.count {
            let only = words[start].lower
            if enOnes[only] != nil || enTeens[only] != nil { return nil }
        }
        return (total, consumed)
    }

    // MARK: - Russian

    private static let ruSmall: [String: Int] = {
        var map: [String: Int] = [
            "ноль": 0,
            "один": 1, "одна": 1, "одно": 1, "одного": 1, "одну": 1,
            "два": 2, "две": 2, "двух": 2,
            "три": 3, "трех": 3, "трёх": 3,
            "четыре": 4, "четырех": 4, "четырёх": 4,
            "пять": 5, "пяти": 5,
            "шесть": 6, "шести": 6,
            "семь": 7, "семи": 7,
            "восемь": 8, "восьми": 8,
            "девять": 9, "девяти": 9,
            "десять": 10, "десяти": 10,
            "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13,
            "четырнадцать": 14, "пятнадцать": 15, "шестнадцать": 16,
            "семнадцать": 17, "восемнадцать": 18, "девятнадцать": 19,
            "двадцать": 20, "тридцать": 30, "сорок": 40,
            "пятьдесят": 50, "шестьдесят": 60, "семьдесят": 70,
            "восемьдесят": 80, "девяносто": 90,
            "сто": 100, "двести": 200, "триста": 300, "четыреста": 400,
            "пятьсот": 500, "шестьсот": 600, "семьсот": 700,
            "восемьсот": 800, "девятьсот": 900,
        ]
        return map
    }()
    private static let ruThousand = Set(["тысяча", "тысячи", "тысяч"])
    private static let ruMillion = Set(["миллион", "миллиона", "миллионов"])
    private static let ruCurrency: [String: String] = [
        "доллар": "$", "доллара": "$", "долларов": "$",
        "евро": "€",
        "фунт": "£", "фунта": "£", "фунтов": "£",
        "рубль": "₽", "рубля": "₽", "рублей": "₽", "руб": "₽",
    ]

    private static func parseRussian(_ words: [Word], start: Int) -> Parsed? {
        guard let (value, consumed) = readRussianNumber(words, start: start, allowBareSmall: true) else {
            return nil
        }
        var i = start + consumed
        var trailing = words[i - 1].trailing
        var symbol: String?
        var asPercent = false
        if i < words.count, let sym = ruCurrency[words[i].lower] {
            symbol = sym
            trailing = words[i].trailing
            i += 1
        } else if i < words.count, isRussianPercent(words[i].lower) {
            asPercent = true
            trailing = words[i].trailing
            i += 1
        }
        let tokenCount = i - start
        let usedScale = (start..<i).contains { ruThousand.contains(words[$0].lower) || ruMillion.contains(words[$0].lower) }
        if symbol == nil && !asPercent && tokenCount < 2 && !usedScale {
            return nil
        }
        if asPercent {
            return Parsed(written: formatCardinal(value) + "%" + trailing, nextIndex: i)
        }
        let written = (symbol.map { formatMoney(symbol: $0, major: value, cents: nil) } ?? formatCardinal(value)) + trailing
        return Parsed(written: written, nextIndex: i)
    }

    private static func isRussianPercent(_ word: String) -> Bool {
        word == "процент" || word == "процента" || word == "процентов" || word == "проценты"
    }

    private static func readRussianNumber(_ words: [Word], start: Int, allowBareSmall: Bool) -> (Int, Int)? {
        var i = start
        var total = 0
        var current = 0
        var consumed = 0
        while i < words.count {
            let w = words[i].lower
            if ruThousand.contains(w) {
                if current == 0 { current = 1 }
                total += current * 1_000
                current = 0
                i += 1
                consumed += 1
                continue
            }
            if ruMillion.contains(w) {
                if current == 0 { current = 1 }
                total += current * 1_000_000
                current = 0
                i += 1
                consumed += 1
                continue
            }
            if let n = ruSmall[w] {
                current += n
                i += 1
                consumed += 1
                continue
            }
            break
        }
        total += current
        if consumed == 0 { return nil }
        if !allowBareSmall && consumed == 1 && total < 20 {
            return nil
        }
        return (total, consumed)
    }

    // MARK: - Formatting

    private static func formatCardinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatMoney(symbol: String, major: Int, cents: Int?) -> String {
        if let cents {
            let amount = Double(major) + Double(cents) / 100.0
            if symbol == "₽" {
                return String(format: "%.2f\(symbol)", amount)
            }
            return String(format: "\(symbol)%.2f", amount)
        }
        let body = formatCardinal(major)
        if symbol == "₽" { return body + symbol }
        return symbol + body
    }
}
