// Checks the trailing space added when finished text is pasted, so the next dictation does not run into it.
import XCTest
import VoiceTypeCore

final class DictationInsertionTests: XCTestCase {
    func testPasteSpacing() {
        XCTAssertEqual(DictationInsertion.text("Done."), "Done. ")
        XCTAssertEqual(DictationInsertion.text("Done. "), "Done. ")
        XCTAssertEqual(DictationInsertion.text("First.\n\nLast?"), "First.\n\nLast? ")
        XCTAssertEqual(DictationInsertion.text("She said, \"Ready.\""), "She said, \"Ready.\" ")
        XCTAssertEqual(DictationInsertion.text("CLAUDE.md"), "CLAUDE.md")
    }
}
