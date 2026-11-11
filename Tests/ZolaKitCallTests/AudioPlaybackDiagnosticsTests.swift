import XCTest
@testable import ZolaKit

final class AudioPlaybackDiagnosticsTests: XCTestCase {
    func testOldPlayerCallbacksCannotConsumeReplacementQueue() {
        var diag = ZolaAudioPlaybackDiagnostics()
        let old = diag.didSchedule(peak: 200)
        diag.resetPlayer()
        let current = diag.didSchedule(peak: 0)
        diag.completed(generation: old, playerRunning: true)
        XCTAssertEqual(diag.queued, 1)
        XCTAssertEqual(diag.playedCallbacks, 0)
        diag.completed(generation: current, playerRunning: true)
        XCTAssertEqual(diag.queued, 0)
        XCTAssertEqual(diag.playedCallbacks, 1)
        XCTAssertEqual(diag.nonzeroBuffers, 1)
        XCTAssertEqual(diag.peak, 200)
    }

    func testStoppedPlayerCompletionIsNotReportedAsPlayback() {
        var diag = ZolaAudioPlaybackDiagnostics()
        let generation = diag.didSchedule(peak: 123)
        diag.completed(generation: generation, playerRunning: false)
        XCTAssertEqual(diag.playedCallbacks, 0)
        XCTAssertEqual(diag.cancelledCallbacks, 1)
        XCTAssertEqual(diag.queued, 0)
    }

    func testOnlyStoppedPlayerInActiveEngineCanResume() {
        XCTAssertTrue(ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: true,
            playerRunning: false, systemManaged: true, systemActive: true))
        XCTAssertFalse(ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: true,
            playerRunning: false, systemManaged: true, systemActive: false))
        XCTAssertFalse(ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: false,
            playerRunning: false, systemManaged: true, systemActive: true))
        XCTAssertFalse(ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: true,
            playerRunning: true, systemManaged: true, systemActive: true))
        XCTAssertTrue(ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: true,
            playerRunning: false, systemManaged: false, systemActive: false))
    }
}
