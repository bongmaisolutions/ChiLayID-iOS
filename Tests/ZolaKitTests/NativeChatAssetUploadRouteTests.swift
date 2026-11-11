import Foundation
import XCTest
@testable import ZolaKit

final class NativeChatAssetUploadRouteTests: XCTestCase {
    private actor Transport: ZolaNetworkTransport {
        var query: [String: String] = [:]
        var requestCount = 0
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            requestCount += 1
            if request.httpMethod == "GET" {
                query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                return (200, Data(#"{"error_code":0,"data":{"listUrls":["https://fixture.invalid/upload"]}}"#.utf8))
            }
            return (200, Data(#"{"error_code":0,"data":{"org":"https://fixture.invalid/completed"}}"#.utf8))
        }
    }
    private func config(name: String, isGroup: Bool, override: Int? = nil) async throws -> [String: String] {
        let transport = Transport()
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true)
        _ = try await ZolaClient(session: session, transport: transport).uploadMediaNativeHTTP(
            fileData: Data([1]), fileName: name, toId: 456, isGroup: isGroup, uploadFeature: override)
        return await transport.query
    }
    func testAudioVideoAndDocumentUseChatAssetRouteForBothRecipientKinds() async throws {
        // Native video752/sub9 maps2 for both3/6; existing ADTS/document direct paths
        // use that completed-URL asset contract. Feature3/cmd1600 instead yields feed media_id.
        for name in ["voice.aac", "voice.m4a", "clip.mp4", "clip.mov", "document.txt", "document.bin"] {
            for group in [false, true] {
                let query = try await config(name: name, isGroup: group)
                XCTAssertEqual(query["uploadFeature"], "2", name)
                XCTAssertEqual(query["destType"], group ? "6" : "3")
                XCTAssertEqual(query["destId"], "456")
            }
        }
    }
    func testPhotoDefaultsAndExplicitNativeFeatureRemainIndependent() async throws {
        let directPhoto = try await config(name: "photo.jpg", isGroup: false)
        let groupPhoto = try await config(name: "photo.jpg", isGroup: true)
        XCTAssertEqual(directPhoto["uploadFeature"], "0")
        XCTAssertEqual(groupPhoto["uploadFeature"], "4")
        let explicit = try await config(name: "voice.aac", isGroup: true, override: 6)
        XCTAssertEqual(explicit["uploadFeature"], "6")
        XCTAssertEqual(explicit["destType"], "6")
    }
    func testLegacyVoiceWrapperRejectsLiveGroupBeforeAnyUpload() async throws {
        // Syntactically valid ADTS bypasses conversion failure: without the early gate,
        // the real upload pipeline performs two requests before the later send gate.
        let frame: [UInt8] = [0xff, 0xf1, 0x50, 0x80, 0x01, 0x5f, 0xfc, 0x10, 0x11, 0x12]
        let adts = Data(Array(repeating: frame, count: 4).flatMap { $0 })
        for explicitGroup in [false, true] {
            let transport = Transport()
            let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: String(repeating: "a", count: 64), zcidIsNative: true, groupIds: explicitGroup ? [] : [456])
            let client = ZolaClient(session: session, transport: transport)
            do {
                _ = try await client.uploadAndSendVoiceFile(audioData: adts, threadId: 456,
                    type: explicitGroup ? .group : .user, dryRun: false)
                XCTFail("Live group wrapper must require explicit group opt-in")
            } catch ZolaError.safetyGate {} catch { XCTFail("Unexpected error: \(error)") }
            let count = await transport.requestCount
            XCTAssertEqual(count, 0, "A disabled group send must not upload the recording")
        }
    }
}
