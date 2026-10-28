// Checks the facts and instructions that local grammar editing must preserve.
// Fixtures distinguish explicit spoken repairs from deliberate comparisons and apologies.
import XCTest
@testable import VoiceTypeCore

final class PolishValidatorTests: XCTestCase {
    func testGrammarAndExplicitCorrectionsAreAccepted() {
        let input = "Send the proposal to Microsoft on Tuesday, sorry, Thursday. The budget is $1,500, no, $1,400. Me and Sarah was reviewing it, and we thinks it's ready. Did Adobe approved the design yet?"
        let output = "Send the proposal to Microsoft on Thursday. The budget is $1,400. Sarah and I were reviewing it, and we think it's ready. Did Adobe approve the design yet?"
        XCTAssertNil(PolishValidator.rejection(input: input, output: output))
    }

    func testMissingOpeningInstructionIsRejected() {
        let input = "Send the proposal to Microsoft on Thursday. The budget is $1,400. Sarah and I were reviewing it, and we think it's ready. Did Adobe approve the design yet?"
        let output = String(input.dropFirst(5))
        XCTAssertEqual(PolishValidator.rejection(input: input, output: output), .beginningLost)
    }

    func testShortGrammarAndTailCorrectionAreAccepted() {
        XCTAssertNil(PolishValidator.rejection(input: "Me and Sarah was reviewing it.", output: "Sarah and I were reviewing it."))
        XCTAssertNil(PolishValidator.rejection(input: "Send the proposal on Tuesday, sorry Thursday.", output: "Send the proposal on Thursday."))
    }

    func testIntentionalContrastRetainsBothValues() {
        let input = "The total should be $1,450.75, not $1,540. Don't mix those up."
        XCTAssertNil(PolishValidator.rejection(input: input, output: input))
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "$1,540", with: "$1,500")), .numbersChanged)
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "$1,540", with: "€1,540")), .numbersChanged)
        XCTAssertEqual(PolishValidator.rejection(input: input, output: "The total should be $1,450.75. Don't mix those up."), .numbersChanged)
    }

    func testCorrectedBudgetCannotKeepTheRetractedValue() {
        let input = "Send the proposal on Thursday. The budget is $1,500, no, $1,400. Please follow up tomorrow."
        let output = "Send the proposal on Thursday. The budget is $1,500. Please follow up tomorrow."
        XCTAssertEqual(PolishValidator.rejection(input: input, output: output), .numbersChanged)
    }

    func testCorrectionDoesNotEraseAnUnrelatedUseOfTheSameAmount() {
        let input = "The invoice is $1500. The budget is $1500, no, $1400. Please send both documents."
        let output = "The invoice is $1,500. The budget is $1,400. Please send both documents."
        XCTAssertNil(PolishValidator.rejection(input: input, output: output))
    }

    func testConditionAndNegationCannotDisappear() {
        let input = "If Adobe has not approved the design by Thursday, do not send the proposal. Please follow up tomorrow morning."
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "not ", with: "")), .negationChanged)
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "If ", with: "Yes, ")), .conditionChanged)
        XCTAssertNil(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "do not", with: "don't")))
    }

    func testRussianCorrectionsRetainTheInstructionAndFinalValues() {
        let input = "Отправь предложение в Microsoft во вторник, нет, в четверг. Бюджет 1500, нет, 1400 долларов."
        let output = "Отправь предложение в Microsoft в четверг. Бюджет 1400 долларов."
        XCTAssertNil(PolishValidator.rejection(input: input, output: output))
        XCTAssertEqual(PolishValidator.rejection(input: input, output: output.replacingOccurrences(of: "четверг", with: "вторник")), .datesChanged)
    }

    func testApologyAndComparisonAreNotSpokenRetractions() {
        let input = "Sorry, Thursday does not work. The budget is $1400, not $1500."
        XCTAssertNil(PolishValidator.rejection(input: input, output: input))
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "Thursday", with: "Tuesday")), .datesChanged)
    }

    func testLastInstructionCannotDisappear() {
        let input = "Send the proposal to Microsoft today. Please also book the room tomorrow morning."
        XCTAssertNotNil(PolishValidator.rejection(input: input, output: "Send the proposal to Microsoft today."))
    }

    func testNamesAndFilenamesCannotBeReplaced() {
        let input = "Send the proposal to Microsoft. Sarah and I reviewed CLAUDE.md and the final design."
        XCTAssertNil(PolishValidator.rejection(input: input, output: input))
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "Sarah", with: "Alex")), .namesChanged)
        XCTAssertEqual(PolishValidator.rejection(input: input, output: input.replacingOccurrences(of: "CLAUDE.md", with: "CLAUDE.txt")), .filenamesChanged)
        let russian = "Мы с Анной уже проверили документы для Яндекса."
        XCTAssertEqual(PolishValidator.rejection(input: russian, output: russian.replacingOccurrences(of: "Анной", with: "Марией")), .namesChanged)
    }

    func testQuotationMarksMustBeBalanced() {
        XCTAssertEqual(PolishValidator.rejection(input: "Sarah said it looks great.", output: "Sarah said, \"It looks great."), .unbalancedQuotes)
        XCTAssertNil(PolishValidator.rejection(input: "Sarah said it looks great.", output: "Sarah said, \"It looks great.\""))
        XCTAssertNil(PolishValidator.rejection(input: "The board is 5\" wide.", output: "The board is 5\" wide."))
    }
}
