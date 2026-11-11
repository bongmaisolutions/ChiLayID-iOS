import Foundation
import XCTest
@testable import ZolaKit

final class NativeUploadBreakerTests: XCTestCase {
    private actor Transport: ZolaNetworkTransport {
        let stage: Int
        let code: Int
        let throwing: Bool
        var calls = 0
        init(stage: Int, code: Int, throwing: Bool) { self.stage = stage; self.code = code; self.throwing = throwing }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            let index = calls; calls += 1
            if index == stage {
                if throwing { throw ZolaError.sessionExpired(code: code, endpoint: "fixture", message: "expired") }
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": code]))
            }
            if index == 0 {
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["listUrls": ["https://fixture.invalid/upload1", "https://fixture.invalid/upload2"]]]))
            }
            // A transient failure reaches multipart; expired responses must stop BEFORE the next request.
            return (502, Data())
        }
    }
    private func verify(stage: Int, code: Int, throwing: Bool) async throws {
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        let transport = Transport(stage: stage, code: code, throwing: throwing)
        let client = ZolaClient(session: session, transport: transport)
        do {
            _ = try await client.uploadMediaNativeHTTP(fileData: Data([1, 2, 3]), fileName: "voice.aac", toId: 456, isGroup: true)
            XCTFail("Expected breaker at stage\(stage), code\(code)")
        } catch ZolaError.sessionExpired(let actual, _, _) {
            XCTAssertEqual(actual, code)
        } catch { XCTFail("Wrong error type at stage\(stage), code\(code): \(error)") }
        let before = await transport.calls
        XCTAssertEqual(before, stage + 1, "No fallback request may follow expiration")
        do {
            _ = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "second.aac", toId: 456, isGroup: true)
            XCTFail("Expired client must remain blocked")
        } catch ZolaError.sessionExpired(_, let endpoint, _) {
            XCTAssertEqual(endpoint, "circuit_breaker")
        } catch { XCTFail("Expected persistent breaker") }
        let after = await transport.calls
        XCTAssertEqual(after, before, "Subsequent operation must perform zero requests")
    }
    func testRawExpiryEnvelopesLatchAtConfigRawAndMultipart() async throws {
        for stage in 0...2 { for code in [102, -96] { try await verify(stage: stage, code: code, throwing: false) } }
    }
    func testThrownExpiryStopsFallbackAndLatchesAtEveryStage() async throws {
        for stage in 0...2 { for code in [102, -96] { try await verify(stage: stage, code: code, throwing: true) } }
    }
    private actor OrdinaryFailureTransport: ZolaNetworkTransport {
        var calls = 0
        let rejectConfig: Bool
        init(rejectConfig: Bool) { self.rejectConfig = rejectConfig }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            calls += 1
            if request.httpMethod == "GET" {
                let body: [String: Any] = rejectConfig ? ["error_code": -600] :
                    ["error_code": 0, "data": ["listUrls": ["https://fixture.invalid/upload"]]]
                return (200, try JSONSerialization.data(withJSONObject: body))
            }
            if request.value(forHTTPHeaderField: "Content-Type") == "raw" {
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": -600]))
            }
            return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["normalUrl": "https://fixture.invalid/complete.aac"]]))
        }
    }
    func testOrdinaryRawRejectionStillAllowsExistingMultipartFallback() async throws {
        let transport = OrdinaryFailureTransport(rejectConfig: false)
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        let client = ZolaClient(session: session, transport: transport)
        let uploaded = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "voice.aac", toId: 456, isGroup: true)
        XCTAssertEqual(uploaded["normalUrl"] as? String, "https://fixture.invalid/complete.aac")
        let count = await transport.calls
        XCTAssertEqual(count, 3)
    }
    func testOrdinaryConfigRejectionStopsWithoutExpiringSession() async throws {
        let transport = OrdinaryFailureTransport(rejectConfig: true)
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        let client = ZolaClient(session: session, transport: transport)
        for expected in 1...2 {
            do {
                _ = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "voice.aac", toId: 456, isGroup: true)
                XCTFail("Expected ordinary config error")
            } catch ZolaError.server(let code, _) { XCTAssertEqual(code, -600) }
            let count = await transport.calls
            XCTAssertEqual(count, expected)
        }
    }

    private actor NestedExpiryTransport: ZolaNetworkTransport {
        let stage: Int
        let code: Int
        let encoding: Int
        var calls = 0
        init(stage: Int, code: Int, encoding: Int) {
            self.stage = stage; self.code = code; self.encoding = encoding
        }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            let index = calls; calls += 1
            if index == stage {
                let error: [String: Any] = ["error_code": code]
                let encrypted = try ZolaCrypto.encryptZCIDParams(error, zcid: String(repeating: "a", count: 64))
                if encoding == 1 { return (200, Data(encrypted.utf8)) }
                let value: Any = encoding == 2 ? encrypted : error
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": value]))
            }
            if index == 0 {
                return (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload","https://fixture.invalid/next"]}}"#.utf8))
            }
            return (502, Data())
        }
    }

    func testRecognizedNestedAndRealEncryptedExpiryStopEveryUploadStage() async throws {
        for stage in 0...2 {
            for code in [102, -96] {
                for encoding in 0...2 { // data dictionary, bare encrypted body, encrypted data string
                    let transport = NestedExpiryTransport(stage: stage, code: code, encoding: encoding)
                    let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
                    let client = ZolaClient(session: session, transport: transport)
                    do {
                        _ = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "voice.aac", toId: 456, isGroup: true)
                        XCTFail("Expected nested expiry")
                    } catch ZolaError.sessionExpired(let actual, _, _) {
                        XCTAssertEqual(actual, code)
                    } catch { XCTFail("Wrong nested expiry error stage=\(stage) format=\(encoding): \(error)") }
                    let requests = await transport.calls
                    XCTAssertEqual(requests, stage + 1, "No fallback after nested/encrypted expiration")
                    do {
                        _ = try await client.uploadMediaNativeHTTP(fileData: Data([2]), fileName: "later.aac", toId: 456)
                        XCTFail("Nested expiry must remain latched")
                    } catch ZolaError.sessionExpired { }
                    catch { XCTFail("Expected latched nested expiry") }
                    let after = await transport.calls
                    XCTAssertEqual(after, requests)
                }
            }
        }
    }

    private actor ConcurrentExpiryTransport: ZolaNetworkTransport {
        let pausedStage: Int
        let returnsCompletedUpload: Bool
        let throwsOrdinaryError: Bool
        var calls = 0
        private var pause: CheckedContinuation<Void, Never>?
        private var paused = false
        private var observer: CheckedContinuation<Void, Never>?
        init(pausedStage: Int, returnsCompletedUpload: Bool, throwsOrdinaryError: Bool) {
            self.pausedStage = pausedStage; self.returnsCompletedUpload = returnsCompletedUpload
            self.throwsOrdinaryError = throwsOrdinaryError
        }
        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release() { pause?.resume(); pause = nil }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            let index = calls; calls += 1
            if index == pausedStage {
                await withCheckedContinuation { continuation in
                    pause = continuation; paused = true
                    observer?.resume(); observer = nil
                }
                if throwsOrdinaryError { throw ZolaError.transport("Synthetic upload timeout") }
                if pausedStage == 0 { return config() }
                if returnsCompletedUpload {
                    return (200, Data(#"{"error_code":0,"data":{"normalUrl":"https://fixture.invalid/complete.aac"}}"#.utf8))
                }
                return (502, Data())
            }
            if index == pausedStage + 1 { return (200, Data(#"{"error_code":102}"#.utf8)) }
            if index == 0 { return config() }
            return (502, Data())
        }
        private func config() -> (Int, Data) {
            (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload","https://fixture.invalid/next"]}}"#.utf8))
        }
    }

    func testConcurrentExpiryBlocksPendingConfigAndRawCompletionWithoutFallback() async throws {
        for (stage, completed, ordinaryThrow) in [(0, false, false), (1, false, false), (1, true, false), (1, false, true)] {
            let transport = ConcurrentExpiryTransport(pausedStage: stage, returnsCompletedUpload: completed, throwsOrdinaryError: ordinaryThrow)
            let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
            let client = ZolaClient(session: session, transport: transport)
            let first = Task {
                try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "first.aac", toId: 456)
            }
            await transport.waitUntilPaused()
            do {
                _ = try await client.uploadMediaNativeHTTP(fileData: Data([2]), fileName: "expired.aac", toId: 456)
                XCTFail("Second upload must latch102")
            } catch ZolaError.sessionExpired { }
            await transport.release()
            do {
                _ = try await first.value
                XCTFail("An upload finishing after concurrent expiry cannot report success")
            } catch ZolaError.sessionExpired(let code, _, _) {
                XCTAssertEqual(code, 102)
            } catch { XCTFail("Expected concurrent expiry, got \(error)") }
            let requests = await transport.calls
            XCTAssertEqual(requests, stage + 2, "No follow-up network request after another operation expires the session")
        }
    }

    private actor MetadataTransport: ZolaNetworkTransport {
        var calls = 0
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            calls += 1
            if calls == 1 {
                return (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload"]}}"#.utf8))
            }
            return (200, Data(#"{"error_code":0,"data":{"normalUrl":"https://fixture.invalid/complete.aac","metadata":{"error_code":102}}}"#.utf8))
        }
    }
    func testErrorLookingFileMetadataIsNotRecursivelyTreatedAsSessionExpiry() async throws {
        let transport = MetadataTransport()
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        let client = ZolaClient(session: session, transport: transport)
        let result = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "voice.aac", toId: 456)
        XCTAssertEqual(result["normalUrl"] as? String, "https://fixture.invalid/complete.aac")
        try await client.assertSessionAlive()
        let calls = await transport.calls
        XCTAssertEqual(calls, 2)
    }

}
