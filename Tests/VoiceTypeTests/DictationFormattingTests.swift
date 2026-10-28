// Verifies filenames, explicit spoken value repairs, and paste spacing independently of models.
// Ordinary prose and deliberate contrasts must remain intact.
import XCTest
@testable import VoiceTypeCore

final class DictationFormattingTests: XCTestCase {
    func testKnownFilenameAliasesAndGeneralExtensions() {
        XCTAssertEqual(DictationTerms.normalize("Open Cloud. Md. and package dot JSON."), "Open CLAUDE.md and package.json.")
        XCTAssertEqual(DictationTerms.normalize("Cloud. Md."), "CLAUDE.md")
        XCTAssertEqual(DictationTerms.normalize("Open readme dot md and main dot py."), "Open README.md and main.py.")
        XCTAssertEqual(DictationTerms.normalize("A cloud moved overhead. We use Markdown."), "A cloud moved overhead. We use Markdown.")
    }

    func testPasteSpacingAndParagraphs() {
        XCTAssertEqual(DictationInsertion.text("Done."), "Done. ")
        XCTAssertEqual(DictationInsertion.text("Done. "), "Done. ")
        XCTAssertEqual(DictationInsertion.text("First.\n\nLast?"), "First.\n\nLast? ")
        XCTAssertEqual(DictationInsertion.text("She said, \"Ready.\""), "She said, \"Ready.\" ")
        XCTAssertEqual(DictationInsertion.text("CLAUDE.md"), "CLAUDE.md")
    }

    func testExplicitValueRepairsAreResolvedWithoutErasingContrast() {
        XCTAssertEqual(SpokenCorrections.resolve("Send it on Tuesday, sorry, Thursday. Budget $1500, no, $1400."), "Send it on Thursday. Budget $1400.")
        XCTAssertEqual(SpokenCorrections.resolve("Отправь во вторник, нет, в четверг. Бюджет 1500, точнее, 1400 долларов."), "Отправь в четверг. Бюджет 1400 долларов.")
        let contrast = "The total should be $1,450.75, not $1,540. Sorry, Thursday does not work."
        XCTAssertEqual(SpokenCorrections.resolve(contrast), contrast)
        let apology = "I sent the proposal, sorry, yesterday."
        XCTAssertEqual(SpokenCorrections.resolve(apology), apology)
    }

    func testCompoundSubjectRepairRetainsTheActualPerson() {
        XCTAssertEqual(PolishedGrammar.repairCompoundSubjects("Me and Sarah was reviewing it."), "Sarah and I were reviewing it.")
        XCTAssertEqual(PolishedGrammar.repairCompoundSubjects("Me and Daniel is ready."), "Daniel and I are ready.")
        XCTAssertEqual(PolishedGrammar.repairCompoundSubjects("Him and Olivia was reviewing it."), "He and Olivia were reviewing it.")
        XCTAssertEqual(PolishedGrammar.repairCompoundSubjects("Give the file to me and Sarah."), "Give the file to me and Sarah.")
    }

    func testSpokenQuotationBoundariesBecomePunctuation() {
        XCTAssertEqual(DictationTerms.normalize("Sarah said quote it looks great end quote."), "Sarah said \"it looks great\".")
        XCTAssertEqual(DictationTerms.normalize("Она сказала открыть кавычки всё готово закрыть кавычки."), "Она сказала «всё готово».")
    }
}
