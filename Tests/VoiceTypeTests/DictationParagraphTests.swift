// Verifies a readable paragraph fallback without changing dictated words.
// Short prose and existing paragraph choices remain untouched.
import XCTest
@testable import VoiceTypeCore

final class DictationParagraphTests: XCTestCase {
    func testLongTextSplitsAtTopicCuesWithoutChangingWords() {
        let introduction = Array(repeating: "Please review the proposal and all supporting documents before approval.", count: 7).joined(separator: " ")
        let input = introduction + " Also, please check the design. One last thing: confirm the total."
        let output = DictationParagraphs.format(input)
        XCTAssertTrue(output.contains("\n\nAlso,"))
        XCTAssertTrue(output.contains("\n\nOne last thing:"))
        XCTAssertEqual(output.replacingOccurrences(of: "\n\n", with: " "), input)
    }

    func testShortAndAlreadyFormattedTextStayUnchanged() {
        let short = "Please check the design. Also, confirm the total."
        XCTAssertEqual(DictationParagraphs.format(short), short)
        let paragraphs = "Please check the design.\n\nConfirm the total."
        XCTAssertEqual(DictationParagraphs.format(paragraphs), paragraphs)
    }
}
