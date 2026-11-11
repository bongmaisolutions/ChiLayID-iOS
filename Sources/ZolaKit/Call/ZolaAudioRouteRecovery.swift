import Foundation
#if os(iOS) || targetEnvironment(macCatalyst)
import AVFoundation
#endif

/// CallKit's own route picker does not call our app's speaker action. Its explicit
/// override/device events take ownership until the app makes another selection.
struct ZolaSystemAudioRoutePolicy {
    private(set) var followsSystemSelection = false

    mutating func appSelectedRoute() { followsSystemSelection = false }

    mutating func observe(managed: Bool, reason: UInt, hasOutput: Bool, matchesAppSelection: Bool = false) -> Bool {
        // AVAudioSession.RouteChangeReason: newDeviceAvailable, oldDeviceUnavailable, override.
        guard managed, hasOutput, [1, 2, 4].contains(reason) else { return false }
        // Our own successful override also emits reason=override. It must not
        // disable bounded recovery if that just-requested route is lost again.
        guard !matchesAppSelection || followsSystemSelection else { return false }
        followsSystemSelection = true
        return true
    }
}

/// Bounded recovery for transient audio-route overrides. Confined to the media queue.
struct ZolaAudioRouteRecovery {
    private(set) var attempts = 0

    private var matchedSince: TimeInterval?

    mutating func reset() { attempts = 0; matchedSince = nil }

    static func canSchedule(running: Bool, systemManaged: Bool, systemActive: Bool, hasEngine: Bool) -> Bool {
        running && (systemManaged ? systemActive : hasEngine)
    }

    mutating func shouldRecover(running: Bool, routeMatches: Bool, configurationMatches: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard running else { return false }
        if routeMatches && configurationMatches {
            if matchedSince == nil { matchedSince = now }
            return false
        }
        // A transient match from our own override cannot refill the retry budget.
        // A later independent route change after at least two stable seconds can.
        if let matchedSince, now - matchedSince >= 2 { attempts = 0 }
        matchedSince = nil
        guard attempts < 3 else { return false }
        attempts += 1
        return true
    }

    #if os(iOS) || targetEnvironment(macCatalyst)
    // This engine uses RemoteIO, not Voice I/O. Chat modes change output processing
    // even when the selected speaker port and rendered PCM remain unchanged.
    static let remoteIOAudioSessionMode: AVAudioSession.Mode = .default
    #endif
}
