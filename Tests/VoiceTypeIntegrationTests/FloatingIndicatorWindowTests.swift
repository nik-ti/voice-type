// Verifies the recording badge uses a cross-app panel configuration.
// This catches regressions where the badge exists but stays behind the app receiving dictation.
import AppKit
import XCTest
@testable import VoiceType

@MainActor
final class FloatingIndicatorWindowTests: XCTestCase {
    func testIndicatorPanelCanAppearWithoutActivatingVoiceType() {
        let panel = AppDelegate.makeFloatingIndicatorPanel()

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
}
