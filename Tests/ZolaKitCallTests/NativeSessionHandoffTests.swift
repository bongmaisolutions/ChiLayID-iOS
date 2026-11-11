import XCTest
@testable import ZolaKit

final class NativeSessionHandoffTests: XCTestCase {
    func testHandoffWaitsForFreshKeysAndPermanentlyFencesOldClient() async throws {
        let transport = HandoffTransport()
        let client = try makeClient(transport)
        let refresh = Task { try await client.fetchKeySet() }
        await fulfillment(of: [transport.started], timeout: 2)
        let handoff = Task { try await client.prepareNativeSocketHandoffSession() }
        await waitForFence(client)
        await assertFails { _ = try await client.fetchKeySet() }
        await transport.release(fail: false)
        _ = try await refresh.value
        let snapshot = try await handoff.value
        XCTAssertEqual(snapshot.keySetId, "fresh-handoff-key")
        XCTAssertEqual(snapshot.keySetValue, Data(repeating: 0x45, count: 32).base64EncodedString())
        let again = try await client.prepareNativeSocketHandoffSession()
        XCTAssertEqual(again.keySetValue, snapshot.keySetValue)
        await client.setNativeSocketExternallyOwned(false)
        await assertFails { try await client.assertNativeSocketLocallyOwned() }
        await assertFails { _ = try await client.fetchKeySet() }
        await assertFails { _ = try await client.listJoinedGroups() }
        let count = await transport.requestCount(); XCTAssertEqual(count, 1)
    }

    func testRefreshFailureFailsHandoffAndRepeatedTransferCannotExportStaleKeys() async throws {
        let transport = HandoffTransport()
        let client = try makeClient(transport)
        let refresh = Task { try await client.fetchKeySet() }
        await fulfillment(of: [transport.started], timeout: 2)
        let handoff = Task { try await client.prepareNativeSocketHandoffSession() }
        await waitForFence(client)
        await transport.release(fail: true)
        await assertFails { _ = try await refresh.value }
        await assertFails { _ = try await handoff.value }
        await assertFails { _ = try await client.prepareNativeSocketHandoffSession() }
        let count = await transport.requestCount(); XCTAssertEqual(count, 2, "Only preexisting refresh may complete its bounded retry")
    }

    func testLateOrdinaryHTTPResponseCannotExpireOrMutateHandedOffSession() async throws {
        let transport = HandoffTransport()
        let client = try makeClient(transport)
        let request = Task { try await client.listJoinedGroups() }
        await fulfillment(of: [transport.started], timeout: 2)
        let handoff = Task { try await client.prepareNativeSocketHandoffSession() }
        await waitForFence(client)
        await transport.release(fail: true)
        await assertFails { _ = try await request.value }
        let snapshot = try await handoff.value
        XCTAssertFalse(snapshot.isExpired)
        XCTAssertEqual(snapshot.keySetId, "old-key")
        let expired = await client.session.isExpired; XCTAssertFalse(expired)
        await assertFails { _ = try await client.listJoinedGroups() }
        let count = await transport.requestCount(); XCTAssertEqual(count, 1)
    }

    private func makeClient(_ transport: HandoffTransport) throws -> ZolaClient {
        let session = try ZolaSession(uid: 100_000_101, sessionKey: "synthetic-handoff", cryptKey: Data(repeating: 0x22, count: 16),
            zcid: ZolaDeviceIdentity.defaultProfile.zcid, zcidIsNative: true,
            keySetId: "old-key", keySetValue: Data(repeating: 0x11, count: 32).base64EncodedString(),
            accessToken: "synthetic-access-token", loginPhone: "0909123456")
        return ZolaClient(session: session, transport: transport)
    }
    private func waitForFence(_ client: ZolaClient) async {
        for _ in 0..<100 {
            if await client.nativeSocketExternallyOwned { return }
            await Task.yield()
        }
        XCTFail("Handoff should fence before awaiting transport")
    }
    private func assertFails(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected fenced/failed operation") } catch {}
    }
}

private actor HandoffTransport: ZolaNetworkTransport {
    nonisolated let started = XCTestExpectation(description: "transport started")
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var fail = false
    private var count = 0
    func execute(_ request: URLRequest) async throws -> (Int, Data) {
        count += 1
        if count == 1 { started.fulfill() }
        if !released { await withCheckedContinuation { gate = $0 } }
        // Deliberately ignores task cancellation: late transport completions must still be fenced.
        if fail {
            let code = request.url?.path.contains("getKeySet") == true ? 500 : 102
            return (200, Data("{\"error_code\":\(code),\"error_message\":\"synthetic failure\"}".utf8))
        }
        let key = Data(repeating: 0x45, count: 32).base64EncodedString()
        return (200, Data("{\"error_code\":0,\"data\":{\"keySetId\":\"fresh-handoff-key\",\"keySetValue\":\"\(key)\"}}".utf8))
    }
    func release(fail: Bool) { self.fail = fail; released = true; gate?.resume(); gate = nil }
    func requestCount() -> Int { count }
}
