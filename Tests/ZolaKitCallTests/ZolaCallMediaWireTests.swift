import CryptoKit
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreVideo) && canImport(CoreMedia)
import CoreVideo
import CoreMedia
#endif
#if canImport(Network)
import Network
#endif
import XCTest
@testable import ZolaKit

// CALL REGRESSION TESTS — bộ test bảo vệ cuộc gọi thoại/video (target ZolaKitCallTests).
// Chuyển nguyên văn từ Tests/ZolaKitTests/ZolaKitTests.swift; helper được chép lại vì khác target.
// Chạy riêng: swift test --filter ZolaKitCallTests  (xem docs/CALL-MODULE.md)

final class ZolaCallMediaWireTests: XCTestCase {
    private func element(msgType: Int8, retCode: Int32, cmd: Int16 = 201) -> ZolaUnpackedChatElement {
        ZolaUnpackedChatElement(
            frameSize: 27,
            version: 2,
            checksum: 0,
            needAck: 0,
            msgType: msgType,
            seqId: 9,
            srcId: 1,
            srcType: 3,
            cmd: cmd,
            subCmd: 1,
            bodyData: Data(),
            retCode: retCode
        )
    }

    func testVoipExtendDataDisablesSp2pAndAudioRtcpFramingAndInitAckGuard() throws {
        let ext = ZolaCrypto.makeVoipExtendDataJson(isVideo: true)
        let extDict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ext.utf8)) as? [String: Any])
        XCTAssertEqual(extDict["sP2P"] as? Int, 0, "1-1 ZRTC calls must advertise sP2P=0 so official Zalo never flips isP2PConnected=1 onto unreachable candidates")

        let ansFrame = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipAnswerCallFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_500).payload
        )
        let ansUtf8 = String(decoding: ansFrame.bodyData, as: UTF8.self)
        XCTAssertTrue(ansUtf8.contains("\"sP2P\":0"))

        let ringFrame = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipCalleeRingingFrame(srcId: 100_000_102, partnerId: 100_000_103, callId: 901_500, isVideo: true).payload
        )
        let ringUtf8 = String(decoding: ringFrame.decodedBodyData, as: UTF8.self)
        XCTAssertTrue(ringUtf8.contains("\"sP2P\":0"))

        let upgraded = ZolaClient.makeVoipVideoUpgradeExtendData(from: #"{"callType":0,"sP2P":1}"#)
        XCTAssertTrue(upgraded.contains("\"sP2P\":0"))

        // Production client (`relayToken == nil`) must NEVER fabricate a 0x02 InitZRTP server ACK (`pktCmd == 11|12`).
        let initPkt = ZolaCrypto.packZrtcInitServerPacket(
            isCaller: true,
            selfUid: 100_000_103,
            partnerUid: 100_000_102,
            callId: 901_500,
            sessionId: "sess_901500",
            seq: 1
        )
        XCTAssertNil(ZolaCrypto.packZrtcPongPacket(fromPing: initPkt, selfUid: 100_000_102))
        XCTAssertNotNil(ZolaCrypto.packZrtcPongPacket(fromPing: initPkt, selfUid: 0, relayToken: 0x1234_5678))

        // Audio RTCP (`0x05` outbound / `0x07` inbound) must unwrap strictly as RTCP and never leak into Opus RTP decode.
        #if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
        let audioCompound = ZolaH264RtpPacketizer.buildCompoundRtcpPacket(
            senderSsrc: 0x4155_4401,
            cname: "zola_audio"
        )
        let out05 = ZolaCrypto.packZrtcOneToOneAudioRtcpPacket(token: 0xCAFE_1111, rtcpPayload: audioCompound)
        let in07 = ZolaCrypto.packZrtcOneToOneAudioRtcpRelayInboundPacket(rtcpPayload: audioCompound)
        XCTAssertEqual(out05.first, 0x05)
        XCTAssertEqual(in07.first, 0x07)
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(out05), "0x05 carrying RTCP PT 200/201 must never unwrap as Opus audio RTP")
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(in07), "0x07 relay audio RTCP must never unwrap as Opus audio RTP")
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioRtcpPayload(out05), audioCompound)
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioRtcpPayload(in07), audioCompound)
        #endif
    }

    #if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testRfc3550CompoundRtcpSrRrSdesRembAndReceiverStatsWireEncoding() throws {
        var tracker = ZolaRtpReceiverStatsTracker(clockRateHz: 90_000)
        // Deliver seq 100, duplicate 101, 103 across 32-bit `rtpTimestamp` wraparound (`0xFFFF_F500 -> 0x0000_0290`):
        // duplicate `seq=101` must NOT skew `cumulativeLost` / `fractionLost`, and 32-bit wrap must NOT blow up jitter!
        tracker.recordInboundRtp(ssrc: 0x7788_99AA, sequenceNumber: 100, rtpTimestamp: 0xFFFF_F500, byteCount: 1_100, arrivalUptime: 1.00)
        tracker.recordInboundRtp(ssrc: 0x7788_99AA, sequenceNumber: 101, rtpTimestamp: 0xFFFF_F500, byteCount: 1_100, arrivalUptime: 1.01)
        tracker.recordInboundRtp(ssrc: 0x7788_99AA, sequenceNumber: 101, rtpTimestamp: 0xFFFF_F500, byteCount: 1_100, arrivalUptime: 1.011)
        tracker.recordInboundRtp(ssrc: 0x7788_99AA, sequenceNumber: 103, rtpTimestamp: 0x0000_00B8, byteCount: 1_100, arrivalUptime: 1.05)
        tracker.recordInboundSenderReport(ntpMiddle32: 0xABCD_1234, arrivalUptime: 1.25)

        let rb = try XCTUnwrap(tracker.buildReportBlock(nowUptime: 1.75))
        XCTAssertEqual(rb.ssrc, 0x7788_99AA)
        XCTAssertEqual(rb.cumulativeLost, 1)
        XCTAssertEqual(rb.fractionLost, 64)
        XCTAssertLessThan(rb.interarrivalJitter, 10_000, "32-bit RTP timestamp wraparound must remain modular with bounded jitter")
        XCTAssertEqual(rb.extendedHighestSequence, 103)
        XCTAssertEqual(rb.lastSrMiddle32, 0xABCD_1234)
        XCTAssertEqual(rb.delaySinceLastSr, 32_768, "0.50s delay * 65536 = 32768 DLSR units")

        let srStats = ZolaRtcpSenderStats(
            ntpSeconds: 0x83AA_7E80,
            ntpFraction: 0x8000_0000,
            rtpTimestamp: 180_000,
            senderPacketCount: 42,
            senderOctetCount: 38_400
        )
        let compound = ZolaH264RtpPacketizer.buildCompoundRtcpPacket(
            senderSsrc: 0x1122_3344,
            senderStats: srStats,
            reportBlock: rb,
            cname: "zola_test",
            rembBitrateBps: 950_000,
            rembSsrcs: [0x7788_99AA]
        )
        XCTAssertEqual(compound.count % 4, 0, "Every RFC 3550 compound RTCP packet must be 32-bit word aligned")
        let parsed = ZolaH264RtpDepacketizer.parseInboundRtcpCompound(compound)
        XCTAssertEqual(parsed.senderSsrc, 0x1122_3344)
        XCTAssertEqual(parsed.senderNtpMiddle32, 0x7E80_8000)
        XCTAssertEqual(parsed.senderRtpTimestamp, 180_000)
        XCTAssertEqual(parsed.reportedFractionLost, 64)
        XCTAssertFalse(parsed.requestsKeyframe)
        let decodedRemb = try XCTUnwrap(parsed.rembBitrateBps)
        XCTAssertGreaterThan(decodedRemb, 940_000)
        XCTAssertLessThan(decodedRemb, 960_000)
    }
    #endif

    #if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    #if canImport(Network)
    func testZrtcVideoRelayLoopbackWithReorderingRtxNoiseCompoundRtcpAndBlockedP2PPing() async throws {
        final class RelayState: @unchecked Sendable {
            let lock = NSLock()
            var callerConn: NWConnection?
            var calleeConn: NWConnection?
            var heldCallerVideoPacket: Data?
            var swappedOnce = false
            var sawVideoCompoundRtcpWithRemb = false
            var sawAudioRtcp05 = false
            var rogueReplies = 0
        }

        let udpQueue = DispatchQueue(label: "test.zrtc.video.bwe.loopback")
        let relayListener = try NWListener(using: .udp, on: .any)
        let rogueListener = try NWListener(using: .udp, on: .any)
        defer {
            relayListener.cancel()
            rogueListener.cancel()
        }

        let relayReady = expectation(description: "Mock :4200 relay ready")
        let rogueReady = expectation(description: "Mock rogue P2P socket ready")
        let videoRembExp = expectation(description: "Relay received 0x0f compound video RTCP with REMB")
        videoRembExp.assertForOverFulfill = false
        let audioRtcpExp = expectation(description: "Relay received 0x05 audio RTCP")
        audioRtcpExp.assertForOverFulfill = false
        let calleeDecodedExp = expectation(description: "Callee decoded reordered + RTX-noisy H.264 stream")
        calleeDecodedExp.assertForOverFulfill = false
        let callerDecodedExp = expectation(description: "Caller decoded H.264 stream")
        callerDecodedExp.assertForOverFulfill = false

        let state = RelayState()
        let callerToken: UInt32 = 0x1357_2468
        let calleeToken: UInt32 = 0x2468_1357

        relayListener.stateUpdateHandler = { st in
            if case .ready = st { relayReady.fulfill() }
        }
        rogueListener.stateUpdateHandler = { st in
            if case .ready = st { rogueReady.fulfill() }
        }

        rogueListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pumpRogue() {
                conn.receiveMessage { data, _, _, err in
                    if err != nil { return }
                    if let data, !data.isEmpty {
                        state.lock.withLock { state.rogueReplies += 1 }
                    }
                    if case .cancelled = conn.state { return }
                    pumpRogue()
                }
            }
            pumpRogue()
        }

        relayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pump() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, !data.isEmpty, let b0 = data.first {
                        switch b0 {
                        case 0x01:
                            if data.count >= 20, let cmd = try? data.readUInt16LE(at: 18) {
                                if cmd == 11 {
                                    state.lock.withLock { state.callerConn = conn }
                                    if let ack = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0, relayToken: callerToken) {
                                        conn.send(content: ack, completion: .contentProcessed { _ in })
                                    }
                                } else if cmd == 12 {
                                    state.lock.withLock { state.calleeConn = conn }
                                    if let ack = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0, relayToken: calleeToken) {
                                        conn.send(content: ack, completion: .contentProcessed { _ in })
                                    }
                                } else if cmd == 3 {
                                    if let pong = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0) {
                                        conn.send(content: pong, completion: .contentProcessed { _ in })
                                    }
                                }
                            }
                        case 0x05:
                            if ZolaCrypto.unpackZrtcAudioRtcpPayload(data) != nil {
                                let fire = state.lock.withLock { () -> Bool in
                                    let first = !state.sawAudioRtcp05
                                    state.sawAudioRtcp05 = true
                                    return first
                                }
                                if fire { audioRtcpExp.fulfill() }
                            }
                        case 0x0d, 0x0f:
                            guard data.count > 5, let tok = try? data.readUInt32LE(at: 1) else { break }
                            let inner = data.subdata(in: 5..<data.count)
                            let isRtcp = (b0 == 0x0f)
                            if isRtcp {
                                let parsed = ZolaH264RtpDepacketizer.parseInboundRtcpCompound(inner)
                                if let remb = parsed.rembBitrateBps, remb >= 800_000 {
                                    let fire = state.lock.withLock { () -> Bool in
                                        let first = !state.sawVideoCompoundRtcpWithRemb
                                        state.sawVideoCompoundRtcpWithRemb = true
                                        return first
                                    }
                                    if fire { videoRembExp.fulfill() }
                                }
                            }
                            let dst: NWConnection? = state.lock.withLock {
                                tok == callerToken ? state.calleeConn : (tok == calleeToken ? state.callerConn : nil)
                            }
                            if !isRtcp && tok == callerToken, let dst {
                                // Inject an interleaved RTX `PT=100` noise packet + swap one adjacent RTP pair!
                                let rtx = ZolaVoipMediaEngine.buildRtpPacket(
                                    payloadType: 100,
                                    sequenceNumber: 8_888,
                                    timestamp: 77_777,
                                    ssrc: 0xDEAD_1000,
                                    payload: Data([0x00, 0x01, 0xAA, 0xBB])
                                )
                                dst.send(
                                    content: ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(isRtcp: false, payload: rtx),
                                    completion: .contentProcessed { _ in }
                                )
                                var toSend: [Data] = []
                                state.lock.withLock {
                                    if !state.swappedOnce {
                                        if let held = state.heldCallerVideoPacket {
                                            // Emit current packet BEFORE held packet -> out-of-order UDP delivery!
                                            toSend = [inner, held]
                                            state.heldCallerVideoPacket = nil
                                            state.swappedOnce = true
                                        } else {
                                            state.heldCallerVideoPacket = inner
                                        }
                                    } else {
                                        toSend = [inner]
                                    }
                                }
                                for p in toSend {
                                    let wrapped = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(isRtcp: false, payload: p)
                                    dst.send(content: wrapped, completion: .contentProcessed { _ in })
                                }
                            } else if let dst {
                                let wrapped = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(isRtcp: isRtcp, payload: inner)
                                dst.send(content: wrapped, completion: .contentProcessed { _ in })
                            }
                        default:
                            break
                        }
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pump()
                }
            }
            pump()
        }

        relayListener.start(queue: udpQueue)
        rogueListener.start(queue: udpQueue)
        await fulfillment(of: [relayReady, rogueReady], timeout: 3.0)
        let relayPort = try XCTUnwrap(relayListener.port?.rawValue)
        let roguePort = try XCTUnwrap(rogueListener.port?.rawValue)
        let relayEp = ZolaVoipMediaEngine.MediaEndpoint(host: "127.0.0.1", port: relayPort)

        let caller = ZolaVoipMediaEngine(callId: 881_200)
        let callee = ZolaVoipMediaEngine(callId: 881_200)
        caller.forceZrtcFramingOnLoopback = true
        callee.forceZrtcFramingOnLoopback = true
        defer {
            caller.stop()
            callee.stop()
        }

        callee.onRemoteVideoFrame = { _ in calleeDecodedExp.fulfill() }
        caller.onRemoteVideoFrame = { _ in callerDecodedExp.fulfill() }

        caller.setVideoMode(enabled: true, h264PayloadType: 97, cameraEnabled: false)
        callee.setVideoMode(enabled: true, h264PayloadType: 97, cameraEnabled: false)
        caller.configureZrtcSession(isCaller: true, selfUid: 100_000_103, partnerUid: 100_000_102, sessionId: "sess_b80")
        callee.configureZrtcSession(isCaller: false, selfUid: 100_000_102, partnerUid: 100_000_103, sessionId: "sess_b80")

        try caller.prepareTransport(relay: relayEp)
        try callee.prepareTransport(relay: relayEp)

        let callerAck = await caller.waitForRelayHandshake(timeoutMs: 2_000)
        let calleeAck = await callee.waitForRelayHandshake(timeoutMs: 2_000)
        XCTAssertTrue(callerAck)
        XCTAssertTrue(calleeAck)

        // Probe caller's bound UDP listener from a non-relay rogue socket with `pktCmd = 5` P2P ping + `pktCmd = 11` InitZRTP:
        // caller MUST ignore both completely!
        if caller.boundLocalPort > 0, let targetPort = NWEndpoint.Port(rawValue: caller.boundLocalPort) {
            let probeParams = NWParameters.udp
            probeParams.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: roguePort)!)
            let rogueProbe = NWConnection(to: .hostPort(host: "127.0.0.1", port: targetPort), using: probeParams)
            rogueProbe.start(queue: udpQueue)
            var p2pPing = ZolaCrypto.packZrtcPingPacket(selfUid: 100_000_102, partnerUid: 100_000_103, callId: 881_200, seq: 9)
            p2pPing[18] = 5
            p2pPing[19] = 0
            let fakeInit = ZolaCrypto.packZrtcInitServerPacket(isCaller: true, selfUid: 100_000_102, partnerUid: 100_000_103, callId: 881_200, sessionId: "sess_b80", seq: 2)
            rogueProbe.send(content: p2pPing, completion: .contentProcessed { _ in })
            rogueProbe.send(content: fakeInit, completion: .contentProcessed { _ in })
            defer { rogueProbe.cancel() }
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        for idx in 0..<4 {
            let c = UInt8(truncatingIfNeeded: 50 + idx * 40)
            caller.sendSyntheticVideoFrameForTesting(width: 320, height: 240, r: c, g: 0x77, b: 0xDD)
            callee.sendSyntheticVideoFrameForTesting(width: 320, height: 240, r: 0xDD, g: c, b: 0x55)
            try await Task.sleep(nanoseconds: 45_000_000)
        }

        await fulfillment(of: [calleeDecodedExp, callerDecodedExp, videoRembExp, audioRtcpExp], timeout: 4.0)
        XCTAssertEqual(state.lock.withLock { state.rogueReplies }, 0, "ZRTC relay session must never reply to non-relay P2P pings or InitZRTP packets")
    }
    #endif
    #endif

    func testH264CompanionPayloadMappingsAndAcceptedPayloadUpdates() throws {
        for (input, delta, key): (UInt8, UInt8, UInt8) in [
            (97, 97, 98), (98, 97, 98), (121, 122, 121), (122, 122, 121),
            (125, 125, 126), (126, 125, 126), (110, 110, 111), (127, 127, 127),
        ] {
            XCTAssertEqual(ZolaH264RtpPacketizer.companionDeltaPayloadType(for: input), delta)
            XCTAssertEqual(ZolaH264RtpPacketizer.companionKeyframePayloadType(for: input), key)
            var receiver = ZolaH264RtpDepacketizer(expectedPayloadType: input)
            XCTAssertEqual(receiver.acceptedPayloadTypes, [delta, key])
            receiver.acceptedPayloadTypes = [110]
            receiver.expectedPayloadType = input
            XCTAssertEqual(receiver.acceptedPayloadTypes, [delta, key])
            receiver.requestPli()
            XCTAssertTrue(receiver.needsKeyframePli)
            receiver.clearPliFlag()
            XCTAssertFalse(receiver.needsKeyframePli)
            let media = ZolaVoipMediaEngine(callId: 880_101)
            defer { media.stop() }
            media.setVideoMode(enabled: true, h264PayloadType: input, cameraEnabled: false)
            XCTAssertEqual(media.h264PayloadType, delta)
            XCTAssertEqual(media.h264KeyframePayloadType, key)
            XCTAssertEqual(media.acceptedH264PayloadTypes, [delta, key])
            let video = ZolaVoipVideoEngine(callId: 880_102)
            video.setPayloadType(input)
            XCTAssertEqual(video.currentPayloadType, delta)
        }
        let custom = ZolaH264RtpDepacketizer(acceptedPayloadTypes: [110])
        XCTAssertEqual(custom.acceptedPayloadTypes, [110])
        var packetizer = ZolaH264RtpPacketizer(ssrc: 1, keyframePayloadType: 120)
        let singleIdr = packetizer.packetizeAccessUnit(nalUnits: [Data([0x65, 0x80])], isKeyframe: true, rtpTimestamp: 1)
        XCTAssertEqual(try XCTUnwrap(ZolaH264RtpDepacketizer.parseRtpPacket(singleIdr[0])).payloadType, 120)
    }

    func testH264DualPayloadTypesUseOneContinuousSequenceAndSsrc() throws {
        var packetizer = ZolaH264RtpPacketizer(
            ssrc: 0xCAFE_1234, maxPayloadSize: 320,
            initialSequenceNumber: 65_533, initialTimestampOffset: 0
        )
        let keyPackets = packetizer.packetizeAccessUnit(
            nalUnits: [Data([0x06, 0x80]), Data([0x65]) + Data(repeating: 0x55, count: 1_020)],
            sps: Data([0x67, 0x42, 0xC0, 0x1E]), pps: Data([0x68, 0xCE, 0x3C, 0x80]),
            isKeyframe: true, rtpTimestamp: 90_000
        )
        let deltaPackets = packetizer.packetizeAccessUnit(
            nalUnits: [Data([0x41, 0x9A, 0x22])], isKeyframe: false, rtpTimestamp: 93_000
        )
        XCTAssertEqual(keyPackets.count, 6, "STAP-A, SEI and four FU-A fragments")
        XCTAssertEqual(deltaPackets.count, 1)
        for (index, packet) in (keyPackets + deltaPackets).enumerated() {
            let parsed = try XCTUnwrap(ZolaH264RtpDepacketizer.parseRtpPacket(packet))
            XCTAssertEqual(parsed.payloadType, index < keyPackets.count ? 98 : 97)
            XCTAssertEqual(parsed.ssrc, 0xCAFE_1234)
            XCTAssertEqual(parsed.sequenceNumber, UInt16(65_533) &+ UInt16(index))
        }
    }

    func testH264KeyframePayloadLocksBeforeDeltaWithReorderingAndRtx() throws {
        var packetizer = ZolaH264RtpPacketizer(
            ssrc: 0x55AA_7788, maxPayloadSize: 320,
            initialSequenceNumber: 500, initialTimestampOffset: 0
        )
        let sps = Data([0x67, 0x42, 0xC0, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let idr = Data([0x65]) + Data(repeating: 0x55, count: 1_020)
        // Explicit wire PT reproduces Build 83 independently of the outbound packetizer.
        let keyPackets = packetizer.packetizeAccessUnit(
            nalUnits: [idr], sps: sps, pps: pps, isKeyframe: true, rtpTimestamp: 90_000
        ).map { packet -> Data in
            var wire = packet
            wire[1] = (wire[1] & 0x80) | 98
            return wire
        }
        var receiver = ZolaH264RtpDepacketizer(reorderWindow: 16)
        XCTAssertTrue(receiver.ingestRtpPacket(keyPackets[0], arrivalUptime: 10).isEmpty)
        XCTAssertEqual(receiver.remoteSsrc, 0x55AA_7788)
        XCTAssertEqual(receiver.latestSps, sps)
        XCTAssertEqual(receiver.latestPps, pps)
        var units: [ZolaH264AssembledAccessUnit] = []
        for (step, index) in [2, 1, 4, 3].enumerated() {
            let noise = ZolaVoipMediaEngine.buildRtpPacket(
                payloadType: 100, sequenceNumber: UInt16(9_000 + step), timestamp: 90_000,
                ssrc: 0xDEAD_BEEF, payload: Data([0x65, 0xAA])
            )
            XCTAssertTrue(receiver.ingestRtpPacket(noise, arrivalUptime: 10.001).isEmpty)
            units += receiver.ingestRtpPacket(keyPackets[index], arrivalUptime: 10.002 + Double(step) * 0.004)
        }
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.vclNalUnits, [idr])
        let delta = Data([0x41, 0x9A, 0x22])
        for timestamp: UInt32 in [93_000, 96_000] {
            let packets = packetizer.packetizeAccessUnit(nalUnits: [delta], rtpTimestamp: timestamp)
            XCTAssertEqual(receiver.ingestRtpPacket(packets[0], arrivalUptime: 10.03).first?.vclNalUnits, [delta])
        }
        XCTAssertFalse(receiver.needsKeyframePli)
    }

    func testRfc6184H264StapASingleNalFuARoundtripAndPliOnPacketLoss() throws {
        var packetizer = ZolaH264RtpPacketizer(ssrc: 0xCAFE_1234, payloadType: 97, maxPayloadSize: 400)
        var depacketizer = ZolaH264RtpDepacketizer()

        let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x01, 0x41, 0xFB, 0x01, 0x10])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        // Large IDR slice (1,050 bytes -> split into 3 FU-A fragments at maxPayloadSize=400)
        var idrNal = Data([0x65])
        for i in 0..<1_049 {
            idrNal.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7))
        }

        let keyframeRtp = packetizer.packetizeAccessUnit(
            nalUnits: [idrNal],
            sps: sps,
            pps: pps,
            isKeyframe: true,
            rtpTimestamp: 90_000
        )
        XCTAssertEqual(keyframeRtp.count, 4, "1 STAP-A (SPS+PPS) + 3 FU-A fragments expected")

        var decodedUnits: [ZolaH264AssembledAccessUnit] = []
        for pkt in keyframeRtp {
            decodedUnits.append(contentsOf: depacketizer.ingestRtpPacket(pkt))
        }
        XCTAssertFalse(depacketizer.needsKeyframePli)
        XCTAssertEqual(decodedUnits.count, 1)
        XCTAssertEqual(decodedUnits[0].sps, sps)
        XCTAssertEqual(decodedUnits[0].pps, pps)
        XCTAssertTrue(decodedUnits[0].containsIdr)
        XCTAssertEqual(decodedUnits[0].vclNalUnits, [idrNal])

        // Single small P-slice NAL (<= 400 bytes -> Single NAL mode)
        let pSlice = Data([0x41, 0x9A, 0x22, 0x33, 0x44, 0x55])
        let pRtp = packetizer.packetizeAccessUnit(
            nalUnits: [pSlice],
            sps: nil,
            pps: nil,
            isKeyframe: false,
            rtpTimestamp: 94_500
        )
        XCTAssertEqual(pRtp.count, 1)
        let pUnits = depacketizer.ingestRtpPacket(pRtp[0])
        XCTAssertEqual(pUnits.count, 1)
        XCTAssertEqual(pUnits[0].vclNalUnits, [pSlice])
        XCTAssertFalse(pUnits[0].containsIdr)

        // Simulate sequence gap (drop 1 FU-A fragment) -> must request RTCP PLI and discard partial FU-A!
        let lostFrameRtp = packetizer.packetizeAccessUnit(
            nalUnits: [idrNal],
            sps: nil,
            pps: nil,
            isKeyframe: false,
            rtpTimestamp: 99_000
        )
        XCTAssertEqual(lostFrameRtp.count, 3)
        _ = depacketizer.ingestRtpPacket(lostFrameRtp[0]) // FU-A Start
        // Drop lostFrameRtp[1] (middle fragment)!
        let corruptedUnits = depacketizer.ingestRtpPacket(lostFrameRtp[2]) // FU-A End after gap
        XCTAssertTrue(corruptedUnits.isEmpty, "Corrupted FU-A with missing middle fragment must be dropped")
        XCTAssertTrue(depacketizer.needsKeyframePli, "Sequence gap must raise needsKeyframePli for instant keyframe recovery")
        depacketizer.clearPliFlag()

        // Simulate dropping a Single-NAL P-frame packet -> arriving non-IDR slice after gap must be discarded + raise PLI!
        let droppedSingleP = packetizer.packetizeAccessUnit(
            nalUnits: [pSlice],
            sps: nil,
            pps: nil,
            isKeyframe: false,
            rtpTimestamp: 103_500
        )
        let afterGapSingleP = packetizer.packetizeAccessUnit(
            nalUnits: [pSlice],
            sps: nil,
            pps: nil,
            isKeyframe: false,
            rtpTimestamp: 108_000
        )
        _ = droppedSingleP // intentionally lost in transit
        let gapPUnits = depacketizer.ingestRtpPacket(afterGapSingleP[0])
        XCTAssertTrue(gapPUnits.isEmpty, "Non-IDR Single-NAL arriving immediately after RTP sequence gap must not emit incomplete/unreferenced slice")
        XCTAssertTrue(depacketizer.needsKeyframePli)

        // Malformed RTP padding (`P=1` with trailing `padLen = 0`) must return `nil`
        var badPaddedRtp = Data([0xA0, 0x61, 0x00, 0x99, 0x00, 0x01, 0xAB, 0xCD, 0xCA, 0xFE, 0x12, 0x34])
        badPaddedRtp.append(contentsOf: [0x41, 0x9A, 0x00])
        XCTAssertNil(ZolaH264RtpDepacketizer.parseRtpPacket(badPaddedRtp))
    }

    #if canImport(Network)
    func testSeqWaiterIgnoresSuccessfulMsgType3AndWaitsForMsgType4() {
        XCTAssertFalse(ZolaVoipSocketSession.resolvesSeqWaiter(element(msgType: 3, retCode: 0)))
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(element(msgType: 3, retCode: -12)))
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(element(msgType: 4, retCode: 0)))
        XCTAssertTrue(ZolaVoipSocketSession.resolvesSeqWaiter(element(msgType: 4, retCode: 0, cmd: 205)))
        XCTAssertFalse(ZolaVoipSocketSession.resolvesSeqWaiter(element(msgType: 1, retCode: 0)))
    }
    #endif

    #if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testH264DepacketizerFiltersRtxFecEmptyPaddingAndReordersOutOfOrderUdpPackets() throws {
        var packetizer = ZolaH264RtpPacketizer(
            ssrc: 0x55AA_7788,
            payloadType: 97,
            maxPayloadSize: 320,
            initialSequenceNumber: 500,
            initialTimestampOffset: 0
        )
        var depacketizer = ZolaH264RtpDepacketizer(
            expectedPayloadType: 97,
            reorderWindow: 16,
            maxReorderHoldSeconds: 0.050
        )

        let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x01, 0x41, 0xFB, 0x01, 0x10])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        var idrNal = Data([0x65])
        for i in 0..<1_020 {
            idrNal.append(UInt8(truncatingIfNeeded: i &* 17 &+ 3))
        }

        let rtpList = packetizer.packetizeAccessUnit(
            nalUnits: [idrNal],
            sps: sps,
            pps: pps,
            isKeyframe: true,
            rtpTimestamp: 90_000
        )
        XCTAssertEqual(rtpList.count, 5, "1 STAP-A + 4 FU-A fragments expected")

        // 1. Pre-lock foreign RTX packet (`PT = 100`, SSRC `0xDEAD_BEEF`) must not lock `remoteSsrc`.
        let rtxNoise = ZolaVoipMediaEngine.buildRtpPacket(
            payloadType: 100,
            sequenceNumber: 9_999,
            timestamp: 12_345,
            ssrc: 0xDEAD_BEEF,
            payload: Data([0x01, 0xF4, 0x41, 0x9A, 0x11])
        )
        XCTAssertTrue(depacketizer.ingestRtpPacket(rtxNoise, arrivalUptime: 10.0).isEmpty)
        XCTAssertEqual(depacketizer.remoteSsrc, 0)
        XCTAssertFalse(depacketizer.needsKeyframePli)

        // 2. Deliver packets out of order (`0, 2, 1, 4, 3`) with interleaved RTX noise mid-FU-A!
        let reorderedIndices = [0, 2, 1, 4, 3]
        var assembled: [ZolaH264AssembledAccessUnit] = []
        for (step, idx) in reorderedIndices.enumerated() {
            let t = 10.01 + Double(step) * 0.004
            if step == 2 {
                // Inject secondary-SSRC RTX mid-FU-A: must NOT reset `remoteSsrc` or corrupt `fuaBuffer`!
                let midRtx = ZolaVoipMediaEngine.buildRtpPacket(
                    payloadType: 100,
                    sequenceNumber: 10_000,
                    timestamp: 99_999,
                    ssrc: 0xDEAD_BEEF,
                    payload: Data([0x01, 0xF5, 0x7C, 0x05, 0xAA])
                )
                XCTAssertTrue(depacketizer.ingestRtpPacket(midRtx, arrivalUptime: t).isEmpty)
            }
            assembled.append(contentsOf: depacketizer.ingestRtpPacket(rtpList[idx], arrivalUptime: t))
        }

        XCTAssertFalse(depacketizer.needsKeyframePli, "Out-of-order FU-A fragments within reorder window must reassemble with zero false PLI")
        XCTAssertGreaterThanOrEqual(depacketizer.reorderedPacketsRecovered, 2)
        XCTAssertEqual(assembled.count, 1)
        XCTAssertTrue(assembled[0].containsIdr)
        XCTAssertEqual(assembled[0].vclNalUnits, [idrNal])

        // 3. Same-SSRC empty RFC 3550 RTP padding probe (`P=1`, `PT=97`, 24 padding bytes, different timestamp)
        // followed by a P-frame at the next sequence number must NOT trigger a false sequence gap or abort frames!
        let padSeq = packetizer.sequenceNumber
        var paddingProbe = Data([0xA0, 97]) // V=2, P=1, PT=97
        paddingProbe.append(UInt8((padSeq >> 8) & 0xFF))
        paddingProbe.append(UInt8(padSeq & 0xFF))
        paddingProbe.append(contentsOf: [0x00, 0x00, 0x11, 0x11]) // probe timestamp != video frame timestamp
        paddingProbe.append(contentsOf: [0x55, 0xAA, 0x77, 0x88]) // matching SSRC 0x55AA7788
        paddingProbe.append(Data(repeating: 0x00, count: 23))
        paddingProbe.append(24) // RFC 3550 padding length byte = 24
        let parsedPad = try XCTUnwrap(ZolaH264RtpDepacketizer.parseRtpPacketAllowingEmptyPadding(paddingProbe))
        XCTAssertTrue(parsedPad.payload.isEmpty)
        XCTAssertTrue(depacketizer.ingestRtpPacket(paddingProbe, arrivalUptime: 10.05).isEmpty)
        XCTAssertFalse(depacketizer.needsKeyframePli)

        // Advance packetizer past `padSeq` by building a manual P-frame at `padSeq &+ 1`
        let pNal = Data([0x41, 0x9A, 0x55, 0x66, 0x77])
        var pPkt = Data([0x80, 0x80 | 97])
        let nextSeq = padSeq &+ 1
        pPkt.append(UInt8((nextSeq >> 8) & 0xFF))
        pPkt.append(UInt8(nextSeq & 0xFF))
        pPkt.append(contentsOf: [0x00, 0x01, 0x71, 0x24, 0x55, 0xAA, 0x77, 0x88])
        pPkt.append(pNal)
        let pOut = depacketizer.ingestRtpPacket(pPkt, arrivalUptime: 10.06)
        XCTAssertEqual(pOut.count, 1)
        XCTAssertFalse(depacketizer.needsKeyframePli)

        // 4. Genuine packet loss (`nextSeq &+ 1` lost, `nextSeq &+ 2` arrives) flushes after 50ms timeout and raises PLI!
        let afterLossSeq = nextSeq &+ 2
        var postLossPkt = Data([0x80, 0x80 | 97])
        postLossPkt.append(UInt8((afterLossSeq >> 8) & 0xFF))
        postLossPkt.append(UInt8(afterLossSeq & 0xFF))
        postLossPkt.append(contentsOf: [0x00, 0x01, 0x82, 0xB8, 0x55, 0xAA, 0x77, 0x88])
        postLossPkt.append(pNal)
        XCTAssertTrue(depacketizer.ingestRtpPacket(postLossPkt, arrivalUptime: 11.00).isEmpty, "Held briefly inside 50ms reorder window")
        XCTAssertTrue(depacketizer.hasPendingReorderPackets)
        _ = depacketizer.flushExpiredReorderBuffer(nowUptime: 11.06)
        XCTAssertFalse(depacketizer.hasPendingReorderPackets)
        XCTAssertTrue(depacketizer.needsKeyframePli, "Expired reorder gap must raise needsKeyframePli within 50ms")
        depacketizer.clearPliFlag()

        // 5. Same-SSRC backward sequence restart (e.g. `seq = 12` after `~508`, `behindDistance > maxLateBehind`)
        // must reset continuity and decode immediately instead of dropping ~32k packets!
        var restartPkt = Data([0x80, 0x80 | 97, 0x00, 12])
        restartPkt.append(contentsOf: [0x00, 0x02, 0x00, 0x00, 0x55, 0xAA, 0x77, 0x88])
        restartPkt.append(Data([0x65, 0x88, 0x84, 0x21]))
        let restartUnits = depacketizer.ingestRtpPacket(restartPkt, arrivalUptime: 12.00)
        XCTAssertEqual(restartUnits.count, 1, "Backward sequence restart on same SSRC must deliver frame immediately")
        XCTAssertTrue(depacketizer.needsKeyframePli)
    }
    #endif
}
