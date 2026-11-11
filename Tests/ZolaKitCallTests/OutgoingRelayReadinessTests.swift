import XCTest
import Network
import Foundation
@testable import ZolaKit
#if canImport(AVFoundation) && canImport(AudioToolbox)
final class OutgoingRelayReadinessTests: XCTestCase {
    func testDelayedRelayAcknowledgementMustPrecede416() async throws {
        try await runRelayOrdering(ackDelay: 0.9)
    }
    func testDroppedRelayAcknowledgementCancelsAllocatedCallWithout416() async throws {
        try await runRelayOrdering(ackDelay: nil)
    }
    private func runRelayOrdering(ackDelay: Double?) async throws {
        let tcpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.pre416.tcp")
        let udpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.pre416.udp")
        let tcpListener = try NWListener(using: .tcp, on: .any)
        let udpRelayListener = try NWListener(using: .udp, on: .any)
        defer {
            tcpListener.cancel()
            udpRelayListener.cancel()
        }

        let tcpReady = expectation(description: "Mock 0x7d0 TCP ready")
        let udpReady = expectation(description: "Mock :4200 UDP relay ready")
        let ringingExp = XCTestExpectation(description: "Received cmd=407 continuous ringing")
        let cancelExp = XCTestExpectation(description: "Allocated call cancelled on relay timeout")

        final class OrderingBox: @unchecked Sendable {
            private let lock = NSLock()
            var timeline: [String] = []
            var cmd416PayloadUtf8: String = ""
            func record(_ event: String) {
                lock.lock()
                timeline.append(event)
                lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return timeline
            }
        }
        let box = OrderingBox()

        tcpListener.stateUpdateHandler = { st in if case .ready = st { tcpReady.fulfill() } }
        udpRelayListener.stateUpdateHandler = { st in if case .ready = st { udpReady.fulfill() } }

        udpRelayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pumpUdp() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, data.count >= 31, data[0] == 0x01, (try? data.readUInt16LE(at: 18)) == 11 {
                        box.record("udp:init11")
                        // Build exact 54-byte live-shaped `0x02` `InitZRTP` response (`retCode=0 @ 21`, `callId @ 25`, `addrLen=19 @ 33`, ASCII `"58.187.162.19:51515" @ 35`).
                        let seq = (try? data.readUInt32LE(at: 6)) ?? 1
                        let selfUidWord = (try? data.readUInt32LE(at: 10)) ?? 0
                        let callIdWord = (try? data.readUInt32LE(at: 21)) ?? 0
                        let reflectedAscii = Data("58.187.162.19:51515".utf8)
                        var ack = Data(capacity: 35 + reflectedAscii.count)
                        ack.append(0x02)
                        ack.append(0x00)
                        ack.appendUInt32LE(0)
                        ack.appendUInt32LE(seq)
                        ack.appendUInt32LE(selfUidWord)
                        ack.appendUInt32LE(0)
                        ack.appendUInt16LE(11)
                        ack.append(0x02)
                        ack.appendUInt32LE(0) // `retCode = 0`
                        ack.appendUInt32LE(callIdWord)
                        ack.appendUInt32LE(0xFA95_CA05)
                        ack.appendUInt16LE(UInt16(reflectedAscii.count))
                        ack.append(reflectedAscii)
                        if let ackDelay {
                            let delayedAck = ack
                            udpQueue.asyncAfter(deadline: .now() + ackDelay) {
                                box.record("udp:ack02")
                                conn.send(content: delayedAck, completion: .contentProcessed { _ in })
                            }
                        }
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pumpUdp()
                }
            }
            pumpUdp()
        }

        udpRelayListener.start(queue: udpQueue)
        await fulfillment(of: [udpReady], timeout: 3.0)
        let udpPort = try XCTUnwrap(udpRelayListener.port?.rawValue)

        tcpListener.newConnectionHandler = { conn in
            conn.start(queue: tcpQueue)
            var buf = Data()
            var upgraded = false
            func pumpTcp() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, _ in
                    if let chunk, !chunk.isEmpty {
                        buf.append(chunk)
                        if !upgraded, let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                            buf.removeSubrange(buf.startIndex..<r.upperBound)
                            upgraded = true
                            conn.send(content: Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        if upgraded {
                            while buf.count >= 23, let fLen = try? Data(buf.prefix(4)).readUInt32LE(at: 0), buf.count >= Int(fLen) {
                                let raw = Data(buf.prefix(Int(fLen)))
                                buf.removeFirst(Int(fLen))
                                guard let el = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }
                                if el.cmd == 1 {
                                    let ack = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 1, subCmd: 5, seqId: el.seqId)
                                    conn.send(content: ack.payload, completion: .contentProcessed { _ in })
                                } else if el.cmd == 401 {
                                    box.record("tcp:401")
                                    let rtpStr = "127.0.0.1:\(udpPort)"
                                    let body = Data(#"{"error_code":0,"data":{"status":0,"id":770055,"sessId":"sess_pre416_live","serverAddr":[{"rtp":"\#(rtpStr)","rtcp":"\#(rtpStr)"}]}}"#.utf8)
                                    let resp = ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 100_000_102, msgType: 3, cmd: 401, subCmd: 1, seqId: el.seqId)
                                    conn.send(content: resp.payload, completion: .contentProcessed { _ in })
                                } else if el.cmd == 405 {
                                    box.record("tcp:405")
                                    if ackDelay == nil { cancelExp.fulfill() }
                                } else if el.cmd == 416 {
                                    box.record("tcp:416")
                                    box.cmd416PayloadUtf8 = String(decoding: el.bodyData, as: UTF8.self)
                                    // Push live-shaped `cmd=407` with nested `extraData` JSON string carrying callee's P2P candidates (`status: 0`).
                                    let ringJson = #"{"error_code":0,"data":{"id":770055,"status":0,"neekACK":1,"extraData":"{\"audioCodec\":{},\"extendData\":{\"callType\":0,\"p2p\":[{\"ip\":\"192.168.1.9\",\"port\":53827,\"type\":0},{\"ip\":\"58.187.162.19\",\"port\":53827,\"type\":1}]}}"}}"#
                                    let ringPush = ZolaCrypto.packServerChatElementFrame(bodyData: Data(ringJson.utf8), srcId: 100_000_102, msgType: 1, cmd: 407, subCmd: 0, seqId: 99)
                                    conn.send(content: ringPush.payload, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    if !isComplete { pumpTcp() }
                }
            }
            pumpTcp()
        }

        tcpListener.start(queue: tcpQueue)
        await fulfillment(of: [tcpReady], timeout: 3.0)
        let tcpPort = try XCTUnwrap(tcpListener.port?.rawValue)

        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_pre416_test",
            zcid: "native_zcid_pre416",
            zcidIsNative: true
        )
        let client = ZolaClient(
            session: session,
            voipLoopbackEndpoints: [("127.0.0.1", tcpPort)]
        )
        await client.setVoipEventHandler { ev in
            if case .ringing(callId: 770_055, partnerUid: 100_000_102) = ev {
                ringingExp.fulfill()
            }
        }

        if ackDelay == nil {
            do {
                _ = try await client.startVoipCall(partnerUid: 100_000_102, callId: 111_222,
                    localEndpoint: "192.168.1.35:49000")
                XCTFail("A relay that never ACKs must not publish416")
            } catch {
                guard case let ZolaError.server(code, _) = error else { throw error }
                XCTAssertEqual(code, -3402)
            }
            await fulfillment(of: [cancelExp], timeout: 2)
            XCTAssertFalse(box.snapshot().contains("tcp:416"))
            let retained = await client.takePreparedVoipMediaEngine(forCallId: 770_055)
            XCTAssertNil(retained)
            await client.closeVoipCallSession()
            return
        }

        let receipt = try await client.startVoipCall(
            partnerUid: 100_000_102,
            callId: 111_222,
            localEndpoint: "192.168.1.35:49000"
        )
        XCTAssertTrue(receipt.ok)
        XCTAssertEqual(receipt.callId, 770_055)

        let prepared = await client.takePreparedVoipMediaEngine(forCallId: 770_055)
        let engine = try XCTUnwrap(prepared, "ZolaClient.startVoipCall must retain the pre-416 registered ZolaVoipMediaEngine for single-socket continuity")
        defer { engine.stop() }
        XCTAssertTrue(engine.isRelayHandshakeConfirmed)
        XCTAssertEqual(engine.reflectedPublicEndpoint, "58.187.162.19:51515")

        await fulfillment(of: [ringingExp], timeout: 3.0)

        let events = box.snapshot()
        guard let idx401 = events.firstIndex(of: "tcp:401"),
              let idxInit11 = events.firstIndex(of: "udp:init11"),
              let idx416 = events.firstIndex(of: "tcp:416")
        else {
            return XCTFail("Missing expected protocol sequence in \(events)")
        }
        XCTAssertLessThan(idx401, idxInit11, "InitZRTP (pktCmd=11) must follow cmd=401")
        XCTAssertLessThan(idxInit11, idx416)
        let idxAck = try XCTUnwrap(events.firstIndex(of: "udp:ack02"))
        XCTAssertLessThan(idxAck, idx416, "Even an ACK arriving after the old400ms deadline must precede416")
        XCTAssertTrue(box.cmd416PayloadUtf8.contains("58.187.162.19"), "cmd=416 externData must advertise STUN-reflected type=1 P2P candidate")
        XCTAssertTrue(box.cmd416PayloadUtf8.contains("51515"))

        let rawCtx = await client.voipCallEndpoints(forCallId: 770_055)
        let ctx = try XCTUnwrap(rawCtx)
        XCTAssertEqual(ctx.rtpAddress, "127.0.0.1:\(udpPort)", "cmd=407 must not clobber registered caller relay rtpAddress")
        let peerCandidates = ZolaVoipMediaEngine.parseP2PEndpoints(fromExtendData: ctx.extendData)
        XCTAssertTrue(peerCandidates.contains(ZolaVoipMediaEngine.MediaEndpoint(host: "192.168.1.9", port: 53_827)))
        XCTAssertTrue(peerCandidates.contains(ZolaVoipMediaEngine.MediaEndpoint(host: "58.187.162.19", port: 53_827)))

        try await client.cancelVoipCall(partnerUid: 100_000_102, callId: 770_055)
    }
}
#endif
