// Regression checks for session ordering, bounded optional work, and safe delivery.
// These tests use delayed workers instead of loading speech models or touching the microphone.
import XCTest
@testable import VoiceTypeCore

final class ReliabilityTests: XCTestCase {
    func testRussianNumbersStayRussian() {
        XCTAssertEqual(TextCleanupService.basicFormat("Я купил 5 яблок", language: .russian), "Я купил 5 яблок.")
    }

    func testLegitimateWordsAndAgreementSurvive() {
        XCTAssertEqual(TextCleanupService.basicFormat("I feel ill today", language: .english), "I feel ill today.")
        XCTAssertEqual(TextCleanupService.basicFormat("uh-huh I agree", language: .english), "Uh-huh I agree.")
        XCTAssertEqual(TextCleanupService.basicFormat("We had had enough", language: .english), "We had had enough.")
    }

    func testEarlyReleaseCannotBecomeRecordingLater() {
        var session = DictationSession()
        let id = session.begin()!
        XCTAssertEqual(session.requestStop(), .cancelStartup)
        XCTAssertFalse(session.didStart(id))
        XCTAssertNil(session.begin(), "Must wait for startup cleanup")
        session.finish(id)
        XCTAssertNotNil(session.begin())
    }

    func testProcessingCannotOverlapAndOldCompletionCannotResetNewSession() {
        var session = DictationSession()
        let first = session.begin()!
        XCTAssertTrue(session.didStart(first))
        XCTAssertEqual(session.requestStop(), .transcribe)
        XCTAssertNil(session.begin())
        session.finish(first)
        let next = session.begin()!
        session.finish(first)
        XCTAssertTrue(session.didStart(next))
    }

    @MainActor
    func testDeadlineReturnsBeforeUncooperativeWorkAndKeepsGateClosed() async {
        let worker = DeadlineWorker<String>()
        let clock = ContinuousClock()
        let start = clock.now
        let result = await worker.run(timeout: .milliseconds(30)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    continuation.resume(returning: "late")
                }
            }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(200))
        XCTAssertTrue(worker.isBusy)
        let overlapping = await worker.run(timeout: .seconds(1)) { "must not run" }
        XCTAssertNil(overlapping)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(worker.isBusy)
        let next = await worker.run(timeout: .seconds(1)) { "next" }
        XCTAssertEqual(next, "next")
    }

    @MainActor
    func testCancellationReturnsWithoutAcceptingLateResult() async {
        let worker = DeadlineWorker<String>()
        let task = Task { await worker.run(timeout: .seconds(5)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    continuation.resume(returning: "late")
                }
            }
        } }
        await Task.yield()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(worker.isBusy)
    }

    func testPasteRequiresPermissionFocusAndClipboardOwnership() {
        XCTAssertFalse(PastePolicy.canPost(hasPermission: false, targetIsFrontmost: true, clipboardUnchanged: true))
        XCTAssertFalse(PastePolicy.canPost(hasPermission: true, targetIsFrontmost: false, clipboardUnchanged: true))
        XCTAssertFalse(PastePolicy.canPost(hasPermission: true, targetIsFrontmost: true, clipboardUnchanged: false))
        XCTAssertTrue(PastePolicy.canPost(hasPermission: true, targetIsFrontmost: true, clipboardUnchanged: true))
    }
}
