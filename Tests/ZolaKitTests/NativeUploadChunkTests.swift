import Foundation
import XCTest
@testable import ZolaKit

/// Large uploads (videos) must be split like native `uploadFile:`/`UploadChunk` (2 MB chunks), not sent as
/// one multipart request (that made Zalo answer HTTP 413). Offline: a local mock transport plays the server.
final class NativeUploadChunkTests: XCTestCase {
    private static let zcid = String(repeating: "a", count: 64)

    private struct ChunkSeen: Sendable {
        let chunkId: Int
        let totalChunk: Int
        let crc: Int64
        let clientFileId: Int
        let bodyCount: Int
        let header: String
    }

    private actor ChunkServer: ZolaNetworkTransport {
        var seen: [ChunkSeen] = []
        var rawCalls = 0
        let preUploadExtra: [String: Int]
        let failAtChunk: Int?
        init(preUploadExtra: [String: Int] = [:], failAtChunk: Int? = nil) {
            self.preUploadExtra = preUploadExtra
            self.failAtChunk = failAtChunk
        }
        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            if request.httpMethod == "GET" {
                var data: [String: Any] = ["listUrls": ["https://fixture.invalid/upload"]]
                for (key, value) in preUploadExtra { data[key] = value }
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": data]))
            }
            if request.value(forHTTPHeaderField: "Content-Type") == "raw" {
                rawCalls += 1
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["normalUrl": "https://fixture.invalid/raw.mp4"]]))
            }
            let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let hex = comps?.queryItems?.first(where: { $0.name == "data" })?.value ?? ""
            let inner = try ZolaCrypto.decryptZCIDParams(hex, zcid: NativeUploadChunkTests.zcid)
            let item = ChunkSeen(chunkId: ZolaJSON.int(inner["chunk_id"]), totalChunk: ZolaJSON.int(inner["total_chunk"]),
                                 crc: Int64(ZolaJSON.int(inner["crc"])), clientFileId: ZolaJSON.int(inner["client_file_id"]),
                                 bodyCount: request.httpBody?.count ?? 0,
                                 header: request.value(forHTTPHeaderField: "x-md-hv") ?? "")
            seen.append(item)
            if item.chunkId == failAtChunk {
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": -1004, "error_message": "chunk rejected"]))
            }
            if item.chunkId < item.totalChunk {
                return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": [String: Any]()]))
            }
            return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["normalUrl": "https://fixture.invalid/video.mp4"]]))
        }
    }

    private func client(_ transport: ChunkServer) throws -> ZolaClient {
        let session = try ZolaSession(uid: 123, sessionKey: "offline", zcid: Self.zcid, zcidIsNative: true)
        return ZolaClient(session: session, transport: transport)
    }

    private func video(bytes count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    func testChunkRangesFollowNativeCeilDivision() {
        let mb2 = ZolaClient.nativeDefaultUploadChunkSize
        XCTAssertEqual(mb2, 2_097_152)
        XCTAssertEqual(ZolaClient.nativeUploadChunkRanges(fileSize: mb2, chunkSize: mb2), [0..<mb2])
        XCTAssertEqual(ZolaClient.nativeUploadChunkRanges(fileSize: mb2 + 1, chunkSize: mb2), [0..<mb2, mb2..<(mb2 + 1)])
        XCTAssertEqual(ZolaClient.nativeUploadChunkRanges(fileSize: 0, chunkSize: mb2), [])
        XCTAssertEqual(ZolaClient.nativeUploadChunkSize(from: [:]), mb2)
        XCTAssertEqual(ZolaClient.nativeUploadChunkSize(from: ["data": ["chunkSize": 1_048_576]]), 1_048_576)
        XCTAssertEqual(ZolaClient.nativeUploadChunkSize(from: ["chunk_size": 1]), 256 * 1024)
        XCTAssertEqual(ZolaClient.nativeUploadChunkSize(from: ["chunkSize": 100_000_000]), 8 * 1024 * 1024)
    }

    func testLargeVideoIsSentAsNativeChunksWithPerChunkCrc() async throws {
        let server = ChunkServer()
        let file = video(bytes: 5 * 1024 * 1024 + 123)
        let uploaded = try await client(server).uploadMediaNativeHTTP(fileData: file, fileName: "clip.mp4", toId: 456,
                                                                      cliFileId: 4242)
        XCTAssertEqual(uploaded["normalUrl"] as? String, "https://fixture.invalid/video.mp4")
        let seen = await server.seen
        let raw = await server.rawCalls
        XCTAssertEqual(raw, 0, "files of 2 MB or more go straight to chunked upload, like native")
        XCTAssertEqual(seen.map(\.chunkId), [1, 2, 3])
        XCTAssertEqual(Set(seen.map(\.totalChunk)), [3])
        XCTAssertEqual(Set(seen.map(\.clientFileId)), [4242])
        let ranges = ZolaClient.nativeUploadChunkRanges(fileSize: file.count, chunkSize: ZolaClient.nativeDefaultUploadChunkSize)
        for (item, range) in zip(seen, ranges) {
            XCTAssertEqual(item.crc, Int64(ZolaCrypto.crc32(file.subdata(in: range))))
            XCTAssertEqual(item.header, "f=1; v=\(ZolaCrypto.crc32(file))")
            XCTAssertLessThan(item.bodyCount, ZolaClient.nativeDefaultUploadChunkSize + 1024, "one chunk per request, never the whole file")
        }
    }

    func testPreUploadChunkSizeIsHonoured() async throws {
        let server = ChunkServer(preUploadExtra: ["chunkSize": 1_048_576])
        _ = try await client(server).uploadMediaNativeHTTP(fileData: video(bytes: 3 * 1_048_576), fileName: "clip.mp4", toId: 456)
        let ids = await server.seen.map(\.chunkId)
        XCTAssertEqual(ids, [1, 2, 3])
    }

    func testRejectedChunkStopsWithServerErrorAndNoLaterChunks() async throws {
        let server = ChunkServer(failAtChunk: 2)
        do {
            _ = try await client(server).uploadMediaNativeHTTP(fileData: video(bytes: 5 * 1024 * 1024), fileName: "clip.mp4", toId: 456)
            XCTFail("a rejected chunk must fail the upload")
        } catch ZolaError.server(let code, let message) {
            XCTAssertEqual(code, -1004)
            XCTAssertEqual(message, "chunk rejected")
        }
        let ids = await server.seen.map(\.chunkId)
        XCTAssertEqual(ids, [1, 2])
    }

    func testSmallFileStillUsesRawUpload() async throws {
        let server = ChunkServer()
        let uploaded = try await client(server).uploadMediaNativeHTTP(fileData: video(bytes: 900_000), fileName: "clip.mp4", toId: 456)
        XCTAssertEqual(uploaded["normalUrl"] as? String, "https://fixture.invalid/raw.mp4")
        let seen = await server.seen
        XCTAssertTrue(seen.isEmpty)
    }
}
