import XCTest
@testable import VoiceTypeCore

final class TextCleanupTests: XCTestCase {
    func testEnglishHesitationsAreStripped() {
        let input = "um so I need to umm schedule a meeting uh next tuesday"
        let output = TextCleanupService.basicFormat(input, language: .english)
        XCTAssertFalse(output.lowercased().contains("um"))
        XCTAssertFalse(output.lowercased().contains("uh"))
        XCTAssertTrue(output.contains("Tuesday"))
        XCTAssertTrue(output.hasPrefix("So I need") || output.hasPrefix("I need"))
    }

    func testEnglishVariableLengthHesitations() {
        let input = "uhhh hmm well I think erm that works"
        let output = TextCleanupService.removeHesitations(input, language: .english).lowercased()
        XCTAssertFalse(output.contains("uhhh"))
        XCTAssertFalse(output.contains("hmm"))
        XCTAssertFalse(output.contains("erm"))
        XCTAssertTrue(output.contains("well i think"))
        XCTAssertTrue(output.contains("that works"))
    }

    func testFalseStartsCollapse() {
        let output = TextCleanupService.collapseFalseStarts("I was I was going to the store")
        XCTAssertEqual(output, "I was going to the store")
    }

    func testDoesNotDeleteRealWordsInRegularMode() {
        let input = "I actually like pizza and I honestly think it is good"
        let output = TextCleanupService.basicFormat(input, language: .english)
        XCTAssertTrue(output.lowercased().contains("actually"))
        XCTAssertTrue(output.lowercased().contains("like pizza"))
        XCTAssertTrue(output.lowercased().contains("honestly"))
    }

    func testRussianHesitationsAreStripped() {
        let input = "эм я хотел эээ сказать что встреча завтра"
        let output = TextCleanupService.basicFormat(input, language: .russian)
        XCTAssertFalse(output.contains("эм"))
        XCTAssertFalse(output.contains("эээ"))
        XCTAssertTrue(output.contains("хотел"))
        XCTAssertTrue(output.contains("сказать"))
    }

    func testRussianDoesNotStripEnglishUmAsIfItWerePortugueseArticle() {
        let input = "Я хотел сказать"
        let output = TextCleanupService.removeHesitations(input, language: .russian)
        XCTAssertEqual(output, "Я хотел сказать")
    }

    func testContractionsAndPronounI() {
        let output = TextCleanupService.basicFormat("im sure thats ready", language: .english)
        XCTAssertTrue(output.contains("I'm"))
        XCTAssertTrue(output.contains("that's"))
    }

    func testTimesAndPercent() {
        let output = TextCleanupService.basicFormat("meet at 3pm for 50 percent", language: .english)
        XCTAssertTrue(output.contains("3 PM"))
        XCTAssertTrue(output.contains("50%"))
    }

    func testSpacedPercentSignIsGlued() {
        let output = TextCleanupService.polishPostPass("the chance is 50 % tomorrow")
        XCTAssertTrue(output.contains("50%"), output)
        XCTAssertFalse(output.contains("50 %"), output)
    }

    func testNarrowSpacedPercentSignIsGlued() {
        let output = TextCleanupService.polishPostPass("discount of 12.5\u{00A0}%")
        XCTAssertTrue(output.contains("12.5%"), output)
        XCTAssertFalse(output.contains("12.5 %"), output)
    }

    func testSpokenFiftyPercent() {
        let output = SpokenNumberFormatter.rewrite("about fifty percent chance")
        XCTAssertTrue(output.contains("50%"), output)
        XCTAssertFalse(output.lowercased().contains("fifty percent"), output)
    }

    func testRussianSpokenPercent() {
        let output = SpokenNumberFormatter.rewrite("скидка пятьдесят процентов")
        XCTAssertTrue(output.contains("50%"), output)
        XCTAssertFalse(output.contains("процент"), output)
    }

    func testRegularModeKeepsAmbiguousLike() {
        let output = TextCleanupService.basicFormat(
            "um so like I need to schedule a meeting",
            language: .english
        )
        XCTAssertTrue(output.lowercased().contains("like"))
        XCTAssertFalse(output.lowercased().contains("um"))
    }

    func testDetectsEnglish() {
        let detected = TextCleanupService.detectLanguage(from: "I need to schedule a meeting for next Tuesday")
        XCTAssertEqual(detected.code, "en")
        XCTAssertEqual(detected.cleanupLanguage, .english)
    }

    func testDetectsRussian() {
        let detected = TextCleanupService.detectLanguage(from: "Я хотел сказать что встреча завтра в офисе")
        XCTAssertEqual(detected.cleanupLanguage, .russian)
        XCTAssertTrue(["ru", "uk", "bg"].contains(detected.code))
    }

    func testDetectsMixedEnglishAndRussian() {
        let detected = TextCleanupService.detectLanguage(from: "Let's meet завтра в офисе after lunch")
        XCTAssertEqual(detected.code, "mixed")
        XCTAssertEqual(detected.cleanupLanguage, .mixed)
    }

    func testFiveThousandDollarsBecomesCurrency() {
        let output = TextCleanupService.basicFormat("i need five thousand dollars", language: .english)
        XCTAssertTrue(output.contains("$5,000") || output.contains("$5000"), output)
        XCTAssertFalse(output.lowercased().contains("five thousand dollars"))
    }

    func testTwentyThreeStaysAsDigits() {
        let output = SpokenNumberFormatter.rewrite("there are twenty three people")
        XCTAssertTrue(output.contains("23"), output)
    }

    func testLoneOneIsNotRewritten() {
        let output = SpokenNumberFormatter.rewrite("one of us should go")
        XCTAssertTrue(output.lowercased().contains("one of us"), output)
    }

    func testOneAndIsNotANumber() {
        let output = SpokenNumberFormatter.rewrite("I want one and that's it")
        XCTAssertTrue(output.lowercased().contains("one and"), output)
        XCTAssertFalse(output.contains(" 1 "), output)
    }

    func testLoneDigitOneBecomesWord() {
        let output = TextCleanupService.restoreSmallCardinals("this is the 1 thing I meant")
        XCTAssertTrue(output.contains("the one thing"), output)
    }

    func testStripsUnknownModelTokens() {
        let input = "книгу Федора Достоевского под названием <unk>Идиот<unk>."
        let output = TextCleanupService.basicFormat(input, language: .russian)
        XCTAssertFalse(output.contains("unk"), output)
        XCTAssertTrue(output.contains("Идиот"), output)
    }

    func testRejectsDroppedLastSentence() {
        let input = "I need to send the file today. Please also book the room."
        let cut = "I need to send the file today."
        XCTAssertFalse(TextCleanupService.preservesEnding(cut, of: input))
        XCTAssertTrue(TextCleanupService.preservesEnding(input, of: input))
    }

    func testMeasuredDigitStays() {
        let output = TextCleanupService.restoreSmallCardinals("call me in 5 minutes about chapter 1")
        XCTAssertTrue(output.contains("5 minutes"), output)
        XCTAssertTrue(output.contains("chapter 1"), output)
    }

    func testRussianFiveThousandDollars() {
        let output = SpokenNumberFormatter.rewrite("мне нужно пять тысяч долларов")
        XCTAssertTrue(output.contains("$5,000") || output.contains("$5000"), output)
    }

    func testFiveDollarsAndFiftyCents() {
        let output = SpokenNumberFormatter.rewrite("it costs five dollars and fifty cents")
        XCTAssertTrue(output.contains("$5.50"), output)
    }
}
