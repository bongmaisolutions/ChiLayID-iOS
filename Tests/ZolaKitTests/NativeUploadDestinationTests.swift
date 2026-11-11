import Foundation
import XCTest
@testable import ZolaKit

final class NativeUploadDestinationTests: XCTestCase {
    private actor ConfigTransport: ZolaNetworkTransport {
        var query: [String: String] = [:]
        var calls = 0
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            calls += 1
            if calls == 1 {
                query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                return (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload"]}}"#.utf8))
            }
            return (200, Data(#"{"error_code":0,"data":{"normalUrl":"https://fixture.invalid/complete.aac"}}"#.utf8))
        }
    }
    func testConfigUsesNativeRecipientTypesForDirectAndGroup() async throws {
        // Native261002 ZAUploadModel destType3/6 is carried through UploadItem+0x250
        // into the HTTP formatter at0x103aa8ed0 without 0/1 translation.
        for (isGroup, expectedType) in [(false, "3"), (true, "6")] {
            let transport = ConfigTransport()
            let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
            let client = ZolaClient(session: session, transport: transport)
            _ = try await client.uploadMediaNativeHTTP(fileData: Data([1]), fileName: "synthetic.aac", toId: 987654321, isGroup: isGroup, uploadFeature: 2)
            let query = await transport.query
            XCTAssertEqual(query["destType"], expectedType)
            XCTAssertEqual(query["destId"], "987654321")
            XCTAssertEqual(query["uploadFeature"], "2", "Recipient type must not rewrite an explicitly selected native feature")
            let count = await transport.calls
            XCTAssertEqual(count, 2)
        }
    }
}
