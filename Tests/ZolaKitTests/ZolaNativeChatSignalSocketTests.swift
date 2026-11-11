import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Fixtures are derived from native IPA 26.10.02 dispatch/parser/ACK implementations.
/// They are not captured production packets. The test exercises the encrypted transport and real client handler.
final class ZolaNativeChatSignalSocketTests: XCTestCase {
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
        let keyID = "signal-fixture-key"
        let queue = DispatchQueue(label: "zolakit.signal.encrypted.fixture")
        private var connection: NWConnection?
        private var crypto: ZolaSocketCrypto?
        private let lock = NSLock()
        private var received: [ZolaUnpackedChatElement] = []
        var frames: [ZolaUnpackedChatElement] { lock.withLock { received } }
        init() throws { listener = try NWListener(using: .tcp, on: .any) }
        func start(ready: XCTestExpectation, acks: XCTestExpectation,
                   ackCommands: [Int16] = [103, 108, 210, 211], expectedAckCount: Int = 3) {
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
                                        return received.filter { ackCommands.contains($0.cmd) }.count
                                    }
                                    if ackCommands.contains(element.cmd), ackCount == expectedAckCount { acks.fulfill() }
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

    private actor DurableGate {
        var attempts = 0
        var continuation: CheckedContinuation<Void, Never>?
        func accept(_ events: [ZolaEvent], offline: Bool, failed: XCTestExpectation, waiting: XCTestExpectation) async throws {
            attempts += 1
            XCTAssertFalse(offline)
            XCTAssertEqual(events.first?.message?.id, 9001)
            if attempts == 1 {
                failed.fulfill()
                throw ZolaError.transport("Synthetic durable write failure")
            }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiting.fulfill()
            }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testDurableIntakeFailureAndSuspensionWithholdDeliveredAckAndWatermarks() async throws {
        let server = try Server(); defer { server.stop() }
        let ready = expectation(description: "Durable fixture ready")
        let ack = expectation(description: "Delivered only after durable commit")
        let failed = expectation(description: "First persistence attempt failed")
        let waiting = expectation(description: "Second persistence attempt waiting")
        server.start(ready: ready, acks: ack, ackCommands: [102], expectedAckCount: 1)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-durable", cryptKey: Data(repeating: 3, count: 16),
            zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let http = NoHTTP(), events = Events(), gate = DurableGate()
        let client = ZolaClient(session: session, transport: http, minPollIntervalSeconds: 0)
        await client.setRealtimeEventHandler { _ = events.append($0) }
        await client.setDurableRealtimeMessageHandler { batch, offline in
            try await gate.accept(batch, offline: offline, failed: failed, waiting: waiting)
        }
        try await client.startVoipIncomingListener()
        let before = await client.watermarks
        let payload = Data(#"{"msg":[{"gmi":9001,"cmi":1001,"si":42,"di":100000001,"ts":1700000000000,"msg":"Durable fixture"}]}"#.utf8)
        let frame = ZolaCrypto.packServerChatElementFrame(bodyData: payload, srcId: 42, msgType: 3, cmd: 101)
        server.push([frame])
        await fulfillment(of: [failed], timeout: 3)
        let afterFailure = await client.watermarks
        XCTAssertEqual(before.seenIds, afterFailure.seenIds)
        XCTAssertEqual(before.femcLastGlbId, afterFailure.femcLastGlbId)
        XCTAssertEqual(before.femcLastCliId, afterFailure.femcLastCliId)
        XCTAssertLessThanOrEqual(afterFailure.singleCursors[42] ?? 0, 1)
        XCTAssertFalse(server.frames.contains { $0.cmd == 102 })
        XCTAssertTrue(events.values.isEmpty)
        server.push([frame])
        await fulfillment(of: [waiting], timeout: 3)
        let whileWaiting = await client.watermarks
        XCTAssertEqual(before.seenIds, whileWaiting.seenIds)
        XCTAssertEqual(before.femcLastGlbId, whileWaiting.femcLastGlbId)
        XCTAssertEqual(before.femcLastCliId, whileWaiting.femcLastCliId)
        XCTAssertFalse(server.frames.contains { $0.cmd == 102 })
        XCTAssertTrue(events.values.isEmpty)
        await gate.release()
        await fulfillment(of: [ack], timeout: 3)
        XCTAssertEqual(events.values.first?.message?.id, 9001)
        XCTAssertEqual(events.values.count, 1)
        XCTAssertEqual(http.requestCount, 0)
        await client.stopVoipIncomingListener()
    }

    func testEncryptedSignalsReachClientWithoutMessagesWatermarksOrAckLoops() async throws {
        let server = try Server(); defer { server.stop() }
        let ready = expectation(description: "Encrypted fixture ready")
        let acks = expectation(description: "Three status acknowledgements")
        let received = expectation(description: "Five delivery/typing updates")
        server.start(ready: ready, acks: acks)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-signals", cryptKey: Data(repeating: 3, count: 16),
            zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let http = NoHTTP(), events = Events()
        let client = ZolaClient(session: session, transport: http, minPollIntervalSeconds: 0)
        try await client.sendTypingNative(threadId: 42) // Default dry run must not open the socket.
        XCTAssertTrue(server.frames.isEmpty)
        XCTAssertEqual(http.requestCount, 0)
        await client.setRealtimeEventHandler { event in if events.append(event) == 5 { received.fulfill() } }
        try await client.startVoipIncomingListener()
        try await client.sendTypingNative(threadId: 42, dryRun: false) // Reuses the listener socket.
        let before = await client.watermarks
        let direct = Data(#"{"data":[{"di":100000001,"msg":[{"sid":42,"cmi":1001,"gmi":9001}]}],"more":1}"#.utf8)
        let group = Data(#"{"data":[{"di":777,"msg":[{"sid":42,"cmi":1002,"gmi":9002}]}]}"#.utf8)
        let packets = [
            ZolaCrypto.packServerChatElementFrame(bodyData: direct, gzipBody: true, srcId: 42, msgType: 3, cmd: 102, seqId: 80),
            ZolaCrypto.packServerChatElementFrame(bodyData: direct, srcId: 42, msgType: 3, cmd: 107, seqId: 81),
            ZolaCrypto.packServerChatElementFrame(bodyData: group, srcId: 42, msgType: 3, cmd: 203, seqId: 82),
            ZolaCrypto.packChatElementFrame(bodyData: Data(), srcId: 42, srcType: 3, msgType: 2, cmd: 106, subCmd: 1, seqId: 90),
            ZolaCrypto.packChatElementFrame(bodyData: Data(#"{"uid":42}"#.utf8), srcId: 777, srcType: 3, msgType: 2, cmd: 206, subCmd: 1, seqId: 91),
            ZolaCrypto.packServerChatElementFrame(bodyData: direct, srcId: 42, msgType: 4, cmd: 102),
            ZolaCrypto.packServerChatElementFrame(bodyData: direct, srcId: 42, msgType: 3, cmd: 103),
            ZolaCrypto.packServerChatElementFrame(bodyData: direct, srcId: 42, msgType: 3, cmd: 102, retCode: -500),
            ZolaCrypto.packServerChatElementFrame(bodyData: Data("not-json".utf8), srcId: 42, msgType: 3, cmd: 102)
        ]
        server.push(packets)
        await fulfillment(of: [received, acks], timeout: 3)
        try await Task.sleep(nanoseconds: 1_150_000_000)
        let after = await client.watermarks
        XCTAssertEqual(events.values.map(\.type), ["message.delivery", "message.delivery", "message.delivery", "conversation.typing", "conversation.typing"])
        XCTAssertTrue(events.values.allSatisfy { $0.message == nil })
        XCTAssertEqual(server.frames.filter { [Int16(103), 108, 210, 211].contains($0.cmd) }.map(\.cmd), [103,108,211])
        XCTAssertFalse(server.frames.contains { $0.cmd == 102 || $0.cmd == 202 })
        XCTAssertEqual(before, after)
        XCTAssertEqual(http.requestCount, 0)
        XCTAssertEqual(server.frames.filter { [Int16(104), 1996].contains($0.cmd) }.map(\.cmd).sorted(), [104,1996])
        let typing = try XCTUnwrap(server.frames.first { $0.cmd == 106 })
        XCTAssertEqual(typing.bodyData, Data([0]))
        XCTAssertEqual(typing.needAck, 0)
        server.push([ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"{"error_code":102}"#.utf8),
            srcId: 42, msgType: 3, cmd: 102)])
        try await Task.sleep(nanoseconds: 150_000_000)
        let expired = await client.session.isExpired
        XCTAssertTrue(expired)
        XCTAssertEqual(events.values.last?.type, "session.expired")
        do {
            try await client.sendTypingNative(threadId: 42)
            XCTFail("Expired sessions must fail even in dry run")
        } catch let error as ZolaError {
            guard case .sessionExpired = error else { return XCTFail("Expected circuit breaker, got \(error)") }
        }
        await client.stopVoipIncomingListener()
    }
}
#endif
