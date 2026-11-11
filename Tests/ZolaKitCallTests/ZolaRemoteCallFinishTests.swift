import XCTest
import Foundation
import Network
import CryptoKit
@testable import ZolaKit

final class ZolaRemoteCallFinishTests: XCTestCase {
    func testEncryptedRemoteEndLateFinalizerReportsOnceWithoutEndingRedial() async throws {
        let queue = DispatchQueue(label: "test.remote.finish.encrypted")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let ready = expectation(description: "listener ready")
        let firstInvite = expectation(description: "first incoming")
        let firstAck = expectation(description: "first408")
        let ended = expectation(description: "remote409")
        let redialInvite = expectation(description: "redial incoming")
        let redialAck = expectation(description: "redial408")
        let reported = expectation(description: "old call406")
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let key = Data(repeating: 0x41, count: 32)
        let keyID = "remoteFinishKey1"
        final class State: @unchecked Sendable {
            var connection: NWConnection?
            var crypto: ZolaSocketCrypto?
            var endFrames = 0
            var reports = 0
        }
        let state = State()
        func frame(_ cmd: Int16, id: Int32, type: Int8 = 1) -> ZolaChatElementFrame {
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data("{\"error_code\":0,\"data\":{\"id\":\(id),\"partnerId\":100000102,\"callerId\":100000102,\"callType\":3,\"sessId\":\"test-session-\(id)\"}}".utf8),
                srcId: 100_000_102, msgType: type, cmd: cmd, subCmd: 0)
        }
        func push(_ cmd: Int16, id: Int32) {
            queue.async {
                guard let crypto = state.crypto,
                      let payload = try? crypto.sealFrame(frame(cmd, id: id).payload) else { return }
                state.connection?.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
        listener.newConnectionHandler = { connection in
            state.connection = connection
            var buffer = Data()
            var preamble = false
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, complete, error in
                    if let chunk {
                        buffer.append(chunk)
                        if !preamble, let marker = buffer.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            buffer.removeSubrange(..<marker.upperBound); preamble = true
                        }
                        while preamble, buffer.count >= 51,
                              let length = try? buffer.readUInt32LE(at: 0), buffer.count >= Int(length) {
                            let wire = Data(buffer.prefix(Int(length))); buffer.removeFirst(Int(length))
                            if wire[4] == 0x08 {
                                guard let auth = try? ZolaSocketCrypto.openAuthenFrame(wire,
                                    serverPrivateKeyRaw32: privateKey.rawRepresentation,
                                    resolveKeySetValue: { $0 == keyID ? key : nil }),
                                    let element = try? ZolaCrypto.unpackChatElementFrame(auth.chatElementPayload),
                                    let crypto = try? ZolaSocketCrypto(keySetId: keyID, keySetValueBase64: key.base64EncodedString()) else { continue }
                                state.crypto = crypto
                                let response = ZolaCrypto.packServerChatElementFrame(bodyData: Data(),
                                    srcId: 100_000_103, msgType: 3, cmd: 1, subCmd: 5, seqId: element.seqId)
                                if let sealed = try? crypto.sealFrame(response.payload) {
                                    connection.send(content: sealed, completion: .contentProcessed { _ in })
                                }
                            } else if let crypto = state.crypto,
                                      let raw = try? crypto.openFrame(wire),
                                      let element = try? ZolaCrypto.unpackChatElementFrame(raw) {
                                if element.cmd == 402, element.subCmd == 3 {
                                    // Answer body: partner(Int32), status(Int8), callId(Int32).
                                    guard let id = try? element.bodyData.readInt32LE(at: 5),
                                          let sealed = try? crypto.sealFrame(frame(408, id: id, type: 3).payload) else { continue }
                                    connection.send(content: sealed, completion: .contentProcessed { _ in })
                                } else if element.cmd == 409 || element.cmd == 405 {
                                    state.endFrames += 1
                                } else if element.cmd == 406 {
                                    state.reports += 1
                                    XCTAssertEqual(try? element.bodyData.readInt32LE(at: 12), 991_122)
                                    XCTAssertEqual(try? element.bodyData.readInt32LE(at: 4), 0)
                                    XCTAssertEqual(try? element.bodyData.readInt32LE(at: 8), 23)
                                    XCTAssertEqual(try? element.bodyData.readInt32LE(at: 20), 1)
                                    if state.reports == 1 { reported.fulfill() }
                                }
                            }
                        }
                    }
                    if !complete && error == nil { pump() }
                }
            }
            connection.start(queue: queue); pump()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "test-remote-finish",
            zcid: "native-test-remote", zcidIsNative: true,
            socketServers: [ZolaSocketServer(hostName: "127.0.0.1", hostPort: Int(port), key: 5,
                pubKey: privateKey.publicKey.rawRepresentation.base64EncodedString(), tagName: "chat")],
            keySetId: keyID, keySetValue: key.base64EncodedString())
        let client = ZolaClient(session: session)
        await client.setVoipEventHandler { event in
            switch event {
            case .incomingInvite(let id, _, _, _, _, _, _, _):
                if id == 991_122 { firstInvite.fulfill() } else if id == 991_123 { redialInvite.fulfill() }
            case .answered(let id, _):
                if id == 991_122 { firstAck.fulfill() } else if id == 991_123 { redialAck.fulfill() }
            case .ended(let id, _, _):
                if id == 991_122 { ended.fulfill() }
            default: break
            }
        }
        try await client.startVoipIncomingListener()
        push(402, id: 991_122)
        await fulfillment(of: [firstInvite], timeout: 3)
        do {
            _ = try await client.prepareNativeSocketHandoffSession()
            XCTFail("An active incoming call must retain ownership")
        } catch {
            guard case ZolaError.safetyGate = error else { throw error }
        }
        try await client.assertNativeSocketLocallyOwned()
        try await client.answerVoipCall(partnerUid: 100_000_102, callId: 991_122)
        await fulfillment(of: [firstAck], timeout: 3)
        push(409, id: 991_122)
        await fulfillment(of: [ended], timeout: 3)
        push(402, id: 991_123)
        await fulfillment(of: [redialInvite], timeout: 3)
        // Old view disappears after the next invite. Even a default local-end caller must
        // respect retained terminal provenance and never echo409 or unbind the redial.
        try await client.cancelVoipCall(partnerUid: 100_000_102, callId: 991_122,
            durationSeconds: 23, isConnected: true)
        try await client.cancelVoipCall(partnerUid: 100_000_102, callId: 991_122,
            durationSeconds: 23, isConnected: true)
        await fulfillment(of: [reported], timeout: 3)
        let context = await client.voipCallEndpoints(forCallId: 991_123)
        XCTAssertEqual(context?.sessionId, "test-session-991123")
        try await client.answerVoipCall(partnerUid: 100_000_102, callId: 991_123)
        await fulfillment(of: [redialAck], timeout: 3)
        let counts = queue.sync { (state.endFrames, state.reports) }
        XCTAssertEqual(counts.0, 0, "Remote finish must not echo409 or cancel the new call")
        XCTAssertEqual(counts.1, 1, "Competing finalizers emit one finish406")
        await client.stopVoipIncomingListener()
    }
}
