// Verifies explicit list structure without confusing labels with facts or ordinary prose.
// Formatting must retain every item's contents and work without an LLM.
import XCTest
@testable import VoiceTypeCore

final class DictationListTests: XCTestCase {
    func testSpokenLabelsProduceColonAndSeparateItems() {
        let input = "Here's the list of constraints. Number one, Keep the video short. Number two, Write tests first. Number three, Make the UI mobile-friendly."
        let expected = "Here's the list of constraints:\n\n1. Keep the video short.\n2. Write tests first.\n3. Make the UI mobile-friendly."
        XCTAssertEqual(DictationLists.format(input), expected)
        XCTAssertEqual(DictationLists.format(expected), expected)
        XCTAssertEqual(DictationLists.format(input.replacingOccurrences(of: "one", with: "1").replacingOccurrences(of: "two", with: "2").replacingOccurrences(of: "three", with: "3")), expected)
    }

    func testRussianMarkersAndListWithoutIntroduction() {
        XCTAssertEqual(DictationLists.format("Вот список требований. Пункт один, Сохранить договор. Пункт два, Проверить адрес."),
                       "Вот список требований:\n\n1. Сохранить договор.\n2. Проверить адрес.")
        XCTAssertEqual(DictationLists.format("Number one, Keep the quote. Number two, Call Sarah."),
                       "1. Keep the quote.\n2. Call Sarah.")
    }

    func testOrdinaryProseAndIncompleteSequencesAreUntouched() {
        let examples = [
            "My number one priority is to finish today.",
            "Here's a list of constraints. Number one, Keep the video short.",
            "Here's a list of constraints. Number one, Keep the video short. Number three, Write tests.",
            "Product number one is ready. Product number two arrives tomorrow.",
            "Here's a list of phrases: \"number one\" and \"number two\".",
        ]
        for example in examples { XCTAssertEqual(DictationLists.format(example), example) }
    }

    func testNumberedLayoutDoesNotChangeTheProtectedAmounts() {
        let input = "Here's the list of payments. Number one, Send $1,400 to Sarah. Number two, Keep $250 for Adobe."
        let output = "Here's the list of payments:\n\n1. Send $1,400 to Sarah.\n2. Keep $250 for Adobe."
        XCTAssertNil(PolishValidator.rejection(input: input, output: output))
        XCTAssertNotNil(PolishValidator.rejection(input: input, output: output.replacingOccurrences(of: "$1,400", with: "$1,500")))
    }

    func testDroppedAndReorderedItemsAreRejected() {
        let input = "Here are the constraints. Number 1, Keep the video under 10 seconds. Number 2, Run tests before release. Number 3, Make the UI mobile-friendly."
        let dropped = "Here are the constraints:\n\n1. Keep the video under 10 seconds.\n2. Run tests before release."
        let reordered = "Here are the constraints:\n\n1. Run tests before release.\n2. Keep the video under 10 seconds.\n3. Make the UI mobile-friendly."
        XCTAssertEqual(PolishValidator.rejection(input: input, output: dropped), .listItemsChanged)
        XCTAssertEqual(PolishValidator.rejection(input: input, output: reordered), .listItemsChanged)
    }

    func testPunctuationInsideAnItemMayBeCorrected() {
        let input = "Here's the list of constraints. Number one, Keep the video short. Number two, The UI must be mobile friendly."
        let edited = DictationLists.format(input).replacingOccurrences(of: "mobile friendly", with: "mobile-friendly")
        XCTAssertNil(PolishValidator.rejection(input: input, output: edited))
    }
}
