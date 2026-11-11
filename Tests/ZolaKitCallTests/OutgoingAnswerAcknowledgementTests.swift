import XCTest
import Network
import CryptoKit
@testable import ZolaKit

final class OutgoingAnswerAcknowledgementTests: XCTestCase {
    func testEncryptedCallerConfirmationUnlocksCalleeAndIsIdempotent() async throws {
        let server = try AnswerConfirmationServer()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2)
        let callerAnswered = expectation(description: "Caller receives403")
        let calleeAnswered = expectation(description: "Callee receives408 only after caller confirmation")
        let caller = try server.socket(uid: 101) { event in
            if case .answered = event { callerAnswered.fulfill() }
        }
        let callee = try server.socket(uid: 202) { event in
            if case .answered = event { calleeAnswered.fulfill() }
        }
        try await caller.connectAndAuthenticate()
        try await callee.connectAndAuthenticate()
        await caller.bindCall(serverCallId: 900, clientCallId: 800, partnerUid: 202, isVideo: true)
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900) }
        server.push(uid: 202, cmd: 402, id: 900, peer: 101)
        server.push(uid: 101, cmd: 403, id: 800, peer: 202)
        await fulfillment(of: [callerAnswered], timeout: 2)
        XCTAssertEqual(server.confirmationCount, 0, "Receiving403 alone must not claim relay readiness")
        // Application has now confirmed its transport. Concurrent/repeated callbacks emit one408.
        async let first: Void = caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 800)
        async let second: Void = caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900)
        try await first; try await second
        await fulfillment(of: [calleeAnswered, server.confirmed], timeout: 2)
        try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900)
        XCTAssertEqual(server.confirmationCount, 1)
        XCTAssertEqual(server.confirmationCallID, 900, "Wire confirmation must use mapped server call ID")
        await assertRejected { try await callee.acknowledgeOutgoingAnswer(partnerUid: 101, callId: 900) }
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 303, callId: 900) }
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 901) }
        await caller.unbindCall()
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900) }
        await caller.close(); await callee.close()
    }

    func testNonAnswerAndForeignSignalsCannotEnableConfirmation() async throws {
        let server = try AnswerConfirmationServer()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2)
        let observed = expectation(description: "signals observed")
        observed.expectedFulfillmentCount = 4
        let caller = try server.socket(uid: 101) { _ in observed.fulfill() }
        try await caller.connectAndAuthenticate()
        await caller.bindCall(serverCallId: 900, clientCallId: 800, partnerUid: 202, isVideo: false)
        server.push(uid: 101, cmd: 403, id: 901, peer: 202) // stale call ignored
        server.push(uid: 101, cmd: 403, id: 900, peer: 303) // foreign peer cannot enable408
        server.push(uid: 101, cmd: 407, id: 900, peer: 202)
        server.push(uid: 101, cmd: 408, id: 900, peer: 202) // never echo an incoming408
        server.push(uid: 101, cmd: 403, id: 900, peer: 202, status: 6)
        await fulfillment(of: [observed], timeout: 2)
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900) }
        XCTAssertEqual(server.confirmationCount, 0)
        await caller.bindCall(serverCallId: 902, clientCallId: 802, partnerUid: 202, isVideo: false)
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 902) }
        await caller.finishFailedOutgoingSetup(callId: 900, partnerUid: 202, closeSocket: true)
        let redialStillBound = await caller.matchesCall(callId: 902, partnerUid: 202)
        XCTAssertTrue(redialStillBound, "Late failed setup must preserve a newer call")
        await caller.close()
    }

    func testMissingWireCallIDNeverEnablesConfirmationFromActiveFallback() async throws {
        let server = try AnswerConfirmationServer()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2)
        let parsed = expectation(description: "Legacy parser resolves missing ID")
        let caller = try server.socket(uid: 101) { _ in parsed.fulfill() }
        try await caller.connectAndAuthenticate()
        await caller.bindCall(serverCallId: 900, clientCallId: 800, partnerUid: 202, isVideo: false)
        server.push(uid: 101, cmd: 403, id: nil, peer: 202)
        await fulfillment(of: [parsed], timeout: 2)
        await assertRejected { try await caller.acknowledgeOutgoingAnswer(partnerUid: 202, callId: 900) }
        XCTAssertEqual(server.confirmationCount, 0)
        await caller.close()
    }

    private func assertRejected(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Unowned/unaccepted call must be rejected") }
        catch {}
    }
}

private final class AnswerConfirmationServer: @unchecked Sendable {
    let listener: NWListener
    let ready = XCTestExpectation(description: "server ready")
    let confirmed = XCTestExpectation(description: "received408")
    private let queue = DispatchQueue(label: "fixture.caller408")
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let key = Data(repeating: 0x41, count: 32)
    private let keyID = "answer-confirmation-fixture"
    private var peers: [Int32: (NWConnection, ZolaSocketCrypto)] = [:]
    private var count = 0
    private var callID: Int32 = 0
    var confirmationCount: Int { queue.sync { count } }
    var confirmationCallID: Int32 { queue.sync { callID } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] in if case .ready = $0 { self?.ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
    }
    func socket(uid: Int64, event: @escaping @Sendable (ZolaVoipCallEvent) -> Void) throws -> ZolaVoipSocketSession {
        let port = try XCTUnwrap(listener.port?.rawValue)
        return ZolaVoipSocketSession(selfUid: uid,
            authenPayload: ZolaCrypto.packSocketAuthenFrame(srcId: Int32(uid), sessionKey: "synthetic", subCmd: 5).payload,
            encryptedEndpoints: [ZolaVoipEndpoint(host: "127.0.0.1", port: port,
                serverPubKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString())],
            socketCrypto: try ZolaSocketCrypto(keySetId: keyID, keySetValueBase64: key.base64EncodedString()),
            keepAliveAfterCallEnd: true, onEvent: event)
    }
    func stop() { queue.async { self.peers.values.forEach { $0.0.cancel() }; self.listener.cancel() } }
    func push(uid: Int32, cmd: Int16, id: Int32?, peer: Int32, status: Int = 0) {
        queue.async { self.send(uid: uid, cmd: cmd, id: id, peer: peer, status: status) }
    }
    private func send(uid: Int32, cmd: Int16, id: Int32?, peer: Int32, status: Int = 0) {
        guard let (connection, crypto) = peers[uid] else { return }
        let idField = id.map { "\"id\":\($0)," } ?? ""
        let body = Data("{\"error_code\":0,\"data\":{\(idField)\"partnerId\":\(peer),\"status\":\(status),\"protocol\":3,\"callType\":3}}".utf8)
        let frame = ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: peer, msgType: 1, cmd: cmd, subCmd: 0)
        if let wire = try? crypto.sealFrame(frame.payload) {
            connection.send(content: wire, completion: .contentProcessed { _ in })
        }
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data(); var upgraded = false; var uid: Int32 = 0
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] chunk, _, done, error in
                if let chunk { buffer.append(chunk) }
                if !upgraded, let end = buffer.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                    buffer.removeSubrange(..<end.upperBound); upgraded = true
                }
                while upgraded, buffer.count >= 51, let length = try? buffer.readUInt32LE(at: 0), buffer.count >= Int(length) {
                    let wire = Data(buffer.prefix(Int(length))); buffer.removeFirst(Int(length))
                    if wire[4] == 0x08 {
                        guard let auth = try? ZolaSocketCrypto.openAuthenFrame(wire,
                            serverPrivateKeyRaw32: privateKey.rawRepresentation,
                            resolveKeySetValue: { $0 == self.keyID ? self.key : nil }),
                              let element = try? ZolaCrypto.unpackChatElementFrame(auth.chatElementPayload),
                              let crypto = try? ZolaSocketCrypto(keySetId: keyID, keySetValueBase64: key.base64EncodedString()) else { continue }
                        uid = element.srcId; peers[uid] = (connection, crypto)
                        let ack = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: uid, msgType: 3, cmd: 1, subCmd: 5, seqId: element.seqId)
                        if let sealed = try? crypto.sealFrame(ack.payload) { connection.send(content: sealed, completion: .contentProcessed { _ in }) }
                    } else if let crypto = peers[uid]?.1, let payload = try? crypto.openFrame(wire),
                              let element = try? ZolaCrypto.unpackChatElementFrame(payload), element.cmd == 408 {
                        count += 1
                        callID = (try? element.bodyData.readInt32LE(at: 4)) ?? 0
                        XCTAssertEqual(element.subCmd, 0)
                        XCTAssertEqual(element.bodyData.count, 12)
                        XCTAssertEqual(try? element.bodyData.readInt32LE(at: 0), 202)
                        XCTAssertEqual(try? element.bodyData.readInt32LE(at: 8), 0)
                        if count == 1 { confirmed.fulfill(); send(uid: 202, cmd: 408, id: callID, peer: 101) }
                    }
                }
                if !done && error == nil { pump() }
            }
        }
        pump()
    }
}
