import Foundation
import XCTest
@testable import ZolaKit

final class NativeUploadResponseTests: XCTestCase {
    private actor Transport: ZolaNetworkTransport {
        let response: Data
        var calls = 0
        init(_ response: Data) { self.response = response }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            calls += 1
            if request.httpMethod == "GET" {
                return (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload"]}}"#.utf8))
            }
            return (200, response)
        }
    }
    private func upload(_ payload: [String: Any], encrypted: Bool = false) async throws -> [String: Any] {
        let zcid = String(repeating: "a", count: 64)
        let data: Any = encrypted ? try ZolaCrypto.encryptZCIDParams(payload, zcid: zcid) : payload
        let response = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": data])
        let transport = Transport(response)
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: zcid, zcidIsNative: true)
        return try await ZolaClient(session: session, transport: transport).uploadMediaNativeHTTP(
            fileData: Data([1]), fileName: "synthetic.aac", toId: 456, isGroup: true, uploadFeature: 3)
    }
    func testNativeNormalAliasAcceptsPlainAndEncryptedCompletedLinks() async throws {
        // Native parseLinkInfo reads url, normal, org at0x100b275a4/275f4/27644.
        for encrypted in [false, true] {
            let value = try await upload(["normal": "https://fixture.invalid/complete.aac"], encrypted: encrypted)
            XCTAssertEqual(value["normalUrl"] as? String, "https://fixture.invalid/complete.aac")
            XCTAssertEqual(value["fileUrl"] as? String, "https://fixture.invalid/complete.aac")
        }
    }
    func testNativeUrlNormalOrgPrecedencePreservesNormalizedAppContract() async throws {
        let url = "https://fixture.invalid/url.aac", normal = "https://fixture.invalid/normal.aac", org = "https://fixture.invalid/org.aac"
        for (input, expected): ([String: Any], String) in [
            (["url": url, "normal": normal, "org": org], url),
            (["normal": normal, "org": org], normal),
            (["normalUrl": org, "url": url, "normal": normal], org)
        ] {
            let value = try await upload(input)
            XCTAssertEqual(value["normalUrl"] as? String, expected)
        }
    }
    func testZeroErrorOrPendingMetadataWithoutUsableLinkIsNotCompletedUpload() async throws {
        for input: [String: Any] in [
            ["error_code": 0],
            ["error_code": 0, "fileId": 123, "status": "pending", "progress": 100],
            ["normal": "not a link"],
            ["normal": "http://fixture.invalid/insecure.aac"]
        ] {
            do { _ = try await upload(input); XCTFail("No usable completed link must never become success") }
            catch { }
        }
    }
}
