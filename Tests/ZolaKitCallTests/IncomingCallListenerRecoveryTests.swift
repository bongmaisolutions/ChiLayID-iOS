import XCTest
@testable import ZolaKit
#if canImport(Network)
import Network

final class IncomingCallListenerRecoveryTests: XCTestCase {
    func testForegroundEnsureReconnectsBeforeSupervisorBackoffExpires() async throws {
        let server = try ListenerRecoveryServer(secondAuthCode: 0)
        defer { server.stop() }
        let client = try await startClient(server)
        await server.disconnectFirst()
        // FIN has reached the SDK receive loop before asking foreground to restore the listener.
        try await Task.sleep(nanoseconds: 150_000_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await client.startVoipIncomingListener() } }
            try await group.waitForAll()
        }
        await fulfillment(of: [server.secondAuth], timeout: 1.0)
        let connections = await server.connectionCount()
        XCTAssertEqual(connections, 2, "Concurrent foreground recovery must share exactly one replacement AUTHEN socket")
        let active = await client.isVoipIncomingListenerActive()
        XCTAssertTrue(active)
        await client.stopVoipIncomingListener()
    }

    func testForegroundReconnectAuthenticationRejectionStopsSupervisor() async throws {
        let server = try ListenerRecoveryServer(secondAuthCode: 102)
        defer { server.stop() }
        let client = try await startClient(server)
        await server.disconnectFirst()
        try await Task.sleep(nanoseconds: 150_000_000)
        do {
            try await client.startVoipIncomingListener()
            XCTFail("Foreground reconnect must report the native authentication rejection")
        } catch {
            // Only liveness is asserted here: the protocol already tests exact expiry mapping.
        }
        await fulfillment(of: [server.secondAuth], timeout: 1.0)
        let active = await client.isVoipIncomingListenerActive()
        XCTAssertFalse(active, "Terminal authentication failure cannot leave reconnect ownership active")
        await client.stopVoipIncomingListener()
    }

    func testStoppedPendingConnectCannotReplaceRestartedListener() async throws {
        let server = try ListenerRecoveryServer(secondAuthCode: 0, delayFirstAuth: true)
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2.0)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "loopback_generation",
            cryptKey: Data(repeating: 0x22, count: 16), zcid: ZolaDeviceIdentity.defaultProfile.zcid,
            zcidIsNative: true)
        let client = ZolaClient(session: session, voipLoopbackEndpoints: [("127.0.0.1", port)])
        let originalStart = Task { try await client.startVoipIncomingListener() }
        await fulfillment(of: [server.firstAuth], timeout: 2.0)
        await client.stopVoipIncomingListener()
        try await client.startVoipIncomingListener()
        await fulfillment(of: [server.secondAuth], timeout: 1.0)
        do {
            try await originalStart.value
            XCTFail("The superseded startup cannot report owning the new listener")
        } catch { }
        let active = await client.isVoipIncomingListenerActive()
        XCTAssertTrue(active, "Cleanup from the old startup cannot clear the restarted listener")
        await client.stopVoipIncomingListener()
    }

    func testExternalOwnerRevokesPendingAuthenticationWithoutReconnect() async throws {
        let server = try ListenerRecoveryServer(secondAuthCode: 0, delayFirstAuth: true)
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2.0)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "loopback_external_owner",
            cryptKey: Data(repeating: 0x22, count: 16), zcid: ZolaDeviceIdentity.defaultProfile.zcid,
            zcidIsNative: true)
        let client = ZolaClient(session: session, voipLoopbackEndpoints: [("127.0.0.1", port)])
        let startup = Task { try await client.startVoipIncomingListener() }
        await fulfillment(of: [server.firstAuth], timeout: 2.0)
        await client.setNativeSocketExternallyOwned(true)
        do { try await startup.value; XCTFail("Transferred startup cannot become owner") } catch { }
        let active = await client.isVoipIncomingListenerActive()
        XCTAssertFalse(active)
        let count = await server.connectionCount()
        XCTAssertEqual(count, 1)
        do { try await client.startVoipIncomingListener(); XCTFail("Cannot reconnect while external owner active") } catch { }
        await client.stopVoipIncomingListener()
    }

    private func startClient(_ server: ListenerRecoveryServer) async throws -> ZolaClient {
        await fulfillment(of: [server.ready], timeout: 2.0)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let session = try ZolaSession(uid: 100_000_103, sessionKey: "loopback_incoming_listener",
            cryptKey: Data(repeating: 0x22, count: 16), zcid: ZolaDeviceIdentity.defaultProfile.zcid,
            zcidIsNative: true)
        let client = ZolaClient(session: session, voipLoopbackEndpoints: [("127.0.0.1", port)])
        try await client.startVoipIncomingListener()
        return client
    }
}

// Real loopback transport: exercises AUTHEN, disconnect detection and the reconnect supervisor;
// never reaches a Zalo host or reads an account/session from disk.
private final class ListenerRecoveryServer: @unchecked Sendable {
    let listener: NWListener
    let ready = XCTestExpectation(description: "Loopback ready")
    let firstAuth = XCTestExpectation(description: "First AUTHEN")
    let secondAuth = XCTestExpectation(description: "Foreground reconnect AUTHEN")
    private let queue = DispatchQueue(label: "zolakit.incoming-recovery-test")
    private let delayFirstAuth: Bool
    private let secondAuthCode: Int32
    private var connections: [NWConnection] = []

    init(secondAuthCode: Int32, delayFirstAuth: Bool = false) throws {
        self.delayFirstAuth = delayFirstAuth
        self.secondAuthCode = secondAuthCode
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func connectionCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.connections.count) }
        }
    }

    func disconnectFirst() async {
        await withCheckedContinuation { continuation in
            queue.async { self.connections.first?.cancel(); continuation.resume() }
        }
    }

    func stop() {
        queue.async { self.connections.forEach { $0.cancel() }; self.listener.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        let ordinal = connections.count
        connection.start(queue: queue)
        var buffer = Data()
        var upgraded = false
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if !upgraded, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    upgraded = true
                    connection.send(content: Data("HTTP/1.1 200 OK\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
                while upgraded, buffer.count >= 23,
                      let size = try? Data(buffer.prefix(4)).readUInt32LE(at: 0),
                      size >= 23, buffer.count >= Int(size) {
                    let frame = Data(buffer.prefix(Int(size))); buffer.removeFirst(Int(size))
                    guard let element = try? ZolaCrypto.unpackChatElementFrame(frame), element.cmd == 1 else { continue }
                    let response = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: element.srcId,
                        msgType: 3, cmd: 1, subCmd: 2, seqId: element.seqId,
                        retCode: ordinal == 1 ? 0 : self.secondAuthCode)
                    if ordinal == 1 {
                        self.firstAuth.fulfill()
                    }
                    if ordinal == 1 && self.delayFirstAuth {
                        self.queue.asyncAfter(deadline: .now() + 0.5) {
                            connection.send(content: response.payload, completion: .contentProcessed { _ in })
                        }
                    } else {
                        connection.send(content: response.payload, completion: .contentProcessed { _ in })
                    }
                    if ordinal == 2 { self.secondAuth.fulfill() }
                }
                if !complete && error == nil { pump() }
            }
        }
        pump()
    }
}
#endif
