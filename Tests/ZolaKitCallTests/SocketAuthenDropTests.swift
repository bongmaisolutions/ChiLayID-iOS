import XCTest
@testable import ZolaKit
#if canImport(Network)
import Network

/// A server that cannot decrypt the AUTHEN frame (stale socket keySet) accepts TCP + upgrade and then
/// closes the stream without an ack. That must surface as the keySet-rejected code (-67) so the client
/// refreshes the keySet once — or stops retrying when it cannot — instead of a generic transport error
/// retried every few seconds. A host that never accepts TCP stays a transport (network) error.
final class SocketAuthenDropTests: XCTestCase {
    func testServerClosingRightAfterAuthenIsReportedAsRejectedKeySet() async throws {
        let server = try AuthenDropServer()
        defer { server.stop() }
        await fulfillment(of: [server.ready], timeout: 2)
        let port = try XCTUnwrap(server.listener.port?.rawValue)
        let socket = makeSocket(ports: [port])
        do {
            try await socket.connectAndAuthenticate(perHostTimeout: 2)
            XCTFail("A dropped AUTHEN must not count as connected")
        } catch let ZolaError.server(code, _) {
            XCTAssertEqual(code, ZolaConstants.errorInvalidSessionKey)
        } catch {
            XCTFail("Expected keySet rejection, got \(error)")
        }
        await fulfillment(of: [server.authenReceived], timeout: 1)
        await socket.close()
    }

    func testUnreachableHostStaysTransportError() async throws {
        let closed = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "port allocated")
        closed.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        closed.newConnectionHandler = { $0.cancel() }
        closed.start(queue: .global())
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(closed.port?.rawValue)
        closed.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        let socket = makeSocket(ports: [port])
        do {
            try await socket.connectAndAuthenticate(perHostTimeout: 1)
            XCTFail("Nothing listens on the port")
        } catch let ZolaError.transport(detail) {
            XCTAssertFalse(detail.isEmpty)
        } catch {
            XCTFail("A network failure must stay a transport error, got \(error)")
        }
        await socket.close()
    }

    private func makeSocket(ports: [UInt16]) -> ZolaVoipSocketSession {
        let authen = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: 100_000_103,
            msgType: 3, cmd: 1, subCmd: 5).payload
        return ZolaVoipSocketSession(
            selfUid: 100_000_103,
            authenPayload: authen,
            encryptedEndpoints: ports.map { ZolaVoipEndpoint(host: "127.0.0.1", port: $0, serverPubKeyBase64: nil) },
            socketCrypto: nil,
            onEvent: nil
        )
    }
}

private final class AuthenDropServer: @unchecked Sendable {
    let listener: NWListener
    let ready = XCTestExpectation(description: "Loopback ready")
    let authenReceived = XCTestExpectation(description: "AUTHEN bytes received")
    private let queue = DispatchQueue(label: "zolakit.authen-drop-test")
    private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.ready.fulfill() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { self.connections.forEach { $0.cancel() }; self.listener.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
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
                if upgraded, !buffer.isEmpty {
                    // Like Zalo with an undecryptable AUTHEN: no ack, just a clean close (FIN).
                    self.authenReceived.fulfill()
                    connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                if !complete && error == nil { pump() }
            }
        }
        pump()
    }
}
#endif
