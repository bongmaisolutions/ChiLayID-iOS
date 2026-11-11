import Foundation

/// Explicit, per-process diagnostic trial. Failure is sticky for this call; ordinary launches
/// retain the accepted RemoteIO graph. Never enables voice processing on an active graph.
struct ZolaVoiceProcessingTrial {
    enum Failure: String { case none, enable, format, start, stopped }
    let requested: Bool
    private(set) var selected = false
    private(set) var failure: Failure = .none
    private(set) var errorCode = 0
    var requiresVoiceChatMode: Bool { selected }
    /// `infoValue` is the app's `ZolaKitAECTrial` Info.plist value, set from the `ZOLAKIT_AEC_TRIAL`
    /// build setting of your app. Set it to "1" to enable voice processing (AEC); anything else keeps the RemoteIO graph.
    /// This survives PushKit/CallKit relaunches, which drop launch arguments.
    init(arguments: [String], infoValue: Any? = nil) {
        requested = arguments.contains("--zolakit-aec-test") || (infoValue as? String) == "1"
    }
    static func forCurrentProcess() -> ZolaVoiceProcessingTrial {
        ZolaVoiceProcessingTrial(arguments: ProcessInfo.processInfo.arguments,
                                 infoValue: Bundle.main.object(forInfoDictionaryKey: "ZolaKitAECTrial"))
    }
    mutating func selectForStartup(canRecord: Bool) {
        selected = requested && canRecord && failure == .none
    }
    mutating func reject(_ reason: Failure, code: Int = 0) {
        selected = false
        if failure == .none { failure = reason; errorCode = code }
    }
    mutating func observeStoppedGraph(systemManaged: Bool, systemActive: Bool, hasEngine: Bool, running: Bool) {
        if selected && hasEngine && !running && (!systemManaged || systemActive) { reject(.stopped) }
    }
    static func formatsMatch(inputRate: Double, inputChannels: UInt32, outputRate: Double, outputChannels: UInt32) -> Bool {
        inputRate.isFinite && inputRate > 0 && inputChannels > 0
            && inputRate == outputRate && inputChannels == outputChannels
    }
}

/// Fixed-size, queue-confined capture diagnostics. Values are enums/counts/codes only;
/// never retain audio, error descriptions, routes, account IDs or device identifiers.
struct ZolaAudioCaptureDiagnostics {
    enum Authorization: String { case unchecked, granted, denied, undetermined, restricted, unknown }
    enum Path: String { case idle, starting, duplex, playbackOnly, failed }
    enum Stage: String {
        case none, permission, inputFormat, duplexStart, playbackFormat, playbackStart
        case encoderCreate, encoderFill, encoderNoOutput, encoderOutputBounds
    }
    struct Failure {
        var stage: Stage = .none
        var code: Int = 0
        var text: String { "\(stage.rawValue):\(code)" }
    }
    private(set) var authorization: Authorization = .unchecked
    private(set) var path: Path = .idle
    private(set) var fallback = Failure()
    private(set) var startupFailure = Failure()
    private(set) var encoderFailure = Failure()
    var captureBuffers = 0
    var captureIgnored = 0
    private(set) var convertedBuffers = 0
    private(set) var convertedBytes = 0
    private(set) var conversionFailures = 0
    var encodedPackets = 0
    private(set) var encodingFailures = 0

    mutating func beginStartup(authorization: Authorization) {
        self.authorization = authorization
        path = .starting
        fallback = Failure()
        startupFailure = Failure()
    }
    mutating func recordFallback(_ stage: Stage, code: Int = 0) {
        fallback = Failure(stage: stage, code: code)
    }
    mutating func started(_ path: Path) { self.path = path }
    mutating func failedStartup(_ stage: Stage, code: Int = 0) {
        path = .failed
        startupFailure = Failure(stage: stage, code: code)
    }
    mutating func converted(byteCount: Int?) {
        guard let byteCount else { conversionFailures += 1; return }
        convertedBuffers += 1
        convertedBytes += byteCount
    }
    mutating func failedEncoding(_ stage: Stage, code: Int = 0) {
        encodingFailures += 1
        encoderFailure = Failure(stage: stage, code: code)
    }
    var line: String {
        "mic-auth=\(authorization.rawValue) audio-path=\(path.rawValue)"
            + " audio-fallback=\(fallback.text) audio-start-error=\(startupFailure.text)"
            + " capture=\(captureBuffers) capture-ignored=\(captureIgnored)"
            + " pcm=\(convertedBuffers)/\(convertedBytes) pcm-fail=\(conversionFailures)"
            + " encoded=\(encodedPackets) encode-fail=\(encodingFailures) encode-error=\(encoderFailure.text)"
    }
}
#if canImport(CoreVideo) && canImport(CoreMedia)
import CoreVideo
import CoreMedia
#endif

#if canImport(Network) && canImport(AVFoundation) && canImport(AudioToolbox)
import Network
import AVFoundation
import AudioToolbox
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Bidirectional VoIP audio engine for Zalo `0x7d0` calls (`WP-5` / `CALL-NATIVE-SPEC.md`).
///
/// - **Capture → encode → RTP**: `AVAudioEngine.inputNode` 20 ms frames, Opus 48 kHz
///   (`kAudioFormatOpus`, RTP PT `113`/`112` matching the `opus/48000/2` codec list from `mac35`),
///   graceful fallback to PCM16 LE (PT `111`) or G.711 μ-law (PT `0`) when the runtime lacks an
///   Opus `AudioConverter` encoder.
/// - **Receive → decode → play**: RTP v2 validation, PT dispatch (`113`/`112` Opus, `0` μ-law,
///   `8` A-law, `111` PCM16 LE), decoded LPCM pushed into `AVAudioPlayerNode`.
/// - **Transport**: one `NWListener` for inbound UDP (relay or P2P candidates announced in
///   `extendData`) plus per-endpoint `NWConnection`s; periodic keepalive packets keep NAT open.
///
/// `SSRC = UInt32(bitPattern: callId)` per `ZrtpVoipService`. All network/audio work is serialized
/// on `queue`; the type is `@unchecked Sendable` for use from `ZolaClient` actor methods.
public final class ZolaVoipMediaEngine: @unchecked Sendable {
    /// A UDP endpoint the engine should send RTP/RTCP toward (relay or P2P candidate).
    public struct MediaEndpoint: Sendable, Hashable {
        public let host: String
        public let port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    /// Audio payload codec carried in the RTP payload type byte.
    public enum MediaCodec: Sendable, Equatable {
        case opus // PT 113 (send) / 113|112 (receive)
        case pcm16LE // PT 111
        case pcmu // PT 0 (G.711 μ-law)
        case pcma // PT 8 (G.711 A-law)

        public var preferredPayloadType: UInt8 {
            switch self {
            case .opus: return 113
            case .pcm16LE: return 111
            case .pcmu: return 0
            case .pcma: return 8
            }
        }
    }

    public private(set) var callId: Int32
    /// Negotiated codec actually in use (`opus` preferred; falls back automatically).
    public private(set) var activeCodec: MediaCodec = .opus
    /// `true` while `start` succeeded and the engine is running.
    public private(set) var isRunning = false
    /// `true` when the mic is muted (capture frames are zeroed but keepalive/RTP continue).
    public private(set) var muted = false
    /// `true` when output routes to the speakerphone instead of the earpiece.
    public private(set) var speakerphone = false
    /// `true` when this media session carries 2-way H.264 video alongside Opus/G.711 audio.
    public private(set) var isVideoCall = false
    /// Negotiated H.264 RTP dynamic payload type (`97` default per `CallController.cpp` `0x1005237e8`).
    public private(set) var h264PayloadType: UInt8 = 97
    public private(set) var h264KeyframePayloadType: UInt8 = 98
    public var acceptedH264PayloadTypes: Set<UInt8> { [h264PayloadType, h264KeyframePayloadType] }
    /// Thread-safe snapshot of `isVideoCall` for `@MainActor` callers.
    public var currentIsVideoCall: Bool {
        (try? performOnQueueSync { isVideoCall }) ?? false
    }
    /// Thread-safe snapshot of `h264PayloadType` for `@MainActor` callers.
    public var currentH264PayloadType: UInt8 {
        (try? performOnQueueSync { h264PayloadType }) ?? 97
    }

    #if canImport(CoreVideo) && canImport(CoreMedia)
    public var onRemoteVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)? {
        didSet {
            let cb = onRemoteVideoPixelBuffer
            performOnQueueAsyncOrInline { [weak self] in
                guard let self else { return }
                #if canImport(VideoToolbox) && canImport(CoreGraphics)
                self.queuedOnRemoteVideoPixelBuffer = cb
                self.videoEngine?.onRemoteVideoPixelBuffer = cb
                #endif
            }
        }
    }

    public var onLocalVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)? {
        didSet {
            let cb = onLocalVideoPixelBuffer
            performOnQueueAsyncOrInline { [weak self] in
                guard let self else { return }
                #if canImport(VideoToolbox) && canImport(CoreGraphics)
                self.queuedOnLocalVideoPixelBuffer = cb
                self.videoEngine?.onLocalVideoPixelBuffer = cb
                #endif
            }
        }
    }
    #endif

    /// Fired (on `queue`) with every inbound RTP payload type seen — diagnostics for the UI layer.
    public var onRemotePayloadType: (@Sendable (UInt8) -> Void)?
    /// Fired when the remote RTP source address changes mid-call (relay → P2P migration).
    public var onRemoteEndpointChanged: (@Sendable (MediaEndpoint) -> Void)?
    #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    /// Fired whenever a remote H.264 video frame is decoded via `VideoToolbox`.
    public var onRemoteVideoFrame: (@Sendable (CGImage) -> Void)? {
        didSet {
            let cb = onRemoteVideoFrame
            performOnQueueAsyncOrInline { [weak self] in
                guard let self else { return }
                self.queuedOnRemoteVideoFrame = cb
                self.videoEngine?.onRemoteVideoFrame = cb
            }
        }
    }
    /// Fired whenever a local camera preview frame is captured (`nil` when local camera is turned off).
    public var onLocalVideoFrame: (@Sendable (CGImage?) -> Void)? {
        didSet {
            let cb = onLocalVideoFrame
            performOnQueueAsyncOrInline { [weak self] in
                guard let self else { return }
                self.queuedOnLocalVideoFrame = cb
                self.videoEngine?.onLocalVideoFrame = cb
            }
        }
    }
    #endif
    /// Enables `0x7f` ZRTC relay framing + `initZRTPToServer` even when `relay` is `127.0.0.1` (for loopback unit tests).
    public var forceZrtcFramingOnLoopback = false
    /// Total number of deduplicated inbound RTP/ZRTC audio frames decoded by this engine.
    public private(set) var decodedFrameCount: Int = 0

    private static let queueKey = DispatchSpecificKey<Void>()
    private let queue = DispatchQueue(label: "com.zolakit.voip.media")
    private var udpListener: NWListener?
    private var remoteConnections: [NWEndpoint: NWConnection] = [:]
    private var inboundConnections: [NWEndpoint: NWConnection] = [:]
    private var localUdpPort: UInt16 = 0
    private var keepaliveTimer: DispatchSourceTimer?

    private var systemAudioSessionManaged = false
    private var systemAudioSessionActive = false
    private var engine: AVAudioEngine?
    private var voiceProcessingTrial = ZolaVoiceProcessingTrial.forCurrentProcess()
    private var voiceTrialInputRate: Double = 0
    private var voiceTrialOutputRate: Double = 0
    private var voiceTrialInputChannels: UInt32 = 0
    private var voiceTrialOutputChannels: UInt32 = 0
    private var playerNode: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var configChangeObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var routeRecovery = ZolaAudioRouteRecovery()
    private var systemRoutePolicy = ZolaSystemAudioRoutePolicy()
    private var lastRouteChangeReason: UInt = 0
    private var routeRecoveryGeneration: UInt64 = 0
    private var routeRecoveryPending = false
    private var routeErrorStage = "none"
    private var routeErrorCode = 0
    private var isFullDuplexAudioActive = false
    private var audioPlaybackDiag = ZolaAudioPlaybackDiagnostics()
    private var recentInboundRtpKeys: [UInt64] = []
    private var recentInboundRtpCursor: Int = 0

    // Opus converters (created lazily; `nil` ⇒ codec fallback engaged).
    private var opusEncodeConverter: AudioConverterRef?
    private var opusDecodeConverter: AudioConverterRef?

    // RTP + ZRTC relay state.
    private let ssrc: UInt32
    private var sequenceNumber: UInt16 = UInt16.random(in: 0...UInt16.max)
    private var rtpTimestamp: UInt32 = UInt32.random(in: 0...UInt32.max)
    /// 20 ms per RTP tick at 48 kHz.
    private static let rtpTimestampStep: UInt32 = 960
    /// Last remote endpoint reported to `onRemoteEndpointChanged` (dedup per datagram).
    private var lastReportedRemoteEndpoint: MediaEndpoint?

    private var zrtcIsCaller: Bool = true
    private var zrtcSelfUid: Int64 = 0
    private var zrtcPartnerUid: Int64 = 0
    private var zrtcSessionId: String = ""
    private var primaryRelayEndpoint: NWEndpoint?
    private var transportPrepared = false
    private var relayHandshakeConfirmed = false
    private var zrtcRelayToken: UInt32 = 0
    private var zrtcSessionEpoch: UInt64 = 0
    private var zrtcInitSeqEpoch: [UInt32: UInt64] = [:]
    private var pendingPreHandshakeRtp: [Data] = []
    private var pendingPreHandshakeVideo: [(payload: Data, isRtcp: Bool)] = []
    private var droppedPreHandshakeVideo = false
    private var audioTxPackets: UInt32 = 0
    private var audioTxOctets: UInt32 = 0
    private var lastAudioTxRtpTimestamp: UInt32 = 0
    private var speakerphoneExplicitlySet = false
    private var desiredCameraEnabled = true
    #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    private var videoEngine: ZolaVoipVideoEngine?
    private var audioRxStats = ZolaRtpReceiverStatsTracker(clockRateHz: 48_000)
    private var queuedOnRemoteVideoFrame: (@Sendable (CGImage) -> Void)?
    private var queuedOnLocalVideoFrame: (@Sendable (CGImage?) -> Void)?
    private var queuedOnRemoteVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    private var queuedOnLocalVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    #endif
    private var reflectedPublicEndpointStorage: String = ""
    private var relayHandshakeWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var zrtcInitSeq: UInt32 = 0
    private var zrtcPingSeq: UInt32 = 0
    private var zrtcInitTimer: DispatchSourceTimer?
    /// Counters for the in-app call log (`diagnosticsSnapshot`); queue-confined, never hold keys or tokens.
    private var diag = CallDiagnostics()
    private var audioCaptureDiag = ZolaAudioCaptureDiagnostics()

    private struct CallDiagnostics {
        var initSent = 0
        var initAckOk = 0
        var audioSent = 0
        var videoSent = 0
        var audioHeld = 0
        var videoHeld = 0
        var audioRtcpSent = 0
        var audioRtcpRecv = 0
        var droppedNoConnection = 0
        var inboundByType: [UInt8: Int] = [:]
    }

    // PCM scratch buffers for encode/decode.
    private var pcmSendBuffer = Data()
    private var pcmSendLock = NSLock()

    public init(callId: Int32) {
        self.callId = callId
        self.ssrc = UInt32(bitPattern: callId)
        self.queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        // `stop()` must be called before release; deinit is a safety net for converter cleanup.
        zrtcInitTimer?.cancel()
        keepaliveTimer?.cancel()
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver { NotificationCenter.default.removeObserver(obs) }
        if let c = opusEncodeConverter { AudioConverterDispose(c) }
        if let c = opusDecodeConverter { AudioConverterDispose(c) }
    }

    // MARK: - Lifecycle

    private func resetRelayHandshakeStateOnQueue() {
        zrtcSessionEpoch &+= 1
        relayHandshakeConfirmed = false
        zrtcRelayToken = 0
        zrtcInitSeqEpoch.removeAll(keepingCapacity: true)
        pendingPreHandshakeRtp.removeAll(keepingCapacity: true)
        pendingPreHandshakeVideo.removeAll(keepingCapacity: true)
        droppedPreHandshakeVideo = false
    }

    /// Configures `libzrtc` relay session credentials (`initZRTPToServer` `pktCmd = 11|12`, `0x03`/`0x04` 1-1 relay framing).
    /// Leave `sessionId` empty in pure-RTP loopback unit tests.
    public func configureZrtcSession(
        isCaller: Bool,
        selfUid: Int64,
        partnerUid: Int64,
        sessionId: String
    ) {
        try? performOnQueueSync {
            let roleChanged = (self.zrtcIsCaller != isCaller)
            self.zrtcIsCaller = isCaller
            if selfUid != 0 { self.zrtcSelfUid = selfUid }
            if partnerUid != 0 { self.zrtcPartnerUid = partnerUid }
            let cleanSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            let newlyConfiguredSession = self.zrtcSessionId.isEmpty && !cleanSession.isEmpty
            let sessionChanged = !cleanSession.isEmpty && !self.zrtcSessionId.isEmpty && cleanSession != self.zrtcSessionId
            if !cleanSession.isEmpty {
                self.zrtcSessionId = cleanSession
            }
            if roleChanged || sessionChanged || newlyConfiguredSession {
                self.resetRelayHandshakeStateOnQueue()
                if self.transportPrepared || self.isRunning {
                    self.startZrtcHandshakeOnQueue()
                }
            }
        }
    }

    /// Pre-binds the UDP socket and begins `libzrtc` `initZRTPToServer` (`pktCmd = 11|12`) + `pktCmd = 3`
    /// relay keepalives immediately during call setup / ringing (`mac35 [1141]`), BEFORE starting
    /// `AVAudioEngine` mic/playback. Calling `start(...)` afterwards reuses the exact same UDP socket!
    public func prepareTransport(
        relay: MediaEndpoint,
        p2pEndpoints: [MediaEndpoint] = [],
        preferredLocalPort: UInt16 = 0
    ) throws {
        try performOnQueueSync {
            try self.prepareTransportOnQueue(
                relay: relay,
                p2pEndpoints: p2pEndpoints,
                preferredLocalPort: preferredLocalPort
            )
        }
    }

    /// `true` once the primary ZRTC relay (`:4200`) has acknowledged `initZRTPToServer` (`0x02`, `retCode == 0`).
    public var isRelayHandshakeConfirmed: Bool {
        (try? performOnQueueSync { relayHandshakeConfirmed }) ?? false
    }

    /// 4-byte `CallToken` returned by the ZRTC `:4200` relay inside its `0x02` `InitZRTP` response (`u32LE @ 29..32`).
    public var relayToken: UInt32 {
        (try? performOnQueueSync { zrtcRelayToken }) ?? 0
    }

    /// Currently configured primary ZRTC relay endpoint, if any.
    public var currentRelayEndpoint: MediaEndpoint? {
        try? performOnQueueSync {
            guard let ep = primaryRelayEndpoint, case let .hostPort(host, port) = ep else { return nil }
            return MediaEndpoint(host: "\(host)", port: port.rawValue)
        }
    }

    /// STUN-reflected public `<ip>:<port>` returned by the ZRTC `:4200` relay inside its `0x02` `InitZRTP` response (`u16LE @ 33`, ASCII `@ 35`).
    public var reflectedPublicEndpoint: String {
        (try? performOnQueueSync { reflectedPublicEndpointStorage }) ?? ""
    }

    /// Waits asynchronously (up to `timeoutMs`, best-effort) for the ZRTC `:4200` relay to acknowledge
    /// `initZRTPToServer` (`0x02`, `retCode == 0`) so `cmd = 416` is transmitted only after caller UDP registration.
    public func waitForRelayHandshake(timeoutMs: Int = 800) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: false)
                    return
                }
                if self.relayHandshakeConfirmed {
                    cont.resume(returning: true)
                    return
                }
                guard timeoutMs > 0,
                      (self.transportPrepared || self.isRunning),
                      let relayEp = self.primaryRelayEndpoint,
                      self.shouldUseZrtcRelay(for: relayEp)
                else {
                    cont.resume(returning: false)
                    return
                }
                let waiterId = UUID()
                self.relayHandshakeWaiters[waiterId] = cont
                self.queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
                    guard let self else { return }
                    if let pending = self.relayHandshakeWaiters.removeValue(forKey: waiterId) {
                        pending.resume(returning: self.relayHandshakeConfirmed)
                    }
                }
            }
        }
    }

    private func resolveRelayHandshakeWaitersOnQueue(confirmed: Bool) {
        guard !relayHandshakeWaiters.isEmpty else { return }
        let pending = relayHandshakeWaiters
        relayHandshakeWaiters.removeAll()
        for (_, cont) in pending {
            cont.resume(returning: confirmed)
        }
    }

    /// Starts the engine: ensures UDP + ZRTC relay transport is bound, arms keepalive packets, and begins
    /// capture/playback. Throws `ZolaError.transport` when UDP or audio cannot be started.
    public func start(
        relay: MediaEndpoint,
        p2pEndpoints: [MediaEndpoint] = [],
        preferredLocalPort: UInt16 = 0,
        preferredCodec: MediaCodec = .opus
    ) throws {
        try performOnQueueSync {
            guard !self.isRunning else { return }
            self.activeCodec = preferredCodec
            try self.prepareTransportOnQueue(
                relay: relay,
                p2pEndpoints: p2pEndpoints,
                preferredLocalPort: preferredLocalPort
            )
            try self.startAudioOnQueue()
            self.isRunning = true
            self.registerAudioRouteObserverOnQueue()
            self.scheduleAudioRouteRecoveryOnQueue()
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            if self.isVideoCall {
                self.ensureVideoEngineOnQueue().start(cameraEnabled: self.desiredCameraEnabled)
            }
            #endif
            if !self.zrtcSessionId.isEmpty && !self.relayHandshakeConfirmed {
                self.sendZrtcInitPacketOnQueue()
            }
        }
    }

    private func prepareTransportOnQueue(
        relay: MediaEndpoint,
        p2pEndpoints: [MediaEndpoint],
        preferredLocalPort: UInt16
    ) throws {
        if !self.transportPrepared {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            if preferredLocalPort > 0,
               let wantedPort = NWEndpoint.Port(rawValue: preferredLocalPort),
               let bound = try? NWListener(using: params, on: wantedPort)
            {
                listener = bound
            } else {
                listener = try NWListener(using: params)
            }
            listener.newConnectionHandler = { [weak self] inbound in
                self?.queue.async { self?.acceptInboundConnection(inbound) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case let .failed(err) = state {
                    self.stopOnQueue()
                    fputs("ZolaVoipMediaEngine listener failed: \(err)\n", stderr)
                }
            }
            listener.start(queue: queue)
            self.udpListener = listener
            self.localUdpPort = listener.port?.rawValue ?? preferredLocalPort
            self.transportPrepared = true
        }

        let trimmedHost = relay.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholderRelay = trimmedHost.isEmpty || trimmedHost == "49.213.95.89"
        let effectiveRelay: MediaEndpoint
        if isPlaceholderRelay,
           let existingEp = self.primaryRelayEndpoint,
           case let .hostPort(existingHost, existingPort) = existingEp
        {
            effectiveRelay = MediaEndpoint(host: "\(existingHost)", port: existingPort.rawValue)
        } else {
            effectiveRelay = relay
        }

        if let relayPort = NWEndpoint.Port(rawValue: effectiveRelay.port), !effectiveRelay.host.isEmpty {
            let newRelay = NWEndpoint.hostPort(host: NWEndpoint.Host(effectiveRelay.host), port: relayPort)
            if newRelay != self.primaryRelayEndpoint {
                self.primaryRelayEndpoint = newRelay
                self.resetRelayHandshakeStateOnQueue()
            }
        }

        var remotes = [effectiveRelay]
        let singleRelayMode: Bool = {
            guard let relayEp = self.primaryRelayEndpoint else { return false }
            return self.shouldUseZrtcRelay(for: relayEp)
        }()
        if !singleRelayMode {
            remotes.append(contentsOf: p2pEndpoints)
        }
        var seen = Set<MediaEndpoint>()
        for ep in remotes where seen.insert(ep).inserted {
            guard let port = NWEndpoint.Port(rawValue: ep.port), !ep.host.isEmpty else { continue }
            let nwEp = NWEndpoint.hostPort(host: NWEndpoint.Host(ep.host), port: port)
            if self.remoteConnections[nwEp] == nil {
                self.connectRemoteEndpoint(ep)
            }
        }

        if !self.relayHandshakeConfirmed {
            self.startZrtcHandshakeOnQueue()
        }
        self.startKeepaliveOnQueue()
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        if self.isVideoCall && !self.isRunning {
            self.ensureVideoEngineOnQueue().ensureDecoderRunning()
        }
        #endif
    }

    /// Updates the authoritative ZRTC media relay endpoint and/or `sessionId` mid-call (e.g. when `cmd = 408`
    /// answer ACK or `cmd = 403` peer answer arrives after `startTwoWayVoiceSession` already started),
    /// immediately triggering `initZRTPToServer` (`pktCmd = 11|12`) and switching outbound RTP to `0x03` 1-1 relay framing.
    public func updateRelaySession(
        relay: MediaEndpoint?,
        isCaller: Bool? = nil,
        selfUid: Int64 = 0,
        partnerUid: Int64 = 0,
        sessionId: String = ""
    ) {
        try? performOnQueueSync {
            var needsRehandshake = false
            if let isCaller, self.zrtcIsCaller != isCaller {
                self.zrtcIsCaller = isCaller
                needsRehandshake = true
            }
            if selfUid != 0 { self.zrtcSelfUid = selfUid }
            if partnerUid != 0 { self.zrtcPartnerUid = partnerUid }
            let cleanSession = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSession.isEmpty, cleanSession != self.zrtcSessionId {
                self.zrtcSessionId = cleanSession
                needsRehandshake = true
            }
            if let relay, !relay.host.isEmpty, relay.host != "49.213.95.89",
               let relayPort = NWEndpoint.Port(rawValue: relay.port), relayPort.rawValue > 0
            {
                let newRelayEp = NWEndpoint.hostPort(host: NWEndpoint.Host(relay.host), port: relayPort)
                if newRelayEp != self.primaryRelayEndpoint {
                    self.primaryRelayEndpoint = newRelayEp
                    needsRehandshake = true
                }
                if (self.isRunning || self.transportPrepared), self.remoteConnections[newRelayEp] == nil {
                    self.connectRemoteEndpoint(relay)
                }
            }
            if needsRehandshake {
                self.resetRelayHandshakeStateOnQueue()
                if self.isRunning || self.transportPrepared {
                    self.startZrtcHandshakeOnQueue()
                    self.startKeepaliveOnQueue()
                }
            }
        }
    }

    /// Injects a pre-built RTP packet onto the active outbound transport path (for deterministic unit tests).
    public func sendTestRtpPacket(_ rtpPacket: Data) {
        try? performOnQueueSync {
            self.sendAudioPacketOnQueue(rtpPacket)
        }
    }

    /// Dynamically adds a newly discovered peer P2P UDP endpoint mid-call (ignored when ZRTC `:4200` relay mode is active).
    public func addPeerEndpoint(_ ep: MediaEndpoint) {
        queue.async {
            guard (self.isRunning || self.transportPrepared), !ep.host.isEmpty, ep.port > 0 else { return }
            if let relayEp = self.primaryRelayEndpoint, self.shouldUseZrtcRelay(for: relayEp) {
                return
            }
            guard let port = NWEndpoint.Port(rawValue: ep.port) else { return }
            let nwEp = NWEndpoint.hostPort(host: NWEndpoint.Host(ep.host), port: port)
            guard self.remoteConnections[nwEp] == nil else { return }
            self.connectRemoteEndpoint(ep)
        }
    }

    /// Parses `<host>:<port>` (IPv4, IPv6, or hostname, stripping any trailing NUL/control bytes) into a `MediaEndpoint`.
    public static func parseEndpointString(_ raw: String) -> MediaEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty, let colonIdx = trimmed.lastIndex(of: ":") else { return nil }
        let portSub = trimmed[trimmed.index(after: colonIdx)...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard let port = UInt16(portSub), port > 0 else { return nil }
        var host = String(trimmed[..<colonIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        return MediaEndpoint(host: host, port: port)
    }

    /// Extracts all P2P / relay UDP endpoints advertised inside Zalo `cmd=401`/`cmd=402` `extendData` JSON.
    public static func parseP2PEndpoints(fromExtendData extendDataJson: String?) -> [MediaEndpoint] {
        guard let raw = extendDataJson?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }

        var results: [MediaEndpoint] = []
        var seen = Set<MediaEndpoint>()
        func appendCandidate(_ candidate: MediaEndpoint?) {
            guard let ep = candidate, !ep.host.isEmpty, ep.port > 0 else { return }
            if seen.insert(ep).inserted {
                results.append(ep)
            }
        }
        for key in ["p2pAddr", "peerP2PAddr"] {
            if let s = dict[key] as? String {
                appendCandidate(parseEndpointString(s))
            }
        }
        if let localIp = dict["localP2PIp"] as? String {
            let portVal = (dict["localP2PPort"] as? Int)
                ?? (dict["localP2PPort"] as? NSNumber)?.intValue
                ?? 0
            if portVal > 0 && portVal <= Int(UInt16.max) {
                appendCandidate(MediaEndpoint(host: localIp, port: UInt16(portVal)))
            }
        }
        if let p2pArray = dict["p2p"] as? [[String: Any]] {
            for entry in p2pArray {
                let ip = (entry["ip"] as? String) ?? (entry["host"] as? String) ?? ""
                let p = (entry["port"] as? Int) ?? (entry["port"] as? NSNumber)?.intValue ?? 0
                if !ip.isEmpty && p > 0 && p <= Int(UInt16.max) {
                    appendCandidate(MediaEndpoint(host: ip, port: UInt16(p)))
                }
            }
        } else if let p2pStrs = dict["p2p"] as? [String] {
            for s in p2pStrs {
                appendCandidate(parseEndpointString(s))
            }
        }
        return results
    }

    /// Local UDP port bound by `start` — advertised to the peer inside `extendData`/`localP2PPort`
    /// for P2P candidates.
    public var boundLocalPort: UInt16 {
        (try? performOnQueueSync { localUdpPort }) ?? 0
    }

    /// Mutes/unmutes the microphone. Muted captures are replaced with silence so RTP/keepalive
    /// timing stays intact (Zalo tracks packet cadence for NAT binding).
    public func setMuted(_ muted: Bool) {
        queue.async { self.muted = muted }
    }

    /// Routes playback to the loudspeaker (`true`) or earpiece (`false`). Applied immediately
    /// when the engine is running.
    public func setSpeakerphone(_ enabled: Bool) {
        queue.async {
            self.speakerphoneExplicitlySet = true
            self.speakerphone = enabled
            self.systemRoutePolicy.appSelectedRoute()
            self.routeRecovery.reset()
            // A prewarmed transport must not change an unrelated audio session.
            if self.isRunning {
                if self.engine?.isRunning != true { try? self.rebuildAudioEngineOnQueue() }
                self.applyAudioRouteOnQueue()
                self.scheduleAudioRouteRecoveryOnQueue()
            }
        }
    }

    /// Enables or updates 2-way H.264 video (`VideoToolbox` + RFC 6184 RTP/RTCP PLI) over the shared ZRTC UDP socket.
    /// Defaults audio output to speakerphone unless explicitly overridden via `setSpeakerphone`.
    public func setVideoMode(
        enabled: Bool,
        h264PayloadType: UInt8 = 97,
        cameraEnabled: Bool = true,
        preferFrontCamera: Bool? = nil
    ) {
        try? performOnQueueSync {
            self.isVideoCall = enabled
            self.h264PayloadType = (96...127).contains(Int(h264PayloadType)) ? h264PayloadType : 97
            self.desiredCameraEnabled = cameraEnabled
            if enabled && !self.speakerphoneExplicitlySet {
                self.speakerphone = true
            }
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            self.h264PayloadType = ZolaH264RtpPacketizer.companionDeltaPayloadType(for: self.h264PayloadType)
            self.h264KeyframePayloadType = ZolaH264RtpPacketizer.companionKeyframePayloadType(for: self.h264PayloadType)
            if enabled {
                let ve = self.ensureVideoEngineOnQueue()
                ve.setPayloadType(self.h264PayloadType)
                if let preferFrontCamera {
                    ve.setPreferFrontCamera(preferFrontCamera)
                }
                if self.isRunning {
                    ve.start(cameraEnabled: cameraEnabled)
                    self.applyAudioRouteOnQueue()
                } else if self.transportPrepared {
                    ve.ensureDecoderRunning()
                }
            } else {
                self.videoEngine?.stopAsync()
            }
            #endif
        }
    }

    /// Turns local camera capture/encoding on or off mid-call without disturbing audio or inbound video decode.
    public func setCameraEnabled(_ enabled: Bool) {
        queue.async {
            self.desiredCameraEnabled = enabled
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            self.videoEngine?.setCameraEnabled(enabled)
            #endif
        }
    }

    /// `true` while local camera capture is enabled.
    public var isCameraEnabled: Bool {
        (try? performOnQueueSync { desiredCameraEnabled }) ?? false
    }

    /// Switches between front and rear cameras (returns `true` if front camera is now selected).
    @discardableResult
    public func flipCamera() -> Bool {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        return (try? performOnQueueSync {
            self.ensureVideoEngineOnQueue().flipCamera()
        }) ?? true
        #else
        return true
        #endif
    }

    /// `true` when the front-facing camera is selected.
    public var isUsingFrontCamera: Bool {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        return (try? performOnQueueSync { self.videoEngine?.currentUsingFrontCamera ?? true }) ?? true
        #else
        return true
        #endif
    }

    /// Total number of remote H.264 video frames decoded via `VideoToolbox`.
    public var decodedVideoFrameCount: Int {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        return (try? performOnQueueSync { self.videoEngine?.currentDecodedFrameCount ?? 0 }) ?? 0
        #else
        return 0
        #endif
    }

    /// One log line of packet counters for the in-app call log. Runs on the media queue and calls back
    /// on the main queue, so the UI never waits on media work. Holds no keys, tokens or addresses.
    public func diagnosticsSnapshot(_ completion: @escaping (String) -> Void) {
        queue.async {
            let d = self.diag
            let inbound = d.inboundByType.keys.sorted()
                .map { String(format: "%02x:%d", $0, d.inboundByType[$0] ?? 0) }
                .joined(separator: ",")
            var line = "relay=\(self.primaryRelayEndpoint == nil ? "khong" : "co")"
                + " ack=\(self.relayHandshakeConfirmed ? "co" : "chua") token=\(self.zrtcRelayToken == 0 ? "0" : "co")"
                + " init=\(d.initSent)/ok\(d.initAckOk)"
                + " gui-tieng=\(d.audioSent) giu-tieng=\(d.audioHeld)"
                + " rtcp-tieng=\(d.audioRtcpSent)/\(d.audioRtcpRecv)"
                + " gui-hinh=\(d.videoSent) giu-hinh=\(d.videoHeld)"
                + " mat-ket-noi=\(d.droppedNoConnection) p2p=\(self.remoteConnections.count)"
                + " nhan=[\(inbound)]"
                + " " + self.audioCaptureDiag.line
                + " " + self.audioPlaybackDiag.line
                + " audio-decoded=\(self.decodedFrameCount) player-running=\(self.playerNode?.isPlaying == true ? 1 : 0)"
                + " voice-processing=\(self.isFullDuplexAudioActive && self.engine?.inputNode.isVoiceProcessingEnabled == true ? 1 : 0)"
                + " player-volume=\(self.playerNode?.volume ?? -1) mixer-volume=\(self.engine?.mainMixerNode.outputVolume ?? -1)"
                + " player-sample=\(self.playerNode.flatMap { node in node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0)?.sampleTime } } ?? -1)"
                + " audio-running=\(self.engine?.isRunning == true ? 1 : 0) mic-muted=\(self.muted ? 1 : 0)"
            if self.voiceProcessingTrial.requested {
                line += " aec-test=1 aec-selected=\(self.voiceProcessingTrial.selected ? 1 : 0)"
                    + " aec-fallback=\(self.voiceProcessingTrial.failure.rawValue):\(self.voiceProcessingTrial.errorCode)"
                    + " aec-in=\((Int(exactly: self.voiceTrialInputRate) ?? 0))/\(self.voiceTrialInputChannels)"
                    + " aec-out=\((Int(exactly: self.voiceTrialOutputRate) ?? 0))/\(self.voiceTrialOutputChannels)"
            }
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            if let ve = self.videoEngine {
                line += " " + ve.diagnosticsLine
            }
            #endif
            #if os(iOS) || targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            let output = outputs.contains { $0.portType == .builtInSpeaker } ? "speaker"
                : outputs.contains { $0.portType == .builtInReceiver } ? "receiver"
                : outputs.isEmpty ? "none" : "external"
            line += " output-volume=\(session.outputVolume) audio-output=\(output) speaker-wanted=\(self.speakerphone ? 1 : 0)"
            line += " route-reason=\(self.lastRouteChangeReason) route-system=\(self.systemRoutePolicy.followsSystemSelection ? 1 : 0)"
                + " route-category=\(session.category.rawValue) route-mode=\(session.mode.rawValue)"
                + " route-options=\(session.categoryOptions.rawValue) route-retries=\(self.routeRecovery.attempts)"
                + " route-error=\(self.routeErrorStage):\(self.routeErrorCode)"
            #endif
            DispatchQueue.main.async { completion(line) }
        }
    }

    /// Runs `block` on the media queue after every teardown/start already queued, e.g. to touch
    /// `AVAudioSession` only once `stopAsync()` has released the audio engine.
    public func afterPendingWork(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// Requests an immediate H.264 IDR keyframe from the peer via RTCP PLI (`0x0f` / `PT = 206`).
    public func requestRemoteVideoKeyframe() {
        queue.async {
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            self.videoEngine?.requestRemoteKeyframe()
            #endif
        }
    }

    /// Encodes and transmits a deterministic synthetic `CVPixelBuffer` via `VTCompressionSession` + RFC 6184 RTP
    /// over the active UDP/ZRTC transport (for deterministic loopback integration tests).
    @discardableResult
    public func sendSyntheticVideoFrameForTesting(
        width: Int = 320,
        height: Int = 240,
        r: UInt8 = 0x22,
        g: UInt8 = 0x88,
        b: UInt8 = 0xEE,
        forceKeyframe: Bool = true
    ) -> Bool {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        return (try? performOnQueueSync {
            let ve = self.ensureVideoEngineOnQueue()
            if !self.isVideoCall {
                self.isVideoCall = true
            }
            ve.ensureDecoderRunning()
            return ve.encodeSyntheticFrame(
                width: width,
                height: height,
                r: r,
                g: g,
                b: b,
                forceKeyframe: forceKeyframe
            )
        }) ?? false
        #else
        return false
        #endif
    }

    #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    private func ensureVideoEngineOnQueue() -> ZolaVoipVideoEngine {
        if let existing = videoEngine {
            return existing
        }
        let ve = ZolaVoipVideoEngine(callId: callId, payloadType: h264PayloadType)
        ve.onRemoteVideoFrame = queuedOnRemoteVideoFrame
        ve.onLocalVideoFrame = queuedOnLocalVideoFrame
        ve.onRemoteVideoPixelBuffer = queuedOnRemoteVideoPixelBuffer
        ve.onLocalVideoPixelBuffer = queuedOnLocalVideoPixelBuffer
        ve.onOutboundVideoPacket = { [weak self] payload, isRtcp in
            self?.queue.async { [weak self] in
                self?.sendVideoPacketOnQueue(payload, isRtcp: isRtcp)
            }
        }
        videoEngine = ve
        return ve
    }
    #endif

    /// CallKit owns activation for opted-in system calls. Default calls retain the existing route behavior.
    public func setSystemAudioSessionManaged(_ managed: Bool) {
        performOnQueueAsyncOrInline { [weak self] in self?.systemAudioSessionManaged = managed }
    }

    /// Suspend audio nodes without dropping UDP/signaling when CallKit deactivates the session.
    public func setSystemAudioSessionActive(_ active: Bool) {
        performOnQueueAsyncOrInline { [weak self] in
            guard let self, self.systemAudioSessionManaged else { return }
            self.systemAudioSessionActive = active
            guard self.isRunning else { return }
            if active {
                self.routeRecovery.reset()
                if self.engine?.isRunning != true { try? self.rebuildAudioEngineOnQueue() }
            } else {
                self.teardownAudioNodesOnQueue()
            }
        }
    }

    /// Stops capture, playback, keepalive, and every UDP flow. Safe to call multiple times.
    public func stop() {
        try? performOnQueueSync { self.stopOnQueue() }
    }

    /// Non-blocking teardown for `@MainActor` callers so UI transitions never stall on `queue`.
    public func stopAsync() {
        queue.async { self.stopOnQueue() }
    }

    // MARK: - UDP plumbing (queue-confined)

    private func acceptInboundConnection(_ inbound: NWConnection) {
        inbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pumpInboundDatagrams(on: inbound)
            case .failed, .cancelled:
                self.inboundConnections.removeValue(forKey: inbound.endpoint)
            default:
                break
            }
        }
        inbound.start(queue: queue)
        // Store accepted inbound UDP flows separately when ZRTC relay framing is active so we never
        // mirror duplicate `0x03` P2P copies back over inbound relay/peer sockets; pure-RTP loopback keeps P2P reply.
        inboundConnections[inbound.endpoint] = inbound
        if zrtcSessionId.isEmpty, remoteConnections[inbound.endpoint] == nil {
            remoteConnections[inbound.endpoint] = inbound
        }
    }

    private func shouldUseZrtcRelay(for endpoint: NWEndpoint) -> Bool {
        guard !zrtcSessionId.isEmpty else { return false }
        return !Self.isLoopbackEndpoint(endpoint) || forceZrtcFramingOnLoopback
    }

    private static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let raw = "\(host)".trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "127.0.0.1" || raw == "::1" || raw == "localhost"
    }

    private func isFromPrimaryRelay(_ conn: NWConnection) -> Bool {
        guard let relayEp = primaryRelayEndpoint else { return true }
        if let primaryConn = remoteConnections[relayEp], conn === primaryConn {
            return true
        }
        if conn.endpoint == relayEp {
            return true
        }
        if case let .hostPort(h1, p1) = conn.endpoint,
           case let .hostPort(h2, p2) = relayEp,
           p1 == p2,
           "\(h1)" == "\(h2)"
        {
            return true
        }
        return false
    }

    private func connectRemoteEndpoint(_ ep: MediaEndpoint) {
        guard let port = NWEndpoint.Port(rawValue: ep.port) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ep.host), port: port)
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.pumpInboundDatagrams(on: conn)
                if endpoint == self.primaryRelayEndpoint,
                   self.shouldUseZrtcRelay(for: endpoint),
                   !self.relayHandshakeConfirmed
                {
                    self.sendZrtcInitPacketOnQueue()
                }
            }
        }
        conn.start(queue: queue)
        remoteConnections[endpoint] = conn
    }

    private func pumpInboundDatagrams(on conn: NWConnection) {
        guard isRunning || transportPrepared else { return }
        conn.receiveMessage { [weak self] data, _, isComplete, err in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, (self.isRunning || self.transportPrepared) else { return }
                switch conn.state {
                case .cancelled, .failed:
                    return
                default:
                    break
                }
                if let err {
                    if case .posix(.ECANCELED) = err { return }
                    if case .posix(.ECONNREFUSED) = err,
                       conn.endpoint == self.primaryRelayEndpoint,
                       Self.isLoopbackEndpoint(conn.endpoint)
                    {
                        self.resolveRelayHandshakeWaitersOnQueue(confirmed: false)
                    }
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                        self?.pumpInboundDatagrams(on: conn)
                    }
                    return
                }
                if let data, !data.isEmpty {
                    self.handleInboundDatagram(data, from: conn)
                } else if isComplete {
                    return
                }
                // For UDP (`NWParameters.udp`), `isComplete` is `true` on EVERY datagram ("datagram complete",
                // NOT stream EOF) — always re-arm `receiveMessage` while the engine and connection remain active!
                self.pumpInboundDatagrams(on: conn)
            }
        }
    }

    private func isDuplicateRtpPacket(ssrc: UInt32, seq: UInt16) -> Bool {
        let key = (UInt64(ssrc) << 16) | UInt64(seq)
        if recentInboundRtpKeys.contains(key) {
            return true
        }
        if recentInboundRtpKeys.count < 64 {
            recentInboundRtpKeys.append(key)
        } else {
            recentInboundRtpKeys[recentInboundRtpCursor % 64] = key
            recentInboundRtpCursor = (recentInboundRtpCursor + 1) % 64
        }
        return false
    }

    /// Exercises the real RTP/ZRTC dispatcher without opening a socket or starting audio/camera capture.
    internal func ingestDatagramForTesting(_ data: Data) throws {
        try performOnQueueSync {
            let peer = NWConnection(host: "127.0.0.1", port: 9, using: .udp)
            self.handleInboundDatagram(data, from: peer)
        }
    }

    private func handleInboundDatagram(_ data: Data, from conn: NWConnection) {
        // Track the actual responding remote endpoint for relay→P2P migration (deduped).
        if case let .hostPort(host, port) = conn.endpoint {
            let ep = MediaEndpoint(host: "\(host)", port: port.rawValue)
            if ep != lastReportedRemoteEndpoint {
                lastReportedRemoteEndpoint = ep
                onRemoteEndpointChanged?(ep)
            }
        }
        guard let b0 = data.first else { return }
        diag.inboundByType[b0, default: 0] += 1
        if b0 == 0x02 {
            // Confirm ZRTC registration only when the primary relay ACKs `initZRTPToServer` (`pktCmd = 11|12`, `retCode = 0`, matching `callId` & active epoch).
            let expectedCmd: UInt16 = zrtcIsCaller ? 11 : 12
            if isFromPrimaryRelay(conn),
               let ack = ZolaCrypto.parseZrtcInitServerAck(data),
               ack.pktCmd == expectedCmd,
               ack.retCode == 0,
               (callId == 0 || ack.callId == UInt32(bitPattern: callId)),
               (zrtcInitSeqEpoch.isEmpty || zrtcInitSeqEpoch[ack.seq] == zrtcSessionEpoch)
            {
                zrtcRelayToken = ack.token
                diag.initAckOk += 1
                if !ack.reflectedAddress.isEmpty, Self.parseEndpointString(ack.reflectedAddress) != nil {
                    reflectedPublicEndpointStorage = ack.reflectedAddress
                }
                relayHandshakeConfirmed = true
                zrtcInitTimer?.cancel()
                zrtcInitTimer = nil
                let hadDroppedPreHandshakeVideo = droppedPreHandshakeVideo
                droppedPreHandshakeVideo = false
                if (!pendingPreHandshakeRtp.isEmpty || !pendingPreHandshakeVideo.isEmpty),
                   let relayEp = primaryRelayEndpoint,
                   let relayConn = remoteConnections[relayEp]
                {
                    let queued = pendingPreHandshakeRtp
                    pendingPreHandshakeRtp.removeAll(keepingCapacity: true)
                    for rtp in queued {
                        recordOutboundAudioRtpStatsOnQueue(rtp)
                        let relayPkt = ZolaCrypto.packZrtcOneToOneRtpPacket(
                            isP2P: false,
                            token: zrtcRelayToken,
                            rtpPayload: rtp
                        )
                        relayConn.send(content: relayPkt, completion: .contentProcessed { _ in })
                        diag.audioSent += 1
                    }
                    let queuedVid = pendingPreHandshakeVideo
                    pendingPreHandshakeVideo.removeAll(keepingCapacity: true)
                    for item in queuedVid {
                        let relayVidPkt = ZolaCrypto.packZrtcOneToOneVideoPacket(
                            isRtcp: item.isRtcp,
                            token: zrtcRelayToken,
                            payload: item.payload
                        )
                        relayConn.send(content: relayVidPkt, completion: .contentProcessed { _ in })
                        diag.videoSent += 1
                    }
                }
                sendAudioRtcpOnQueue()
                #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
                videoEngine?.noteTransportReady(hadDroppedPreHandshakePackets: hadDroppedPreHandshakeVideo)
                #endif
                resolveRelayHandshakeWaitersOnQueue(confirmed: true)
            }
            return
        }
        if b0 == 0x01 {
            // In ZRTC `:4200` relay mode (`sP2P = 0`), answer `0x01` pings ONLY from `primaryRelayEndpoint`
            // so the remote peer never mistakes an unverified P2P probe (`pktCmd = 5`) as connected and splits media off `:4200`!
            if let relayEp = primaryRelayEndpoint, shouldUseZrtcRelay(for: relayEp) {
                guard isFromPrimaryRelay(conn) else { return }
            }
            if let pong = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: zrtcSelfUid) {
                conn.send(content: pong, completion: .contentProcessed { _ in })
            }
            return
        }

        if let audioRtcp = ZolaCrypto.unpackZrtcAudioRtcpPayload(data) {
            diag.audioRtcpRecv += 1
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            let parsedRtcp = ZolaH264RtpDepacketizer.parseInboundRtcpCompound(audioRtcp)
            if let ntpMid = parsedRtcp.senderNtpMiddle32 {
                audioRxStats.recordInboundSenderReport(
                    ntpMiddle32: ntpMid,
                    arrivalUptime: ProcessInfo.processInfo.systemUptime
                )
            }
            #endif
            return
        }

        if let videoUnpacked = ZolaCrypto.unpackZrtcVideoPayload(data) {
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            if videoUnpacked.isRtcp {
                videoEngine?.handleInboundVideoPacket(videoUnpacked.payload, isRtcp: true)
            } else {
                if let rtpParsed = ZolaH264RtpDepacketizer.parseRtpPacketAllowingEmptyPadding(videoUnpacked.payload),
                   acceptedH264PayloadTypes.contains(rtpParsed.payloadType)
                {
                    onRemotePayloadType?(rtpParsed.payloadType)
                }
                let ve = ensureVideoEngineOnQueue()
                if !isVideoCall {
                    isVideoCall = true
                }
                ve.ensureDecoderRunning()
                ve.handleInboundVideoPacket(videoUnpacked.payload, isRtcp: false)
            }
            #endif
            return
        }

        if let inner = ZolaCrypto.unpackZrtcAudioPayload(data) {
            if let parsed = Self.parseRtpHeaderAndPayload(inner) {
                guard !isDuplicateRtpPacket(ssrc: parsed.ssrc, seq: parsed.sequenceNumber) else { return }
                #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
                audioRxStats.recordInboundRtp(
                    ssrc: parsed.ssrc,
                    sequenceNumber: parsed.sequenceNumber,
                    rtpTimestamp: parsed.timestamp,
                    byteCount: inner.count,
                    arrivalUptime: ProcessInfo.processInfo.systemUptime
                )
                #endif
                onRemotePayloadType?(parsed.payloadType)
                if let pcm = decodeRtpPayload(payloadType: parsed.payloadType, payload: parsed.payload) {
                    decodedFrameCount += 1
                    playDecodedPcm(pcm)
                }
            } else if !inner.isEmpty, !(inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1])) {
                // Raw Opus frame inside ZRTC wrapper when peer skips 12B RTP header (excluding RFC 5761 RTCP-mux 192...223).
                onRemotePayloadType?(113)
                if let pcm = decodeRtpPayload(payloadType: 113, payload: inner) {
                    decodedFrameCount += 1
                    playDecodedPcm(pcm)
                }
            }
            return
        }

        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        if data.count >= 8, (data[data.startIndex] >> 6) == 2, (192...223).contains(data[data.startIndex + 1]) {
            let parsedRtcp = ZolaH264RtpDepacketizer.parseInboundRtcpCompound(data)
            let isVideoFeedback = parsedRtcp.requestsKeyframe || parsedRtcp.rembBitrateBps != nil
            let isAudioRtcp = !isVideoFeedback && ((videoEngine == nil) || (audioRxStats.initialized && parsedRtcp.senderSsrc == audioRxStats.ssrc))
            if isAudioRtcp {
                diag.audioRtcpRecv += 1
                if let ntpMid = parsedRtcp.senderNtpMiddle32 {
                    audioRxStats.recordInboundSenderReport(
                        ntpMiddle32: ntpMid,
                        arrivalUptime: ProcessInfo.processInfo.systemUptime
                    )
                }
            } else {
                videoEngine?.handleInboundVideoPacket(data, isRtcp: true)
            }
            return
        }
        #endif

        guard let parsed = Self.parseRtpHeaderAndPayload(data) else { return }
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        if isVideoCall && acceptedH264PayloadTypes.contains(parsed.payloadType) {
            onRemotePayloadType?(parsed.payloadType)
            let ve = ensureVideoEngineOnQueue()
            ve.ensureDecoderRunning()
            ve.handleInboundVideoPacket(data, isRtcp: false)
            return
        }
        #endif
        guard !isDuplicateRtpPacket(ssrc: parsed.ssrc, seq: parsed.sequenceNumber) else { return }
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        audioRxStats.recordInboundRtp(
            ssrc: parsed.ssrc,
            sequenceNumber: parsed.sequenceNumber,
            rtpTimestamp: parsed.timestamp,
            byteCount: data.count,
            arrivalUptime: ProcessInfo.processInfo.systemUptime
        )
        #endif
        onRemotePayloadType?(parsed.payloadType)
        guard let pcm = decodeRtpPayload(payloadType: parsed.payloadType, payload: parsed.payload) else { return }
        decodedFrameCount += 1
        playDecodedPcm(pcm)
    }

    private func broadcastDatagram(_ data: Data) {
        for (_, conn) in remoteConnections {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func recordOutboundAudioRtpStatsOnQueue(_ rtpPacket: Data) {
        guard rtpPacket.count >= 12 else { return }
        audioTxPackets &+= 1
        audioTxOctets &+= UInt32(truncatingIfNeeded: max(0, rtpPacket.count - 12))
        let s = rtpPacket.startIndex
        lastAudioTxRtpTimestamp = (UInt32(rtpPacket[s + 4]) << 24)
            | (UInt32(rtpPacket[s + 5]) << 16)
            | (UInt32(rtpPacket[s + 6]) << 8)
            | UInt32(rtpPacket[s + 7])
    }

    private func sendAudioRtcpOnQueue() {
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        guard relayHandshakeConfirmed,
              let relayEp = primaryRelayEndpoint,
              shouldUseZrtcRelay(for: relayEp),
              let relayConn = remoteConnections[relayEp]
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reportBlock = audioRxStats.buildReportBlock(nowUptime: now)
        let senderStats: ZolaRtcpSenderStats?
        if audioTxPackets > 0 {
            let ntp = ZolaH264RtpPacketizer.ntpTimestamp()
            senderStats = ZolaRtcpSenderStats(
                ntpSeconds: ntp.seconds,
                ntpFraction: ntp.fraction,
                rtpTimestamp: lastAudioTxRtpTimestamp,
                senderPacketCount: audioTxPackets,
                senderOctetCount: audioTxOctets
            )
        } else {
            senderStats = nil
        }
        let rtcp = ZolaH264RtpPacketizer.buildCompoundRtcpPacket(
            senderSsrc: ssrc == 0 ? 0x4155_4431 : ssrc,
            senderStats: senderStats,
            reportBlock: reportBlock,
            cname: "zola\(ssrc)",
            rembBitrateBps: nil,
            rembSsrcs: []
        )
        let wire = ZolaCrypto.packZrtcOneToOneAudioRtcpPacket(token: zrtcRelayToken, rtcpPayload: rtcp)
        relayConn.send(content: wire, completion: .contentProcessed { _ in })
        diag.audioRtcpSent += 1
        #endif
    }

    private func sendAudioPacketOnQueue(_ rtpPacket: Data) {
        if let relayEp = primaryRelayEndpoint,
           shouldUseZrtcRelay(for: relayEp),
           let relayConn = remoteConnections[relayEp]
        {
            guard relayHandshakeConfirmed else {
                // Hold up to 6 recent 20ms frames (~120ms) while `InitZRTP` (`0x01 -> 0x02`) completes so we never
                // transmit `token = 0` packets that `:4200` drops, nor clip the first syllables after answer.
                if pendingPreHandshakeRtp.count >= 6 {
                    pendingPreHandshakeRtp.removeFirst(pendingPreHandshakeRtp.count - 5)
                }
                pendingPreHandshakeRtp.append(rtpPacket)
                diag.audioHeld += 1
                return
            }
            recordOutboundAudioRtpStatsOnQueue(rtpPacket)
            // Single-path 1-1 ZRTC relay (`0x03` + 4-byte `CallToken`, `0x100613b84`): never blast simultaneous P2P copies to unverified candidates.
            let relayPkt = ZolaCrypto.packZrtcOneToOneRtpPacket(
                isP2P: false,
                token: zrtcRelayToken,
                rtpPayload: rtpPacket
            )
            relayConn.send(content: relayPkt, completion: .contentProcessed { _ in })
            diag.audioSent += 1
            return
        }

        if remoteConnections.isEmpty { diag.droppedNoConnection += 1 } else {
            recordOutboundAudioRtpStatsOnQueue(rtpPacket)
            diag.audioSent += 1
        }
        let useZrtcFraming = !zrtcSessionId.isEmpty
        for (ep, conn) in remoteConnections {
            if useZrtcFraming && (!Self.isLoopbackEndpoint(ep) || forceZrtcFramingOnLoopback) {
                // Per `ZRTCPacket` (`0x100613b84`), 1-1 Audio RTP is ALWAYS `0x03` (`0x05` is Audio RTCP!).
                let rtpFramed = ZolaCrypto.packZrtcOneToOneRtpPacket(
                    isP2P: false,
                    token: zrtcRelayToken,
                    rtpPayload: rtpPacket
                )
                conn.send(content: rtpFramed, completion: .contentProcessed { _ in })
            } else {
                conn.send(content: rtpPacket, completion: .contentProcessed { _ in })
            }
        }
    }

    private func sendVideoPacketOnQueue(_ payload: Data, isRtcp: Bool) {
        if let relayEp = primaryRelayEndpoint,
           shouldUseZrtcRelay(for: relayEp),
           let relayConn = remoteConnections[relayEp]
        {
            guard relayHandshakeConfirmed else {
                // Buffer up to 64 initial SPS/PPS/IDR/RTCP packets until `InitZRTP` (`0x01 -> 0x02`) populates `zrtcRelayToken`.
                // If an oversized initial burst exceeds 64 packets, evict the oldest RTP packet (preserving RTCP) and mark
                // `droppedPreHandshakeVideo = true` so `noteTransportReady` immediately emits a fresh clean IDR keyframe!
                if pendingPreHandshakeVideo.count >= 64 {
                    if let firstRtpIdx = pendingPreHandshakeVideo.firstIndex(where: { !$0.isRtcp }) {
                        pendingPreHandshakeVideo.remove(at: firstRtpIdx)
                        droppedPreHandshakeVideo = true
                    } else {
                        pendingPreHandshakeVideo.removeFirst()
                    }
                }
                pendingPreHandshakeVideo.append((payload: payload, isRtcp: isRtcp))
                diag.videoHeld += 1
                return
            }
            let relayPkt = ZolaCrypto.packZrtcOneToOneVideoPacket(
                isRtcp: isRtcp,
                token: zrtcRelayToken,
                payload: payload
            )
            relayConn.send(content: relayPkt, completion: .contentProcessed { _ in })
            diag.videoSent += 1
            return
        }

        if remoteConnections.isEmpty { diag.droppedNoConnection += 1 } else { diag.videoSent += 1 }
        let useZrtcFraming = !zrtcSessionId.isEmpty
        for (ep, conn) in remoteConnections {
            if useZrtcFraming && (!Self.isLoopbackEndpoint(ep) || forceZrtcFramingOnLoopback) {
                let p2pPkt = ZolaCrypto.packZrtcOneToOneVideoPacket(
                    isRtcp: isRtcp,
                    token: zrtcRelayToken,
                    payload: payload
                )
                conn.send(content: p2pPkt, completion: .contentProcessed { _ in })
            } else {
                conn.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    private func sendZrtcInitPacketOnQueue() {
        guard let relayEp = primaryRelayEndpoint,
              shouldUseZrtcRelay(for: relayEp),
              let conn = remoteConnections[relayEp]
        else { return }
        zrtcInitSeq &+= 1
        zrtcInitSeqEpoch[zrtcInitSeq] = zrtcSessionEpoch
        if zrtcInitSeqEpoch.count > 32 {
            let minKeep = zrtcInitSeq &- 24
            zrtcInitSeqEpoch = zrtcInitSeqEpoch.filter { $0.key >= minKeep }
        }
        let pkt = ZolaCrypto.packZrtcInitServerPacket(
            isCaller: zrtcIsCaller,
            selfUid: zrtcSelfUid,
            partnerUid: zrtcPartnerUid,
            callId: callId,
            sessionId: zrtcSessionId,
            seq: zrtcInitSeq
        )
        conn.send(content: pkt, completion: .contentProcessed { _ in })
        diag.initSent += 1
    }

    private func startZrtcHandshakeOnQueue() {
        zrtcInitTimer?.cancel()
        zrtcInitTimer = nil
        guard let relayEp = primaryRelayEndpoint,
              shouldUseZrtcRelay(for: relayEp)
        else { return }
        sendZrtcInitPacketOnQueue()
        var attempts = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, self.transportPrepared else { return }
            attempts += 1
            if self.relayHandshakeConfirmed {
                self.zrtcInitTimer?.cancel()
                self.zrtcInitTimer = nil
                return
            }
            // A lost first burst used to leave the whole call silent (media stays held until the ACK);
            // after ~3 s of fast retries keep asking once per second for as long as the call runs.
            if attempts > 12 && attempts % 4 != 0 {
                return
            }
            self.sendZrtcInitPacketOnQueue()
        }
        zrtcInitTimer = timer
        timer.resume()
    }

    private func startKeepaliveOnQueue() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = zrtcSessionId.isEmpty ? 5.0 : 2.0
        timer.schedule(deadline: .now() + 1.0, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, (self.isRunning || self.transportPrepared) else { return }
            if let relayEp = self.primaryRelayEndpoint,
               self.shouldUseZrtcRelay(for: relayEp),
               let conn = self.remoteConnections[relayEp]
            {
                self.zrtcPingSeq &+= 1
                let ping = ZolaCrypto.packZrtcPingPacket(
                    selfUid: self.zrtcSelfUid,
                    partnerUid: self.zrtcPartnerUid,
                    callId: self.callId,
                    seq: self.zrtcPingSeq
                )
                conn.send(content: ping, completion: .contentProcessed { _ in })
                if self.relayHandshakeConfirmed {
                    self.sendAudioRtcpOnQueue()
                }
            } else if self.isRunning {
                self.broadcastDatagram(Data([0, 0, 0, 0]))
            }
        }
        keepaliveTimer = timer
        timer.resume()
    }

    // MARK: - Audio capture/playback (queue-confined)

    /// Upgrades a running playback-only `AVAudioEngine` to full-duplex capture + playback in place
    /// (e.g. once microphone permission transitions from `.undetermined` to `.granted`), WITHOUT tearing down
    /// the bound UDP listener, ZRTC session registration, or peer connections.
    public func upgradeToFullDuplexAudio() {
        queue.async {
            guard self.isRunning else { return }
            if !self.isFullDuplexAudioActive {
                try? self.rebuildAudioEngineOnQueue()
            }
            #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
            if self.isVideoCall, self.desiredCameraEnabled {
                self.videoEngine?.setCameraEnabled(true)
            }
            #endif
        }
    }

    private func teardownAudioNodesOnQueue() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        if isFullDuplexAudioActive, let input = engine?.inputNode {
            input.removeTap(onBus: 0)
        }
        isFullDuplexAudioActive = false
        audioPlaybackDiag.resetPlayer()
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    private func registerAudioConfigChangeObserverOnQueue(for activeEngine: AVAudioEngine) {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: activeEngine,
            queue: nil
        ) { [weak self, weak activeEngine] _ in
            self?.queue.async {
                guard let self, let activeEngine, self.engine === activeEngine, self.isRunning else { return }
                self.audioPlaybackDiag.engineConfigurationChanges += 1
                // Bluetooth HFP / speaker sample-rate transitions stop `AVAudioEngine` (`isRunning == false`).
                if !self.systemAudioSessionManaged, self.engine?.isRunning == false,
                   self.routeRecovery.shouldRecover(running: self.isRunning, routeMatches: false, configurationMatches: false) {
                    if self.voiceProcessingTrial.selected {
                        // This callback retains activeEngine. Leave its scope before disposing
                        // VPIO and building RemoteIO; a call ended/replaced in between owns no work.
                        let identity = ObjectIdentifier(activeEngine)
                        self.queue.async { [weak self] in
                            guard let self, self.isRunning, self.engine?.isRunning == false,
                                  self.engine.map({ ObjectIdentifier($0) }) == identity else { return }
                            try? self.rebuildAudioEngineOnQueue()
                        }
                    } else {
                        try? self.rebuildAudioEngineOnQueue()
                    }
                }
                self.scheduleAudioRouteRecoveryOnQueue()
            }
        }
    }

    private func rebuildAudioEngineOnQueue() throws {
        voiceProcessingTrial.observeStoppedGraph(systemManaged: systemAudioSessionManaged,
            systemActive: systemAudioSessionActive, hasEngine: engine != nil, running: engine?.isRunning == true)
        // A transient startup failure leaves engine=nil. Keep bounded recovery
        // scheduled while CallKit is active, rather than abandoning audio forever.
        defer { scheduleAudioRouteRecoveryOnQueue() }
        teardownAudioNodesOnQueue()
        try startAudioOnQueue()
    }

    private func startAudioOnQueue() throws {
        guard !systemAudioSessionManaged || systemAudioSessionActive else {
            throw ZolaError.transport("CallKit chưa kích hoạt âm thanh cuộc gọi")
        }
        var authorization: ZolaAudioCaptureDiagnostics.Authorization = .unknown
        var canRecordInput = true
        #if os(iOS) || targetEnvironment(macCatalyst)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: authorization = .granted
        case .denied: authorization = .denied
        case .undetermined: authorization = .undetermined
        @unknown default: authorization = .unknown
        }
        canRecordInput = authorization == .granted
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorization = .granted
        case .denied: authorization = .denied
        case .notDetermined: authorization = .undetermined
        case .restricted: authorization = .restricted
        @unknown default: authorization = .unknown
        }
        #endif
        audioCaptureDiag.beginStartup(authorization: authorization)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        voiceProcessingTrial.selectForStartup(canRecord: canRecordInput)
        #else
        voiceProcessingTrial.selectForStartup(canRecord: false)
        #endif
        applyAudioRouteOnQueue()
        let playFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )
        guard let playFmt else {
            audioCaptureDiag.failedStartup(.playbackFormat)
            throw ZolaError.transport("Không tạo được định dạng phát lại PCM 48kHz cho VoIP")
        }
        self.playerFormat = playFmt
        self.audioPlaybackDiag.resetPlayer()

        // Attempt full-duplex (microphone capture + speaker/earpiece playback) ONLY when microphone
        // permission is `.granted` on iOS/Catalyst (touching `inputNode` when `.undetermined` triggers an
        // unplanned system prompt or stalls `AVAudioEngine`).
        #if os(iOS) || targetEnvironment(macCatalyst)
        if !canRecordInput { audioCaptureDiag.recordFallback(.permission) }
        #endif
        if canRecordInput {
            if voiceProcessingTrial.selected {
                if autoreleasepool(invoking: { startVoiceProcessingTrialOnQueue(format: playFmt) }) { return }
                // The failed trial has been fully stopped/disposed before reverting session mode
                // and constructing the existing full-duplex RemoteIO graph below.
                applyAudioRouteOnQueue()
            }
            let duplexEngine = AVAudioEngine()
            let duplexPlayer = AVAudioPlayerNode()
            duplexEngine.attach(duplexPlayer)
            duplexEngine.connect(duplexPlayer, to: duplexEngine.mainMixerNode, format: playFmt)
            let input = duplexEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
                input.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                    self?.queue.async { self?.consumeCaptureBuffer(buffer) }
                }
                duplexEngine.prepare()
                do {
                    try duplexEngine.start()
                    audioPlaybackDiag.engineStarts += 1
                    if !duplexEngine.isRunning { audioPlaybackDiag.engineStoppedAtStart += 1 }
                    audioCaptureDiag.started(.duplex)
                    self.engine = duplexEngine
                    self.playerNode = duplexPlayer
                    self.isFullDuplexAudioActive = true
                    self.registerAudioConfigChangeObserverOnQueue(for: duplexEngine)
                    duplexPlayer.play()
                    return
                } catch {
                    audioCaptureDiag.recordFallback(.duplexStart, code: (error as NSError).code)
                }
                input.removeTap(onBus: 0)
            } else {
                audioCaptureDiag.recordFallback(.inputFormat)
            }
        }

        // Graceful playback-only fallback when microphone permission is `.undetermined`/`.denied` or no hardware mic exists:
        // keeps ZRTC UDP relay + incoming Opus/G.711 playback alive instead of tearing down the call.
        let playbackEngine = AVAudioEngine()
        let playbackPlayer = AVAudioPlayerNode()
        playbackEngine.attach(playbackPlayer)
        playbackEngine.connect(playbackPlayer, to: playbackEngine.mainMixerNode, format: playFmt)
        playbackEngine.prepare()
        do {
            try playbackEngine.start()
            audioPlaybackDiag.engineStarts += 1
            if !playbackEngine.isRunning { audioPlaybackDiag.engineStoppedAtStart += 1 }
        } catch {
            audioCaptureDiag.failedStartup(.playbackStart, code: (error as NSError).code)
            throw ZolaError.transport("Không khởi động được engine âm thanh VoIP: \(error.localizedDescription)")
        }
        audioCaptureDiag.started(.playbackOnly)
        self.engine = playbackEngine
        self.playerNode = playbackPlayer
        self.isFullDuplexAudioActive = false
        self.registerAudioConfigChangeObserverOnQueue(for: playbackEngine)
        playbackPlayer.play()
    }

    /// Mirrors Apple's UsingVoiceProcessing sample: the capture tap and mixer→output
    /// use one identical format. Enabling VPIO alone with automatic stereo output is insufficient.
    private func startVoiceProcessingTrialOnQueue(format: AVAudioFormat) -> Bool {
        let candidate = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let input = candidate.inputNode
        var tapInstalled = false
        var retained = false
        var stage: ZolaVoiceProcessingTrial.Failure = .enable
        defer {
            if !retained {
                if tapInstalled { input.removeTap(onBus: 0) }
                player.stop()
                candidate.stop()
                candidate.reset()
                // VPIO owns session processing until its I/O nodes are disposed. This function
                // returns before the caller changes mode or creates the fallback engine.
            }
        }
        do {
            try input.setVoiceProcessingEnabled(true) // stopped, before formats/connections
            stage = .format
            let output = candidate.outputNode
            let voiceFormat = input.outputFormat(forBus: 0)
            let deviceOutput = output.outputFormat(forBus: 0)
            // Preflight before connect/installTap: AVFAudio format assertions are Objective-C
            // exceptions, not Swift errors. Use the enabled input's actual format, never force
            // the decoder's 48kHz mono format onto a different hardware input route.
            guard voiceFormat.sampleRate.isFinite, voiceFormat.sampleRate > 0, voiceFormat.channelCount > 0,
                  deviceOutput.sampleRate.isFinite, deviceOutput.sampleRate > 0, deviceOutput.channelCount > 0 else {
                voiceProcessingTrial.reject(.format)
                return false
            }
            candidate.attach(player)
            candidate.connect(player, to: candidate.mainMixerNode, format: format)
            candidate.connect(candidate.mainMixerNode, to: output, format: voiceFormat)
            input.installTap(onBus: 0, bufferSize: 1_024, format: voiceFormat) { [weak self] buffer, _ in
                self?.queue.async { self?.consumeCaptureBuffer(buffer) }
            }
            tapInstalled = true
            stage = .format
            let capture = input.outputFormat(forBus: 0)
            let render = output.inputFormat(forBus: 0)
            voiceTrialInputRate = capture.sampleRate
            voiceTrialOutputRate = render.sampleRate
            voiceTrialInputChannels = capture.channelCount
            voiceTrialOutputChannels = render.channelCount
            guard input.isVoiceProcessingEnabled, output.isVoiceProcessingEnabled,
                  ZolaVoiceProcessingTrial.formatsMatch(inputRate: capture.sampleRate, inputChannels: capture.channelCount,
                    outputRate: render.sampleRate, outputChannels: render.channelCount), capture.isEqual(render) else {
                voiceProcessingTrial.reject(.format)
                return false
            }
            stage = .start
            candidate.prepare()
            try candidate.start()
            audioPlaybackDiag.engineStarts += 1
            guard candidate.isRunning else {
                audioPlaybackDiag.engineStoppedAtStart += 1
                voiceProcessingTrial.reject(.stopped)
                return false
            }
            self.engine = candidate
            self.playerNode = player
            self.isFullDuplexAudioActive = true
            audioCaptureDiag.started(.duplex)
            registerAudioConfigChangeObserverOnQueue(for: candidate)
            player.play()
            retained = true
            return true
        } catch {
            voiceProcessingTrial.reject(stage, code: (error as NSError).code)
            return false
        }
    }

    /// Observe for the lifetime of this call, not each AVAudioEngine replacement.
    private func registerAudioRouteObserverOnQueue() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            self?.queue.async {
                guard let self else { return }
                self.lastRouteChangeReason = reason
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let actualSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
                let builtInOnly = outputs.allSatisfy { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
                if self.systemRoutePolicy.observe(managed: self.systemAudioSessionManaged,
                    reason: reason, hasOutput: !outputs.isEmpty,
                    matchesAppSelection: builtInOnly && actualSpeaker == self.speakerphone) {
                    self.speakerphone = actualSpeaker
                    self.speakerphoneExplicitlySet = true
                    self.routeRecovery.reset()
                }
                self.scheduleAudioRouteRecoveryOnQueue()
            }
        }
        #endif
    }

    private func scheduleAudioRouteRecoveryOnQueue() {
        #if os(iOS) || targetEnvironment(macCatalyst)
        guard ZolaAudioRouteRecovery.canSchedule(running: isRunning,
            systemManaged: systemAudioSessionManaged, systemActive: systemAudioSessionActive,
            hasEngine: engine != nil), !routeRecoveryPending else { return }
        routeRecoveryPending = true
        let generation = routeRecoveryGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, generation == self.routeRecoveryGeneration else { return }
            self.routeRecoveryPending = false
            guard ZolaAudioRouteRecovery.canSchedule(running: self.isRunning,
                systemManaged: self.systemAudioSessionManaged, systemActive: self.systemAudioSessionActive,
                hasEngine: self.engine != nil) else { return }
            let session = AVAudioSession.sharedInstance()
            let followsSystem = self.systemAudioSessionManaged && self.systemRoutePolicy.followsSystemSelection
            let options: AVAudioSession.CategoryOptions = self.speakerphone && !self.systemAudioSessionManaged
                ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP]
            let mode: AVAudioSession.Mode = self.voiceProcessingTrial.requiresVoiceChatMode ? .voiceChat : ZolaAudioRouteRecovery.remoteIOAudioSessionMode
            let outputs = session.currentRoute.outputs
            let actualSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
            let matches = !outputs.isEmpty && (followsSystem || actualSpeaker == self.speakerphone)
            if self.routeRecovery.shouldRecover(
                running: self.isRunning,
                routeMatches: matches,
                configurationMatches: self.engine?.isRunning == true && session.category == .playAndRecord &&
                    (!self.voiceProcessingTrial.requested || session.mode == mode) &&
                    (followsSystem || (session.mode == mode && session.categoryOptions == options))
            ) {
                if (self.systemAudioSessionManaged || self.voiceProcessingTrial.selected), self.engine?.isRunning != true {
                    try? self.rebuildAudioEngineOnQueue()
                } else {
                    self.applyAudioRouteOnQueue()
                }
                // Verify delayed route settlement even if the OS emits no notification on failure.
                self.scheduleAudioRouteRecoveryOnQueue()
            }
        }
        #endif
    }

    private func applyAudioRouteOnQueue() {
        guard !systemAudioSessionManaged || systemAudioSessionActive else { return }
        #if os(iOS) || targetEnvironment(macCatalyst)
        let session = AVAudioSession.sharedInstance()
        let followsSystem = systemAudioSessionManaged && systemRoutePolicy.followsSystemSelection
        // A system-selected speaker/receiver/Bluetooth route must survive engine rebuilds.
        // CallKit owns activation and its route picker; defaultToSpeaker would
        // otherwise force its receiver selection back to speaker.
        let audioMode: AVAudioSession.Mode = voiceProcessingTrial.requiresVoiceChatMode ? .voiceChat : ZolaAudioRouteRecovery.remoteIOAudioSessionMode
        if followsSystem, session.category == .playAndRecord, !session.currentRoute.outputs.isEmpty,
           !voiceProcessingTrial.requested || session.mode == audioMode { return }
        let options: AVAudioSession.CategoryOptions = speakerphone && !systemAudioSessionManaged
            ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP]
        var stage = "category"
        do {
            if session.category != .playAndRecord || session.mode != audioMode || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: audioMode, options: options)
            }
            stage = "activate"
            if !systemAudioSessionManaged { try session.setActive(true) }
            stage = "override"
            let outputs = session.currentRoute.outputs
            let actualSpeaker = outputs.contains { $0.portType == .builtInSpeaker }
            if outputs.isEmpty || (!followsSystem && actualSpeaker != speakerphone) {
                try session.overrideOutputAudioPort(speakerphone ? .speaker : .none)
            }
            routeErrorStage = "none"
            routeErrorCode = 0
        } catch {
            routeErrorStage = stage
            routeErrorCode = (error as NSError).code
        }
        #endif
    }

    private func consumeCaptureBuffer(_ buffer: AVAudioPCMBuffer) {
        audioCaptureDiag.captureBuffers += 1
        guard isRunning else { audioCaptureDiag.captureIgnored += 1; return }
        let converted = Self.convertToPcm48kMono(buffer)
        audioCaptureDiag.converted(byteCount: converted?.count)
        guard let pcm48 = converted else { return }

        pcmSendLock.lock()
        pcmSendBuffer.append(pcm48)
        // 20 ms of PCM16 mono @48kHz = 960 samples = 1920 bytes.
        let frameBytes = 1_920
        var outbound = Data()
        while pcmSendBuffer.count >= frameBytes {
            if muted {
                outbound.append(Data(count: frameBytes))
            } else {
                outbound.append(pcmSendBuffer.prefix(frameBytes))
            }
            pcmSendBuffer.removeFirst(frameBytes)
        }
        pcmSendLock.unlock()

        guard !outbound.isEmpty else { return }
        encodeAndSend(pcm48kMonoInt16: outbound)
    }

    /// Converts any `AVAudioPCMBuffer` into little-endian PCM16 48 kHz mono — a cheap
    /// linear-resample good enough for voice; the Opus/G.711 encoders only ever see this format.
    private static func convertToPcm48kMono(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let fmt = buffer.format as AVAudioFormat?, fmt.channelCount > 0 else { return nil }
        let inRate = fmt.sampleRate
        guard inRate > 0 else { return nil }
        var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
        if let floatChannels = buffer.floatChannelData {
            let ch = Int(fmt.channelCount)
            for c in 0..<ch {
                let src = floatChannels[c]
                for i in 0..<Int(buffer.frameLength) {
                    mono[i] += src[i] / Float(ch)
                }
            }
        } else if let intChannels = buffer.int16ChannelData {
            let ch = Int(fmt.channelCount)
            for c in 0..<ch {
                let src = intChannels[c]
                for i in 0..<Int(buffer.frameLength) {
                    mono[i] += Float(src[i]) / 32_768 / Float(ch)
                }
            }
        } else {
            return nil
        }
        let outFrames = Int((Double(mono.count) * 48_000 / inRate).rounded())
        guard outFrames > 0 else { return nil }
        var out = Data(count: outFrames * 2)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            guard let p = dst.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<outFrames {
                let srcIdx = min(mono.count - 1, Int(Double(i) * inRate / 48_000))
                let s = max(-1, min(1, mono[srcIdx]))
                p[i] = Int16((s * 32_767).rounded())
            }
        }
        return out
    }

    private func encodeAndSend(pcm48kMonoInt16 pcm: Data) {
        // Each 20 ms block (1_920 B) becomes exactly one RTP datagram.
        var offset = 0
        while offset + 1_920 <= pcm.count {
            let frame = pcm.subdata(in: (pcm.startIndex + offset)..<(pcm.startIndex + offset + 1_920))
            offset += 1_920
            let (pt, payload): (UInt8, Data)
            switch activeCodec {
            case .opus:
                if let pkt = encodeOpusFrame(pcm16: frame) {
                    pt = 113
                    payload = pkt
                } else {
                    // Signaling negotiated `PT=113` (`opus/48000/2`) — never permanently downgrade to `PT=0` (`.pcmu`),
                    // which Zalo's ZRTC peer rejects as an unnegotiated payload type. Reset converter and skip this 20ms frame.
                    if let c = opusEncodeConverter {
                        AudioConverterDispose(c)
                        opusEncodeConverter = nil
                    }
                    rtpTimestamp &+= Self.rtpTimestampStep
                    continue
                }
            case .pcm16LE:
                pt = 111
                payload = downsamplePcm48To16k(frame)
            case .pcmu:
                pt = 0
                payload = Self.encodePcmu(frame)
            case .pcma:
                pt = 8
                payload = Self.encodePcma(frame)
            }
            audioCaptureDiag.encodedPackets += 1
            sequenceNumber &+= 1
            rtpTimestamp &+= Self.rtpTimestampStep
            let packet = Self.buildRtpPacket(
                payloadType: pt,
                sequenceNumber: sequenceNumber,
                timestamp: rtpTimestamp,
                ssrc: ssrc,
                payload: payload
            )
            sendAudioPacketOnQueue(packet)
        }
    }

    /// PCM16LE fallback for PT=111: decimate 48 kHz → 16 kHz by picking every 3rd sample.
    private func downsamplePcm48To16k(_ pcm: Data) -> Data {
        var out = Data(capacity: pcm.count / 3)
        pcm.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let p = src.bindMemory(to: Int16.self).baseAddress else { return }
            var i = 0
            while i < src.count / 2 {
                out.appendLE(p[i])
                i += 3
            }
        }
        return out
    }

    // MARK: - RTP framing

    /// Minimal RTP v2 header (`0x80`, no CSRC/extension): `[V=2|P|X|CC][M|PT][seq][ts][ssrc]`.
    public static func buildRtpPacket(
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    ) -> Data {
        var pkt = Data(capacity: 12 + payload.count)
        pkt.append(0x80)
        pkt.append(payloadType & 0x7F)
        pkt.appendBE(sequenceNumber)
        pkt.appendBE(timestamp)
        pkt.appendBE(ssrc)
        pkt.append(payload)
        return pkt
    }

    /// Validates RTP v2 (`version == 2`, no CSRC/extension handling beyond skipping them) and
    /// returns `(payloadType, payload)`; `nil` on malformed/non-RTP datagrams (e.g. keepalive).
    public static func parseRtpV2(_ data: Data) -> (payloadType: UInt8, payload: Data)? {
        guard let parsed = parseRtpHeaderAndPayload(data) else { return nil }
        return (parsed.payloadType, parsed.payload)
    }

    static func parseRtpHeaderAndPayload(
        _ data: Data
    ) -> (payloadType: UInt8, sequenceNumber: UInt16, timestamp: UInt32, ssrc: UInt32, payload: Data)? {
        guard data.count >= 12 else { return nil }
        let s = data.startIndex
        let b0 = data[s]
        let b1 = data[s + 1]
        guard (b0 >> 6) == 2 else { return nil }
        // RFC 5761 §4 (`rtcp-mux`): RTCP packet types `192...223` (`SR=200`, `RR=201`, `SDES=202`, `BYE=203`, etc.) must not be treated as RTP!
        guard !(192...223).contains(b1) else { return nil }
        let seq = (UInt16(data[s + 2]) << 8) | UInt16(data[s + 3])
        let ts = (UInt32(data[s + 4]) << 24)
            | (UInt32(data[s + 5]) << 16)
            | (UInt32(data[s + 6]) << 8)
            | UInt32(data[s + 7])
        let pktSsrc = (UInt32(data[s + 8]) << 24)
            | (UInt32(data[s + 9]) << 16)
            | (UInt32(data[s + 10]) << 8)
            | UInt32(data[s + 11])
        let cc = Int(b0 & 0x0F)
        let hasExt = (b0 & 0x10) != 0
        let hasPadding = (b0 & 0x20) != 0
        var headerLen = 12 + cc * 4
        guard data.count >= headerLen else { return nil }
        if hasExt {
            guard data.count >= headerLen + 4 else { return nil }
            let extLenWords = Int(
                (UInt16(data[s + headerLen + 2]) << 8)
                    | UInt16(data[s + headerLen + 3])
            )
            headerLen += 4 + extLenWords * 4
            guard data.count >= headerLen else { return nil }
        }
        var endIdx = data.endIndex
        if hasPadding {
            guard endIdx > s + headerLen else { return nil }
            let padLen = Int(data[endIdx - 1])
            guard padLen > 0, endIdx - padLen >= s + headerLen else { return nil }
            endIdx -= padLen
        }
        let pt = b1 & 0x7F
        return (pt, seq, ts, pktSsrc, data.subdata(in: (s + headerLen)..<endIdx))
    }

    // MARK: - Payload decode + playback

    private func decodeRtpPayload(payloadType: UInt8, payload: Data) -> Data? {
        audioPlaybackDiag.decodeAttempts += 1
        audioPlaybackDiag.lastPayloadType = payloadType
        let pcm: Data?
        switch payloadType {
        case 113, 112: pcm = decodeOpusPacket(payload)
        case 0: pcm = Self.decodePcmu(payload, sampleRate: 8_000)
        case 8: pcm = Self.decodePcma(payload, sampleRate: 8_000)
        case 111: pcm = Self.resamplePcm16(payload, fromRate: 16_000, toRate: 48_000)
        default: pcm = nil
        }
        if pcm == nil || pcm?.isEmpty == true { audioPlaybackDiag.decodeFailures += 1 }
        return pcm
    }

    private func playDecodedPcm(_ pcm48MonoInt16: Data) {
        guard let playerNode, let playerFormat, !pcm48MonoInt16.isEmpty else {
            audioPlaybackDiag.unavailableDrops += 1; return
        }
        // Engine capture may still run after a route transition stops just its player.
        // Resume only an active call's stopped player, without touching audio routing.
        if ZolaAudioPlaybackDiagnostics.shouldResumePlayer(engineRunning: engine?.isRunning == true,
            playerRunning: playerNode.isPlaying, systemManaged: systemAudioSessionManaged,
            systemActive: systemAudioSessionActive) {
            playerNode.play()
            audioPlaybackDiag.playerRestarts += 1
        }
        // Bound playout queue to <= 12 buffers; never accumulate multi-second lag.
        guard audioPlaybackDiag.queued < 12 else { audioPlaybackDiag.queueDrops += 1; return }
        let frames = AVAudioFrameCount(pcm48MonoInt16.count / 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frames) else {
            audioPlaybackDiag.bufferDrops += 1; return
        }
        buf.frameLength = frames
        guard let dst = buf.floatChannelData?[0] else { audioPlaybackDiag.bufferDrops += 1; return }
        var peak = 0
        pcm48MonoInt16.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let p = src.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<Int(frames) {
                peak = max(peak, abs(Int(p[i])))
                dst[i] = Float(p[i]) / 32_768
            }
        }
        let generation = audioPlaybackDiag.didSchedule(peak: peak)
        playerNode.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                self.audioPlaybackDiag.completed(generation: generation,
                    playerRunning: self.playerNode?.isPlaying == true && self.engine?.isRunning == true)
            }
        }
    }

    // MARK: - Opus (AudioConverter) encode/decode

    /// Lazily builds the LPCM 48k mono int16 → Opus 48k mono converter; `nil` on runtimes without
    /// an Opus encoder (callers then fall back to μ-law).
    private func ensureOpusEncoder() -> AudioConverterRef? {
        if let c = opusEncodeConverter { return c }
        var src = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var dst = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&src, &dst, &ref)
        guard status == noErr, let conv = ref else {
            audioCaptureDiag.failedEncoding(.encoderCreate, code: Int(status))
            return nil
        }
        // 20 ms frames, 32 kbps — matches Zalo's `opus/48000/2` `frmPtime=20` offer.
        var bitrate: UInt32 = 32_000
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        opusEncodeConverter = conv
        return conv
    }

    private func encodeOpusFrame(pcm16: Data) -> Data? {
        guard let conv = ensureOpusEncoder(), !pcm16.isEmpty else { return nil }
        var outBuf = Data(count: 1_024)
        var outPktDesc = AudioStreamPacketDescription()
        var ioPackets: UInt32 = 1
        var outAblSize: UInt32 = 0
        let status: OSStatus = pcm16.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
            let inAbl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(pcm16.count),
                    mData: UnsafeMutableRawPointer(mutating: srcPtr.baseAddress)
                )
            )
            var ctx = OpusIOContext(
                bufferList: inAbl,
                packetDescriptionPtr: nil,
                units: UInt32(pcm16.count / 2),
                consumed: false
            )
            let outCap = outBuf.count
            return outBuf.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) -> OSStatus in
                var outAbl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(outCap),
                        mData: dstPtr.baseAddress
                    )
                )
                let s = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                    AudioConverterFillComplexBuffer(
                        conv, opusConverterInputProc, ctxPtr, &ioPackets, &outAbl, &outPktDesc
                    )
                }
                outAblSize = outAbl.mBuffers.mDataByteSize
                return s
            }
        }
        guard status == noErr || status == kOpusNeedMoreInputStatus else {
            audioCaptureDiag.failedEncoding(.encoderFill, code: Int(status))
            return nil
        }
        guard ioPackets > 0 else {
            audioCaptureDiag.failedEncoding(.encoderNoOutput, code: Int(status))
            return nil
        }
        let start = Int(outPktDesc.mStartOffset)
        let byteLen = outPktDesc.mDataByteSize > 0 ? Int(outPktDesc.mDataByteSize) : Int(outAblSize)
        guard byteLen > 0, start >= 0, start + byteLen <= outBuf.count else {
            audioCaptureDiag.failedEncoding(.encoderOutputBounds, code: Int(status))
            return nil
        }
        return outBuf.subdata(in: start..<(start + byteLen))
    }

    /// Computes the total 48 kHz PCM sample count encoded inside a single RFC 6716 Opus packet (`120...5_760`, <= 120 ms).
    public static func opusPacketSampleCount(_ packet: Data) -> UInt32? {
        guard let toc = packet.first else { return nil }
        let config = Int((toc >> 3) & 0x1F)
        let samplesPerFrame: UInt32
        if config < 12 {
            // SILK-only NB/MB/WB: 10, 20, 40, 60 ms @ 48 kHz
            let table: [UInt32] = [480, 960, 1_920, 2_880]
            samplesPerFrame = table[config & 0x03]
        } else if config < 16 {
            // Hybrid SWB/FB: 10, 20 ms @ 48 kHz
            samplesPerFrame = (config & 0x01) == 0 ? 480 : 960
        } else {
            // CELT-only NB/WB/SWB/FB: 2.5, 5, 10, 20 ms @ 48 kHz
            let table: [UInt32] = [120, 240, 480, 960]
            samplesPerFrame = table[config & 0x03]
        }

        let code = toc & 0x03
        let frameCount: UInt32
        switch code {
        case 0:
            frameCount = 1
        case 1:
            guard packet.count >= 2, (packet.count - 1) % 2 == 0 else { return nil }
            frameCount = 2
        case 2:
            guard packet.count >= 2 else { return nil }
            frameCount = 2
        default:
            guard packet.count >= 2 else { return nil }
            let m = UInt32(packet[packet.startIndex + 1] & 0x3F)
            guard m >= 1 else { return nil }
            frameCount = m
        }

        let totalSamples = samplesPerFrame * frameCount
        guard (120...5_760).contains(totalSamples) else { return nil }
        return totalSamples
    }

    /// Encodes a single 20 ms 48 kHz mono PCM16 frame (`1_920` bytes) to Opus (`kAudioFormatOpus`) for unit tests.
    public func encodeOpusFrameForTesting(_ pcm48kMonoInt16: Data) -> Data? {
        try? performOnQueueSync {
            self.encodeOpusFrame(pcm16: pcm48kMonoInt16)
        }
    }

    /// Decodes a single RFC 6716 Opus packet (`2.5 ms...120 ms`, including `maxFT: 60` multi-frame packets) to 48 kHz mono PCM16 for unit tests.
    public func decodeOpusPacketForTesting(_ opusPacket: Data) -> Data? {
        try? performOnQueueSync {
            self.decodeOpusPacket(opusPacket)
        }
    }

    /// Lazily builds the Opus 48k (`opus/48000/2`, RFC 7587) → LPCM 48k mono int16 decoder.
    /// `mFramesPerPacket = 0` enables variable-duration RFC 6716 Opus packets (`10/20/40/60 ms` up to `120 ms`);
    /// configuring 2 input channels handles both mono and stereo Opus TOC packets seamlessly.
    private func ensureOpusDecoder() -> AudioConverterRef? {
        if let c = opusDecodeConverter { return c }
        var src = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var dst = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&src, &dst, &ref)
        guard status == noErr else { audioPlaybackDiag.decoderError = status; return nil }
        opusDecodeConverter = ref
        return ref
    }

    private func decodeOpusPacket(_ packet: Data) -> Data? {
        guard let conv = ensureOpusDecoder(),
              let expectedFrames = Self.opusPacketSampleCount(packet)
        else { return nil }
        let maxFrames: UInt32 = 5_760 // up to 120 ms @ 48 kHz (RFC 6716 §3.2.5 maximum)
        var outPcm = Data(count: Int(maxFrames) * 2)
        var ioFrames: UInt32 = maxFrames
        let pktDescPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        pktDescPtr.initialize(to: AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: expectedFrames,
            mDataByteSize: UInt32(packet.count)
        ))
        defer {
            pktDescPtr.deinitialize(count: 1)
            pktDescPtr.deallocate()
        }
        let status: OSStatus = packet.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) in
            let inAbl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(packet.count),
                    mData: UnsafeMutableRawPointer(mutating: srcPtr.baseAddress)
                )
            )
            var ctx = OpusIOContext(
                bufferList: inAbl,
                packetDescriptionPtr: pktDescPtr,
                units: 1,
                consumed: false
            )
            let outCap = outPcm.count
            return outPcm.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) -> OSStatus in
                var outAbl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(outCap),
                        mData: dstPtr.baseAddress
                    )
                )
                return withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                    AudioConverterFillComplexBuffer(
                        conv, opusConverterInputProc, ctxPtr, &ioFrames, &outAbl, nil
                    )
                }
            }
        }
        guard (status == noErr || status == kOpusNeedMoreInputStatus), ioFrames > 0 else {
            audioPlaybackDiag.decoderError = status; return nil
        }
        return Data(outPcm.prefix(min(outPcm.count, Int(ioFrames) * 2)))
    }

    // MARK: - G.711 codecs (pure Swift, no OS dependency)

    private static let ulawExpTable: [Int16] = {
        var table = [Int16](repeating: 0, count: 256)
        for i in 0..<256 {
            let u = Int16(bitPattern: UInt16(i)) & 0xFF
            let mag = ~u & 0x7F
            let seg = Int(mag >> 4) & 0x07
            let mant = Int(mag) & 0x0F
            var sample = Int16(((mant << 3) + 33) << seg)
            sample -= 33
            table[i] = (u & 0x80) != 0 ? -sample : sample
        }
        return table
    }()

    private static let alawExpTable: [Int16] = {
        var table = [Int16](repeating: 0, count: 256)
        for i in 0..<256 {
            var a = UInt8(i) ^ 0x55
            let seg = (Int(a) >> 4) & 0x07
            var sample: Int16
            if seg == 0 {
                sample = Int16((Int(a & 0x0F) << 1) + 1)
            } else {
                sample = Int16(((Int(a & 0x0F) << 1) + 33) << (seg - 1))
            }
            table[i] = (a & 0x80) != 0 ? sample : -sample
        }
        return table
    }()

    /// G.711 μ-law → PCM16 (8 kHz → upsampled 48 kHz).
    private static func decodePcmu(_ payload: Data, sampleRate: Int) -> Data {
        var out = Data(capacity: payload.count * 2)
        for b in payload {
            out.appendLE(ulawExpTable[Int(b)])
        }
        return resamplePcm16(out, fromRate: sampleRate, toRate: 48_000)
    }

    private static func decodePcma(_ payload: Data, sampleRate: Int) -> Data {
        var out = Data(capacity: payload.count * 2)
        for b in payload {
            out.appendLE(alawExpTable[Int(b)])
        }
        return resamplePcm16(out, fromRate: sampleRate, toRate: 48_000)
    }

    /// PCM16 (any rate) → μ-law 8 kHz single byte stream (downsamples 48k→8k by 6×).
    private static func encodePcmu(_ pcm16: Data) -> Data {
        var out = Data(capacity: pcm16.count / 6)
        pcm16.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let p = src.bindMemory(to: Int16.self).baseAddress else { return }
            var i = 0
            let n = src.count / 2
            while i < n {
                out.append(linearToUlaw(p[i]))
                i += 6
            }
        }
        return out
    }

    private static func encodePcma(_ pcm16: Data) -> Data {
        var out = Data(capacity: pcm16.count / 6)
        pcm16.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let p = src.bindMemory(to: Int16.self).baseAddress else { return }
            var i = 0
            let n = src.count / 2
            while i < n {
                out.append(linearToAlaw(p[i]))
                i += 6
            }
        }
        return out
    }

    /// Nearest-neighbor resample of PCM16 LE mono (`fromRate` → `toRate`).
    private static func resamplePcm16(_ pcm: Data, fromRate: Int, toRate: Int) -> Data {
        guard fromRate > 0, toRate > 0, fromRate != toRate, !pcm.isEmpty else { return pcm }
        let inFrames = pcm.count / 2
        let outFrames = Int((Double(inFrames) * Double(toRate) / Double(fromRate)).rounded())
        guard outFrames > 0 else { return Data() }
        var out = Data(count: outFrames * 2)
        pcm.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let p = src.bindMemory(to: Int16.self).baseAddress else { return }
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let q = dst.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<outFrames {
                    let srcIdx = min(inFrames - 1, Int(Double(i) * Double(fromRate) / Double(toRate)))
                    q[i] = p[srcIdx]
                }
            }
        }
        return out
    }

    private static func linearToUlaw(_ sample: Int16) -> UInt8 {
        var s = Int(sample)
        var sign: UInt8 = 0
        if s < 0 {
            sign = 0x80
            s = -s
        }
        s = min(s, 32_634) + 33
        var seg = 0
        var v = s >> 7
        while v > 0, seg < 7 {
            seg += 1
            v >>= 1
        }
        if seg > 7 { return UInt8(sign | 0x7F) }
        let uval = UInt8((seg << 4) | ((s >> (seg + 3)) & 0x0F))
        return ~(uval | sign)
    }

    private static func linearToAlaw(_ sample: Int16) -> UInt8 {
        var s = Int(sample)
        var mask: UInt8 = 0xD5
        if s < 0 {
            s = -s - 1
            mask = 0x55
        }
        s = min(s, 32_767)
        var seg = 0
        var v = s >> 8
        while v > 0, seg < 7 {
            seg += 1
            v >>= 1
        }
        let aval: UInt8 = seg >= 8 ? 0x7F : UInt8((seg << 4) | ((seg < 2 ? (s >> 4) : (s >> (seg + 3))) & 0x0F))
        return aval ^ mask
    }

    // MARK: - Teardown

    private func stopOnQueue() {
        resolveRelayHandshakeWaitersOnQueue(confirmed: false)
        guard isRunning || transportPrepared || engine != nil || udpListener != nil else { return }
        isRunning = false
        routeRecoveryGeneration &+= 1
        routeRecoveryPending = false
        routeRecovery.reset()
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        transportPrepared = false
        relayHandshakeConfirmed = false
        zrtcRelayToken = 0
        zrtcInitSeqEpoch.removeAll(keepingCapacity: false)
        pendingPreHandshakeRtp.removeAll(keepingCapacity: false)
        pendingPreHandshakeVideo.removeAll(keepingCapacity: false)
        droppedPreHandshakeVideo = false
        audioTxPackets = 0
        audioTxOctets = 0
        lastAudioTxRtpTimestamp = 0
        #if canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        audioRxStats.reset()
        videoEngine?.stopAsync()
        videoEngine = nil
        #endif
        reflectedPublicEndpointStorage = ""
        zrtcInitTimer?.cancel()
        zrtcInitTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        teardownAudioNodesOnQueue()
        recentInboundRtpKeys.removeAll(keepingCapacity: false)
        recentInboundRtpCursor = 0
        for (_, conn) in inboundConnections { conn.cancel() }
        inboundConnections.removeAll()
        for (_, conn) in remoteConnections { conn.cancel() }
        remoteConnections.removeAll()
        primaryRelayEndpoint = nil
        udpListener?.cancel()
        udpListener = nil
        if let c = opusEncodeConverter { AudioConverterDispose(c); opusEncodeConverter = nil }
        if let c = opusDecodeConverter { AudioConverterDispose(c); opusDecodeConverter = nil }
        pcmSendLock.lock()
        pcmSendBuffer.removeAll(keepingCapacity: false)
        pcmSendLock.unlock()
    }

    /// Runs `block` synchronously on `queue`, rethrowing — re-entrant safe via `queueKey`.
    private func performOnQueueSync<T>(_ block: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }

    private func performOnQueueAsyncOrInline(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            block()
        } else {
            queue.async(execute: block)
        }
    }
}

/// Sentinel returned from `opusConverterInputProc` once the current frame/packet has been
/// consumed, preventing `AudioConverterFillComplexBuffer` from interpreting `ioCount = 0` + `noErr`
/// as permanent end-of-stream (EOF).
private let kOpusNeedMoreInputStatus: OSStatus = 0x5A4F_4C41 // 'ZOLA'

/// Carries the converter input across `AudioConverterFillComplexBuffer`'s `inUserData`
/// (the C callback cannot capture Swift context).
private struct OpusIOContext {
    var bufferList: AudioBufferList
    var packetDescriptionPtr: UnsafeMutablePointer<AudioStreamPacketDescription>?
    /// Frames (encode input) or packet count (decode input).
    var units: UInt32
    var consumed: Bool
}

private let opusConverterInputProc: AudioConverterComplexInputDataProc = { _, ioCount, ioData, outDataPacketDescription, userData in
    guard let userData = userData else {
        ioCount.pointee = 0
        return kOpusNeedMoreInputStatus
    }
    let ctx = userData.assumingMemoryBound(to: OpusIOContext.self)
    guard !ctx.pointee.consumed else {
        ioCount.pointee = 0
        return kOpusNeedMoreInputStatus
    }
    ctx.pointee.consumed = true
    ioData.pointee.mNumberBuffers = ctx.pointee.bufferList.mNumberBuffers
    ioData.pointee.mBuffers = ctx.pointee.bufferList.mBuffers
    if let pktDescPtr = ctx.pointee.packetDescriptionPtr, let outDataPacketDescription {
        outDataPacketDescription.pointee = pktDescPtr
    }
    ioCount.pointee = ctx.pointee.units
    return noErr
}

private extension Data {
    mutating func appendLE(_ v: Int16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendBE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendBE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}
#endif
