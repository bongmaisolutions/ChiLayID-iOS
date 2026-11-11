import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Fixtures are derived from native IPA 26.10.02 dispatch/parser/ACK implementations.
/// They are not captured production packets. The test exercises the encrypted transport and real client handler.
final class NativeNotificationAcknowledgementSocketTests: XCTestCase {
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
        private var connectionCountValue = 0
        var connectionCount: Int { lock.withLock { connectionCountValue } }
        var frames: [ZolaUnpackedChatElement] { lock.withLock { received } }
        init() throws { listener = try NWListener(using: .tcp, on: .any) }
        func start(ready: XCTestExpectation, acks: XCTestExpectation) {
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { [self] conn in
                lock.withLock { connectionCountValue += 1 }
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
                                        return received.filter { $0.cmd == 601 }.count
                                    }
                                    if element.cmd == 601, ackCount == 2 { acks.fulfill() }
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

    func testEncryptedNotificationReplayAcknowledgesExactIDsWithoutDuplicateEvents() async throws {
        let server = try Server(); defer { server.stop() }
        let ready = expectation(description: "Encrypted notification fixture ready")
        let acks = expectation(description: "Original and replay notification acknowledgements")
        let received = expectation(description: "Two targeted group invalidations")
        server.start(ready: ready, acks: acks)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-notifications", cryptKey: Data(repeating: 3, count: 16),
            zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let http = NoHTTP(), events = Events()
        let client = ZolaClient(session: session, transport: http, minPollIntervalSeconds: 0)
        await client.setRealtimeEventHandler { event in
            if events.append(event) == 2 { received.fulfill() }
        }
        try await client.startVoipIncomingListener()
        let before = await client.watermarks
        let body = Data(#"[{"id":"9007199254740993","type":188,"item":[{"groupId":777},{"groupId":778}]}]"#.utf8)
        let valid = ZolaCrypto.packServerChatElementFrame(bodyData: body, gzipBody: true, srcId: 42, msgType: 3, cmd: 600)
        server.push([valid, valid,
            ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 42, msgType: 3, cmd: 601),
            ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 42, msgType: 4, cmd: 600),
            ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 42, msgType: 3, cmd: 600, retCode: -500),
            ZolaCrypto.packServerChatElementFrame(bodyData: Data("bad-json".utf8), srcId: 42, msgType: 3, cmd: 600),
            ZolaCrypto.packServerChatElementFrame(bodyData: Data([0x1f,0x8b,0,1]), srcId: 42, msgType: 3, cmd: 600),
            ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"[{"id":"99","type":189,"item":[{"groupId":777}]}]"#.utf8), srcId: 42, msgType: 3, cmd: 600)
        ])
        await fulfillment(of: [received, acks], timeout: 3)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(events.values.map(\.type), ["group.info.changed", "group.info.changed"])
        XCTAssertEqual(events.values.compactMap(\.groupId).sorted(), [777,778])
        XCTAssertTrue(events.values.allSatisfy { $0.message == nil })
        let replies = server.frames.filter { $0.cmd == 601 }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(server.connectionCount, 1)
        for reply in replies {
            XCTAssertEqual(reply.bodyData, Data([1,0,0,0,0,0,0x20,0]))
            XCTAssertEqual(reply.srcId, 100_000_001)
            XCTAssertEqual(reply.srcType, 3)
            XCTAssertEqual(reply.msgType, 1)
            XCTAssertEqual(reply.subCmd, 0)
            XCTAssertEqual(reply.needAck, 0)
        }
        let after = await client.watermarks
        XCTAssertEqual(before, after)
        XCTAssertFalse(server.frames.contains { $0.cmd == 102 || $0.cmd == 202 })
        // -67 is a refreshable native session-key error, not permanent session expiry.
        server.push([ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"{"error_code":-67}"#.utf8), srcId: 42, msgType: 3, cmd: 600)])
        try await Task.sleep(nanoseconds: 150_000_000)
        let aliveAfterKeyError = await client.session.isExpired == false
        XCTAssertTrue(aliveAfterKeyError)
        XCTAssertEqual(events.values.map(\.type), ["group.info.changed", "group.info.changed"])
        XCTAssertEqual(server.frames.filter { $0.cmd == 601 }.count, 2, "Key errors are never notification ACK targets")
        server.push([ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"{"error_code":102}"#.utf8), srcId: 42, msgType: 3, cmd: 600)])
        try await Task.sleep(nanoseconds: 150_000_000)
        let expired = await client.session.isExpired
        XCTAssertTrue(expired)
        XCTAssertEqual(events.values.last?.type, "session.expired")
        XCTAssertEqual(events.values.last?.errorCode, 102, "The listener remains usable after the refreshable -67 error")
        XCTAssertEqual(server.frames.filter { $0.cmd == 601 }.count, 2)
        await client.stopVoipIncomingListener()
    }
}
#endif
