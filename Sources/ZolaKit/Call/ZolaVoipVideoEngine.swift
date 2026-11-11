import Foundation

#if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
#if canImport(CoreImage)
import CoreImage
#endif

// MARK: - RFC 6184 H.264 RTP Packetizer & RTCP PLI (`CallController.cpp` `0x1005237e8`: `"h264"`, `payload = 97`)

/// Deterministic RFC 6184 H.264 RTP v2 packetizer (Single NAL `1..23`, STAP-A `24`, FU-A `28`) + RTCP PLI builder.
public struct ZolaH264RtpPacketizer: Sendable {
    public let ssrc: UInt32
    public var payloadType: UInt8
    public var keyframePayloadType: UInt8
    public var maxPayloadSize: Int
    public private(set) var sequenceNumber: UInt16
    private let timestampOffset: UInt32
    private var accessUnitCount: UInt64 = 0

    public init(
        ssrc: UInt32,
        payloadType: UInt8 = 97,
        keyframePayloadType: UInt8? = nil,
        maxPayloadSize: Int = 1_150,
        initialSequenceNumber: UInt16 = UInt16.random(in: 0...UInt16.max),
        initialTimestampOffset: UInt32 = UInt32.random(in: 0...UInt32.max)
    ) {
        self.ssrc = ssrc == 0 ? 0x5649_4431 : ssrc
        self.payloadType = payloadType & 0x7F
        self.keyframePayloadType = keyframePayloadType ?? Self.companionKeyframePayloadType(for: payloadType)
        self.maxPayloadSize = max(256, maxPayloadSize)
        self.sequenceNumber = initialSequenceNumber
        self.timestampOffset = initialTimestampOffset
    }

    public static func companionKeyframePayloadType(for deltaPayloadType: UInt8) -> UInt8 {
        switch deltaPayloadType {
        case 97, 98: return 98
        case 121, 122: return 121
        case 125, 126: return 126
        default: return deltaPayloadType < 127 ? (deltaPayloadType + 1) : deltaPayloadType
        }
    }

    public static func companionDeltaPayloadType(for payloadType: UInt8) -> UInt8 {
        switch payloadType {
        case 97, 98: return 97
        case 121, 122: return 122
        case 125, 126: return 125
        default: return payloadType
        }
    }

    /// Converts presentation timestamp (seconds) to 90 kHz RTP clock ticks.
    public func rtpTimestamp(forPresentationSeconds seconds: Double) -> UInt32 {
        guard seconds.isFinite else { return timestampOffset }
        let ticks = Int64((seconds * 90_000.0).rounded())
        return timestampOffset &+ UInt32(truncatingIfNeeded: ticks)
    }

    /// Strips any leading Annex-B `00 00 00 01` or `00 00 01` start code prefix from a single NAL unit.
    public static func stripAnnexBStartCode(_ nal: Data) -> Data {
        if nal.count >= 4,
           nal[nal.startIndex] == 0,
           nal[nal.startIndex + 1] == 0,
           nal[nal.startIndex + 2] == 0,
           nal[nal.startIndex + 3] == 1
        {
            return nal.subdata(in: (nal.startIndex + 4)..<nal.endIndex)
        }
        if nal.count >= 3,
           nal[nal.startIndex] == 0,
           nal[nal.startIndex + 1] == 0,
           nal[nal.startIndex + 2] == 1
        {
            return nal.subdata(in: (nal.startIndex + 3)..<nal.endIndex)
        }
        return nal
    }

    /// Packetizes a single H.264 access unit (one video frame) into MTU-safe RTP v2 packets (`<= maxPayloadSize + 12` bytes).
    /// - Emits SPS (`7`) + PPS (`8`) via STAP-A (`24`) on keyframes and every 15 frames so late-joining peers lock immediately.
    /// - Fragments large VCL slices (`> maxPayloadSize`) using RFC 6184 §5.8 FU-A (`28`).
    /// - Sets RTP Marker (`M = 1`) only on the final packet of the access unit.
    public mutating func packetizeAccessUnit(
        nalUnits: [Data],
        sps: Data? = nil,
        pps: Data? = nil,
        isKeyframe: Bool = false,
        rtpTimestamp: UInt32
    ) -> [Data] {
        let cleanedNals: [Data] = nalUnits.compactMap { raw in
            let stripped = Self.stripAnnexBStartCode(raw)
            guard !stripped.isEmpty else { return nil }
            let nalType = stripped[stripped.startIndex] & 0x1F
            // Drop Access Unit Delimiter (`9`) & Filler (`12`) to save relay bandwidth.
            if nalType == 9 || nalType == 12 { return nil }
            return stripped
        }
        guard !cleanedNals.isEmpty else { return [] }

        let pktPt = isKeyframe ? keyframePayloadType : payloadType
        accessUnitCount &+= 1
        var packets: [Data] = []
        let cleanSps = sps.map(Self.stripAnnexBStartCode).flatMap { $0.isEmpty ? nil : $0 }
        let cleanPps = pps.map(Self.stripAnnexBStartCode).flatMap { $0.isEmpty ? nil : $0 }
        // Native `libzrtc` `RtpPacketizerH264::GeneratePackets` (`0x1004da590`) emits `STAP-A (SPS+PPS)` strictly on
        // IDR keyframes (`PT = 98`), because `RtpDepacketizerH264::ProcessStapAOrSingleNalu` (`0x1004d9f60`) marks
        // every `STAP-A` packet `isFirstPacket = 1`.
        let shouldEmitParameterSets = isKeyframe

        if shouldEmitParameterSets, let cleanSps, let cleanPps {
            let stapLen = 1 + 2 + cleanSps.count + 2 + cleanPps.count
            if stapLen <= maxPayloadSize {
                var stap = Data(capacity: stapLen)
                stap.append(0x78) // F=0, NRI=3 (0x60), Type=24 (STAP-A)
                stap.appendVideoBE(UInt16(cleanSps.count))
                stap.append(cleanSps)
                stap.appendVideoBE(UInt16(cleanPps.count))
                stap.append(cleanPps)
                packets.append(makeRtpPacket(payload: stap, marker: false, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt))
            } else {
                packets.append(contentsOf: packetizeSingleOrFua(nal: cleanSps, isLastNalOfFrame: false, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt))
                packets.append(contentsOf: packetizeSingleOrFua(nal: cleanPps, isLastNalOfFrame: false, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt))
            }
        }

        for (idx, nal) in cleanedNals.enumerated() {
            let isLast = (idx == cleanedNals.count - 1)
            packets.append(contentsOf: packetizeSingleOrFua(nal: nal, isLastNalOfFrame: isLast, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt))
        }
        return packets
    }

    private mutating func packetizeSingleOrFua(
        nal: Data,
        isLastNalOfFrame: Bool,
        rtpTimestamp: UInt32,
        payloadTypeOverride pktPt: UInt8
    ) -> [Data] {
        guard !nal.isEmpty else { return [] }
        if nal.count <= maxPayloadSize {
            return [makeRtpPacket(payload: nal, marker: isLastNalOfFrame, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt)]
        }

        // RFC 6184 §5.8 FU-A (`type = 28`)
        let nalHeader = nal[nal.startIndex]
        let fnri = nalHeader & 0xE0
        let nalType = nalHeader & 0x1F
        let fuIndicator = fnri | 28
        let maxChunk = max(1, maxPayloadSize - 2)
        let bodyStart = nal.startIndex + 1
        let totalBody = nal.count - 1
        var offset = 0
        var out: [Data] = []

        while offset < totalBody {
            let chunkLen = min(maxChunk, totalBody - offset)
            let isFirstChunk = (offset == 0)
            let isLastChunk = (offset + chunkLen >= totalBody)
            var fuHeader = nalType
            if isFirstChunk { fuHeader |= 0x80 }
            if isLastChunk { fuHeader |= 0x40 }

            var payload = Data(capacity: 2 + chunkLen)
            payload.append(fuIndicator)
            payload.append(fuHeader)
            payload.append(nal.subdata(in: (bodyStart + offset)..<(bodyStart + offset + chunkLen)))

            let marker = isLastNalOfFrame && isLastChunk
            out.append(makeRtpPacket(payload: payload, marker: marker, rtpTimestamp: rtpTimestamp, payloadTypeOverride: pktPt))
            offset += chunkLen
        }
        return out
    }

    private mutating func makeRtpPacket(
        payload: Data,
        marker: Bool,
        rtpTimestamp: UInt32,
        payloadTypeOverride: UInt8
    ) -> Data {
        let seq = sequenceNumber
        sequenceNumber &+= 1
        var pkt = Data(capacity: 12 + payload.count)
        pkt.append(0x80) // V=2, P=0, X=0, CC=0
        pkt.append((marker ? 0x80 : 0x00) | (payloadTypeOverride & 0x7F))
        pkt.appendVideoBE(seq)
        pkt.appendVideoBE(rtpTimestamp)
        pkt.appendVideoBE(ssrc)
        pkt.append(payload)
        return pkt
    }

    /// Builds a 12-byte RFC 4585 RTCP Picture Loss Indication (`PT = 206` PSFB, `FMT = 1` PLI) packet
    /// requesting an immediate H.264 IDR + SPS/PPS keyframe from the remote peer.
    public static func buildRtcpPliPacket(senderSsrc: UInt32, mediaSsrc: UInt32) -> Data {
        var rtcp = Data(capacity: 12)
        rtcp.append(0x81) // V=2, P=0, FMT=1 (PLI)
        rtcp.append(206)  // PT=206 (PSFB)
        rtcp.appendVideoBE(UInt16(2)) // length = 2 32-bit words minus 1 = 12 bytes total
        rtcp.appendVideoBE(senderSsrc)
        rtcp.appendVideoBE(mediaSsrc)
        return rtcp
    }

    /// Converts a wall-clock `Date` to an RFC 3550 64-bit NTP timestamp (seconds since 1900-01-01 + 32-bit fractional seconds).
    public static func ntpTimestamp(for date: Date = Date()) -> (seconds: UInt32, fraction: UInt32) {
        let unixSeconds = max(0.0, date.timeIntervalSince1970)
        let ntpTotal = unixSeconds + 2_208_988_800.0
        let whole = floor(ntpTotal)
        let sec = UInt32(truncatingIfNeeded: UInt64(whole))
        let frac = UInt32(clamping: UInt64(((ntpTotal - whole) * 4_294_967_296.0).rounded()))
        return (sec, frac)
    }

    /// Builds an RFC 3550 compound RTCP feedback packet (`SR PT=200` when `senderStats != nil` else `RR PT=201`,
    /// optional 24-byte `ZolaRtcpReportBlock`, `SDES PT=202` `CNAME`, and optional Google WebRTC `REMB PT=206 FMT=15`).
    /// Satisfies `libzrtc` `VideoRtpRtcp` (`0x1005f7680`) and Audio RTCP receiver BWE/liveness checks over `:4200`.
    public static func buildCompoundRtcpPacket(
        senderSsrc: UInt32,
        senderStats: ZolaRtcpSenderStats? = nil,
        reportBlock: ZolaRtcpReportBlock? = nil,
        cname: String = "zola",
        rembBitrateBps: UInt64? = nil,
        rembSsrcs: [UInt32] = []
    ) -> Data {
        var out = Data(capacity: 112)
        let rc: UInt8 = reportBlock != nil ? 1 : 0

        if let sr = senderStats {
            let lengthWords = UInt16(6 + (reportBlock != nil ? 6 : 0))
            out.append(0x80 | rc)
            out.append(200) // SR
            out.appendVideoBE(lengthWords)
            out.appendVideoBE(senderSsrc)
            out.appendVideoBE(sr.ntpSeconds)
            out.appendVideoBE(sr.ntpFraction)
            out.appendVideoBE(sr.rtpTimestamp)
            out.appendVideoBE(sr.senderPacketCount)
            out.appendVideoBE(sr.senderOctetCount)
        } else {
            let lengthWords = UInt16(1 + (reportBlock != nil ? 6 : 0))
            out.append(0x80 | rc)
            out.append(201) // RR
            out.appendVideoBE(lengthWords)
            out.appendVideoBE(senderSsrc)
        }

        if let rb = reportBlock {
            out.appendVideoBE(rb.ssrc)
            out.append(rb.fractionLost)
            let clampedLost = max(-0x80_0000, min(0x7F_FFFF, rb.cumulativeLost))
            let lost24 = UInt32(bitPattern: clampedLost) & 0x00FF_FFFF
            out.append(UInt8((lost24 >> 16) & 0xFF))
            out.append(UInt8((lost24 >> 8) & 0xFF))
            out.append(UInt8(lost24 & 0xFF))
            out.appendVideoBE(rb.extendedHighestSequence)
            out.appendVideoBE(rb.interarrivalJitter)
            out.appendVideoBE(rb.lastSrMiddle32)
            out.appendVideoBE(rb.delaySinceLastSr)
        }

        // SDES (PT = 202) with CNAME item (type = 1) padded to 32-bit boundary.
        let cnameBytes = Array(cname.utf8.prefix(255))
        var sdesChunk = Data(capacity: 8 + cnameBytes.count + 4)
        sdesChunk.appendVideoBE(senderSsrc)
        sdesChunk.append(1) // CNAME
        sdesChunk.append(UInt8(cnameBytes.count))
        sdesChunk.append(contentsOf: cnameBytes)
        sdesChunk.append(0) // END item list
        while sdesChunk.count % 4 != 0 {
            sdesChunk.append(0)
        }
        let sdesWords = UInt16((4 + sdesChunk.count) / 4 - 1)
        out.append(0x81) // V=2, P=0, SC=1
        out.append(202)  // SDES
        out.appendVideoBE(sdesWords)
        out.append(sdesChunk)

        // Optional WebRTC REMB (`PT = 206`, `FMT = 15`, `'R','E','M','B'`).
        if let rembBitrateBps {
            let validSsrcs = Array(rembSsrcs.filter { $0 != 0 }.prefix(255))
            var mantissa = rembBitrateBps
            var exp: UInt8 = 0
            while mantissa > 0x3_FFFF && exp < 63 {
                mantissa >>= 1
                exp += 1
            }
            let m18 = UInt32(min(mantissa, 0x3_FFFF))
            let rembWords = UInt16(4 + validSsrcs.count)
            out.append(0x8F) // V=2, P=0, FMT=15
            out.append(206)  // PSFB
            out.appendVideoBE(rembWords)
            out.appendVideoBE(senderSsrc)
            out.appendVideoBE(UInt32(0)) // Media source SSRC = 0 per draft-alvestrand-rmcat-remb-03
            out.append(contentsOf: [0x52, 0x45, 0x4D, 0x42]) // "REMB"
            out.append(UInt8(validSsrcs.count))
            out.append((exp << 2) | UInt8((m18 >> 16) & 0x03))
            out.append(UInt8((m18 >> 8) & 0xFF))
            out.append(UInt8(m18 & 0xFF))
            for ssrc in validSsrcs {
                out.appendVideoBE(ssrc)
            }
        }

        return out
    }
}

/// Sender statistics carried inside an RFC 3550 RTCP Sender Report (`PT = 200`).
public struct ZolaRtcpSenderStats: Sendable, Equatable {
    public var ntpSeconds: UInt32
    public var ntpFraction: UInt32
    public var rtpTimestamp: UInt32
    public var senderPacketCount: UInt32
    public var senderOctetCount: UInt32

    public init(
        ntpSeconds: UInt32,
        ntpFraction: UInt32,
        rtpTimestamp: UInt32,
        senderPacketCount: UInt32,
        senderOctetCount: UInt32
    ) {
        self.ntpSeconds = ntpSeconds
        self.ntpFraction = ntpFraction
        self.rtpTimestamp = rtpTimestamp
        self.senderPacketCount = senderPacketCount
        self.senderOctetCount = senderOctetCount
    }
}

/// 24-byte RFC 3550 §6.4.1 RTCP Receiver Report block.
public struct ZolaRtcpReportBlock: Sendable, Equatable {
    public var ssrc: UInt32
    public var fractionLost: UInt8
    public var cumulativeLost: Int32
    public var extendedHighestSequence: UInt32
    public var interarrivalJitter: UInt32
    public var lastSrMiddle32: UInt32
    public var delaySinceLastSr: UInt32

    public init(
        ssrc: UInt32,
        fractionLost: UInt8,
        cumulativeLost: Int32,
        extendedHighestSequence: UInt32,
        interarrivalJitter: UInt32,
        lastSrMiddle32: UInt32,
        delaySinceLastSr: UInt32
    ) {
        self.ssrc = ssrc
        self.fractionLost = fractionLost
        self.cumulativeLost = cumulativeLost
        self.extendedHighestSequence = extendedHighestSequence
        self.interarrivalJitter = interarrivalJitter
        self.lastSrMiddle32 = lastSrMiddle32
        self.delaySinceLastSr = delaySinceLastSr
    }
}

/// Parsed summary of an inbound compound RTCP datagram (`0x11`/`0x0f` video RTCP or `0x07`/`0x05` audio RTCP).
public struct ZolaParsedRtcpCompound: Sendable, Equatable {
    public var senderSsrc: UInt32?
    public var senderNtpMiddle32: UInt32?
    public var senderRtpTimestamp: UInt32?
    public var reportedFractionLost: UInt8?
    public var requestsKeyframe: Bool
    public var rembBitrateBps: UInt64?
}

/// RFC 3550 Appendix A.1 / A.3 / A.8 RTP receiver stream statistics tracker (`90 kHz` video / `48 kHz` Opus audio).
public struct ZolaRtpReceiverStatsTracker: Sendable {
    public let clockRateHz: UInt32
    public private(set) var ssrc: UInt32 = 0
    public private(set) var initialized = false
    private var baseSeq: UInt16 = 0
    private var maxSeq: UInt16 = 0
    private var cycles: UInt32 = 0
    private var receivedPackets: UInt32 = 0
    private var expectedPrior: UInt32 = 0
    private var receivedPrior: UInt32 = 0
    private var hasTransit = false
    private var lastTransit32: UInt32 = 0
    private var jitterQ4: UInt64 = 0
    private var lastSrMiddle32: UInt32 = 0
    private var lastSrArrivalUptime: TimeInterval = 0
    private var bytesSinceLastReport: Int = 0
    private var lastReportUptime: TimeInterval = 0
    private var recentKeys: [UInt64] = []
    private var recentCursor: Int = 0
    public private(set) var measuredBitrateBps: UInt64 = 0

    public init(clockRateHz: UInt32) {
        self.clockRateHz = max(1, clockRateHz)
    }

    public mutating func reset() {
        ssrc = 0
        initialized = false
        baseSeq = 0
        maxSeq = 0
        cycles = 0
        receivedPackets = 0
        expectedPrior = 0
        receivedPrior = 0
        hasTransit = false
        lastTransit32 = 0
        jitterQ4 = 0
        lastSrMiddle32 = 0
        lastSrArrivalUptime = 0
        bytesSinceLastReport = 0
        lastReportUptime = 0
        recentKeys.removeAll(keepingCapacity: true)
        recentCursor = 0
        measuredBitrateBps = 0
    }

    private mutating func isDuplicate(ssrc pktSsrc: UInt32, seq: UInt16) -> Bool {
        let key = (UInt64(pktSsrc) << 16) | UInt64(seq)
        if recentKeys.contains(key) {
            return true
        }
        if recentKeys.count < 64 {
            recentKeys.append(key)
        } else {
            recentKeys[recentCursor % 64] = key
            recentCursor = (recentCursor + 1) % 64
        }
        return false
    }

    public mutating func recordInboundRtp(
        ssrc pktSsrc: UInt32,
        sequenceNumber seq: UInt16,
        rtpTimestamp: UInt32,
        byteCount: Int,
        arrivalUptime: TimeInterval
    ) {
        guard pktSsrc != 0 else { return }
        if !initialized || pktSsrc != ssrc {
            let keepSrMiddle = (pktSsrc == ssrc) ? lastSrMiddle32 : 0
            let keepSrUptime = (pktSsrc == ssrc) ? lastSrArrivalUptime : 0
            reset()
            _ = isDuplicate(ssrc: pktSsrc, seq: seq)
            ssrc = pktSsrc
            initialized = true
            baseSeq = seq
            maxSeq = seq
            receivedPackets = 1
            bytesSinceLastReport = max(0, byteCount)
            lastReportUptime = arrivalUptime
            lastSrMiddle32 = keepSrMiddle
            lastSrArrivalUptime = keepSrUptime
            let arrivalTicks32 = UInt32(truncatingIfNeeded: Int64((arrivalUptime * Double(clockRateHz)).rounded()))
            lastTransit32 = arrivalTicks32 &- rtpTimestamp
            hasTransit = true
            return
        }

        // Ignore duplicate UDP packets so `receivedPackets` / `cumulativeLost` / `fractionLost` remain exact.
        guard !isDuplicate(ssrc: pktSsrc, seq: seq) else { return }

        let udelta = seq &- maxSeq
        if udelta < 0x8000 {
            if seq < maxSeq {
                cycles &+= 0x0001_0000
            }
            maxSeq = seq
        } else if (0xFF00...0xFFFF).contains(udelta) {
            // Reordered packet within 256 packets behind `maxSeq`: count as received without resetting cycles.
        } else {
            // Stream restart / large jump.
            baseSeq = seq
            maxSeq = seq
            cycles = 0
            receivedPackets = 0
            expectedPrior = 0
            receivedPrior = 0
            hasTransit = false
            jitterQ4 = 0
        }

        receivedPackets &+= 1
        bytesSinceLastReport += max(0, byteCount)

        let arrivalTicks32 = UInt32(truncatingIfNeeded: Int64((arrivalUptime * Double(clockRateHz)).rounded()))
        let transit32 = arrivalTicks32 &- rtpTimestamp
        if hasTransit {
            let d = abs(Int64(Int32(bitPattern: transit32 &- lastTransit32)))
            let currentJitter = Int64(jitterQ4 >> 4)
            let nextJitter = Int64(jitterQ4) + (d - currentJitter)
            jitterQ4 = UInt64(max(0, nextJitter))
        } else {
            hasTransit = true
        }
        lastTransit32 = transit32
    }

    public mutating func recordInboundSenderReport(ntpMiddle32: UInt32, arrivalUptime: TimeInterval) {
        lastSrMiddle32 = ntpMiddle32
        lastSrArrivalUptime = arrivalUptime
    }

    public mutating func buildReportBlock(nowUptime: TimeInterval) -> ZolaRtcpReportBlock? {
        guard initialized, ssrc != 0 else { return nil }
        let extendedMax = cycles &+ UInt32(maxSeq)
        let expected = extendedMax &- UInt32(baseSeq) &+ 1
        let cumLost = Int32(bitPattern: expected) &- Int32(bitPattern: receivedPackets)

        let expectedInterval = expected &- expectedPrior
        expectedPrior = expected
        let receivedInterval = receivedPackets &- receivedPrior
        receivedPrior = receivedPackets
        let lostInterval = Int64(expectedInterval) - Int64(receivedInterval)
        let fractionLost: UInt8
        if expectedInterval == 0 || lostInterval <= 0 {
            fractionLost = 0
        } else {
            fractionLost = UInt8(min(255, (lostInterval * 256) / Int64(expectedInterval)))
        }

        if lastReportUptime > 0 && nowUptime > lastReportUptime {
            let elapsed = nowUptime - lastReportUptime
            if elapsed >= 0.05 {
                measuredBitrateBps = UInt64((Double(bytesSinceLastReport * 8) / elapsed).rounded())
                bytesSinceLastReport = 0
                lastReportUptime = nowUptime
            }
        } else {
            lastReportUptime = nowUptime
        }

        let dlsr: UInt32
        if lastSrMiddle32 != 0 && nowUptime >= lastSrArrivalUptime {
            dlsr = UInt32(clamping: UInt64(((nowUptime - lastSrArrivalUptime) * 65_536.0).rounded()))
        } else {
            dlsr = 0
        }

        return ZolaRtcpReportBlock(
            ssrc: ssrc,
            fractionLost: fractionLost,
            cumulativeLost: cumLost,
            extendedHighestSequence: extendedMax,
            interarrivalJitter: UInt32(truncatingIfNeeded: jitterQ4 >> 4),
            lastSrMiddle32: lastSrMiddle32,
            delaySinceLastSr: dlsr
        )
    }
}

// MARK: - RFC 6184 H.264 RTP Depacketizer & RTCP Feedback Parser

/// Reassembled H.264 video access unit ready for `VTDecompressionSession`.
public struct ZolaH264AssembledAccessUnit: Sendable, Equatable {
    public let rtpTimestamp: UInt32
    public let vclNalUnits: [Data]
    public let sps: Data?
    public let pps: Data?
    public let containsIdr: Bool
}

/// Aggregate receive-stage diagnostics. Never retains payloads or stream identifiers.
struct ZolaH264ReceiveStageCounters: Sendable {
    var sps = 0
    var pps = 0
    var assembled = 0
    var corrupt = 0
    var rejectedFu = 0
    var completedFu = 0
    var nativeAnnexBFrames = 0
}

/// Stateful RFC 6184 H.264 RTP depacketizer supporting Single NAL (`1..23`), STAP-A (`24`), STAP-B (`25`),
/// FU-A (`28`), and FU-B (`29`) with payload-type isolation, optional UDP reorder buffering, and PLI signaling on packet loss.
public struct ZolaH264RtpDepacketizer: Sendable {
    public var expectedPayloadType: UInt8 {
        didSet { acceptedPayloadTypes = Self.defaultAcceptedPayloadTypes(for: expectedPayloadType) }
    }
    public var acceptedPayloadTypes: Set<UInt8>
    public var reorderWindow: Int
    public var maxReorderHoldSeconds: TimeInterval

    public private(set) var latestSps: Data?
    public private(set) var latestPps: Data?
    public private(set) var remoteSsrc: UInt32 = 0
    public private(set) var needsKeyframePli: Bool = false
    public private(set) var reorderedPacketsRecovered: Int = 0
    public private(set) var ignoredForeignPayloadPackets: Int = 0
    private(set) var receiveStageCounters = ZolaH264ReceiveStageCounters()

    private static let maxFuABufferBytes = 2 * 1024 * 1024

    private struct BufferedRtpPacket: Sendable {
        let marker: Bool
        let payloadType: UInt8
        let sequenceNumber: UInt16
        let timestamp: UInt32
        let ssrc: UInt32
        let payload: Data
        let isMediaPayload: Bool
        let arrivalUptime: TimeInterval
    }

    private var fuaBuffer = Data()
    private var fuaActive = false
    private var fuaExpectedSeq: UInt16 = 0
    private var fuaTimestamp: UInt32 = 0
    private var fuaOriginalType: UInt8 = 0

    private var currentFrameNals: [Data] = []
    private var currentFrameTimestamp: UInt32 = 0
    private var hasCurrentFrame = false
    private var currentFrameCorrupted = false
    private var lastReceivedSeq: UInt16?
    private var expectedNextReorderSeq: UInt16?
    private var reorderBuffer: [UInt16: BufferedRtpPacket] = [:]
    private var consecutiveBackwardPackets: Int = 0
    private var lastPacketHadMarker = true
    private var recentKeys: [UInt64] = []
    private var recentCursor: Int = 0

    public init(
        expectedPayloadType: UInt8 = 97,
        acceptedPayloadTypes: Set<UInt8>? = nil,
        reorderWindow: Int = 0,
        maxReorderHoldSeconds: TimeInterval = 0.050
    ) {
        self.expectedPayloadType = expectedPayloadType & 0x7F
        self.acceptedPayloadTypes = acceptedPayloadTypes ?? Self.defaultAcceptedPayloadTypes(for: expectedPayloadType)
        self.reorderWindow = max(0, reorderWindow)
        self.maxReorderHoldSeconds = max(0.005, maxReorderHoldSeconds)
    }

    public static func defaultAcceptedPayloadTypes(for payloadType: UInt8) -> Set<UInt8> {
        [ZolaH264RtpPacketizer.companionDeltaPayloadType(for: payloadType),
         ZolaH264RtpPacketizer.companionKeyframePayloadType(for: payloadType)]
    }

    public mutating func requestPli() {
        needsKeyframePli = true
    }

    public var hasPendingReorderPackets: Bool {
        !reorderBuffer.isEmpty
    }

    public mutating func clearPliFlag() {
        needsKeyframePli = false
    }

    /// Consumes a raw RTP v2 datagram and returns zero or more complete H.264 access units ready for decode.
    public mutating func ingestRtpPacket(
        _ data: Data,
        arrivalUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [ZolaH264AssembledAccessUnit] {
        guard let parsed = Self.parseRtpPacketAllowingEmptyPadding(data) else { return [] }

        // Ignore foreign-SSRC / pre-lock packets whose RTP payload type is NOT negotiated H.264 (e.g. RTX RFC 4588
        // on a secondary SSRC, CN, or stray non-video packets) so they NEVER reset `remoteSsrc`, corrupt `fuaBuffer`,
        // or trigger false PLI storms. Same-SSRC non-H.264 packets (RED/ULPFEC or empty RTP padding probes) pass
        // through as sequence-continuity markers (`isMediaPayload = false`) without touching NAL reassembly!
        let isExpectedPt = acceptedPayloadTypes.contains(parsed.payloadType)
        if !isExpectedPt {
            guard remoteSsrc != 0 && parsed.ssrc == remoteSsrc else {
                ignoredForeignPayloadPackets += 1
                return []
            }
        }
        guard !isDuplicate(ssrc: parsed.ssrc, seq: parsed.sequenceNumber) else { return [] }

        if isExpectedPt && remoteSsrc != 0 && parsed.ssrc != remoteSsrc {
            lastReceivedSeq = nil
            expectedNextReorderSeq = nil
            reorderBuffer.removeAll(keepingCapacity: true)
            consecutiveBackwardPackets = 0
            lastPacketHadMarker = true
            currentFrameCorrupted = false
            hasCurrentFrame = false
            currentFrameNals.removeAll(keepingCapacity: true)
            fuaActive = false
            fuaBuffer.removeAll(keepingCapacity: true)
        }
        if remoteSsrc == 0 && isExpectedPt {
            remoteSsrc = parsed.ssrc
        } else if isExpectedPt {
            remoteSsrc = parsed.ssrc
        }

        let item = BufferedRtpPacket(
            marker: parsed.marker,
            payloadType: parsed.payloadType,
            sequenceNumber: parsed.sequenceNumber,
            timestamp: parsed.timestamp,
            ssrc: parsed.ssrc,
            payload: parsed.payload,
            isMediaPayload: isExpectedPt && !parsed.payload.isEmpty,
            arrivalUptime: arrivalUptime
        )

        guard reorderWindow > 0 else {
            return deliverOrderedPacket(item)
        }

        guard let expectedSeq = expectedNextReorderSeq else {
            expectedNextReorderSeq = item.sequenceNumber &+ 1
            return deliverOrderedPacket(item)
        }

        let delta = item.sequenceNumber &- expectedSeq
        if delta == 0 {
            consecutiveBackwardPackets = 0
            var completed = deliverOrderedPacket(item)
            expectedNextReorderSeq = expectedSeq &+ 1
            completed.append(contentsOf: drainContiguousReorderPackets())
            return completed
        }

        let maxAhead = max(reorderWindow * 4, 64)
        if delta < 0x8000 {
            consecutiveBackwardPackets = 0
            if Int(delta) <= maxAhead {
                if reorderBuffer[item.sequenceNumber] == nil {
                    reorderBuffer[item.sequenceNumber] = item
                }
                var completed: [ZolaH264AssembledAccessUnit] = []
                while shouldForceAdvanceReorderBuffer(nowUptime: arrivalUptime) {
                    completed.append(contentsOf: advanceReorderBufferPastOldestGap())
                }
                return completed
            } else {
                // Stream sequence jump beyond reorder horizon: flush queued packets in order, then reset base & deliver.
                var completed: [ZolaH264AssembledAccessUnit] = []
                while !reorderBuffer.isEmpty {
                    completed.append(contentsOf: advanceReorderBufferPastOldestGap())
                }
                resetStreamContinuityForSequenceRestart()
                expectedNextReorderSeq = item.sequenceNumber &+ 1
                completed.append(contentsOf: deliverOrderedPacket(item))
                return completed
            }
        }

        // `delta >= 0x8000`: distinguish genuinely late stragglers (`<= maxLateBehind` and `< 8` consecutive)
        // from a same-SSRC backward sequence restart so video never freezes waiting ~32k packets!
        let behindDistance = 0 &- delta
        let maxLateBehind = UInt16(min(1_024, max(reorderWindow * 8, 128)))
        if behindDistance <= maxLateBehind && consecutiveBackwardPackets < 8 {
            consecutiveBackwardPackets += 1
            return []
        }

        consecutiveBackwardPackets = 0
        var completed: [ZolaH264AssembledAccessUnit] = []
        while !reorderBuffer.isEmpty {
            completed.append(contentsOf: advanceReorderBufferPastOldestGap())
        }
        resetStreamContinuityForSequenceRestart()
        expectedNextReorderSeq = item.sequenceNumber &+ 1
        completed.append(contentsOf: deliverOrderedPacket(item))
        return completed
    }

    private mutating func resetStreamContinuityForSequenceRestart() {
        lastReceivedSeq = nil
        lastPacketHadMarker = true
        currentFrameCorrupted = false
        hasCurrentFrame = false
        currentFrameNals.removeAll(keepingCapacity: true)
        fuaActive = false
        fuaBuffer.removeAll(keepingCapacity: true)
        needsKeyframePli = true
    }

    /// Flushes any buffered out-of-order RTP packets whose hold duration has reached `maxReorderHoldSeconds`
    /// so genuine tail packet loss never stalls subsequent frames when traffic pauses.
    public mutating func flushExpiredReorderBuffer(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [ZolaH264AssembledAccessUnit] {
        guard !reorderBuffer.isEmpty else { return [] }
        var completed: [ZolaH264AssembledAccessUnit] = []
        while shouldForceAdvanceReorderBuffer(nowUptime: nowUptime) {
            completed.append(contentsOf: advanceReorderBufferPastOldestGap())
        }
        return completed
    }

    private func shouldForceAdvanceReorderBuffer(nowUptime: TimeInterval) -> Bool {
        guard !reorderBuffer.isEmpty else { return false }
        if reorderBuffer.count > reorderWindow {
            return true
        }
        for (_, pkt) in reorderBuffer {
            if (nowUptime - pkt.arrivalUptime) >= maxReorderHoldSeconds {
                return true
            }
        }
        return false
    }

    private mutating func advanceReorderBufferPastOldestGap() -> [ZolaH264AssembledAccessUnit] {
        guard let baseSeq = expectedNextReorderSeq, !reorderBuffer.isEmpty else { return [] }
        let earliestKey = reorderBuffer.keys.min { a, b in
            (a &- baseSeq) < (b &- baseSeq)
        }
        guard let nextSeq = earliestKey, let firstPkt = reorderBuffer.removeValue(forKey: nextSeq) else {
            return []
        }
        var completed = deliverOrderedPacket(firstPkt)
        expectedNextReorderSeq = nextSeq &+ 1
        completed.append(contentsOf: drainContiguousReorderPackets())
        return completed
    }

    private mutating func drainContiguousReorderPackets() -> [ZolaH264AssembledAccessUnit] {
        var completed: [ZolaH264AssembledAccessUnit] = []
        while let expected = expectedNextReorderSeq,
              let next = reorderBuffer.removeValue(forKey: expected)
        {
            reorderedPacketsRecovered += 1
            completed.append(contentsOf: deliverOrderedPacket(next))
            expectedNextReorderSeq = expected &+ 1
        }
        return completed
    }

    private mutating func deliverOrderedPacket(_ parsed: BufferedRtpPacket) -> [ZolaH264AssembledAccessUnit] {
        var seqGap = false
        if let prevSeq = lastReceivedSeq {
            if parsed.sequenceNumber != (prevSeq &+ 1) {
                seqGap = true
                needsKeyframePli = true
            }
        }
        lastReceivedSeq = parsed.sequenceNumber

        if seqGap && hasCurrentFrame {
            if parsed.timestamp == currentFrameTimestamp || !lastPacketHadMarker {
                currentFrameCorrupted = true
            }
        }

        // Empty RTP padding (`P=1`) or same-SSRC FEC/RED (`PT != expectedPayloadType`) advances `lastReceivedSeq`
        // cleanly without flushing `currentFrameTimestamp` or aborting an in-progress FU-A slice!
        guard parsed.isMediaPayload else {
            if seqGap && fuaActive {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
            } else if fuaActive {
                // Continuity-only packets consume a sequence number too. Keep the
                // FU-A cursor aligned so the next real fragment is not treated as lost.
                fuaExpectedSeq = parsed.sequenceNumber &+ 1
            }
            return []
        }

        var completed: [ZolaH264AssembledAccessUnit] = []
        if hasCurrentFrame && parsed.timestamp != currentFrameTimestamp {
            if let flushed = flushCurrentFrame() {
                completed.append(flushed)
            }
            if fuaActive {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                needsKeyframePli = true
            }
        }

        let payload = parsed.payload
        guard !payload.isEmpty else {
            lastPacketHadMarker = parsed.marker
            return completed
        }
        let firstByte = payload[payload.startIndex]
        let nalType = firstByte & 0x1F

        switch nalType {
        case 0:
            // Native mode0 can send a small complete Annex-B frame without FU wrapping.
            if fuaActive {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                needsKeyframePli = true
            }
            recordNativeAnnexBFrame(payload, timestamp: parsed.timestamp)
        case 1...23:
            if fuaActive {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                needsKeyframePli = true
            }
            if seqGap && (1...4).contains(nalType) {
                // Single-NAL non-IDR arriving immediately after an RTP sequence gap may be missing an earlier slice or reference frame.
                currentFrameCorrupted = true
            }
            recordCompleteNal(payload, timestamp: parsed.timestamp)

        case 24, 25: // STAP-A (24) / STAP-B (25)
            if fuaActive {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                needsKeyframePli = true
            }
            var offset = payload.startIndex + (nalType == 25 ? 3 : 1)
            while offset + 2 <= payload.endIndex {
                let naluLen = (Int(payload[offset]) << 8) | Int(payload[offset + 1])
                offset += 2
                guard naluLen > 0, offset + naluLen <= payload.endIndex else { break }
                let subNal = payload.subdata(in: offset..<(offset + naluLen))
                recordCompleteNal(subNal, timestamp: parsed.timestamp)
                offset += naluLen
            }

        case 28, 29: // FU-A (28) / FU-B (29)
            let headerLen = (nalType == 29) ? 4 : 2
            guard payload.count > headerLen else {
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                lastPacketHadMarker = parsed.marker
                return completed
            }
            let fuHeader = payload[payload.startIndex + 1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let origType = fuHeader & 0x1F
            let reconstructedHeader = (firstByte & 0xE0) | origType
            let fragment = payload.subdata(in: (payload.startIndex + headerLen)..<payload.endIndex)

            if isStart {
                if fuaActive {
                    needsKeyframePli = true
                }
                fuaBuffer.removeAll(keepingCapacity: true)
                guard 1 + fragment.count <= Self.maxFuABufferBytes else {
                    fuaActive = false
                    needsKeyframePli = true
                    lastPacketHadMarker = parsed.marker
                    return completed
                }
                // Zalo native mode0 fragments the whole Annex-B access unit with
                // FU originalType0, retaining its start code. There is no NAL header
                // to reconstruct here (native261002:0x1004da29c/0x1004daa74).
                if origType != 0 { fuaBuffer.append(reconstructedHeader) }
                fuaOriginalType = origType
                fuaBuffer.append(fragment)
                fuaActive = true
                fuaExpectedSeq = parsed.sequenceNumber &+ 1
                fuaTimestamp = parsed.timestamp
                if isEnd {
                    let fullNal = fuaBuffer
                    fuaBuffer.removeAll(keepingCapacity: true)
                    fuaActive = false
                    recordCompleteFu(fullNal, timestamp: parsed.timestamp)
                }
            } else if fuaActive && parsed.sequenceNumber == fuaExpectedSeq && parsed.timestamp == fuaTimestamp && origType == fuaOriginalType {
                guard fuaBuffer.count + fragment.count <= Self.maxFuABufferBytes else {
                    fuaActive = false
                    fuaBuffer.removeAll(keepingCapacity: true)
                    currentFrameCorrupted = true
                    needsKeyframePli = true
                    lastPacketHadMarker = parsed.marker
                    return completed
                }
                fuaBuffer.append(fragment)
                fuaExpectedSeq = parsed.sequenceNumber &+ 1
                if isEnd {
                    let fullNal = fuaBuffer
                    fuaBuffer.removeAll(keepingCapacity: true)
                    fuaActive = false
                    recordCompleteFu(fullNal, timestamp: parsed.timestamp)
                }
            } else {
                // Lost fragment mid-NAL: drop corrupt slice and request IDR via RTCP PLI.
                receiveStageCounters.rejectedFu += 1
                fuaActive = false
                fuaBuffer.removeAll(keepingCapacity: true)
                currentFrameCorrupted = true
                needsKeyframePli = true
            }

        default:
            break
        }

        lastPacketHadMarker = parsed.marker
        if parsed.marker, let flushed = flushCurrentFrame() {
            completed.append(flushed)
        }
        return completed
    }

    private mutating func recordCompleteFu(_ bytes: Data, timestamp: UInt32) {
        receiveStageCounters.completedFu += 1
        if fuaOriginalType == 0 {
            recordNativeAnnexBFrame(bytes, timestamp: timestamp)
        } else {
            recordCompleteNal(bytes, timestamp: timestamp)
        }
    }

    /// Validate the entire native mode0 AU before accepting any parameter sets.
    /// Never scan arbitrary opaque bytes for a plausible H.264 header: an Annex-B
    /// prefix is required at offset0, each NAL must be valid, and sizes are bounded.
    private mutating func recordNativeAnnexBFrame(_ bytes: Data, timestamp: UInt32) {
        guard let nals = Self.nativeAnnexBNals(bytes) else {
            receiveStageCounters.corrupt += 1
            currentFrameCorrupted = true
            needsKeyframePli = true
            return
        }
        receiveStageCounters.nativeAnnexBFrames += 1
        for nal in nals { recordCompleteNal(nal, timestamp: timestamp) }
    }

    private static func nativeAnnexBNals(_ data: Data) -> [Data]? {
        guard data.count <= maxFuABufferBytes else { return nil }
        let bytes = [UInt8](data)
        func prefixLength(at i: Int) -> Int {
            guard i + 2 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0 else { return 0 }
            if bytes[i + 2] == 1 { return 3 }
            if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { return 4 }
            return 0
        }
        let firstPrefix = prefixLength(at: 0)
        guard firstPrefix > 0 else { return nil }
        var start = firstPrefix
        var cursor = start
        var nals: [Data] = []
        func appendNal(endingAt end: Int) -> Bool {
            var end = end
            // Annex-B trailing_zero_8bits do not belong to the NAL payload.
            while end > start && bytes[end - 1] == 0 { end -= 1 }
            guard start < end, nals.count < 256 else { return false }
            let header = bytes[start]
            guard header & 0x80 == 0, (1...23).contains(header & 0x1F) else { return false }
            nals.append(Data(bytes[start..<end]))
            return true
        }
        while cursor < bytes.count {
            let length = prefixLength(at: cursor)
            if length > 0 {
                guard appendNal(endingAt: cursor) else { return nil }
                start = cursor + length
                cursor = start
            } else {
                cursor += 1
            }
        }
        guard appendNal(endingAt: bytes.count) else { return nil }
        return nals
    }

    private mutating func recordCompleteNal(_ rawNal: Data, timestamp: UInt32) {
        let nal = ZolaH264RtpPacketizer.stripAnnexBStartCode(rawNal)
        guard !nal.isEmpty else { return }
        let t = nal[nal.startIndex] & 0x1F
        switch t {
        case 7:
            receiveStageCounters.sps += 1
            latestSps = nal
        case 8:
            receiveStageCounters.pps += 1
            latestPps = nal
        case 1, 2, 3, 4, 5, 6:
            if !hasCurrentFrame {
                hasCurrentFrame = true
                currentFrameTimestamp = timestamp
            }
            currentFrameNals.append(nal)
        default:
            break
        }
    }

    private mutating func flushCurrentFrame() -> ZolaH264AssembledAccessUnit? {
        guard hasCurrentFrame else {
            currentFrameCorrupted = false
            return nil
        }
        hasCurrentFrame = false
        let wasCorrupted = currentFrameCorrupted
        currentFrameCorrupted = false
        let nals = currentFrameNals
        currentFrameNals.removeAll(keepingCapacity: true)
        if wasCorrupted {
            receiveStageCounters.corrupt += 1
            needsKeyframePli = true
            return nil
        }
        let vcl = nals.filter { nal in
            guard let b = nal.first else { return false }
            let t = b & 0x1F
            return t == 1 || t == 5
        }
        guard !vcl.isEmpty else { return nil }
        let hasIdr = vcl.contains { ($0[$0.startIndex] & 0x1F) == 5 }
        if latestSps == nil || latestPps == nil {
            needsKeyframePli = true
        }
        receiveStageCounters.assembled += 1
        return ZolaH264AssembledAccessUnit(
            rtpTimestamp: currentFrameTimestamp,
            vclNalUnits: nals,
            sps: latestSps,
            pps: latestPps,
            containsIdr: hasIdr
        )
    }

    private mutating func isDuplicate(ssrc: UInt32, seq: UInt16) -> Bool {
        let key = (UInt64(ssrc) << 16) | UInt64(seq)
        if recentKeys.contains(key) {
            return true
        }
        if recentKeys.count < 128 {
            recentKeys.append(key)
        } else {
            recentKeys[recentCursor % 128] = key
            recentCursor = (recentCursor + 1) % 128
        }
        return false
    }

    /// Parses a minimal RTP v2 header (with CSRC & RFC 3550 extension header skipping), requiring a non-empty media payload.
    public static func parseRtpPacket(_ data: Data) -> (
        marker: Bool,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    )? {
        guard let parsed = parseRtpPacketInternal(data, allowEmptyPaddedPayload: false) else { return nil }
        return parsed
    }

    /// Parses an RTP v2 packet including valid RFC 3550 padding-only BWE probe packets (`P = 1`, `payload.isEmpty == true`),
    /// while still rejecting malformed `padLen == 0` or truncated headers.
    public static func parseRtpPacketAllowingEmptyPadding(_ data: Data) -> (
        marker: Bool,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    )? {
        parseRtpPacketInternal(data, allowEmptyPaddedPayload: true)
    }

    private static func parseRtpPacketInternal(
        _ data: Data,
        allowEmptyPaddedPayload: Bool
    ) -> (
        marker: Bool,
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        payload: Data
    )? {
        guard data.count >= 12 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        guard (b0 >> 6) == 2 else { return nil }
        // Exclude RFC 5761 RTCP-mux packets (`192...223`).
        if (192...223).contains(b1) { return nil }
        let hasPadding = (b0 & 0x20) != 0
        let hasExtension = (b0 & 0x10) != 0
        let csrcCount = Int(b0 & 0x0F)
        let marker = (b1 & 0x80) != 0
        let pt = b1 & 0x7F
        let seq = (UInt16(data[data.startIndex + 2]) << 8) | UInt16(data[data.startIndex + 3])
        let ts = (UInt32(data[data.startIndex + 4]) << 24)
            | (UInt32(data[data.startIndex + 5]) << 16)
            | (UInt32(data[data.startIndex + 6]) << 8)
            | UInt32(data[data.startIndex + 7])
        let ssrc = (UInt32(data[data.startIndex + 8]) << 24)
            | (UInt32(data[data.startIndex + 9]) << 16)
            | (UInt32(data[data.startIndex + 10]) << 8)
            | UInt32(data[data.startIndex + 11])

        var offset = 12 + csrcCount * 4
        guard data.count >= offset else { return nil }
        if hasExtension {
            guard data.count >= offset + 4 else { return nil }
            let extWords = (Int(data[data.startIndex + offset + 2]) << 8) | Int(data[data.startIndex + offset + 3])
            offset += 4 + extWords * 4
            guard data.count >= offset else { return nil }
        }
        var endOffset = data.count
        if hasPadding {
            guard endOffset > offset else { return nil }
            let padLen = Int(data[data.startIndex + endOffset - 1])
            guard padLen > 0, endOffset - padLen >= offset else { return nil }
            endOffset -= padLen
            if allowEmptyPaddedPayload && endOffset == offset {
                return (marker, pt, seq, ts, ssrc, Data())
            }
        }
        guard endOffset > offset else { return nil }
        let payload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + endOffset))
        return (marker, pt, seq, ts, ssrc, payload)
    }

    /// Parses an inbound compound RTCP datagram (`SR=200`, `RR=201`, `PLI/SLI/FIR`, `REMB`).
    public static func parseInboundRtcpCompound(_ rtcp: Data) -> ZolaParsedRtcpCompound {
        var result = ZolaParsedRtcpCompound(
            senderSsrc: nil,
            senderNtpMiddle32: nil,
            senderRtpTimestamp: nil,
            reportedFractionLost: nil,
            requestsKeyframe: false,
            rembBitrateBps: nil
        )
        var offset = rtcp.startIndex
        while offset + 4 <= rtcp.endIndex {
            let b0 = rtcp[offset]
            guard (b0 >> 6) == 2 else { break }
            let rcOrFmt = b0 & 0x1F
            let pt = rtcp[offset + 1]
            let words = (Int(rtcp[offset + 2]) << 8) | Int(rtcp[offset + 3])
            let pktBytes = (words + 1) * 4
            guard pktBytes >= 4, offset + pktBytes <= rtcp.endIndex else { break }

            if pt == 192 {
                result.requestsKeyframe = true
            } else if pt == 200 && pktBytes >= 28 {
                let ssrc = rtcp.readVideoBE32(at: offset + 4)
                let ntpMid = rtcp.readVideoBE32(at: offset + 10)
                let rtpTs = rtcp.readVideoBE32(at: offset + 16)
                result.senderSsrc = ssrc
                result.senderNtpMiddle32 = ntpMid
                result.senderRtpTimestamp = rtpTs
                if rcOrFmt >= 1 && pktBytes >= 52 {
                    result.reportedFractionLost = rtcp[offset + 32]
                }
            } else if pt == 201 && pktBytes >= 8 {
                if result.senderSsrc == nil {
                    result.senderSsrc = rtcp.readVideoBE32(at: offset + 4)
                }
                if rcOrFmt >= 1 && pktBytes >= 32 {
                    result.reportedFractionLost = rtcp[offset + 12]
                }
            } else if pt == 206 {
                if rcOrFmt == 1 || rcOrFmt == 2 || rcOrFmt == 4 {
                    result.requestsKeyframe = true
                } else if rcOrFmt == 15 && pktBytes >= 20,
                          rtcp[offset + 12] == 0x52,
                          rtcp[offset + 13] == 0x45,
                          rtcp[offset + 14] == 0x4D,
                          rtcp[offset + 15] == 0x42
                {
                    let b17 = rtcp[offset + 17]
                    let b18 = rtcp[offset + 18]
                    let b19 = rtcp[offset + 19]
                    let exp = UInt64(b17 >> 2)
                    let mantissa = (UInt64(b17 & 0x03) << 16) | (UInt64(b18) << 8) | UInt64(b19)
                    if exp < 64 {
                        let shifted = exp >= 46 ? UInt64.max : (mantissa << exp)
                        result.rembBitrateBps = shifted
                    }
                }
            }
            offset += pktBytes
        }
        return result
    }

    /// Returns `true` if a compound RTCP packet contains a PLI (`PT=206, FMT=1`), FIR (`PT=206, FMT=4` / `PT=192`), or SLI (`PT=206, FMT=2`).
    public static func isInboundKeyframeRequestRtcp(_ rtcp: Data) -> Bool {
        parseInboundRtcpCompound(rtcp).requestsKeyframe
    }
}

// MARK: - Hardware `VideoToolbox` H.264 + `AVCaptureSession` Engine

/// Hardware-accelerated H.264 encode/decode + camera capture engine paired with `ZolaVoipMediaEngine`.
final class ZolaVoipVideoEngine: NSObject, @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Void>()
    private let videoQueue = DispatchQueue(label: "com.zolakit.voip.video", qos: .userInteractive)
    private let captureQueue = DispatchQueue(label: "com.zolakit.voip.camera", qos: .userInitiated)

    let videoSsrc: UInt32
    var onOutboundVideoPacket: (@Sendable (_ payload: Data, _ isRtcp: Bool) -> Void)?
    private let callbackLock = NSLock()
    private var _onRemoteVideoFrame: (@Sendable (CGImage) -> Void)?
    private var _onLocalVideoFrame: (@Sendable (CGImage?) -> Void)?

    var onRemoteVideoFrame: (@Sendable (CGImage) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onRemoteVideoFrame
        }
        set {
            callbackLock.lock()
            _onRemoteVideoFrame = newValue
            callbackLock.unlock()
        }
    }

    var onLocalVideoFrame: (@Sendable (CGImage?) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onLocalVideoFrame
        }
        set {
            callbackLock.lock()
            _onLocalVideoFrame = newValue
            callbackLock.unlock()
        }
    }

    private var _onRemoteVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    private var _onLocalVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    var onRemoteVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onRemoteVideoPixelBuffer
        }
        set {
            callbackLock.lock()
            _onRemoteVideoPixelBuffer = newValue
            callbackLock.unlock()
        }
    }

    var onLocalVideoPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onLocalVideoPixelBuffer
        }
        set {
            callbackLock.lock()
            _onLocalVideoPixelBuffer = newValue
            callbackLock.unlock()
        }
    }

    #if canImport(CoreImage)
    private static let previewContext = CIContext(options: [.cacheIntermediates: false])
    #endif

    static func makeVideoImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        #if canImport(CoreImage)
        if image == nil {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            image = previewContext.createCGImage(ciImage, from: ciImage.extent)
        }
        #endif
        return image
    }

    var currentUsingFrontCamera: Bool {
        currentDesiredCaptureState().preferFront
    }

    private var packetizer: ZolaH264RtpPacketizer
    private var depacketizer: ZolaH264RtpDepacketizer
    private var rxStats = ZolaRtpReceiverStatsTracker(clockRateHz: 90_000)
    private var rtcpTimer: DispatchSourceTimer?
    private var rtcpTickCounter: UInt64 = 0
    private var txPacketCount: UInt32 = 0
    private var txOctetCount: UInt32 = 0
    private var lastTxRtpTimestamp: UInt32 = 0
    private var targetEncoderBitrateBps: Int = 480_000

    private var isRunning = false
    private(set) var isCameraEnabled = true
    private(set) var isUsingFrontCamera = true
    private(set) var decodedFrameCount: Int = 0
    private(set) var encodedPacketCount: Int = 0

    private var compressionSession: VTCompressionSession?
    private var encoderWidth: Int32 = 0
    private var encoderHeight: Int32 = 0
    private var forceNextKeyframe = true
    private var lastCapturedEncodeUptime: TimeInterval = 0
    private var syntheticFrameCounter: Int64 = 0

    private var decompressionSession: VTDecompressionSession?
    private var decoderFormatDesc: CMVideoFormatDescription?
    private var activeDecoderSps = Data()
    private var activeDecoderPps = Data()
    private var hasDecodedAnyFrame = false
    private var keyframeDecodePending = false
    private var pendingDecoderUnits: [ZolaH264AssembledAccessUnit] = []
    private var decoderGeneration: UInt64 = 0
    private var lastPliSentUptime: TimeInterval = 0

    private let captureStateLock = NSLock()
    /// Call-log counters, touched from the capture, video and VideoToolbox callback queues.
    private let statsLock = NSLock()
    private var statCaptureFrames = 0
    private var statEncodedFrames = 0
    private var statEncodeErrors = 0
    private var statCaptureStartFailures = 0
    private var statInterruptions = 0
    private var statRuntimeErrors = 0
    private var statDecodedFrames = 0
    private var statDecodeErrors = 0
    private var statPliSent = 0
    private var statPliRecv = 0
    private var statKeyframesTx = 0
    private var statKeyframesRx = 0
    private var statRtcpSent = 0
    private var statRtcpRecv = 0
    private var statReordered = 0
    private var statInboundByPt: [UInt8: Int] = [:]
    private var statInboundByNal: [UInt8: Int] = [:]
    private var statReceiveStages = ZolaH264ReceiveStageCounters()
    private var statMissingParameterSets = 0
    private var statWaitingForIdr = 0
    private var statDecoderSubmissions = 0
    private var statLastDecoderStatus: OSStatus = 0
    private var statLastDecoderFailureStage = "none"
    private var captureObservers: [NSObjectProtocol] = []
    private var desiredCaptureActive = false
    private var desiredPreferFront = true

    // Confined strictly to `captureQueue`:
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?

    init(callId: Int32, payloadType: UInt8 = 97) {
        let rawSsrc = UInt32(bitPattern: callId) ^ 0x5649_4430
        let resolvedSsrc = rawSsrc == 0 ? 0x5649_4431 : rawSsrc
        let cleanPt = ZolaH264RtpPacketizer.companionDeltaPayloadType(for: payloadType & 0x7F)
        self.videoSsrc = resolvedSsrc
        self.packetizer = ZolaH264RtpPacketizer(ssrc: resolvedSsrc, payloadType: cleanPt)
        self.depacketizer = ZolaH264RtpDepacketizer(
            expectedPayloadType: cleanPt,
            reorderWindow: 16,
            maxReorderHoldSeconds: 0.050
        )
        super.init()
        self.videoQueue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        rtcpTimer?.cancel()
        if let comp = compressionSession {
            VTCompressionSessionInvalidate(comp)
        }
        if let decomp = decompressionSession {
            VTDecompressionSessionInvalidate(decomp)
        }
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
    }

    func setPayloadType(_ pt: UInt8) {
        performOnVideoQueueSync {
            let deltaPt = ZolaH264RtpPacketizer.companionDeltaPayloadType(for: pt & 0x7F)
            let keyPt = ZolaH264RtpPacketizer.companionKeyframePayloadType(for: deltaPt)
            self.packetizer.payloadType = deltaPt
            self.packetizer.keyframePayloadType = keyPt
            self.depacketizer.expectedPayloadType = deltaPt
            self.depacketizer.acceptedPayloadTypes = [deltaPt, keyPt]
        }
    }

    var currentPayloadType: UInt8 {
        performOnVideoQueueSync { packetizer.payloadType }
    }

    var currentDecodedFrameCount: Int {
        performOnVideoQueueSync { decodedFrameCount }
    }

    func start(cameraEnabled: Bool = true) {
        performOnVideoQueueSync {
            self.isCameraEnabled = cameraEnabled
            if !self.isRunning {
                self.isRunning = true
            }
            self.forceNextKeyframe = true
            self.startRtcpTimerOnVideoQueue()
            self.sendPeriodicCompoundRtcpOnVideoQueue()
            if self.depacketizer.remoteSsrc != 0 && !self.hasDecodedAnyFrame {
                self.sendPliIfNeededOnVideoQueue(force: true)
            }
            self.updateCaptureStateAsync()
        }
    }

    func ensureDecoderRunning() {
        performOnVideoQueueSync {
            let wasRunning = self.isRunning
            if !self.isRunning {
                self.isRunning = true
                self.forceNextKeyframe = true
            }
            self.startRtcpTimerOnVideoQueue()
            if !wasRunning {
                self.sendPeriodicCompoundRtcpOnVideoQueue()
            }
        }
    }

    /// Invoked by `ZolaVoipMediaEngine` the instant `:4200` `InitZRTP` (`0x02` `retCode=0`) confirms the relay `CallToken`,
    /// forcing a fresh H.264 SPS+PPS+IDR keyframe and an immediate compound RTCP (`SR`/`RR` + `SDES` + `REMB`) report.
    func noteTransportReady(hadDroppedPreHandshakePackets: Bool) {
        videoQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.forceNextKeyframe = true
            if hadDroppedPreHandshakePackets || self.depacketizer.remoteSsrc != 0 {
                self.sendPliIfNeededOnVideoQueue(force: true)
            }
            self.sendPeriodicCompoundRtcpOnVideoQueue()
        }
    }

    func stop() {
        performOnVideoQueueSync {
            self.stopOnVideoQueue(synchronousCaptureTeardown: true)
        }
    }

    func stopAsync() {
        // Capture `self` strongly for the teardown hop so `videoEngine?.stopAsync(); videoEngine = nil`
        // always invalidates VideoToolbox sessions on `videoQueue` and stops `AVCaptureSession` on `captureQueue`.
        videoQueue.async {
            self.stopOnVideoQueue(synchronousCaptureTeardown: false)
        }
    }

    private func stopOnVideoQueue(synchronousCaptureTeardown: Bool) {
        isRunning = false
        rtcpTimer?.cancel()
        rtcpTimer = nil
        rtcpTickCounter = 0
        setDesiredCaptureState(active: false, preferFront: isUsingFrontCamera)
        teardownEncoderOnVideoQueue()
        teardownDecoderOnVideoQueue()
        let activePt = packetizer.payloadType
        depacketizer = ZolaH264RtpDepacketizer(
            expectedPayloadType: activePt,
            reorderWindow: 16,
            maxReorderHoldSeconds: 0.050
        )
        rxStats.reset()
        txPacketCount = 0
        txOctetCount = 0
        lastTxRtpTimestamp = 0
        hasDecodedAnyFrame = false
        if synchronousCaptureTeardown {
            captureQueue.sync {
                self.teardownCaptureSessionOnCaptureQueue()
            }
        } else {
            captureQueue.async {
                self.teardownCaptureSessionOnCaptureQueue()
            }
        }
    }

    func setCameraEnabled(_ enabled: Bool) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.isCameraEnabled = enabled
            if enabled {
                self.forceNextKeyframe = true
            } else {
                self.onLocalVideoFrame?(nil)
            }
            self.updateCaptureStateAsync()
        }
    }

    @discardableResult
    func flipCamera() -> Bool {
        performOnVideoQueueSync {
            self.isUsingFrontCamera.toggle()
            self.forceNextKeyframe = true
            let useFront = self.isUsingFrontCamera
            self.setDesiredCaptureState(active: self.isRunning && self.isCameraEnabled, preferFront: useFront)
            self.reconfigureCaptureDeviceAsync(preferFront: useFront)
            return useFront
        }
    }

    func setPreferFrontCamera(_ preferFront: Bool) {
        performOnVideoQueueSync {
            guard self.isUsingFrontCamera != preferFront else { return }
            self.isUsingFrontCamera = preferFront
            self.forceNextKeyframe = true
            self.setDesiredCaptureState(active: self.isRunning && self.isCameraEnabled, preferFront: preferFront)
            self.reconfigureCaptureDeviceAsync(preferFront: preferFront)
        }
    }

    func requestRemoteKeyframe() {
        videoQueue.async { [weak self] in
            self?.sendPliIfNeededOnVideoQueue(force: true)
        }
    }

    // MARK: - Inbound Video RTP / RTCP & Periodic Compound RTCP (`SR`/`RR` + `SDES` + `REMB`)

    private func startRtcpTimerOnVideoQueue() {
        guard rtcpTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        // 50ms tick flushes expired UDP reorder gaps promptly; every 20th tick (1.0s) emits RFC 3550 compound RTCP!
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.depacketizer.hasPendingReorderPackets {
                let prevRecovered = self.depacketizer.reorderedPacketsRecovered
                let flushedUnits = self.depacketizer.flushExpiredReorderBuffer(nowUptime: now)
                self.bumpStat { $0.statReceiveStages = self.depacketizer.receiveStageCounters }
                let deltaRecovered = self.depacketizer.reorderedPacketsRecovered - prevRecovered
                if deltaRecovered > 0 {
                    self.bumpStat { $0.statReordered += deltaRecovered }
                }
                if self.depacketizer.needsKeyframePli {
                    self.depacketizer.clearPliFlag()
                    self.sendPliIfNeededOnVideoQueue(force: false)
                }
                for unit in flushedUnits {
                    self.decodeAccessUnitOnVideoQueue(unit)
                }
            }
            self.rtcpTickCounter &+= 1
            if self.rtcpTickCounter % 20 == 0 {
                self.sendPeriodicCompoundRtcpOnVideoQueue()
            }
        }
        rtcpTimer = timer
        timer.resume()
    }

    private func sendPeriodicCompoundRtcpOnVideoQueue() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let reportBlock = rxStats.buildReportBlock(nowUptime: now)
        let senderStats: ZolaRtcpSenderStats?
        if txPacketCount > 0 {
            let ntp = ZolaH264RtpPacketizer.ntpTimestamp()
            senderStats = ZolaRtcpSenderStats(
                ntpSeconds: ntp.seconds,
                ntpFraction: ntp.fraction,
                rtpTimestamp: lastTxRtpTimestamp,
                senderPacketCount: txPacketCount,
                senderOctetCount: txOctetCount
            )
        } else {
            senderStats = nil
        }

        // Adaptive REMB (`PT=206, FMT=15`): start at 850 kbps (well above `libzrtc` BWE video suspension threshold
        // `0x1005f7c08` while staying smooth on mobile networks), scaling up to 1.5 Mbps with measured throughput
        // and gently backing off if `fractionLost > 25` (~10% loss).
        var rembBps: UInt64 = 850_000
        let measured = rxStats.measuredBitrateBps
        if measured > 0 {
            let headroom = UInt64((Double(measured) * 1.35).rounded())
            rembBps = min(1_500_000, max(850_000, headroom))
        }
        if let rb = reportBlock, rb.fractionLost > 25 {
            let scale = Double(256 - Int(rb.fractionLost)) / 256.0
            rembBps = max(350_000, UInt64((Double(rembBps) * scale).rounded()))
        }

        let targetSsrcs = depacketizer.remoteSsrc != 0 ? [depacketizer.remoteSsrc] : []
        let compound = ZolaH264RtpPacketizer.buildCompoundRtcpPacket(
            senderSsrc: videoSsrc,
            senderStats: senderStats,
            reportBlock: reportBlock,
            cname: "zola\(videoSsrc)",
            rembBitrateBps: rembBps,
            rembSsrcs: targetSsrcs
        )
        bumpStat { $0.statRtcpSent += 1 }
        onOutboundVideoPacket?(compound, true)
    }

    func handleInboundVideoPacket(_ payload: Data, isRtcp: Bool) {
        videoQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if isRtcp {
                self.bumpStat { $0.statRtcpRecv += 1 }
                let parsedRtcp = ZolaH264RtpDepacketizer.parseInboundRtcpCompound(payload)
                if let ntpMid = parsedRtcp.senderNtpMiddle32 {
                    self.rxStats.recordInboundSenderReport(ntpMiddle32: ntpMid, arrivalUptime: now)
                }
                if parsedRtcp.requestsKeyframe {
                    self.bumpStat { $0.statPliRecv += 1 }
                    self.forceNextKeyframe = true
                }
                if let peerRemb = parsedRtcp.rembBitrateBps, peerRemb > 0 {
                    let clamped = Int(min(650_000, max(180_000, peerRemb)))
                    if abs(clamped - self.targetEncoderBitrateBps) >= 40_000 {
                        self.targetEncoderBitrateBps = clamped
                        // Reconfigure live `VTCompressionSession` bitrate only after the initial keyframe has emitted (`txPacketCount > 0`)
                        // so cold XPC encoder initialization never drops its first IDR frame during rate-control reset.
                        if self.txPacketCount > 0, let comp = self.compressionSession {
                            VTSessionSetProperty(comp, key: kVTCompressionPropertyKey_AverageBitRate, value: clamped as CFNumber)
                        }
                    }
                }
                return
            }

            if let rtpHdr = ZolaH264RtpDepacketizer.parseRtpPacketAllowingEmptyPadding(payload) {
                let pt = rtpHdr.payloadType
                self.bumpStat {
                    $0.statInboundByPt[pt, default: 0] += 1
                    if self.depacketizer.acceptedPayloadTypes.contains(pt), let first = rtpHdr.payload.first {
                        $0.statInboundByNal[first & 0x1F, default: 0] += 1
                    }
                }
                if self.depacketizer.acceptedPayloadTypes.contains(pt)
                    || (self.depacketizer.remoteSsrc != 0 && rtpHdr.ssrc == self.depacketizer.remoteSsrc)
                {
                    self.rxStats.recordInboundRtp(
                        ssrc: rtpHdr.ssrc,
                        sequenceNumber: rtpHdr.sequenceNumber,
                        rtpTimestamp: rtpHdr.timestamp,
                        byteCount: payload.count,
                        arrivalUptime: now
                    )
                }
            }

            let prevRemoteSsrc = self.depacketizer.remoteSsrc
            let prevRecovered = self.depacketizer.reorderedPacketsRecovered
            let units = self.depacketizer.ingestRtpPacket(payload, arrivalUptime: now)
            self.bumpStat { $0.statReceiveStages = self.depacketizer.receiveStageCounters }
            let deltaRecovered = self.depacketizer.reorderedPacketsRecovered - prevRecovered
            if deltaRecovered > 0 {
                self.bumpStat { $0.statReordered += deltaRecovered }
            }
            let ssrcJustDiscovered = (prevRemoteSsrc == 0 && self.depacketizer.remoteSsrc != 0)
            if self.depacketizer.needsKeyframePli {
                self.depacketizer.clearPliFlag()
                self.sendPliIfNeededOnVideoQueue(force: ssrcJustDiscovered)
            }
            for unit in units {
                self.decodeAccessUnitOnVideoQueue(unit)
            }
        }
    }

    private func sendPliIfNeededOnVideoQueue(force: Bool) {
        let mediaSsrc = depacketizer.remoteSsrc
        guard mediaSsrc != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force && (now - lastPliSentUptime) < 0.5 {
            return
        }
        lastPliSentUptime = now
        let pli = ZolaH264RtpPacketizer.buildRtcpPliPacket(senderSsrc: videoSsrc, mediaSsrc: mediaSsrc)
        bumpStat {
            $0.statRtcpSent += 1
            $0.statPliSent += 1
        }
        onOutboundVideoPacket?(pli, true)
    }

    private func decodeAccessUnitOnVideoQueue(_ unit: ZolaH264AssembledAccessUnit) {
        if unit.containsIdr { bumpStat { $0.statKeyframesRx += 1 } }
        guard let sps = unit.sps, let pps = unit.pps else {
            bumpStat { $0.statMissingParameterSets += 1 }
            sendPliIfNeededOnVideoQueue(force: false)
            return
        }
        if decompressionSession == nil || sps != activeDecoderSps || pps != activeDecoderPps {
            guard rebuildDecoderOnVideoQueue(sps: sps, pps: pps) else {
                sendPliIfNeededOnVideoQueue(force: false)
                return
            }
        }
        guard let decomp = decompressionSession, let fmtDesc = decoderFormatDesc else { return }
        if !hasDecodedAnyFrame && !unit.containsIdr {
            // A queued IDR is not yet a successful decode. Hold a short burst of P-frames until
            // its callback arrives, instead of discarding them and sending a false PLI.
            if keyframeDecodePending && pendingDecoderUnits.count < 16 {
                pendingDecoderUnits.append(unit)
                return
            }
            // Wait for an IDR slice before feeding P-frames into a brand-new decoder session.
            bumpStat { $0.statWaitingForIdr += 1 }
            sendPliIfNeededOnVideoQueue(force: false)
            return
        }

        // Build 4-byte Big-Endian AVCC sample data from all slice/SEI NAL units in the access unit.
        var avccLength = 0
        for nal in unit.vclNalUnits {
            avccLength += 4 + nal.count
        }
        guard avccLength > 4 else { return }
        var avccData = Data(capacity: avccLength)
        for nal in unit.vclNalUnits {
            avccData.appendVideoBE(UInt32(nal.count))
            avccData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else {
            recordDecoderFailure(createStatus, stage: "block")
            return
        }
        let replaceStatus = avccData.withUnsafeBytes { rawPtr -> OSStatus in
            guard let base = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            recordDecoderFailure(replaceStatus, stage: "copy")
            return
        }

        var sampleSize = avccData.count
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(unit.rtpTimestamp), timescale: 90_000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fmtDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sampleBuffer else {
            recordDecoderFailure(sbStatus, stage: "sample")
            return
        }

        let generation = decoderGeneration
        if unit.containsIdr { keyframeDecodePending = true }
        bumpStat { $0.statDecoderSubmissions += 1 }
        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decomp,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                self?.recordDecoderFailure(status, stage: imageBuffer == nil && status == noErr ? "no-image" : "callback")
                self?.videoQueue.async { [weak self] in
                    guard let self, self.isRunning, self.decoderGeneration == generation else { return }
                    self.hasDecodedAnyFrame = false
                    self.keyframeDecodePending = false
                    self.pendingDecoderUnits.removeAll(keepingCapacity: true)
                    self.sendPliIfNeededOnVideoQueue(force: false)
                }
                return
            }
            let pts = CMTime(value: CMTimeValue(unit.rtpTimestamp), timescale: 90_000)
            self?.onRemoteVideoPixelBuffer?(imageBuffer, pts)
            let cgImage = Self.makeVideoImage(from: imageBuffer)
            self?.videoQueue.async { [weak self] in
                guard let self, self.isRunning, self.decoderGeneration == generation else { return }
                self.hasDecodedAnyFrame = true
                self.keyframeDecodePending = false
                self.decodedFrameCount += 1
                self.bumpStat { $0.statDecodedFrames += 1 }
                if let cgImage { self.onRemoteVideoFrame?(cgImage) }
                let pendingUnits = self.pendingDecoderUnits
                self.pendingDecoderUnits.removeAll(keepingCapacity: true)
                for pending in pendingUnits {
                    self.decodeAccessUnitOnVideoQueue(pending)
                }
            }
        }
        if decodeStatus != noErr {
            recordDecoderFailure(decodeStatus, stage: "decode")
            teardownDecoderOnVideoQueue()
            sendPliIfNeededOnVideoQueue(force: false)
        }
    }

    private func rebuildDecoderOnVideoQueue(sps: Data, pps: Data) -> Bool {
        teardownDecoderOnVideoQueue()
        var fmtDesc: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress
                else {
                    return -1
                }
                let ptrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                return ptrs.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        guard let pBase = ptrBuf.baseAddress, let sBase = sizeBuf.baseAddress else { return -1 }
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pBase,
                            parameterSetSizes: sBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmtDesc
                        )
                    }
                }
            }
        }
        guard status == noErr, let fmtDesc else {
            recordDecoderFailure(status, stage: "format")
            return false
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let vtStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fmtDesc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard vtStatus == noErr, let session else {
            recordDecoderFailure(vtStatus, stage: "session")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decoderFormatDesc = fmtDesc
        self.decompressionSession = session
        self.activeDecoderSps = sps
        self.activeDecoderPps = pps
        return true
    }

    private func teardownDecoderOnVideoQueue() {
        decoderGeneration &+= 1
        keyframeDecodePending = false
        pendingDecoderUnits.removeAll(keepingCapacity: true)
        if let decomp = decompressionSession {
            VTDecompressionSessionInvalidate(decomp)
            decompressionSession = nil
        }
        decoderFormatDesc = nil
        hasDecodedAnyFrame = false
        activeDecoderSps.removeAll(keepingCapacity: false)
        activeDecoderPps.removeAll(keepingCapacity: false)
    }

    // MARK: - Outbound Hardware `VTCompressionSession` Encode

    func encodeSyntheticFrame(
        width: Int = 320,
        height: Int = 240,
        r: UInt8 = 0x22,
        g: UInt8 = 0x88,
        b: UInt8 = 0xEE,
        forceKeyframe: Bool = true
    ) -> Bool {
        performOnVideoQueueSync {
            guard self.isRunning else { return false }
            var pixelBuffer: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ]
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else { return false }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for y in 0..<height {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        let px = x * 4
                        row[px] = b
                        row[px + 1] = g
                        row[px + 2] = r
                        row[px + 3] = 0xFF
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            self.syntheticFrameCounter &+= 1
            let pts = CMTime(value: self.syntheticFrameCounter * 3_000, timescale: 90_000)
            let ok = self.encodePixelBufferOnVideoQueue(
                pixelBuffer,
                presentationTimeStamp: pts,
                forceKeyframe: forceKeyframe
            )
            if ok, let comp = self.compressionSession {
                VTCompressionSessionCompleteFrames(comp, untilPresentationTimeStamp: .invalid)
            }
            return ok
        }
    }

    @discardableResult
    private func encodePixelBufferOnVideoQueue(
        _ pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        forceKeyframe: Bool
    ) -> Bool {
        guard isRunning else { return false }
        let srcW = Int(CVPixelBufferGetWidth(pixelBuffer))
        let srcH = Int(CVPixelBufferGetHeight(pixelBuffer))
        guard srcW >= 16, srcH >= 16 else { return false }

        // Clamp max edge to 640 px (even dimensions) for crisp, low-latency mobile H.264 over `:4200`.
        let maxEdge = max(srcW, srcH)
        let scale = maxEdge > 640 ? (640.0 / Double(maxEdge)) : 1.0
        let targetW = Int32(max(16, Int((Double(srcW) * scale).rounded()) & ~1))
        let targetH = Int32(max(16, Int((Double(srcH) * scale).rounded()) & ~1))

        if compressionSession == nil || encoderWidth != targetW || encoderHeight != targetH {
            guard rebuildEncoderOnVideoQueue(width: targetW, height: targetH) else {
                bumpStat { $0.statEncodeErrors += 1 }
                return false
            }
        }
        guard let comp = compressionSession else { return false }

        let shouldForceIdr = forceKeyframe || forceNextKeyframe
        forceNextKeyframe = false
        var frameProps: CFDictionary?
        if shouldForceIdr {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        var infoFlags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            comp,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: CMTime(value: 1, timescale: 20),
            frameProperties: frameProps,
            infoFlagsOut: &infoFlags
        ) { [weak self] encodeStatus, _, sampleBuffer in
            guard encodeStatus == noErr, let sampleBuffer else {
                self?.bumpStat { $0.statEncodeErrors += 1 }
                return
            }
            self?.videoQueue.async { [weak self] in
                self?.consumeEncodedSampleBufferOnVideoQueue(sampleBuffer)
            }
        }
        if status != noErr {
            bumpStat { $0.statEncodeErrors += 1 }
            teardownEncoderOnVideoQueue()
            return false
        }
        return true
    }

    private func bumpStat(_ update: (ZolaVoipVideoEngine) -> Void) {
        statsLock.lock()
        update(self)
        statsLock.unlock()
    }

    private func recordDecoderFailure(_ status: OSStatus, stage: String) {
        bumpStat {
            $0.statDecodeErrors += 1
            $0.statLastDecoderStatus = status
            $0.statLastDecoderFailureStage = stage
        }
    }

    /// Short counter summary for the in-app call log (no frame data, keys or addresses).
    var diagnosticsLine: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        let pts = statInboundByPt.keys.sorted()
            .map { "\($0):\(statInboundByPt[$0] ?? 0)" }
            .joined(separator: ",")
        let nals = statInboundByNal.keys.sorted()
            .map { "\($0):\(statInboundByNal[$0] ?? 0)" }
            .joined(separator: ",")
        return "cam=\(statCaptureFrames) mahoa=\(statEncodedFrames) loi-mahoa=\(statEncodeErrors)"
            + " loi-mocam=\(statCaptureStartFailures) ngat-cam=\(statInterruptions) loi-cam=\(statRuntimeErrors)"
            + " giai-ma=\(statDecodedFrames) rtcp=\(statRtcpSent)/\(statRtcpRecv) xep-lai=\(statReordered) pt=[\(pts)]"
            + " pli=\(statPliSent)/\(statPliRecv) loi-giaima=\(statDecodeErrors) idr=\(statKeyframesTx)/\(statKeyframesRx)"
            + " nal=[\(nals)] sps-pps=\(statReceiveStages.sps)/\(statReceiveStages.pps)"
            + " au=\(statReceiveStages.assembled)/\(statReceiveStages.corrupt) fu-loi=\(statReceiveStages.rejectedFu)"
            + " fu-xong=\(statReceiveStages.completedFu) annexb=\(statReceiveStages.nativeAnnexBFrames)"
            + " cho-sps=\(statMissingParameterSets) cho-idr=\(statWaitingForIdr) vt-vao=\(statDecoderSubmissions)"
            + " vt-loi=\(statLastDecoderFailureStage):\(statLastDecoderStatus)"
    }

    private func consumeEncodedSampleBufferOnVideoQueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        bumpStat { $0.statEncodedFrames += 1 }

        var spsData: Data?
        var ppsData: Data?
        var nalHeaderLen: Int32 = 4
        if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsPtr: UnsafePointer<UInt8>?
            var spsSize: Int = 0
            var count: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmtDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPtr,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalHeaderLen
            ) == noErr, let spsPtr, spsSize > 0 {
                spsData = Data(bytes: spsPtr, count: spsSize)
            }
            var ppsPtr: UnsafePointer<UInt8>?
            var ppsSize: Int = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmtDesc,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPtr,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let ppsPtr, ppsSize > 0 {
                ppsData = Data(bytes: ppsPtr, count: ppsSize)
            }
        }

        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > Int(nalHeaderLen) else { return }
        var rawAvcc = Data(count: totalLength)
        let copyStatus = rawAvcc.withUnsafeMutableBytes { dst -> OSStatus in
            guard let base = dst.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: totalLength, destination: base)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let hdrBytes = max(1, min(4, Int(nalHeaderLen)))
        var offset = 0
        var nalUnits: [Data] = []
        while offset + hdrBytes <= totalLength {
            var naluLen = 0
            for i in 0..<hdrBytes {
                naluLen = (naluLen << 8) | Int(rawAvcc[offset + i])
            }
            offset += hdrBytes
            guard naluLen > 0, offset + naluLen <= totalLength else { break }
            nalUnits.append(rawAvcc.subdata(in: offset..<(offset + naluLen)))
            offset += naluLen
        }
        guard !nalUnits.isEmpty else { return }
        let hasIdrNal = nalUnits.contains { (($0.first ?? 0) & 0x1F) == 5 }
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        {
            isKeyframe = (!notSync) || hasIdrNal
        } else {
            isKeyframe = hasIdrNal
        }
        if isKeyframe { bumpStat { $0.statKeyframesTx += 1 } }

        let ptsSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let rtpTs = packetizer.rtpTimestamp(forPresentationSeconds: ptsSeconds)
        let rtpPackets = packetizer.packetizeAccessUnit(
            nalUnits: nalUnits,
            sps: spsData,
            pps: ppsData,
            isKeyframe: isKeyframe,
            rtpTimestamp: rtpTs
        )
        lastTxRtpTimestamp = rtpTs
        for pkt in rtpPackets {
            encodedPacketCount += 1
            txPacketCount &+= 1
            txOctetCount &+= UInt32(truncatingIfNeeded: max(0, pkt.count - 12))
            onOutboundVideoPacket?(pkt, false)
        }
    }

    private func rebuildEncoderOnVideoQueue(width: Int32, height: Int32) -> Bool {
        teardownEncoderOnVideoQueue()
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.5 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetEncoderBitrateBps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 20 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        self.encoderWidth = width
        self.encoderHeight = height
        self.forceNextKeyframe = true
        return true
    }

    private func teardownEncoderOnVideoQueue() {
        if let comp = compressionSession {
            VTCompressionSessionInvalidate(comp)
            compressionSession = nil
        }
        encoderWidth = 0
        encoderHeight = 0
    }

    // MARK: - Local Camera `AVCaptureSession`

    private func setDesiredCaptureState(active: Bool, preferFront: Bool) {
        captureStateLock.lock()
        desiredCaptureActive = active
        desiredPreferFront = preferFront
        captureStateLock.unlock()
    }

    private func currentDesiredCaptureState() -> (active: Bool, preferFront: Bool) {
        captureStateLock.lock()
        let snap = (desiredCaptureActive, desiredPreferFront)
        captureStateLock.unlock()
        return snap
    }

    private func teardownCaptureSessionOnCaptureQueue() {
        captureObservers.forEach { NotificationCenter.default.removeObserver($0) }
        captureObservers.removeAll()
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
            captureSession = nil
        }
        lastCapturedEncodeUptime = 0
    }

    private func updateCaptureStateAsync() {
        let shouldCapture = isRunning && isCameraEnabled
        let preferFront = isUsingFrontCamera
        setDesiredCaptureState(active: shouldCapture, preferFront: preferFront)
        captureQueue.async { [weak self] in
            guard let self else { return }
            let desired = self.currentDesiredCaptureState()
            if !desired.active {
                if let session = self.captureSession, session.isRunning {
                    session.stopRunning()
                }
                return
            }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                // Camera permission not yet granted (or running in headless CI): remote video decode remains active.
                return
            }
            if let existing = self.captureSession {
                if !existing.isRunning, self.currentDesiredCaptureState().active {
                    existing.startRunning()
                }
                return
            }
            guard let device = Self.selectCameraDevice(preferFront: desired.preferFront),
                  let input = try? AVCaptureDeviceInput(device: device)
            else {
                self.bumpStat { $0.statCaptureStartFailures += 1 }
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true
            }
            #endif
            #if os(iOS) || targetEnvironment(macCatalyst)
            session.automaticallyConfiguresApplicationAudioSession = false
            #endif
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
            if session.canAddInput(input) {
                session.addInput(input)
            }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            ]
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            Self.applyPortraitOrientationIfNeeded(to: output)
            session.commitConfiguration()

            // Re-verify desired state on `captureQueue` in case `stop()` or `setCameraEnabled(false)` ran while configuring!
            guard self.currentDesiredCaptureState().active else {
                output.setSampleBufferDelegate(nil, queue: nil)
                return
            }
            self.captureSession = session
            self.videoOutput = output
            self.observeCaptureSessionOnCaptureQueue(session)
            session.startRunning()
        }
    }

    /// Without these the encoder went silent when iOS interrupted the camera (another capture session,
    /// Control Center, a phone call) or hit a media-services reset: no frames, no `0x0d`, no error.
    private func observeCaptureSessionOnCaptureQueue(_ session: AVCaptureSession) {
        let center = NotificationCenter.default
        let restartIfWanted: () -> Void = { [weak self, weak session] in
            self?.captureQueue.async {
                guard let self, let session, self.captureSession === session,
                      self.currentDesiredCaptureState().active, !session.isRunning
                else { return }
                session.startRunning()
            }
        }
        captureObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.bumpStat { $0.statInterruptions += 1 }
        })
        captureObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.videoQueue.async { [weak self] in self?.forceNextKeyframe = true }
            restartIfWanted()
        })
        captureObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            self?.bumpStat { $0.statRuntimeErrors += 1 }
            // Like Apple's AVCam: only a media-services reset is worth an automatic restart; other
            // runtime errors would loop `startRunning()` on a camera that keeps failing.
            #if os(iOS)
            if let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError,
               error.code == .mediaServicesWereReset
            {
                restartIfWanted()
            }
            #else
            _ = note
            #endif
        })
    }

    private func reconfigureCaptureDeviceAsync(preferFront: Bool) {
        captureQueue.async { [weak self] in
            guard let self, self.currentDesiredCaptureState().active, let session = self.captureSession else { return }
            guard let newDevice = Self.selectCameraDevice(preferFront: preferFront),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice)
            else { return }
            session.beginConfiguration()
            let oldInputs = session.inputs
            for oldInput in oldInputs {
                session.removeInput(oldInput)
            }
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                if let out = self.videoOutput {
                    Self.applyPortraitOrientationIfNeeded(to: out)
                }
            } else {
                self.bumpStat { $0.statCaptureStartFailures += 1 }
                for oldInput in oldInputs where session.canAddInput(oldInput) {
                    session.addInput(oldInput)
                }
            }
            session.commitConfiguration()
            self.videoQueue.async { [weak self] in self?.forceNextKeyframe = true }
        }
    }

    private static func selectCameraDevice(preferFront: Bool) -> AVCaptureDevice? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let preferredPos: AVCaptureDevice.Position = preferFront ? .front : .back
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: preferredPos) {
            return dev
        }
        let fallbackPos: AVCaptureDevice.Position = preferFront ? .back : .front
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: fallbackPos) {
            return dev
        }
        #endif
        return AVCaptureDevice.default(for: .video)
    }

    private static func applyPortraitOrientationIfNeeded(to output: AVCaptureVideoDataOutput) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let conn = output.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        #else
        _ = output
        #endif
    }

    private func performOnVideoQueueSync<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return block()
        }
        return videoQueue.sync(execute: block)
    }
}

extension ZolaVoipVideoEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _ = output
        _ = connection
        guard currentDesiredCaptureState().active else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Cap encode + preview rate to ~20 fps (50 ms) to keep battery & relay bandwidth lean.
        guard (now - lastCapturedEncodeUptime) >= 0.046 else { return }
        lastCapturedEncodeUptime = now
        bumpStat { $0.statCaptureFrames += 1 }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onLocalVideoPixelBuffer?(pixelBuffer, pts)
        if let localImage = Self.makeVideoImage(from: pixelBuffer) {
            onLocalVideoFrame?(localImage)
        }
        videoQueue.async { [weak self] in
            guard let self, self.isRunning, self.isCameraEnabled else { return }
            self.encodePixelBufferOnVideoQueue(
                pixelBuffer,
                presentationTimeStamp: pts,
                forceKeyframe: false
            )
        }
    }
}

private extension Data {
    mutating func appendVideoBE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendVideoBE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    func readVideoBE32(at index: Int) -> UInt32 {
        (UInt32(self[index]) << 24)
            | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8)
            | UInt32(self[index + 3])
    }
}
#endif
