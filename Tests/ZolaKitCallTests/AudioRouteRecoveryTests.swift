import XCTest
@testable import ZolaKit
#if os(iOS) || targetEnvironment(macCatalyst)
import AVFoundation
#endif

final class AudioRouteRecoveryTests: XCTestCase {
    func testManagedRebuildFailureRetainsBoundedRetriesWithoutEngine() {
        var recovery = ZolaAudioRouteRecovery()
        var rebuildAttempts = 0
        // Inject repeated failed starts: every attempt leaves no engine behind.
        for index in 0..<10 {
            guard ZolaAudioRouteRecovery.canSchedule(running: true, systemManaged: true,
                systemActive: true, hasEngine: false) else { XCTFail("Lost retry after failed rebuild"); return }
            if recovery.shouldRecover(running: true, routeMatches: true, configurationMatches: false,
                now: Double(index) * 0.15) { rebuildAttempts += 1 }
        }
        XCTAssertEqual(rebuildAttempts, 3)
        XCTAssertFalse(recovery.shouldRecover(running: true, routeMatches: true,
            configurationMatches: true, now: 1.6))
    }

    func testInactiveCallKitCannotScheduleRebuildEvenWithExistingEngine() {
        for hasEngine in [false, true] {
            XCTAssertFalse(ZolaAudioRouteRecovery.canSchedule(running: true, systemManaged: true,
                systemActive: false, hasEngine: hasEngine))
            XCTAssertFalse(ZolaAudioRouteRecovery.canSchedule(running: false, systemManaged: true,
                systemActive: true, hasEngine: hasEngine))
        }
        XCTAssertFalse(ZolaAudioRouteRecovery.canSchedule(running: true, systemManaged: false,
            systemActive: false, hasEngine: false))
        XCTAssertTrue(ZolaAudioRouteRecovery.canSchedule(running: true, systemManaged: false,
            systemActive: false, hasEngine: true))
    }

    func testCallKitExplicitRouteChangesTakeOwnershipUntilAppSelectsAgain() {
        var policy = ZolaSystemAudioRoutePolicy()
        XCTAssertFalse(policy.followsSystemSelection)
        for reason: UInt in [1, 2, 4] {
            XCTAssertTrue(policy.observe(managed: true, reason: reason, hasOutput: true))
            XCTAssertTrue(policy.followsSystemSelection)
            policy.appSelectedRoute()
            XCTAssertFalse(policy.followsSystemSelection)
        }
    }

    func testTransientLostRouteOrCategoryChangeDoesNotBecomeUserSelection() {
        var policy = ZolaSystemAudioRoutePolicy()
        XCTAssertFalse(policy.observe(managed: true, reason: 4, hasOutput: false))
        for reason: UInt in [0, 3, 6, 7, 8] {
            XCTAssertFalse(policy.observe(managed: true, reason: reason, hasOutput: true))
        }
        XCTAssertFalse(policy.followsSystemSelection)
    }

    func testNonCallKitRetainsExistingRouteRecoveryPolicy() {
        var policy = ZolaSystemAudioRoutePolicy()
        XCTAssertFalse(policy.observe(managed: false, reason: 4, hasOutput: true))
        XCTAssertFalse(policy.followsSystemSelection)
    }

    func testOwnSuccessfulOverrideDoesNotDisableLostRouteRecovery() {
        var policy = ZolaSystemAudioRoutePolicy()
        XCTAssertFalse(policy.observe(managed: true, reason: 4, hasOutput: true, matchesAppSelection: true))
        XCTAssertFalse(policy.followsSystemSelection)
        XCTAssertTrue(policy.observe(managed: true, reason: 4, hasOutput: true, matchesAppSelection: false))
        XCTAssertTrue(policy.followsSystemSelection)
    }

    func testRunningEngineRecoversLostSpeakerOverride() {
        var recovery = ZolaAudioRouteRecovery()
        XCTAssertTrue(recovery.shouldRecover(running: true, routeMatches: false, configurationMatches: true, now: 0))
        XCTAssertEqual(recovery.attempts, 1)
        XCTAssertFalse(recovery.shouldRecover(running: true, routeMatches: true, configurationMatches: true, now: 0.2))
        XCTAssertEqual(recovery.attempts, 1)
        // A later independent route change remains recoverable after stable output.
        XCTAssertTrue(recovery.shouldRecover(running: true, routeMatches: false, configurationMatches: true, now: 3))
        XCTAssertEqual(recovery.attempts, 1)
    }

    func testForeignCategoryIsRestoredEvenWhenOutputAlreadyMatches() {
        var recovery = ZolaAudioRouteRecovery()
        XCTAssertTrue(recovery.shouldRecover(running: true, routeMatches: true, configurationMatches: false))
    }

    func testSelfGeneratedNotificationsCannotRetryForever() {
        var recovery = ZolaAudioRouteRecovery()
        let decisions = (0..<20).map { _ in
            recovery.shouldRecover(running: true, routeMatches: false, configurationMatches: false)
        }
        XCTAssertEqual(decisions.filter { $0 }.count, 3)
        recovery.reset() // Explicit user selection starts a fresh bounded attempt.
        XCTAssertTrue(recovery.shouldRecover(running: true, routeMatches: false, configurationMatches: true))
        XCTAssertFalse(recovery.shouldRecover(running: false, routeMatches: false, configurationMatches: false))
    }

    func testTransientMatchesCannotRefillRecoveryBudget() {
        var recovery = ZolaAudioRouteRecovery()
        var repairs = 0
        for index in 0..<20 {
            let time = Double(index) * 0.3
            if recovery.shouldRecover(running: true, routeMatches: false, configurationMatches: true, now: time) {
                repairs += 1
            }
            XCTAssertFalse(recovery.shouldRecover(running: true, routeMatches: true, configurationMatches: true, now: time + 0.15))
        }
        XCTAssertEqual(repairs, 3)
    }

    #if os(iOS) || targetEnvironment(macCatalyst)
    func testRemoteIOCategoryConfigurationPreservesDefaultModeAndHFP() throws {
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        defer { try? session.setCategory(previous.0, mode: previous.1, options: previous.2) }
        // Exercise the real platform category API, without activation, capture or calls.
        // Both receiver/system-managed and app-speaker option sets must keep default mode.
        let configurations: [AVAudioSession.CategoryOptions] = [
            [.allowBluetoothHFP], [.allowBluetoothHFP, .defaultToSpeaker]
        ]
        for options in configurations {
            try session.setCategory(.playAndRecord,
                mode: ZolaAudioRouteRecovery.remoteIOAudioSessionMode, options: options)
            XCTAssertEqual(session.mode, .default)
            XCTAssertEqual(session.category, .playAndRecord)
            XCTAssertTrue(session.categoryOptions.contains(.allowBluetoothHFP))
            XCTAssertEqual(session.categoryOptions.contains(.defaultToSpeaker), options.contains(.defaultToSpeaker))
        }
    }
    #endif
}
