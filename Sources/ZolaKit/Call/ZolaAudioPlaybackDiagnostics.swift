import Foundation

/// Queue-confined numeric diagnostics, with no retained audio or peer identity.
struct ZolaAudioPlaybackDiagnostics {
    var decodeAttempts = 0
    var decodeFailures = 0
    var lastPayloadType: UInt8 = 0
    var decoderError: Int32 = 0
    var scheduled = 0
    var playedCallbacks = 0
    var cancelledCallbacks = 0
    var unavailableDrops = 0
    var queueDrops = 0
    var bufferDrops = 0
    var playerRestarts = 0
    var engineStarts = 0
    var engineStoppedAtStart = 0
    var engineConfigurationChanges = 0
    var nonzeroBuffers = 0
    var peak = 0
    private(set) var queued = 0
    private(set) var generation: UInt64 = 0

    mutating func resetPlayer() { generation &+= 1; queued = 0 }
    mutating func didSchedule(peak: Int) -> UInt64 {
        scheduled += 1; queued += 1
        self.peak = max(self.peak, peak)
        if peak > 0 { nonzeroBuffers += 1 }
        return generation
    }
    mutating func completed(generation: UInt64, playerRunning: Bool) {
        guard generation == self.generation else { return }
        queued = max(0, queued - 1)
        if playerRunning { playedCallbacks += 1 } else { cancelledCallbacks += 1 }
    }
    static func shouldResumePlayer(engineRunning: Bool, playerRunning: Bool,
        systemManaged: Bool, systemActive: Bool) -> Bool {
        engineRunning && !playerRunning && (!systemManaged || systemActive)
    }
    var line: String {
        "audio-rx=\(decodeAttempts) audio-decode-fail=\(decodeFailures) audio-pt=\(lastPayloadType) audio-decode-error=\(decoderError)"
            + " play-scheduled=\(scheduled) play-callback=\(playedCallbacks) play-cancelled=\(cancelledCallbacks) play-queued=\(queued)"
            + " play-drop=\(unavailableDrops)/\(queueDrops)/\(bufferDrops) play-resume=\(playerRestarts)"
            + " engine-starts=\(engineStarts) engine-start-stopped=\(engineStoppedAtStart) engine-config=\(engineConfigurationChanges)"
            + " play-nonzero=\(nonzeroBuffers) play-peak=\(peak)"
    }
}
