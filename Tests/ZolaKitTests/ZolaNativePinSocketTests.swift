import XCTest
import Foundation
import CryptoKit
#if canImport(Network)
import Network
@testable import ZolaKit

/// Encrypted loopback exercises production request waiter registration; no live pin claim.
final class ZolaNativePinSocketTests: XCTestCase {
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
        let keyID = "pin-fixture-key"
        let queue = DispatchQueue(label: "zolakit.pin.encrypted.fixture")
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
                                    if [1708, 1703, 1705, 1706].contains(element.cmd) {
                                        // Empty receipt, unrelated sequence and command must not complete a pin request.
                                        sendNow(ZolaCrypto.packServerChatElementFrame(srcId: element.srcId, msgType: 4,
                                            cmd: element.cmd, subCmd: 2, seqId: element.seqId))
                                        let success = Data(#"{"error_code":0}"#.utf8)
                                        sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: success, gzipBody: true,
                                            srcId: element.srcId, msgType: 3, cmd: element.cmd, subCmd: 2, seqId: element.seqId + 100))
                                        sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: success, gzipBody: true,
                                            srcId: element.srcId, msgType: 3, cmd: 999,
                                            subCmd: 2, seqId: element.seqId))
                                        if let responseBody {
                                            queue.asyncAfter(deadline: .now() + 0.02) { [self] in
                                                sendNow(ZolaCrypto.packServerChatElementFrame(bodyData: Data(responseBody.utf8),
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
        let session = try ZolaSession(uid: 100_000_001, sessionKey: "offline-native-pin-fixture",
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

    func testEncryptedPinReadAndWritesResolveOnlyMatchingBodyResponses() async throws {
        let body = #"{"error_code":0,"data":{"boardVersion":7,"maxBoardItems":10,"items":[]}}"#
        try await withClient(responseBody: body) { client, server, transport in
            for group in [false, true] {
                let board = try await client.fetchNativePinBoard(threadId: 42, isGroup: group, dryRun: false)
                XCTAssertEqual(board?.version, 7)
                XCTAssertEqual(board?.isGroup, group)
            }
            try await client.pinNativeUserMessage(self.message(), boardVersion: 7, dryRun: false)
            try await client.unpinNativeUserMessage(threadId: 42, boardId: 456, boardVersion: 7, dryRun: false)
            XCTAssertEqual(server.frames.filter { [1708,1703,1705,1706].contains($0.cmd) }.map(\.cmd), [1708,1703,1705,1706])
            XCTAssertEqual(server.connectionCount, 1)
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testEncryptedPinServerErrorIsReturnedWithoutWaitingForTimeout() async throws {
        try await withClient(responseBody: #"{"error_code":-105}"#) { client, _, transport in
            do {
                _ = try await client.fetchNativePinBoard(threadId: 42, isGroup: false, dryRun: false)
                XCTFail("Server rejection must fail")
            } catch ZolaError.server(let code, _) {
                XCTAssertEqual(code, -105)
            } catch {
                XCTFail("Expected correlated native API rejection, got \(error)")
            }
            XCTAssertEqual(transport.requestCount, 0)
        }
    }
}
#endif
