// Checks the boundary between recognized number words and written durations.
// A duration must not turn into a different number or an ordinal video position.
import XCTest
import FluidAudio
@testable import VoiceType

final class DurationNormalizationTests: XCTestCase {
    func testTenSecondVideoStaysADuration() {
        let result = TranscriptNormalizer.normalize("Make a ten second video.")
        print("DURATION_NORMALIZER input=Make a ten second video. output=\(result)")
        XCTAssertFalse(result.lowercased().contains("12th"), result)
        XCTAssertTrue(result.lowercased().contains("second"), result)
        XCTAssertTrue(result.contains("10-second"), result)
    }

    func testWrittenDurationAndGenuineOrdinals() {
        let cases = [
            ("Make a 10 second video.", "10-second"),
            ("Make a ten-second video.", "10-second"),
            ("Make a fifteen second clip.", "15-second"),
            ("Ten second videos are useful.", "10-second"),
            ("Make a twenty five second video.", "25-second"),
            ("Wait twenty seconds before starting.", "20 seconds"),
            ("Make a 2.5 second clip.", "2.5-second"),
            ("Set a ten minute timer.", "10-minute"),
            ("Play the twelfth video.", "12th"),
            ("Play the second video.", "2nd"),
            ("Play the twenty second video.", "22nd"),
        ]
        for (input, expected) in cases {
            let result = TranscriptNormalizer.normalize(input)
            XCTAssertTrue(result.contains(expected), "\(input) became \(result)")
        }
    }

    func testUnrelatedNormalizationAndExistingPrivateCharactersStayIntact() {
        for input in ["The total is fifteen hundred dollars.", "Meet on March twenty second.", "Отправь видео через десять секунд."] {
            XCTAssertEqual(TranscriptNormalizer.normalize(input), TextNormalizer.shared.normalizeSentence(input))
        }
        let result = TranscriptNormalizer.normalize("Keep \u{E000} and \u{F0000} and make a ten second video during the trial period before Monday.")
        XCTAssertTrue(result.contains("\u{E000}"), result)
        XCTAssertTrue(result.contains("\u{F0000}"), result)
        XCTAssertTrue(result.contains("10-second"), result)
        XCTAssertTrue(result.contains("trial period"), result)
    }
}
