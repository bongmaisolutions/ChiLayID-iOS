import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Fixtures are derived from native IPA 26.10.02 dispatch/parser/ACK implementations.
/// They are not captured production packets. The test exercises the encrypted transport and real client handler.
final class ZolaNativeReactionSocketTests: XCTestCase {
    private final class NoHTTP: ZolaNetworkTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requestCount: Int { lock.withLock { count } }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            lock.withLock { count += 1 }
            throw ZolaError.transport("Offline fixture forbids HTTP")
        }
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ZolaEvent] = []
        func append(_ event: ZolaEvent) -> Int { lock.withLock { stored.append(event); return stored.count } }
        var values: [ZolaEvent] { lock.withLock { stored } }
    }
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let key = Data(repeating: 0xA5, count: 32)
        let keyID = "reaction-fixture-key"
        let queue = DispatchQueue(label: "zolakit.reaction.encrypted.fixture")
        private var connection: NWConnection?
        private var crypto: ZolaSocketCrypto?
        private let lock = NSLock()
        private var received: [ZolaUnpackedChatElement] = []
        var frames: [ZolaUnpackedChatElement] { lock.withLock { received } }
        init() throws { listener = try NWListener(using: .tcp, on: .any) }
        func start(ready: XCTestExpectation, acks: XCTestExpectation, expectedAckCount: Int = 5) {
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { [self] conn in
                connection = conn
                var buffer = Data()
                var preamble = false
                func pump() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                        if let data { buffer.append(data) }
                        if !preamble, let end = buffer.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                            preamble = true
                        }
                        while preamble, buffer.count >= 51 {
                            guard let length = try? Data(buffer.prefix(4)).readUInt32LE(at: 0), buffer.count >= Int(length) else { break }
                            let wire = Data(buffer.prefix(Int(length)))
                            buffer.removeFirst(Int(length))
                            do {
                                if wire[4] == 0x08 {
                                    let opened = try ZolaSocketCrypto.openAuthenFrame(wire, serverPrivateKeyRaw32: privateKey.rawRepresentation,
                                        resolveKeySetValue: { [self] in $0 == self.keyID ? self.key : nil })
                                    let auth = try ZolaCrypto.unpackChatElementFrame(opened.chatElementPayload)
                                    crypto = try ZolaSocketCrypto(keySetId: keyID, keySetValueBase64: key.base64EncodedString())
                                    let ack = ZolaCrypto.packServerChatElementFrame(bodyData: Data("{}".utf8), srcId: 100_000_001,
                                        msgType: 3, cmd: 1, subCmd: 5, seqId: auth.seqId)
                                    sendNow(ack)
                                } else if wire[4] == 0x04, let crypto {
                                    let element = try ZolaCrypto.unpackChatElementFrame(crypto.openFrame(wire))
                                    let ackCount = lock.withLock {
                                        received.append(element)
                                        return received.filter { $0.cmd == 1781 || $0.cmd == 1786 }.count
                                    }
                                    if (element.cmd == 1781 || element.cmd == 1786), ackCount == expectedAckCount { acks.fulfill() }
                                }
                            } catch { XCTFail("Encrypted fixture decode failed: \(error)") }
                        }
                        if !done && error == nil { pump() }
                    }
                }
                conn.start(queue: queue)
                pump()
            }
            listener.start(queue: queue)
        }
        private func sendNow(_ frame: ZolaChatElementFrame) {
            guard let crypto, let connection else { return }
            do { connection.send(content: try crypto.sealFrame(frame.payload), completion: .contentProcessed { _ in }) }
            catch { XCTFail("Encrypted fixture send failed: \(error)") }
        }
        func push(_ frames: [ZolaChatElementFrame]) { queue.async { frames.forEach { self.sendNow($0) } } }
        func stop() { queue.async { self.connection?.cancel(); self.listener.cancel() } }
    }

    private actor DurableReactions {
        var attempts = 0
        func persist(_ events: [ZolaEvent], offline: Bool, failed: XCTestExpectation) throws {
            attempts += 1
            XCTAssertTrue(offline)
            XCTAssertEqual(events.first?.type, "message.reaction")
            if attempts == 1 { failed.fulfill(); throw ZolaError.transport("Synthetic disk failure") }
        }
    }

    func testReactionAckWaitsForDurableMutationAndFailedBatchCanReplay() async throws {
        let server = try Server(); defer { server.stop() }
        let ready = expectation(description: "Reaction durable fixture ready")
        let ack = expectation(description: "Reaction ACK after durable commit")
        let failed = expectation(description: "First mutation persistence failed")
        server.start(ready: ready, acks: ack, expectedAckCount: 1)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-reaction-durable", cryptKey: Data(repeating: 3, count: 16),
            zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let client = ZolaClient(session: session, transport: NoHTTP()), events = Events(), gate = DurableReactions()
        await client.setRealtimeEventHandler { _ = events.append($0) }
        await client.setDurableRealtimeMessageHandler { events, offline in try await gate.persist(events, offline: offline, failed: failed) }
        try await client.startVoipIncomingListener()
        let payload = try body(envelopeID: 9001, actor: 42, destination: session.uid, icon: "/-heart")
        let frame = ZolaCrypto.packServerChatElementFrame(bodyData: payload, srcId: 42, msgType: 3, cmd: 1780)
        server.push([frame])
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(server.frames.contains { $0.cmd == 1781 })
        XCTAssertTrue(events.values.isEmpty)
        server.push([frame])
        await fulfillment(of: [ack], timeout: 3)
        XCTAssertEqual(events.values.count, 1)
        XCTAssertEqual(events.values.first?.type, "message.reaction")
        await client.stopVoipIncomingListener()
    }

    private func body(envelopeID: Int64, actor: Int64, destination: Int64, icon: String, targetID: Int64 = 5001) throws -> Data {
        let params: [String: Any] = ["rType": 0, "rIcon": icon, "rCount": 1,
            "msgSender": "100000001", "rMsg": [["gMsgID": targetID, "cMsgID": targetID > 0 ? 6001 : 0, "msgType": 1]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["more": 0, "msg": [["text": ["type": "chat.reaction", "data": [
            "id": envelopeID, "cliMsgId": envelopeID + 10000, "fromU": actor, "to": destination,
            "ts": 1_700_000_000_000 as Int64, "msg": "", "attach": ["params": json]]]]]])
    }

    func testReactionAckContainsConcatenatedLittleEndianEnvelopeIDsAndRejectsInvalidIDs() throws {
        for group in [false, true] {
            let frame = try XCTUnwrap(ZolaCrypto.packSocketReactionAckFrame(srcId: 42,
                globalMessageIds: [0x0102030405060708, 9], isGroup: group, seqId: 77))
            let decoded = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            XCTAssertEqual(decoded.cmd, group ? 1786 : 1781)
            XCTAssertEqual(decoded.subCmd, group ? 1 : 0)
            XCTAssertEqual(decoded.srcId, 42)
            XCTAssertEqual(decoded.srcType, 3)
            XCTAssertEqual(decoded.msgType, 1)
            XCTAssertEqual(decoded.needAck, 0)
            XCTAssertEqual(decoded.seqId, 77)
            XCTAssertEqual(Array(decoded.bodyData), [8, 7, 6, 5, 4, 3, 2, 1, 9, 0, 0, 0, 0, 0, 0, 0])
        }
        for ids: [Int64] in [[], [0], [-1], [9, 0]] {
            XCTAssertNil(ZolaCrypto.packSocketReactionAckFrame(srcId: 42, globalMessageIds: ids, isGroup: false, seqId: 77))
        }
    }

    func testEncrypted178xDispatchesReactionsAndAcknowledgesEnvelopeIDsWithoutChatSideEffects() async throws {
        let server = try Server()
        defer { server.stop() }
        let ready = expectation(description: "Encrypted fixture ready")
        let acks = expectation(description: "Five native reaction ACKs")
        let delivered = expectation(description: "Four reaction commands plus replay delivered")
        server.start(ready: ready, acks: acks)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-native-reaction-fixture",
            cryptKey: Data(repeating: 0x33, count: 16), zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                                  pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let transport = NoHTTP()
        let client = ZolaClient(session: session, transport: transport, minPollIntervalSeconds: 0)
        let events = Events()
        await client.setRealtimeEventHandler { event in if events.append(event) == 5 { delivered.fulfill() } }
        try await client.startVoipIncomingListener()
        let before = await client.watermarks
        var packets: [ZolaChatElementFrame] = []
        for (index, cmd) in [Int16(1780), 1782, 1785, 1787].enumerated() {
            let group = cmd >= 1785
            let actor: Int64 = cmd == 1782 ? session.uid : 42
            let destination: Int64 = group ? 777 : (actor == session.uid ? 42 : session.uid)
            let raw = try body(envelopeID: Int64(9001 + index), actor: actor, destination: destination, icon: cmd == 1787 ? "" : ":>")
            packets.append(ZolaCrypto.packServerChatElementFrame(bodyData: raw, gzipBody: index % 2 == 0,
                srcId: Int32(session.uid), msgType: 3, cmd: cmd, subCmd: group ? 1 : 0, seqId: Int32(30 + index)))
        }
        let replay = packets[0]
        let validBody = try body(envelopeID: 9991, actor: 42, destination: session.uid, icon: ":>")
        let invalid = try body(envelopeID: 9992, actor: 42, destination: session.uid, icon: ":>", targetID: 0)
        let gzip = try XCTUnwrap(ZolaCrypto.gzipCompress(validBody))
        var errorBody = try XCTUnwrap(JSONSerialization.jsonObject(with: validBody) as? [String: Any])
        errorBody["error_code"] = -500
        let missingActor = try body(envelopeID: 9993, actor: 0, destination: session.uid, icon: ":>")
        let invalidBodies = [Data("not-json".utf8), Data(gzip.prefix(gzip.count - 6)), invalid, missingActor,
                             try JSONSerialization.data(withJSONObject: errorBody)]
        for raw in invalidBodies {
            packets.append(ZolaCrypto.packServerChatElementFrame(bodyData: raw, srcId: Int32(session.uid), msgType: 3, cmd: 1780))
        }
        packets.append(ZolaCrypto.packServerChatElementFrame(bodyData: validBody, srcId: Int32(session.uid), msgType: 3, cmd: 1780, retCode: -500))
        packets.append(ZolaCrypto.packServerChatElementFrame(bodyData: validBody, srcId: Int32(session.uid), msgType: 4, cmd: 1780))
        packets.append(replay)
        server.push(packets)
        await fulfillment(of: [delivered, acks], timeout: 4)
        try await Task.sleep(nanoseconds: 250_000_000)
        let after = await client.watermarks
        await client.stopVoipIncomingListener()
        let values = events.values
        XCTAssertEqual(values.count, 5)
        XCTAssertTrue(values.allSatisfy { $0.type == "message.reaction" && $0.message == nil })
        XCTAssertEqual(values.compactMap { $0.reaction?.emoji }, ["😆", "😆", "😆", "", "😆"])
        XCTAssertEqual(values.compactMap { $0.reaction?.threadId }, [42, 42, 777, 777, 42])
        XCTAssertEqual(values.compactMap { $0.reaction?.actorUid }, [42, session.uid, 42, 42, 42])
        XCTAssertEqual(values.compactMap { $0.reaction?.messageId }, [5001, 5001, 5001, 5001, 5001])
        let ackFrames = server.frames.filter { $0.cmd == 1781 || $0.cmd == 1786 }
        XCTAssertEqual(ackFrames.map(\.cmd), [1781, 1781, 1786, 1786, 1781])
        XCTAssertEqual(ackFrames.map(\.subCmd), [0, 0, 1, 1, 0])
        XCTAssertTrue(ackFrames.allSatisfy { $0.bodyData.count == 8 && $0.msgType == 1 && $0.needAck == 0 })
        XCTAssertEqual(try ackFrames.map { try $0.bodyData.readInt64LE(at: 0) }, [9001, 9002, 9003, 9004, 9001])
        XCTAssertFalse(server.frames.contains { $0.cmd == 102 || $0.cmd == 202 })
        XCTAssertEqual(after, before, "Reaction IDs must not advance normal chat cursors or seen IDs")
        XCTAssertEqual(transport.requestCount, 0, "Reaction payloads must not be discarded in favor of an HTTP wakeup poll")
    }
}
#endif
