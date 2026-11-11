import XCTest
@testable import ZolaKit

final class VoiceProcessingTrialTests: XCTestCase {
    func testNormalLaunchAndSimilarArgumentsDoNotEnableTrial() {
        for args in [[], ["--zolakit-aec-test=false"], ["zolakit-aec-test"]] {
            var trial = ZolaVoiceProcessingTrial(arguments: args)
            trial.selectForStartup(canRecord: true)
            XCTAssertFalse(trial.selected)
        }
    }
    func testInfoPlistCandidateFlagEnablesTrialOnlyForExactOne() {
        for value: Any? in [nil, "", "0", "true", "YES", 1] {
            var trial = ZolaVoiceProcessingTrial(arguments: [], infoValue: value)
            trial.selectForStartup(canRecord: true)
            XCTAssertFalse(trial.selected, "Info value \(String(describing: value)) must keep the default path")
        }
        var trial = ZolaVoiceProcessingTrial(arguments: [], infoValue: "1")
        trial.selectForStartup(canRecord: true)
        XCTAssertTrue(trial.selected)
        XCTAssertFalse(ZolaVoiceProcessingTrial.forCurrentProcess().requested,
                       "Test host has neither the launch flag nor the candidate Info.plist key")
    }
    func testExplicitTrialRequiresMicrophoneAndKeepsMatchingModeDuringRecovery() {
        var trial = ZolaVoiceProcessingTrial(arguments: ["app", "--zolakit-aec-test"])
        trial.selectForStartup(canRecord: false)
        XCTAssertFalse(trial.selected)
        trial.selectForStartup(canRecord: true)
        XCTAssertTrue(trial.selected)
        XCTAssertTrue(trial.requiresVoiceChatMode)
    }
    func testRejectedGraphNeverRetriesVoiceProcessingInSameCall() {
        var trial = ZolaVoiceProcessingTrial(arguments: ["--zolakit-aec-test"])
        trial.selectForStartup(canRecord: true)
        trial.reject(.start, code: -10851)
        trial.selectForStartup(canRecord: true)
        XCTAssertFalse(trial.selected)
        XCTAssertFalse(trial.requiresVoiceChatMode)
        XCTAssertEqual(trial.failure, .start)
        XCTAssertEqual(trial.errorCode, -10851)
    }
    func testStoppedVPIOFallsBackOnlyWhileSystemAudioShouldBeRunning() {
        var trial = ZolaVoiceProcessingTrial(arguments: ["--zolakit-aec-test"])
        trial.selectForStartup(canRecord: true)
        trial.observeStoppedGraph(systemManaged: true, systemActive: false, hasEngine: true, running: false)
        XCTAssertTrue(trial.selected, "Intentional CallKit deactivation is not a failed VPIO graph")
        trial.observeStoppedGraph(systemManaged: true, systemActive: true, hasEngine: true, running: false)
        XCTAssertFalse(trial.selected)
        XCTAssertEqual(trial.failure, .stopped)
    }
    func testAbsentOrRunningGraphDoesNotDisableTrial() {
        var trial = ZolaVoiceProcessingTrial(arguments: ["--zolakit-aec-test"])
        trial.selectForStartup(canRecord: true)
        trial.observeStoppedGraph(systemManaged: false, systemActive: false, hasEngine: false, running: false)
        trial.observeStoppedGraph(systemManaged: true, systemActive: true, hasEngine: true, running: true)
        XCTAssertTrue(trial.selected)
    }
    func testFormatValidatorRejectsPriorMonoInputStereoOutputAndRateMismatch() {
        XCTAssertTrue(ZolaVoiceProcessingTrial.formatsMatch(inputRate: 48000, inputChannels: 1, outputRate: 48000, outputChannels: 1))
        XCTAssertFalse(ZolaVoiceProcessingTrial.formatsMatch(inputRate: 48000, inputChannels: 1, outputRate: 48000, outputChannels: 2))
        XCTAssertFalse(ZolaVoiceProcessingTrial.formatsMatch(inputRate: 48000, inputChannels: 1, outputRate: 44100, outputChannels: 1))
        XCTAssertFalse(ZolaVoiceProcessingTrial.formatsMatch(inputRate: 0, inputChannels: 1, outputRate: 0, outputChannels: 1))
    }
}
