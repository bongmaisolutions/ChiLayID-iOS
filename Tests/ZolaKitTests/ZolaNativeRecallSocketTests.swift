import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Loopback encrypted-wire fixtures are native-IPA-derived, not a live recall claim.
final class ZolaNativeRecallSocketTests: XCTestCase {
    private final class NoHTTP: ZolaNetworkTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requestCount: Int { lock.withLock { count } }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            lock.withLock { count += 1 }
            throw ZolaError.transport("Offline fixture forbids HTTP")
        }
    }
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let key = Data(repeating: 0xA5, count: 32)
        let keyID = "recall-fixture-key"
        let queue = DispatchQueue(label: "zolakit.recall.encrypted.fixture")
        private var connection: NWConnection?
        private var crypto: ZolaSocketCrypto?
        private let lock = NSLock()
        private var received: [ZolaUnpackedChatElement] = []
        var frames: [ZolaUnpackedChatElement] { lock.withLock { received } }
        let responseBody: String?
        let outOfOrder: Bool
        private var connections = 0
        var connectionCount: Int { lock.withLock { connections } }
        init(responseBody: String? = #"{"error_code":0}"#, outOfOrder: Bool = false) throws {
            self.responseBody = responseBody
            self.outOfOrder = outOfOrder
            listener = try NWListener(using: .tcp, on: .any)
        }
        func start(ready: XCTestExpectation) {
            listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
            listener.newConnectionHandler = { [self] conn in
                lock.withLock { connections += 1 }
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
                                    lock.withLock { received.append(element) }
                                    if element.cmd == 114 || element.cmd == 204 {
                                        // Empty receipt, unrelated seq, and unrelated command must not finish recall.
                                        sendNow(ZolaCrypto.packServerChatElementFrame(srcId: element.srcId, msgType: 4,
                                            cmd: element.cmd, subCmd: 2, seqId: element.seqId))
                                        let success = Data(#"{"error_code":0}"#.utf8)
                                        sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: success, gzipBody: true,
                                            srcId: element.srcId, msgType: 3, cmd: element.cmd, subCmd: 2, seqId: element.seqId + 100))
                                        sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: success, gzipBody: true,
                                            srcId: element.srcId, msgType: 3, cmd: element.cmd == 114 ? 204 : 114,
                                            subCmd: 2, seqId: element.seqId))
                                        if let responseBody {
                                            let originalID = try element.bodyData.readInt64LE(at: 12)
                                            let delayedFailure = outOfOrder && originalID == 123456
                                            let body = delayedFailure ? #"{"error_code":-105}"# : responseBody
                                            queue.asyncAfter(deadline: .now() + (delayedFailure ? 0.09 : 0.01)) { [self] in
                                                sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: Data(body.utf8),
                                                    gzipBody: true, srcId: element.srcId, msgType: 3,
                                                    cmd: element.cmd, subCmd: 2, seqId: element.seqId))
                                            }
                                        }
                                    }
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
        func stop() { queue.async { self.connection?.cancel(); self.listener.cancel() } }
    }

    private func withClient(responseBody: String? = #"{"error_code":0}"#, outOfOrder: Bool = false,
                            _ perform: (ZolaClient, Server, NoHTTP) async throws -> Void) async throws {
        let server = try Server(responseBody: responseBody, outOfOrder: outOfOrder)
        defer { server.stop() }
        let ready = expectation(description: "Encrypted recall fixture ready")
        server.start(ready: ready)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-native-recall-fixture",
            cryptKey: Data(repeating: 0x33, count: 16), zcid: String(repeating: "a", count: 64), zcidIsNative: true,
            socketServers: [.init(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                                  pubKey: server.privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: server.keyID, keySetValue: server.key.base64EncodedString())
        let transport = NoHTTP()
        let client = ZolaClient(session: session, transport: transport, minPollIntervalSeconds: 0)
        try await client.startVoipIncomingListener()
        do { try await perform(client, server, transport) }
        catch { await client.stopVoipIncomingListener(); throw error }
        await client.stopVoipIncomingListener()
    }

    private func message(group: Bool = false) -> ZolaMessage {
        .init(id: 123456, cliMsgId: 98765, threadId: 42, isGroup: group,
              senderId: 100_000_001, toId: 42, tsMs: 1000, text: "Offline fixture", isSelf: true)
    }

    func testEncryptedRecallWaitsForJSONAfterReceiptAndKeepsSharedListener() async throws {
        try await withClient { client, server, transport in
            let first = try await client.recallNative(message: self.message(), threadId: 42, dryRun: false, timeoutSeconds: 1)
            XCTAssertTrue(first)
            let second = try await client.recallNative(message: self.message(group: true), threadId: 42,
                                                       type: .group, dryRun: false, timeoutSeconds: 1)
            XCTAssertTrue(second)
            XCTAssertEqual(server.connectionCount, 1, "Recall must reuse the inbox/reaction listener")
            XCTAssertEqual(server.frames.filter { $0.cmd == 114 || $0.cmd == 204 }.map(\.cmd), [114, 204])
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testRecallReceiptAndUnrelatedResponsesAloneTimeOut() async throws {
        try await withClient(responseBody: nil) { client, server, transport in
            do {
                _ = try await client.recallNative(message: self.message(), threadId: 42, dryRun: false, timeoutSeconds: 0.15)
                XCTFail("Empty receipt must not report a successful recall")
            } catch let ZolaError.transport(message) {
                XCTAssertTrue(message.contains("114"))
            }
            XCTAssertEqual(server.connectionCount, 1)
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testConcurrentOutOfOrderResultsStayBoundToEachRecallRequest() async throws {
        try await withClient(outOfOrder: true) { client, server, _ in
            let rejected = self.message()
            let accepted = ZolaMessage(id: 123457, cliMsgId: 98766, threadId: 42,
                senderId: 100_000_001, toId: 42, tsMs: 1000, text: "Second fixture", isSelf: true)
            async let first: Bool = {
                do {
                    _ = try await client.recallNative(message: rejected, threadId: 42, dryRun: false, timeoutSeconds: 1)
                    return true
                } catch { return false }
            }()
            async let second = client.recallNative(message: accepted, threadId: 42, dryRun: false, timeoutSeconds: 1)
            let (firstResult, secondResult) = try await (first, second)
            XCTAssertFalse(firstResult, "The later rejected request result must not be replaced by another request's success")
            XCTAssertTrue(secondResult)
            XCTAssertEqual(server.connectionCount, 1)
        }
    }

    func testNativeErrorAndMalformedResultNeverConfirmRecall() async throws {
        for body in [#"{"error_code":-105}"#, "{}", "not-json"] {
            try await withClient(responseBody: body) { client, _, transport in
                do {
                    _ = try await client.recallNative(message: self.message(), threadId: 42, dryRun: false, timeoutSeconds: 1)
                    XCTFail("Rejected or malformed recall must throw")
                } catch { }
                XCTAssertEqual(transport.requestCount, 0)
            }
        }
    }
}
#endif
