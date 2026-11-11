import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Native-derived fixtures exercise real fetchGroupPoll through the encrypted socket; no live traffic.
final class NativeGroupPollSocketTests: XCTestCase {
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
        let keyID = "poll-fixture-key"
        let queue = DispatchQueue(label: "zolakit.poll.encrypted.fixture")
        private var connection: NWConnection?
        private var crypto: ZolaSocketCrypto?
        private let lock = NSLock()
        private var received: [ZolaUnpackedChatElement] = []
        var frames: [ZolaUnpackedChatElement] { lock.withLock { received } }
        let responseBody: String?
        private var connections = 0
        var connectionCount: Int { lock.withLock { connections } }
        init(responseBody: String? = #"{"error_code":0}"#) throws {
            self.responseBody = responseBody
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
                                    if element.cmd == 1641 {
                                        // A transport receipt comes first; it is not the poll detail.
                                        sendNow(ZolaCrypto.packServerChatElementFrame(srcId: element.srcId, msgType: 4,
                                            cmd: element.cmd, seqId: element.seqId))
                                        // Unrelated answers command must not satisfy a detail waiter.
                                        sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"{"error_code":0,"data":{"answers":[]}}"#.utf8),
                                            srcId: element.srcId, msgType: 3, cmd: 1646, seqId: element.seqId))
                                        if let responseBody {
                                            queue.asyncAfter(deadline: .now() + 0.02) { [self] in
                                                sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: Data(responseBody.utf8),
                                                    gzipBody: true, srcId: element.srcId, msgType: 3,
                                                    cmd: 1641, seqId: element.seqId))
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

    private func withClient(responseBody: String? = #"{"error_code":0}"#,
                            _ perform: (ZolaClient, Server, NoHTTP) async throws -> Void) async throws {
        let server = try Server(responseBody: responseBody)
        defer { server.stop() }
        let ready = expectation(description: "Encrypted poll fixture ready")
        server.start(ready: ready)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-native-poll-fixture",
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

    private func body(poll: Int64 = 901, group: Int64 = 777) -> String {
        "{\"error_code\":0,\"data\":{\"poll\":{\"id\":\(poll),\"groupId\":\(group),\"question\":\"Native fixture\",\"isAnonymous\":0,\"isHideVotePreview\":0,\"answers\":[{\"id\":1,\"content\":\"A\",\"numVote\":1}]}}}"
    }

    func testEmptyTransportReceiptWaitsForEncryptedPollDetail() async throws {
        try await withClient(responseBody: body()) { client, server, transport in
            let detail = try await client.fetchGroupPoll(pollId: "901", groupId: 777, includeVoters: true)
            XCTAssertEqual(detail.pollId, "901")
            XCTAssertEqual(detail.groupId, 777)
            XCTAssertEqual(detail.question, "Native fixture")
            XCTAssertEqual(detail.answers.first?.votes, 1)
            let requests = server.frames.filter { $0.cmd == 1641 || $0.cmd == 1646 }
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.cmd, 1641, "Uncorrelated1646 enrichment stays disabled")
            XCTAssertEqual(requests.first?.bodyData, Data([0x85, 0x03, 0, 0, 0, 0, 0, 0]))
            XCTAssertEqual(requests.first?.msgType, 1)
            XCTAssertEqual(requests.first?.srcType, 3)
            XCTAssertEqual(requests.first?.subCmd, 0)
            XCTAssertEqual(server.connectionCount, 1)
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testEncryptedWrongPollAndGroupNeverBecomeRequestedDetail() async throws {
        for response in [body(poll: 902), body(group: 778)] {
            try await withClient(responseBody: response) { client, server, transport in
                do {
                    _ = try await client.fetchGroupPoll(pollId: "901", groupId: 777, includeVoters: true)
                    XCTFail("Wrong native poll/group identity must fail closed")
                } catch ZolaError.transport(let message) {
                    XCTAssertEqual(message, "Chi tiết bình chọn không khớp hội thoại")
                }
                XCTAssertEqual(server.frames.filter { $0.cmd == 1641 }.count, 1)
                XCTAssertFalse(server.frames.contains { $0.cmd == 1646 })
                XCTAssertEqual(transport.requestCount, 0)
            }
        }
    }

    func testEncryptedPollRejectionPropagatesBeforeIdentityParsing() async throws {
        try await withClient(responseBody: #"{"error_code":-105}"#) { client, _, transport in
            do {
                _ = try await client.fetchGroupPoll(pollId: "901", groupId: 777)
                XCTFail("Native error must not become an empty poll")
            } catch ZolaError.server(let code, _) {
                XCTAssertEqual(code, -105)
            }
            XCTAssertEqual(transport.requestCount, 0)
        }
    }
}
#endif
