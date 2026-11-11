import CryptoKit
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreVideo) && canImport(CoreMedia)
import CoreVideo
import CoreMedia
#endif
#if canImport(Network)
import Network
#endif
import XCTest
@testable import ZolaKit

private final class MockZolaTransport: ZolaNetworkTransport, @unchecked Sendable {
    private let lock = NSLock()
    let session: ZolaSession
    var requests: [URLRequest] = []
    var octetBodies: [Data] = []
    var step: Int = 0
    var forceFemcE: Int?
    var forceMfetchE: Int?

    var keySetAttempts = 0
    var keySetFailFirst = false
    var mockKeySetErrorCode: Int?
    var mockKeySetId = "aB3d9K2mPq8xYz1w"
    var mockKeySetValue = Data(repeating: 0x5A, count: 32).base64EncodedString()

    init(session: ZolaSession) {
        self.session = session
    }

    func execute(_ request: URLRequest) async throws -> (Int, Data) {
        let isKeySetCall = request.url?.path == "/api/helper/getKeySet"
        let (currentStep, forcedE, keySetAttempt) = lock.withLock {
            requests.append(request)
            if isKeySetCall { keySetAttempts += 1 }
            return (step, forceFemcE, keySetAttempts)
        }

        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZolaError.transport("Bad mock URL")
        }
        var qs: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            qs[item.name] = item.value ?? ""
        }

        switch comps.path {
        case "/api/helper/getKeySet":
            if keySetFailFirst && keySetAttempt == 1 {
                throw ZolaError.transport("Simulated first getKeySet failure")
            }
            if let forcedErr = mockKeySetErrorCode {
                let errOut = try JSONSerialization.data(withJSONObject: [
                    "error_code": forcedErr,
                    "error_message": "The session key was improperly submitted or has reached its timeout",
                ] as [String: Any])
                return (200, errOut)
            }
            let encKeySet = try ZolaCrypto.encryptZCIDParams(
                [
                    "keySet": [
                        "keySetId": mockKeySetId,
                        "keySetValue": mockKeySetValue,
                        "aesPublicId": 9_876_543_210,
                        "aesPrivateId": 1_234_567_890,
                    ] as [String: Any],
                ],
                zcid: session.zcid
            )
            let out = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": encKeySet,
            ] as [String: Any])
            return (200, out)

        case "/group/list":
            let pubKey = Int64(qs["publicKey"] ?? "0") ?? 0
            let payload: [String: Any] = [
                "data": [
                    [
                        "groupId": 900_000_201,
                        "name": "Nhóm Kỹ Thuật",
                        "avt": "https://ava.zalo.me/g1.jpg",
                        "totalMembers": 3,
                        "creatorId": 100_000_101,
                        "adminIds": [100_000_101],
                        "memberIds": ["100000101_1", "500001_1", "500002_1"],
                        "currentMems": [
                            ["id": 500_001, "dName": "Nguyễn Minh", "avt": "https://ava.zalo.me/u1.jpg"],
                            ["id": 500_002, "dName": "Trần Thảo", "avt": "https://ava.zalo.me/u2.jpg"],
                        ],
                        "isE2ee": 0,
                        "ts": 1_793_188_000_000,
                    ] as [String: Any],
                ],
                "lastGroupId": 0,
                "page": 1,
                "hasMoreList": 0,
            ]
            let b64 = try ZolaCrypto.encryptNoisedGroupData(payload, uid: session.uid, publicKey: pubKey)
            let out = try JSONSerialization.data(withJSONObject: ["error_code": 0, "isNoised": 1, "data": b64])
            return (200, out)

        case "/group/info":
            let pubKey = Int64(qs["publicKey"] ?? "0") ?? 0
            let gid = Int64(qs["group_id"] ?? "0") ?? 0
            let payload: [String: Any] = [
                "groupId": gid,
                "name": "Nhóm Kỹ Thuật",
                "desc": "Mô tả nhóm Swift",
                "totalMembers": 3,
            ]
            let b64 = try ZolaCrypto.encryptNoisedGroupData(payload, uid: session.uid, publicKey: pubKey, gid: gid)
            let out = try JSONSerialization.data(withJSONObject: ["error_code": 0, "isNoised": 1, "data": b64])
            return (200, out)

        case "/api/contact/getProfile":
            let uid = Int64(qs["id"] ?? "0") ?? 0
            let out = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "userId": uid,
                    "displayName": "Khách VIP Lê Hoàng",
                    "phoneNumber": "0909***888",
                ] as [String: Any],
            ] as [String: Any])
            return (200, out)

        case "/api/friend/loginfriend":
            let enc = try ZolaCrypto.encryptZCIDParams(
                ["friends": [["userId": 600_001, "displayName": "Bạn Bè Swift", "isFr": 1]]],
                zcid: session.zcid
            )
            let out = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": enc])
            return (200, out)

        case "/api/cm/femc":
            if let forcedE {
                let out = try JSONSerialization.data(withJSONObject: ["e": forcedE, "errMessage": "Session invalid"])
                return (200, out)
            }
            var msgs: [[String: Any]] = [
                [
                    "text": [
                        "type": "webchat",
                        "data": [
                            "id": 1001,
                            "cliMsgId": 9001,
                            "fromU": 500_001,
                            "fromD": "Nguyễn Minh",
                            "to": session.uid,
                            "ts": 1_793_188_001_000,
                            "msg": "Báo giá sản phẩm A",
                        ] as [String: Any],
                    ] as [String: Any],
                ],
            ]
            if currentStep >= 2 {
                msgs.append([
                    "text": [
                        "type": "webchat",
                        "data": [
                            "id": 1002,
                            "cliMsgId": 9002,
                            "fromU": session.uid,
                            "to": session.sendToMeId,
                            "ts": 1_793_188_009_000,
                            "msg": "Ghi chú Cloud",
                        ] as [String: Any],
                    ] as [String: Any],
                ])
            }
            let enc = try ZolaCrypto.encryptZCIDParams(["hasMore": false, "msg": msgs], zcid: session.zcid)
            let out = try JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc])
            return (200, out)

        case "/api/preload":
            var lmsgs: [[String: Any]] = [
                [
                    "text": [
                        "type": "chat.photo",
                        "data": [
                            "id": 5001,
                            "cliMsgId": 8001,
                            "fromU": 500_002,
                            "fromD": "Trần Thảo",
                            "to": 900_000_201,
                            "ts": 1_793_188_002_000,
                            "msg": "",
                            "attach": ["title": "Ảnh máy", "href": "https://img.zalo.me/1.jpg"],
                            "quote": ["ownerId": 500_001, "cliMsgId": 7999, "globalMsgId": 5000, "msg": "Cho xem ảnh"],
                        ] as [String: Any],
                    ] as [String: Any],
                ],
            ]
            if currentStep >= 2 {
                lmsgs.append([
                    "text": [
                        "type": "webchat",
                        "data": [
                            "id": 1002,
                            "cliMsgId": 9002,
                            "fromU": session.uid,
                            "to": session.sendToMeId,
                            "ts": 1_793_188_009_000,
                            "msg": "Ghi chú Cloud",
                        ] as [String: Any],
                    ] as [String: Any],
                ])
                lmsgs.append([
                    "text": [
                        "type": "webchat",
                        "data": [
                            "id": 5002,
                            "cliMsgId": 8002,
                            "fromU": 500_002,
                            "fromD": "Trần Thảo",
                            "to": 900_000_201,
                            "ts": 1_793_188_010_000,
                            "msg": "Chốt đơn!",
                        ] as [String: Any],
                    ] as [String: Any],
                ])
            }
            let enc = try ZolaCrypto.encryptZCIDParams(
                [
                    "infoJoinGroup": [["gid": 900_000_201, "glbMsgId": 5001, "tsJoinGroup": 1_775_619_185_729]],
                    "lastMsgs": lmsgs,
                ],
                zcid: session.zcid
            )
            let out = try JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc])
            return (200, out)

        case "/api/cm/mfetch":
            if let forceMfetchE {
                let out = try JSONSerialization.data(withJSONObject: ["e": forceMfetchE, "errMessage": "Session invalid"])
                return (200, out)
            }
            // Decode the backward-paging cursor (`gId` + `tGmi`) from the encrypted POST body.
            var reqGid: Int64 = 0
            var reqTGmi: Int64 = 0
            if let body = request.httpBody,
               let bodyStr = String(data: body, encoding: .utf8),
               let comps2 = URLComponents(string: "x://x?\(bodyStr)"),
               let dataHex = comps2.queryItems?.first(where: { $0.name == "data" })?.value,
               let inner = try? ZolaCrypto.decryptZCIDParams(dataHex, zcid: session.zcid),
               let dataStr = inner["data"] as? String,
               let dataObj = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any],
               let gIds = dataObj["gIds"] as? [[String: Any]],
               let first = gIds.first {
                reqGid = (first["gId"] as? NSNumber)?.int64Value ?? 0
                reqTGmi = (first["tGmi"] as? NSNumber)?.int64Value ?? 0
            }

            func histMsg(_ glb: Int64, gid: Int64) -> [String: Any] {
                [
                    "text": [
                        "type": "webchat",
                        "data": [
                            "id": glb,
                            "cliMsgId": glb + 100_000,
                            "fromU": 500_001,
                            "fromD": "Nguyễn Minh",
                            "to": gid,
                            "ts": 1_700_000_000_000 + glb,
                            "msg": "Lịch sử nhóm \(glb)",
                        ] as [String: Any],
                    ] as [String: Any],
                ]
            }

            var msgs: [[String: Any]]
            switch reqGid {
            case 820_000_001:
                // Finite server-held window [4000, 4899]; 3 newest per call within [0, tGmi].
                let top: Int64 = reqTGmi == 0 ? 4899 : min(reqTGmi, 4899)
                var page: [[String: Any]] = []
                var g = top
                while g >= 4000 && page.count < 3 {
                    page.append(histMsg(g, gid: reqGid))
                    g -= 1
                }
                msgs = page
            case 820_000_002:
                // Sticky window: server ignores the cursor and returns the same slice — the
                // loop must stop (no backward progress) without double-counting these ids.
                msgs = [histMsg(4899, gid: reqGid), histMsg(4898, gid: reqGid), histMsg(4897, gid: reqGid)]
            default:
                msgs = [
                    [
                        "text": [
                            "type": "webchat",
                            "data": [
                                "id": 4999,
                                "cliMsgId": 7998,
                                "fromU": 500_001,
                                "fromD": "Nguyễn Minh",
                                "to": 900_000_201,
                                "ts": 1_793_187_990_000,
                                "msg": "Tin nhắn lịch sử nhóm từ mfetch",
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                ]
            }
            let enc = try ZolaCrypto.encryptZCIDParams(["msg": msgs], zcid: session.zcid)
            let out = try JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc])
            return (200, out)

        case "/api/message":
            let body = request.httpBody ?? Data()
            let unpacked = try ZolaCrypto.unpackHttpFailoverFrame(body)
            if unpacked.cmd == 115 {
                var offlineMsgs: [[String: Any]] = []
                if currentStep >= 3 {
                    offlineMsgs.append([
                        "text": [
                            "type": "webchat",
                            "data": [
                                "id": 9901,
                                "cliMsgId": 19901,
                                "fromU": 100_000_108,
                                "fromD": "Đỗ Minh Hà",
                                "to": session.uid,
                                "ts": 1_793_188_020_000,
                                "msg": "Tin nhắn 1-1 mới gửi đến từ GetOffline!",
                            ] as [String: Any],
                        ] as [String: Any],
                    ])
                }
                let ack = try JSONSerialization.data(withJSONObject: [
                    "error_code": 0,
                    "error_message": "Successful.",
                    "data": [
                        "offline": [
                            "e": 0,
                            "msg": offlineMsgs,
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any])
                return (200, ack)
            }
            lock.withLock {
                octetBodies.append(body)
            }
            let dec = try ZolaCrypto.decryptMcryptTextBody(unpacked.bodyData, cryptKey: session.cryptKey)
            XCTAssertEqual(dec.subCmd, 41)
            XCTAssertEqual(dec.text, "Xin chào từ ZolaKit iOS!")
            let ack = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "type": 0,
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [
                                    ["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_111)] as [String: Any],
                                ],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any])
            return (200, ack)

        default:
            throw ZolaError.transport("Unexpected path \(comps.path)")
        }
    }
}

final class ZolaKitTests: XCTestCase {
    private let dummyCk = Data("0123456789abcdef".utf8)

    func testCryptoVectorsAndFrameCodecParity() throws {
        // 1. Deterministic zcid generation
        let expectedZcid = "1_166DBF93CC1D91B465795984762712B0AA167703FF97280D3055408744E639F4F1408DC182A12753B9D08FC854AC79697DBCB304DA0B41582329736B39A00D2C0A80B69183E713FA16E48BF31233647D"
        let platform = ZolaCrypto.platformString(shortModel: "iP16Pro", osVersion: "26.3.1", jailbroken: false)
        let generated = try ZolaCrypto.generateZCID(idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB", platform: platform, timestampMs: 1_700_000_000_000)
        XCTAssertEqual(generated, expectedZcid)
        XCTAssertEqual(try ZolaCrypto.paramKey(zcid: generated).count, 32)

        // 2. Noised group AES-256-CBC round-trip
        let encGrp = try ZolaCrypto.encryptNoisedGroupData(["name": "Nhóm Zola"], uid: 100_000_101, publicKey: 987_654_321, gid: 900_000_201)
        let decGrp = try ZolaCrypto.decryptNoisedGroupData(base64: encGrp, uid: 100_000_101, publicKey: 987_654_321, gid: 900_000_201)
        XCTAssertEqual(decGrp["name"] as? String, "Nhóm Zola")

        // 3. TLV subCmd=41 message body & ChatElement wire frame round-trip verification
        let iv20 = try ZolaCrypto.unhex("433c220f4fafbbfea81a209f1c5f19fa")
        let built20 = try ZolaCrypto.buildTextMsgBodyData(
            text: "Xin chào, tin nhắn thử 122",
            isGroup: false,
            includeIOSProps: true,
            trackingIdHex: "55f246ae9333ab20c9ba8a7e2fb32e0e",
            clientIdMs: 1_793_167_535_592,
            cryptKey: dummyCk,
            iv16: iv20
        )
        XCTAssertEqual(built20.bodyData.count, 218)
        let rt20 = try ZolaCrypto.decryptMcryptTextBody(built20.bodyData, cryptKey: dummyCk)
        XCTAssertEqual(rt20.text, "Xin chào, tin nhắn thử 122")

        let elem = ZolaCrypto.packChatElementFrame(
            bodyData: built20.bodyData,
            srcId: 100_000_101,
            srcType: 2,
            msgType: 2,
            cmd: built20.innerCmd,
            subCmd: built20.subCmd,
            seqId: 1,
            needAck: 1,
            desId: 204_278_670,
            desType: 3,
            globalMsgId: 1_793_167_535_592
        )
        let unpacked = try ZolaCrypto.unpackChatElementFrame(elem.payload)
        let rebuilt = ZolaCrypto.packChatElementFrame(
            bodyData: unpacked.bodyData,
            srcId: unpacked.srcId,
            srcType: unpacked.srcType,
            msgType: unpacked.msgType,
            cmd: unpacked.cmd,
            subCmd: unpacked.subCmd,
            seqId: unpacked.seqId,
            needAck: unpacked.needAck,
            desId: unpacked.desId,
            desType: unpacked.desType,
            globalMsgId: unpacked.globalMsgId,
            version: unpacked.version
        )
        XCTAssertEqual(rebuilt.payload, elem.payload)
    }

    func testSessionRedactionAndInteropFileStore() throws {
        let sess = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "p-5E.100000101.a1.SECRET_DO_NOT_PRINT",
            cryptKey: dummyCk,
            sessionBoxTokens: ["group.api.zaloapp.com": ZolaSessionBoxToken(name: "zss_l2", value: "TOP_SECRET_ZSS")]
        )
        XCTAssertFalse(sess.description.contains("SECRET_DO_NOT_PRINT"))
        XCTAssertFalse(sess.debugDescription.contains("TOP_SECRET_ZSS"))

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("session-100000101.local.json")
        let rawJson = try JSONSerialization.data(withJSONObject: [
            "uid": 100_000_101,
            "session_key": "p-5E.100000101.a1.INTEROP_TOKEN",
            "crypt_key_b64": dummyCk.base64EncodedString(),
        ] as [String: Any])
        try ZolaFileSessionStore.writeData0600(rawJson, to: fileURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let loaded = try ZolaFileSessionStore.loadInteropJSON(from: fileURL)
        XCTAssertEqual(loaded.uid, 100_000_101)
        XCTAssertEqual(loaded.cryptKey, dummyCk)
        XCTAssertFalse(loaded.zcidIsNative)
    }

    func testClientInboxPollerAndSafetyGates() async throws {
        let sess = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "p-5E.100000101.a1.SWIFT_ACTOR_TOKEN",
            cryptKey: dummyCk,
            zcidIsNative: false,
            sessionBoxTokens: ["group.api.zaloapp.com": ZolaSessionBoxToken(name: "zss_l2", value: "VAL_999", domain: "group.api.zaloapp.com")]
        )
        let mock = MockZolaTransport(session: sess)
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        // 1. Directory & SessionBox headers
        let groups = try await client.listJoinedGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Nhóm Kỹ Thuật")
        XCTAssertEqual(mock.requests.last?.value(forHTTPHeaderField: ZolaConstants.sessionBoxHeaderName), "zss_l2")

        let ginfo = try await client.getGroupInfo(gid: 900_000_201)
        XCTAssertEqual(ginfo.desc, "Mô tả nhóm Swift")

        let prof = try await client.getUserProfile(uid: 700_999)
        XCTAssertEqual(prof.displayName, "Khách VIP Lê Hoàng")

        // 2. Synthetic zcid blocks loginfriend by default
        do {
            _ = try await client.listFriends()
            XCTFail("Expected safetyGate error")
        } catch let err as ZolaError {
            if case .safetyGate = err {} else { XCTFail("Unexpected error \(err)") }
        }

        // 3. Unified Inbox sync
        let inbox = try await client.syncInbox(discoverGroups: true)
        XCTAssertEqual(inbox.count, 2)
        XCTAssertEqual(inbox[0].threadId, 900_000_201)
        XCTAssertTrue(inbox[0].needsReply)
        XCTAssertEqual(inbox[0].lastMessage?.kind, "photo")
        XCTAssertEqual(inbox[0].lastMessage?.quote?.text, "Cho xem ảnh")

        // 4. Incremental poller + cross-dedupe
        let ev0 = try await client.pollOnce()
        XCTAssertTrue(ev0.isEmpty)
        mock.step = 1
        let ev1 = try await client.pollOnce()
        XCTAssertTrue(ev1.isEmpty)
        mock.step = 2
        let ev2 = try await client.pollOnce()
        XCTAssertEqual(ev2.compactMap { $0.message?.id }, [1002, 5002])

        // 5. Dry-run send default vs explicit live send vs group guard
        let dryReceipt = try await client.sendToMe(text: "Dry run check")
        XCTAssertTrue(dryReceipt.dryRun)
        XCTAssertFalse(dryReceipt.sent)
        XCTAssertEqual(mock.octetBodies.count, 0)

        let liveReceipt = try await client.sendToMe(text: "Xin chào từ ZolaKit iOS!", dryRun: false)
        XCTAssertTrue(liveReceipt.ok)
        XCTAssertTrue(liveReceipt.sent)
        XCTAssertEqual(mock.octetBodies.count, 1)

        do {
            _ = try await client.sendText1To1(to: 900_000_201, text: "Group block")
            XCTFail("Expected groupSendNotSupportedOverHttp")
        } catch ZolaError.groupSendNotSupportedOverHttp {
            // Expected
        }
        let grpFrame = try await client.buildGroupSendSocketFrame(gid: 900_000_201, text: "Offline socket")
        XCTAssertEqual(grpFrame.headerLength, 36)

        let mfetchMsgs = try await client.fetchGroupRange(gid: 900_000_201, fromGlobalId: 0, toGlobalId: 5001)
        XCTAssertEqual(mfetchMsgs.count, 1)
        XCTAssertEqual(mfetchMsgs.first?.text, "Tin nhắn lịch sử nhóm từ mfetch")
        XCTAssertEqual(mfetchMsgs.first?.threadId, 900_000_201)
        XCTAssertTrue(mfetchMsgs.first?.isGroup ?? false)
    }

    func testCircuitBreakerLatchesOnMinus96() async throws {
        let sess = try ZolaSession(uid: 100_000_101, sessionKey: "p-5E.100000101.a1.EXPIRE_TEST", cryptKey: dummyCk)
        let mock = MockZolaTransport(session: sess)
        mock.forceFemcE = -96
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        do {
            _ = try await client.fetchFemc()
            XCTFail("Expected sessionExpired")
        } catch let ZolaError.sessionExpired(code, _, _) {
            XCTAssertEqual(code, -96)
        }

        let countAfterExpire = mock.requests.count
        do {
            _ = try await client.listJoinedGroups()
            XCTFail("Expected circuit breaker to block immediately")
        } catch let ZolaError.sessionExpired(_, endpoint, _) {
            XCTAssertEqual(endpoint, "circuit_breaker")
        }
        XCTAssertEqual(mock.requests.count, countAfterExpire)
    }

    func testDeepHistorySyncBackwardPagingAndDrain() async throws {
        let sess = try ZolaSession(uid: 100_000_101, sessionKey: "p-5E.100000101.a1.HISTORY_TEST", cryptKey: dummyCk)
        let mock = MockZolaTransport(session: sess)
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        // 1. Backward mfetch walks older pages (3 msgs/page) without exhausting within pageLimit.
        let r1 = try await client.fetchOlderGroupHistory(
            gid: 820_000_001, beforeGlobalMsgId: 4900, pageLimit: 3, pageDelayNs: 0
        )
        XCTAssertEqual(r1.messages.count, 9)
        XCTAssertEqual(r1.oldestGlobalMsgId, 4891)
        XCTAssertFalse(r1.exhausted)
        // Returned oldest-first, strictly increasing global ids, no duplicates.
        XCTAssertEqual(r1.messages.map(\.id), [4891, 4892, 4893, 4894, 4895, 4896, 4897, 4898, 4899])
        var exhaustedFlag = await client.isGroupHistoryExhausted(820_000_001)
        XCTAssertFalse(exhaustedFlag)

        // 2. Draining the rest reaches the start of the server window and latches exhausted.
        let r2 = try await client.fetchOlderGroupHistory(
            gid: 820_000_001, beforeGlobalMsgId: 4891, pageLimit: 500, pageDelayNs: 0
        )
        XCTAssertTrue(r2.exhausted)
        XCTAssertEqual(r2.messages.count, 891) // glb 4000...4890 inclusive
        XCTAssertEqual(r2.messages.first?.id, 4000)
        XCTAssertEqual(r2.messages.last?.id, 4890)
        exhaustedFlag = await client.isGroupHistoryExhausted(820_000_001)
        XCTAssertTrue(exhaustedFlag)

        // 3. Once latched, repeat calls short-circuit to empty + exhausted (no extra requests).
        let reqsBefore = mock.requests.count
        let r3 = try await client.fetchOlderGroupHistory(
            gid: 820_000_001, beforeGlobalMsgId: 3999, pageLimit: 10, pageDelayNs: 0
        )
        XCTAssertTrue(r3.messages.isEmpty)
        XCTAssertTrue(r3.exhausted)
        XCTAssertEqual(mock.requests.count, reqsBefore)

        // 4. Sticky server (ignores cursor): dedupe prevents double-count and no-progress stops the loop.
        let r4 = try await client.fetchOlderGroupHistory(
            gid: 820_000_002, beforeGlobalMsgId: 4900, pageLimit: 10, pageDelayNs: 0
        )
        XCTAssertEqual(r4.messages.count, 3)
        XCTAssertEqual(Set(r4.messages.map(\.id)).count, 3)
        XCTAssertTrue(r4.exhausted)

        // 5. drainOfflineHistory pages femc forward (1-1/Cloud) and returns fetched messages.
        let sess2 = try ZolaSession(uid: 100_000_101, sessionKey: "p-5E.100000101.a1.DRAIN_TEST", cryptKey: dummyCk)
        let mock2 = MockZolaTransport(session: sess2)
        let client2 = ZolaClient(session: sess2, transport: mock2, minPollIntervalSeconds: 0)
        let drained = try await client2.drainOfflineHistory(maxPages: 3, pageDelayNs: 0)
        XCTAssertEqual(drained.map(\.id), [1001])

        // 6. Circuit breaker: mfetch `-96` propagates as sessionExpired and does NOT latch exhausted.
        let sess3 = try ZolaSession(uid: 100_000_101, sessionKey: "p-5E.100000101.a1.MFETCH_ERR", cryptKey: dummyCk)
        let mock3 = MockZolaTransport(session: sess3)
        mock3.forceMfetchE = -96
        let client3 = ZolaClient(session: sess3, transport: mock3, minPollIntervalSeconds: 0)
        do {
            _ = try await client3.fetchOlderGroupHistory(
                gid: 820_000_001, beforeGlobalMsgId: 4900, pageLimit: 5, pageDelayNs: 0
            )
            XCTFail("Expected sessionExpired from mfetch -96")
        } catch let ZolaError.sessionExpired(code, _, _) {
            XCTAssertEqual(code, -96)
        }
        let latchedAfterErr = await client3.isGroupHistoryExhausted(820_000_001)
        XCTAssertFalse(latchedAfterErr)
    }

    func testHistoryCursorUsesRealServerGlobalIdNotOptimisticSelfSent() throws {
        let now: Int64 = 1_760_000_000_000
        // Optimistic self-sent before reconcile: `id == cliMsgId`.
        let optimisticCliEcho = ZolaMessage(
            id: 9_000_001, cliMsgId: 9_000_001, threadId: 820_000_001, isGroup: true,
            senderId: 100_000_101, toId: 820_000_001, tsMs: now, text: "optimistic", isSelf: true, source: "sent"
        )
        // Optimistic self-sent with a timestamp-echo id: `id == tsMs`.
        let optimisticTsEcho = ZolaMessage(
            id: now + 5, cliMsgId: 7_000_002, threadId: 820_000_001, isGroup: true,
            senderId: 100_000_101, toId: 820_000_001, tsMs: now + 5, text: "ts echo", isSelf: true, source: "sending"
        )
        // Real server messages with large global ids.
        let realOld = ZolaMessage(
            id: 900_000_000_000_000_001, cliMsgId: 123, threadId: 820_000_001, isGroup: true,
            senderId: 500_001, toId: 820_000_001, tsMs: now - 1000, text: "cũ", isSelf: false, source: "mfetch"
        )
        let realNew = ZolaMessage(
            id: 900_000_000_000_000_050, cliMsgId: 124, threadId: 820_000_001, isGroup: true,
            senderId: 500_001, toId: 820_000_001, tsMs: now - 500, text: "mới", isSelf: false, source: "mfetch"
        )

        XCTAssertFalse(optimisticCliEcho.hasRealServerGlobalId)
        XCTAssertFalse(optimisticTsEcho.hasRealServerGlobalId)
        XCTAssertTrue(realOld.hasRealServerGlobalId)
        XCTAssertTrue(realNew.hasRealServerGlobalId)

        // The backward-history cursor must be the OLDEST REAL global id — not the tiny optimistic id,
        // which would otherwise make the server return an empty page and falsely latch "exhausted".
        let msgs = [optimisticCliEcho, optimisticTsEcho, realOld, realNew]
        let naiveMin = msgs.map(\.id).filter { $0 > 0 }.min()
        let realCursor = msgs.filter { $0.hasRealServerGlobalId }.map(\.id).min()
        XCTAssertEqual(naiveMin, 9_000_001, "Naïve min is poisoned by the optimistic self-sent id")
        XCTAssertEqual(realCursor, 900_000_000_000_000_001, "Cursor must be the real server global id")
        XCTAssertGreaterThan(realCursor ?? 0, 1_000_000_000_000_000, "Cursor is a real glb, not a timestamp")
    }

    func testLoginPrecheckIncludesFullClientParameters() async throws {
        let client = ZolaLoginClient(identity: .defaultProfile)
        let inner = client.makePrecheckInnerPayload(phone: "+84987654321", nowMs: 1_793_205_263_000)

        // Verify all required client verification fields
        XCTAssertEqual(inner["device_identifier"] as? String, ZolaDeviceIdentity.defaultProfile.deviceIdentifier)
        XCTAssertEqual(inner["distributor"] as? String, "iAPP")
        XCTAssertEqual(inner["type"] as? Int, ZolaConstants.clientTypeIOS)
        XCTAssertEqual(inner["client_type"] as? Int, ZolaConstants.clientTypeIOS)
        XCTAssertEqual(inner["client_version"] as? Int, ZolaConstants.clientVersionIOS)
        XCTAssertEqual(inner["fresh_install"] as? Int, 1)
        XCTAssertEqual(inner["width"] as? Int, 402)
        XCTAssertEqual(inner["height"] as? Int, 874)
        XCTAssertEqual(inner["heap"] as? Int, 314)
        XCTAssertEqual(inner["jailbroken"] as? String, "0")
        XCTAssertEqual(inner["device_name"] as? String, "iPhone 16 Pro")
        XCTAssertEqual(inner["time_zone"] as? String, "+07:00")
        XCTAssertEqual(inner["language"] as? String, "vi")
        XCTAssertEqual(inner["captcha_value"] as? String, "")
        XCTAssertEqual(inner["captcha_token"] as? String, "")
        XCTAssertEqual(inner["source_action"] as? Int, 0)
        XCTAssertEqual(inner["source_switch"] as? Int, 0)
        XCTAssertEqual(inner["phone_num"] as? String, "+84987654321")
    }

    func testLoginResponseExtractsCrypKeyDisplayNameAndSendToMeId() async throws {
        let client = ZolaLoginClient(identity: .defaultProfile)
        let ckB64 = dummyCk.base64EncodedString()
        let obj: [String: Any] = [
            "error_code": 0,
            "error_message": "Successful.",
            "data": [
                "user_id": 100_000_101,
                "token": "tok_test_123",
                "session_key": "p-5E.100000101.a1.LOGIN_SK_TEST",
                "CrypKey": ckB64,
                "send2me_id": 204_278_670,
                "profile": [
                    "dpn": "Văn An",
                    "avt": "https://ava.zalo.me/hl.jpg",
                ],
            ] as [String: Any],
        ]
        let outcome = await client.parseLoginResponse(obj: obj, text: "{}", sessionToken: "zk000.test")
        guard case let .success(res) = outcome else {
            return XCTFail("Expected login success")
        }
        XCTAssertEqual(res.userId, 100_000_101)
        XCTAssertEqual(res.cryptKey, dummyCk)
        XCTAssertEqual(res.displayName, "Văn An")
        XCTAssertEqual(res.avatarUrl, "https://ava.zalo.me/hl.jpg")
        XCTAssertEqual(res.sendToMeId, 204_278_670)

        let session = try await client.makeSession(from: res)
        XCTAssertEqual(session.cryptKey, dummyCk)
        XCTAssertEqual(session.sendToMeId, 204_278_670)
    }

    func testGetOfflineSinglePreloadAndRichAttachments() async throws {
        let sess = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "p-5E.100000101.a1.OFFLINE_RECV_TEST",
            cryptKey: dummyCk
        )
        let mock = MockZolaTransport(session: sess)
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        let inbox = try await client.syncInbox(discoverGroups: true)
        await client.primeWatermarks(from: inbox)
        mock.step = 3
        let events = try await client.pollOnce()
        let incomingOffline = events.compactMap(\.message).first(where: { $0.id == 9901 })
        XCTAssertNotNil(incomingOffline)
        XCTAssertEqual(incomingOffline?.threadId, 100_000_108)
        XCTAssertEqual(incomingOffline?.senderName, "Đỗ Minh Hà")
        XCTAssertEqual(incomingOffline?.text, "Tin nhắn 1-1 mới gửi đến từ GetOffline!")
        XCTAssertFalse(incomingOffline?.isGroup ?? true)

        // Verify sticker CDN URL synthesis & rich attachment parsing
        let stickerMsg = ZolaMessage.fromRawItem(
            [
                "text": [
                    "type": "chat.sticker",
                    "data": [
                        "id": 7001,
                        "cliMsgId": 17001,
                        "fromU": 500_001,
                        "to": 100_000_101,
                        "ts": 1_793_188_030_000,
                        "msg": #"{"id":23456,"catId":102,"type":7}"#,
                    ] as [String: Any],
                ] as [String: Any],
            ],
            selfUid: 100_000_101
        )
        XCTAssertEqual(stickerMsg.kind, "sticker")
        XCTAssertEqual(stickerMsg.text, "")
        XCTAssertEqual(stickerMsg.attachments.first?.stickerId, 23456)
        XCTAssertEqual(stickerMsg.attachments.first?.cateId, 102)
        XCTAssertEqual(
            stickerMsg.attachments.first?.url,
            "https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=23456&size=130"
        )

        let fileMsg = ZolaMessage.fromRawItem(
            [
                "text": [
                    "type": "share.file",
                    "data": [
                        "id": 7002,
                        "cliMsgId": 17002,
                        "fromU": 500_001,
                        "to": 100_000_101,
                        "ts": 1_793_188_031_000,
                        "attach": [
                            "title": "HopDong_Thang10.pdf",
                            "href": "https://f.zalo.me/HopDong_Thang10.pdf",
                            "fileSize": 1_548_288,
                        ] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ],
            selfUid: 100_000_101
        )
        XCTAssertEqual(fileMsg.kind, "file")
        XCTAssertEqual(fileMsg.attachments.first?.fileExt, "pdf")
        XCTAssertEqual(fileMsg.attachments.first?.fileSize, 1_548_288)
    }

    func testLoginCode2034ChallengeAndVerificationCodeFlow() async throws {
        final class MockLoginTransport: ZolaNetworkTransport, @unchecked Sendable {
            var paths: [String] = []
            var mintedCount = 0
            var consumedTokens: Set<String> = []
            private let zcid = ZolaDeviceIdentity.defaultProfile.zcid

            private func decodeInner(_ request: URLRequest) -> [String: Any] {
                guard let body = request.httpBody,
                      let bodyStr = String(data: body, encoding: .utf8) else { return [:] }
                for pair in bodyStr.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "data" {
                        let hexStr = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        if let dict = try? ZolaCrypto.decryptZCIDParams(hexStr, zcid: zcid) {
                            return dict
                        }
                    }
                }
                return [:]
            }

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                paths.append(path)
                let inner = decodeInner(request)
                let resp: [String: Any]
                switch path {
                case "/api/register/verifyClientInfo":
                    mintedCount += 1
                    resp = [
                        "error_code": 0,
                        "error_message": "Successful.",
                        "data": [
                            "session_token": "zk2fav2.fresh_token_\(mintedCount)",
                        ] as [String: Any],
                    ]
                case "/api/register/activeAccountByPassword", "/api/register/activePasswordWithQuestion":
                    let tok = (inner["session_token"] as? String) ?? ""
                    if tok.isEmpty || consumedTokens.contains(tok) {
                        resp = ["error_code": 2003, "error_message": "Invalid token"]
                    } else {
                        consumedTokens.insert(tok)
                        resp = [
                            "error_code": 2034,
                            "error_message": "Question already exceed",
                        ]
                    }
                case "/api/register/getActivationCode":
                    let tok = (inner["session_token"] as? String) ?? ""
                    if tok.isEmpty || consumedTokens.contains(tok) {
                        resp = ["error_code": 2003, "error_message": "Invalid token"]
                    } else {
                        consumedTokens.insert(tok)
                        resp = [
                            "error_code": 0,
                            "error_message": "Successful.",
                            "data": [
                                "activationToken": "zk2fav2.act_session_key_\(mintedCount)",
                                "activation_type": 6,
                            ] as [String: Any],
                        ]
                    }
                case "/api/register/activeAccountByActivationCode":
                    let actTok = (inner["activation_token"] as? String) ?? ""
                    if actTok != "zk2fav2.act_session_key_\(mintedCount)" {
                        resp = ["error_code": 2003, "error_message": "Invalid token"]
                    } else {
                        resp = [
                            "error_code": 0,
                            "error_message": "Successful.",
                            "data": [
                                "verificationToken": "zk2fav2.verif_tok_from_otp_999",
                            ] as [String: Any],
                        ]
                    }
                case "/api/register/verifyAccount":
                    let verifTok = (inner["verificationToken"] as? String) ?? ""
                    if verifTok != "zk2fav2.verif_tok_from_otp_999" || inner["session_token"] != nil {
                        resp = ["error_code": 2003, "error_message": "Invalid token"]
                    } else {
                        resp = [
                            "error_code": 0,
                            "error_message": "Successful.",
                            "data": [
                                "user_id": 100_000_101,
                                "token": "tok_after_otp",
                                "session_key": "p-5E.100000101.a1.AFTER_OTP_SK",
                                "CrypKey": Data(repeating: 0x55, count: 16).base64EncodedString(),
                                "send2me_id": 204_278_670,
                            ] as [String: Any],
                        ]
                    }
                default:
                    resp = ["error_code": 0, "data": [:] as [String: Any]]
                }
                let raw = try JSONSerialization.data(withJSONObject: resp)
                return (200, raw)
            }
        }

        let transport = MockLoginTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        // Step 1: Precheck mints single-use token #1
        let pre = try await client.precheck(phone: "0901234567")
        XCTAssertEqual(pre.sessionToken, "zk2fav2.fresh_token_1")

        // Step 2: Password login consumes token #1 and returns 2034 ("Question already exceed")
        let loginOutcome = try await client.login(
            phone: "0901234567",
            password: "test_password",
            existingSessionToken: pre.sessionToken
        )
        guard case let .challenge(fields, ec, _) = loginOutcome else {
            return XCTFail("Expected .challenge on code 2034, got \(loginOutcome)")
        }
        XCTAssertEqual(ec, 2034)
        XCTAssertFalse(fields.isEmpty)
        let challengeAfter2034 = await client.latestChallenge()
        XCTAssertEqual(challengeAfter2034?.isForgotPassword, false)
        XCTAssertNil(challengeAfter2034?.sessionToken, "Consumed precheck session_token must not be retained as unconsumed")

        // Step 3A: Request verification code must automatically mint fresh token #2 via verifyClientInfo (avoiding 2003 Invalid token)
        let reqResult = try await client.requestVerificationCode(
            phone: "0901234567",
            method: .recentDevice,
            existingChallenge: challengeAfter2034,
            existingSessionToken: pre.sessionToken
        )
        XCTAssertTrue(reqResult.sent, "Expected getActivationCode to succeed with fresh token, got \(reqResult.deliveryMessage)")
        XCTAssertEqual(reqResult.errorCode, 0)
        XCTAssertEqual(reqResult.challenge.activationToken, "zk2fav2.act_session_key_2")
        XCTAssertEqual(reqResult.challenge.activationType, 6)
        XCTAssertEqual(reqResult.challenge.method, .recentDevice)

        // Step 3B: Submit 6-digit OTP code and complete verification without sending stale session_token
        let verifyOutcome = try await client.submitVerificationCode(
            phone: "0901234567",
            password: "test_password",
            code: "123456",
            challenge: reqResult.challenge,
            existingSessionToken: pre.sessionToken
        )
        guard case let .success(res) = verifyOutcome else {
            return XCTFail("Expected .success after OTP verification, got \(verifyOutcome)")
        }
        XCTAssertEqual(res.userId, 100_000_101)
        XCTAssertEqual(res.sessionKey, "p-5E.100000101.a1.AFTER_OTP_SK")
        XCTAssertEqual(transport.mintedCount, 2)
        XCTAssertTrue(transport.paths.contains("/api/register/getActivationCode"))
        XCTAssertTrue(transport.paths.contains("/api/register/activeAccountByActivationCode"))
        XCTAssertTrue(transport.paths.contains("/api/register/verifyAccount"))
    }

    func testSmsGatewayCode2012And2021AndStringFlagsWithout2003Overwrite() async throws {
        final class MockSmsGatewayTransport: ZolaNetworkTransport, @unchecked Sendable {
            var getActivationCallCount = 0
            private let zcid = ZolaDeviceIdentity.defaultProfile.zcid

            private func decodeInner(_ request: URLRequest) -> [String: Any] {
                guard let body = request.httpBody,
                      let bodyStr = String(data: body, encoding: .utf8) else { return [:] }
                for pair in bodyStr.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "data" {
                        let hexStr = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        if let dict = try? ZolaCrypto.decryptZCIDParams(hexStr, zcid: zcid) {
                            return dict
                        }
                    }
                }
                return [:]
            }

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                let inner = decodeInner(request)
                let resp: [String: Any]
                switch path {
                case "/api/register/verifyClientInfo":
                    resp = [
                        "error_code": 0,
                        "data": ["sessionToken": "zk2fav2.single_use_req_tok"] as [String: Any],
                    ]
                case "/api/register/getActivationCode":
                    getActivationCallCount += 1
                    // Server requires string "1" / "0" for forget_password and renew_account ("0" for login challenges)
                    XCTAssertEqual(inner["forget_password"] as? String, "0")
                    XCTAssertEqual(inner["renew_account"] as? String, "0")
                    XCTAssertNil(inner["captcha_value"])
                    XCTAssertNil(inner["captcha_token"])
                    if getActivationCallCount > 1 {
                        // A second call would consume the already-used token and return 2003 with non-nil empty data {}
                        resp = ["error_code": 2003, "error_message": "Invalid token", "data": [:] as [String: Any]]
                    } else {
                        resp = [
                            "error_code": 2012,
                            "error_message": "Đã vượt giới hạn nhận mã tự động.",
                            "data": [
                                "activationToken": "zk2fav2.submit_otp_tok_777",
                                "activationType": 1,
                                "activationNumber": 6,
                                "sms_gateway": "7539",
                                "sms_content_hint": "ZALO",
                                "timeout": 180,
                                "title": "Soạn tin nhắn SMS xác minh",
                            ] as [String: Any],
                        ]
                    }
                case "/api/register/activeAccountByActivationCode":
                    XCTAssertEqual(inner["forget_password"] as? String, "0")
                    XCTAssertEqual(inner["renew_account"] as? String, "0")
                    XCTAssertEqual(inner["activation_token"] as? String, "zk2fav2.submit_otp_tok_777")
                    resp = [
                        "error_code": 0,
                        "data": [
                            "verificationToken": "zk2fav2.verif_after_sms_777",
                        ] as [String: Any],
                    ]
                case "/api/register/verifyAccount":
                    resp = [
                        "error_code": 0,
                        "data": [
                            "user_id": 100_000_101,
                            "token": "tok_sms_ok",
                            "session_key": "p-5E.100000101.a1.SMS_GW_SK",
                            "CrypKey": Data(repeating: 0x66, count: 16).base64EncodedString(),
                            "send2me_id": 204_278_670,
                        ] as [String: Any],
                    ]
                default:
                    resp = ["error_code": 0, "data": [:] as [String: Any]]
                }
                return (200, try JSONSerialization.data(withJSONObject: resp))
            }
        }

        let transport = MockSmsGatewayTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let reqResult = try await client.requestVerificationCode(phone: "0901234567", method: .callOrSms)

        XCTAssertEqual(transport.getActivationCallCount, 1, "Must not retry on 2012 SMS gateway challenge")
        XCTAssertTrue(reqResult.sent)
        XCTAssertEqual(reqResult.errorCode, 2012)
        XCTAssertTrue(reqResult.challenge.requiresSmsGateway)
        XCTAssertEqual(reqResult.challenge.smsGateway, "7539")
        XCTAssertEqual(reqResult.challenge.smsContentHint, "ZALO")
        XCTAssertEqual(reqResult.challenge.smsComposeURL?.absoluteString, "sms:7539&body=ZALO")
        XCTAssertEqual(reqResult.challenge.activationToken, "zk2fav2.submit_otp_tok_777")
        XCTAssertNil(reqResult.challenge.sessionToken, "Consumed request token must be cleared")

        let outcome = try await client.submitVerificationCode(
            phone: "0901234567",
            password: "test_password",
            code: "654321",
            challenge: reqResult.challenge
        )
        guard case let .success(res) = outcome else {
            return XCTFail("Expected .success after SMS gateway OTP verification, got \(outcome)")
        }
        XCTAssertEqual(res.sessionKey, "p-5E.100000101.a1.SMS_GW_SK")
    }

    private final class ScriptedLoginTransport: ZolaNetworkTransport, @unchecked Sendable {
        var paths: [String] = []
        var activationResponses: [[String: Any]] = []
        var submitResponse: [String: Any] = ["error_code": 2003, "error_message": "Invalid token"]

        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            let path = request.url?.path ?? ""
            paths.append(path)
            let resp: [String: Any]
            switch path {
            case "/api/register/verifyClientInfo":
                resp = ["error_code": 0, "data": ["sessionToken": "zk000.request_token"] as [String: Any]]
            case "/api/register/getActivationCode":
                resp = activationResponses.isEmpty ? ["error_code": 0, "data": [:] as [String: Any]] : activationResponses.removeFirst()
            case "/api/register/activeAccountByActivationCode":
                resp = submitResponse
            default:
                resp = ["error_code": 2003, "error_message": "Invalid token"]
            }
            return (200, try JSONSerialization.data(withJSONObject: resp))
        }
    }

    func testRequestCodeWithoutActivationTokenIsNotSentAndNeverReusesRequestToken() async throws {
        let transport = ScriptedLoginTransport()
        transport.activationResponses = [["error_code": 0, "error_message": "Successful.", "data": [:] as [String: Any]]]
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        let result = try await client.requestVerificationCode(phone: "0901234567", method: .recentDevice)

        XCTAssertFalse(result.sent)
        XCTAssertNil(result.challenge.activationToken, "The request session_token is not an OTP submit token")
    }

    func testFailedResendKeepsPreviousActivationToken() async throws {
        let transport = ScriptedLoginTransport()
        transport.activationResponses = [["error_code": 2006, "error_message": "Không tạo được mã"]]
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let prior = ZolaLoginChallenge(fields: ["otp"], activationToken: "zk000.previous_submit_token", activationType: 6, method: .recentDevice, isForgotPassword: true)

        let result = try await client.requestVerificationCode(phone: "0901234567", method: .recentDevice, existingChallenge: prior)

        XCTAssertFalse(result.sent)
        XCTAssertEqual(result.challenge.activationToken, "zk000.previous_submit_token")
    }

    func testSubmitStopsAtExpiredActivationTokenWithoutFollowUpLoginCalls() async throws {
        let transport = ScriptedLoginTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let challenge = ZolaLoginChallenge(
            fields: ["otp"],
            verificationToken: "zk000.verification_from_password_step",
            activationToken: "zk000.expired_submit_token",
            activationType: 6,
            method: .recentDevice,
            isForgotPassword: true
        )

        let outcome = try await client.submitVerificationCode(phone: "0901234567", password: "secret", code: "878931", challenge: challenge)

        guard case let .rejected(ec, message, _) = outcome else {
            return XCTFail("Expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(ec, 2003)
        XCTAssertEqual(message, ZolaLoginClient.expiredVerificationCodeMessage)
        XCTAssertEqual(transport.paths, ["/api/register/activeAccountByActivationCode"])
    }

    func testSubmitReportsWrongCodeInsteadOfFollowUpInvalidToken() async throws {
        let transport = ScriptedLoginTransport()
        transport.submitResponse = ["error_code": 2002, "error_message": "Invalid code"]
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let challenge = ZolaLoginChallenge(
            fields: ["otp"],
            verificationToken: "zk000.verification_from_password_step",
            activationToken: "zk000.valid_submit_token",
            activationType: 1,
            method: .callOrSms,
            isForgotPassword: true
        )

        let outcome = try await client.submitVerificationCode(phone: "0901234567", password: "secret", code: "000000", challenge: challenge)

        guard case let .rejected(ec, message, _) = outcome else {
            return XCTFail("Expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(ec, 2002)
        XCTAssertEqual(message, ZolaLoginClient.wrongVerificationCodeMessage)
        XCTAssertEqual(transport.paths, ["/api/register/activeAccountByActivationCode"])
    }

    func testGroupPhotoAttachmentNormalizesBrokenZpgJpgUrlAndIntegerSmsGateway() async throws {
        let rawAttach: [String: Any] = [
            "href": "https://f64-zpg-r.zdn.vn/jpg/1000000000000000001/0123456789abcdef0123.jpg",
            "thumb": "https://f64-zpg-r.zdn.vn/jpg/1000000000000000001/0123456789abcdef0123.jpg",
            "width": 3023,
            "height": 4032,
        ]
        let att = ZolaAttachment.fromRaw(msgType: "chat.photo", attach: rawAttach)
        XCTAssertEqual(att.url, "https://f64-zpg-r.zdn.vn/1000000000000000001/0123456789abcdef0123.jpg")
        XCTAssertEqual(att.thumbUrl, "https://f64-zpg-r.zdn.vn/1000000000000000001/0123456789abcdef0123.jpg")

        let challenge = ZolaLoginChallenge(
            fields: ["otp"],
            smsGateway: "8066",
            smsContentHint: "Hệ thống đang xử lý, không thể gửi mã xác thực tự động vào thời điểm này.\nCách 1: Gọi đến tổng đài 1900 1223\nCách 2: Soạn ZALO gửi 8066",
            smsFormat: "ZALO"
        )
        XCTAssertTrue(challenge.requiresSmsGateway)
        XCTAssertEqual(challenge.smsKeyword, "ZALO")
        XCTAssertEqual(challenge.smsComposeURL?.absoluteString, "sms:8066&body=ZALO")
    }

    func testSessionKeyMaterialRoundTripsBothStoresAndLegacyPayloadDecodes() throws {
        let sess = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "p-5E.100000101.a1.KS_STORE_TEST",
            cryptKey: dummyCk,
            socketServers: [
                ZolaSocketServer(hostName: "49.213.95.89", hostPort: 443, key: 5, pubKey: "srv_pub_b64", tagName: "chat", aesKey: "aesk"),
                ZolaSocketServer(hostName: "2001:df0:13:1::105", hostPort: 443, key: 5, pubKey: "srv_pub_b64_v6"),
            ],
            keySetId: "aB3d9K2mPq8xYz1w",
            keySetValue: "UNIT_KEYSET_VALUE_SECRET",
            aesPublicId: 9_876_543_210,
            aesPrivateId: 1_234_567_890
        )
        XCTAssertFalse(sess.description.contains("UNIT_KEYSET_VALUE_SECRET"))

        // 1. Codable round-trip (the exact payload ZolaKeychainSessionStore persists)
        let encoded = try JSONEncoder().encode(sess)
        XCTAssertEqual(try JSONDecoder().decode(ZolaSession.self, from: encoded), sess)

        // 2. Real Keychain store round-trip
        let store = ZolaKeychainSessionStore(service: "com.zolakit.session.test.\(UUID().uuidString)")
        defer { try? store.delete(account: "100000101") }
        try store.save(sess, account: "100000101")
        XCTAssertEqual(try store.load(account: "100000101"), sess)

        // 3. File interop store parses 16-char ASCII `key_set_id` + `socket_servers`
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("session-100000101.local.json")
        try ZolaFileSessionStore.writeData0600(try JSONSerialization.data(withJSONObject: [
            "uid": 100_000_101,
            "session_key": "p-5E.100000101.a1.KS_FILE_TEST",
            "crypt_key_b64": dummyCk.base64EncodedString(),
            "key_set_id": "aB3d9K2mPq8xYz1w",
            "key_set_value": "UNIT_KEYSET_VALUE_SECRET",
            "aes_public_id": 9_876_543_210,
            "aes_private_id": 1_234_567_890,
            "socket_servers": [
                ["hostName": "49.213.95.89", "hostPort": 443, "key": "5", "pubKey": "srv_pub_b64", "tagName": "chat"],
                ["hostName": "2001:df0:13:1::105", "hostPort": "443", "key": 5, "pubKey": "srv_pub_b64_v6"],
            ],
        ] as [String: Any]), to: fileURL)
        let fileLoaded = try ZolaFileSessionStore.loadInteropJSON(from: fileURL)
        XCTAssertEqual(fileLoaded.keySetId, "aB3d9K2mPq8xYz1w")
        XCTAssertEqual(fileLoaded.keySetValue, "UNIT_KEYSET_VALUE_SECRET")
        XCTAssertEqual(fileLoaded.aesPublicId, 9_876_543_210)
        XCTAssertEqual(fileLoaded.aesPrivateId, 1_234_567_890)
        XCTAssertEqual(fileLoaded.socketServers?.count, 2)
        XCTAssertEqual(fileLoaded.socketServers?.first?.hostPort, 443)
        XCTAssertEqual(fileLoaded.socketServers?.first?.key, 5)
        XCTAssertEqual(fileLoaded.socketServers?.last?.hostName, "2001:df0:13:1::105")

        // 4. A session persisted before the new fields existed still decodes (all nil)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "uid": 100_000_101,
            "sessionKey": "p-5E.100000101.a1.LEGACY",
            "cryptKey": dummyCk.base64EncodedString(),
            "zcid": "1_LEGACY",
            "zcidIsNative": true,
            "apiKey": "k", "apiSecret": "s",
            "femcHost": ZolaConstants.defaultFemcHost,
            "mfetchHost": ZolaConstants.defaultMfetchHost,
            "groupApiHost": ZolaConstants.defaultGroupApiHost,
            "tapiHost": ZolaConstants.defaultTapiHost,
            "friendHost": ZolaConstants.defaultFriendHost,
            "failoverUrl": ZolaConstants.defaultFailoverHost,
            "failoverUrlE2ee": ZolaConstants.defaultFailoverUrlE2ee,
            "sendToMeId": 204_278_670,
            "groupIds": [Int64](),
            "sessionBoxTokens": [String: Any](),
        ] as [String: Any])
        let legacySession = try JSONDecoder().decode(ZolaSession.self, from: legacy)
        XCTAssertNil(legacySession.keySetId)
        XCTAssertNil(legacySession.keySetValue)
        XCTAssertNil(legacySession.socketServers)
        XCTAssertNil(legacySession.aesPublicId)
        XCTAssertNil(legacySession.aesPrivateId)

        // 5. Legacy integer `keySetId: 77` in persisted Codable JSON upgrades cleanly to `"77"`
        var legacyIntObj = (try JSONSerialization.jsonObject(with: legacy) as? [String: Any]) ?? [:]
        legacyIntObj["keySetId"] = 77
        let legacyIntData = try JSONSerialization.data(withJSONObject: legacyIntObj)
        let upgradedIntSession = try JSONDecoder().decode(ZolaSession.self, from: legacyIntData)
        XCTAssertEqual(upgradedIntSession.keySetId, "77")
    }

    func testLoginResponseExtractsKeySetAndSocketServers() async throws {
        let client = ZolaLoginClient(identity: .defaultProfile)
        let obj: [String: Any] = [
            "error_code": 0,
            "error_message": "Successful.",
            "data": [
                "user_id": 100_000_101,
                "token": "tok_ks_test",
                "session_key": "p-5E.100000101.a1.KS_LOGIN_TEST",
                "CrypKey": dummyCk.base64EncodedString(),
                "keySet": [
                    "keySetId": "aB3d9K2mPq8xYz1w",
                    "keySetValue": "UNIT_KEYSET_VALUE_SECRET",
                    "aesPublicId": 9_876_543_210,
                    "aesPrivateId": 1_234_567_890,
                ] as [String: Any],
                "socketServers": [
                    ["hostName": "49.213.95.89", "hostPort": 443, "key": "5", "pubKey": "srv_pub_b64", "tagName": "chat"],
                    ["hostName": "2001:df0:13:1::105", "hostPort": "443", "key": 5, "pubKey": "srv_pub_b64_v6"],
                    ["hostName": "", "hostPort": 443],
                ],
            ] as [String: Any],
        ]
        let outcome = await client.parseLoginResponse(obj: obj, text: "{}", sessionToken: nil)
        guard case let .success(res) = outcome else {
            return XCTFail("Expected login success")
        }
        XCTAssertEqual(res.keySetId, "aB3d9K2mPq8xYz1w")
        XCTAssertEqual(res.keySetValue, "UNIT_KEYSET_VALUE_SECRET")
        XCTAssertEqual(res.aesPublicId, 9_876_543_210)
        XCTAssertEqual(res.aesPrivateId, 1_234_567_890)
        XCTAssertEqual(res.socketServers.count, 2)
        XCTAssertEqual(res.socketServers[0].hostName, "49.213.95.89")
        XCTAssertEqual(res.socketServers[0].key, 5)
        XCTAssertEqual(res.socketServers[1].hostName, "2001:df0:13:1::105")

        let session = try await client.makeSession(from: res)
        XCTAssertEqual(session.keySetId, "aB3d9K2mPq8xYz1w")
        XCTAssertEqual(session.keySetValue, "UNIT_KEYSET_VALUE_SECRET")
        XCTAssertEqual(session.aesPublicId, 9_876_543_210)
        XCTAssertEqual(session.aesPrivateId, 1_234_567_890)
        XCTAssertEqual(session.socketServers?.count, 2)
    }

    func testFetchKeySetUpdatesSessionAndRetriesAtMostOnce() async throws {
        let validKeyB64 = Data(repeating: 0x5A, count: 32).base64EncodedString()
        let sess = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "p-5E.100000103.a1.KS_FETCH_TEST",
            cryptKey: dummyCk,
            accessToken: "zk_unit_access_token_secret",
            loginPhone: "0909123456"
        )
        let mock = MockZolaTransport(session: sess)
        mock.mockKeySetValue = validKeyB64
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        mock.keySetFailFirst = true
        let ks = try await client.fetchKeySet()
        XCTAssertEqual(ks.keySetId, "aB3d9K2mPq8xYz1w")
        XCTAssertEqual(ks.keySetValue, validKeyB64)
        XCTAssertEqual(ks.aesPublicId, 9_876_543_210)
        XCTAssertEqual(ks.aesPrivateId, 1_234_567_890)
        XCTAssertEqual(mock.keySetAttempts, 2)

        let updated = await client.session
        XCTAssertEqual(updated.keySetId, "aB3d9K2mPq8xYz1w")
        XCTAssertEqual(updated.keySetValue, validKeyB64)
        XCTAssertEqual(updated.aesPublicId, 9_876_543_210)
        XCTAssertEqual(updated.aesPrivateId, 1_234_567_890)

        let lastReq = try XCTUnwrap(mock.requests.last)
        XCTAssertEqual(lastReq.httpMethod, "POST")
        XCTAssertTrue((lastReq.url?.absoluteString ?? "").contains("/api/helper/getKeySet"))
        let bodyText = String(data: try XCTUnwrap(lastReq.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyText.contains("encryptParams=1"))
        var formPairs: [String: String] = [:]
        for kv in bodyText.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                formPairs[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            }
        }
        let inner = try ZolaCrypto.decryptZCIDParams(try XCTUnwrap(formPairs["data"]), zcid: sess.zcid)
        XCTAssertEqual(inner["phone_num"] as? String, "+84909123456")
        XCTAssertEqual(
            inner["token"] as? String,
            try ZolaLoginClient.encryptPhoneBoundValue("zk_unit_access_token_secret", phone: "+84909123456")
        )
        XCTAssertEqual(inner["protover"] as? String, "1")
        let ckeysetB64 = try XCTUnwrap(inner["ckeyset"] as? String)
        XCTAssertEqual(Data(base64Encoded: ckeysetB64)?.count, 8)
    }
}

// MARK: - Phone lookup & friend requests (api/friend/*)

private final class FriendServiceMockTransport: ZolaNetworkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let zcid: String
    /// path → (outer error_code, plaintext payload to encrypt, error_message)
    var responses: [String: (code: Int, payload: [String: Any]?, message: String)] = [:]
    var rawHandlers: [String: (URLRequest) -> (Int, Data)] = [:]
    private(set) var innerParamsByPath: [String: [String: Any]] = [:]
    private(set) var requests: [URLRequest] = []

    init(zcid: String) { self.zcid = zcid }

    func execute(_ request: URLRequest) async throws -> (Int, Data) {
        lock.withLock { requests.append(request) }
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ZolaError.transport("Bad mock URL")
        }
        var pairs: [String: String] = [:]
        for item in comps.queryItems ?? [] { pairs[item.name] = item.value ?? "" }
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
            for kv in text.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    pairs[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                }
            }
        }
        let path = comps.path
        let inner = pairs["data"].flatMap { try? ZolaCrypto.decryptZCIDParams($0, zcid: zcid) } ?? [:]
        if let rawHandler = lock.withLock({ () -> ((URLRequest) -> (Int, Data))? in
            innerParamsByPath[path] = inner
            return rawHandlers[path]
        }) {
            return rawHandler(request)
        }
        let response = lock.withLock { () -> (code: Int, payload: [String: Any]?, message: String)? in
            innerParamsByPath[path] = inner
            return responses[path]
        }
        guard let response else {
            return (200, try JSONSerialization.data(withJSONObject: ["error_code": -1, "error_message": "unmocked \(path)"]))
        }
        var env: [String: Any] = ["error_code": response.code, "error_message": response.message]
        if let payload = response.payload {
            env["data"] = try ZolaCrypto.encryptZCIDParams(payload, zcid: zcid)
        }
        return (200, try JSONSerialization.data(withJSONObject: env))
    }

    func inner(_ path: String) -> [String: Any] {
        lock.withLock { innerParamsByPath[path] ?? [:] }
    }
}

final class ZolaFriendServiceTests: XCTestCase {
    private let ownUid: Int64 = 100_000_001

    private func makeClient(native: Bool = true) throws -> (ZolaClient, FriendServiceMockTransport) {
        let zcid = ZolaDeviceIdentity.defaultProfile.zcid
        let sess = try ZolaSession(
            uid: ownUid,
            sessionKey: "test_session_key_not_sent",
            cryptKey: Data("0123456789abcdef".utf8),
            zcid: native ? zcid : "",
            zcidIsNative: native
        )
        let mock = FriendServiceMockTransport(zcid: sess.zcid)
        return (ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0), mock)
    }

    func testInternationalPhoneNormalization() {
        XCTAssertEqual(ZolaClient.internationalPhone("0901234567"), "84901234567")
        XCTAssertEqual(ZolaClient.internationalPhone("901234567"), "84901234567")
        XCTAssertEqual(ZolaClient.internationalPhone("84901234567"), "84901234567")
        XCTAssertEqual(ZolaClient.internationalPhone("+84 901 234 567"), "84901234567")
        XCTAssertEqual(ZolaClient.internationalPhone("090.123.4567"), "84901234567")
        // 9-digit subscriber number that itself starts with 84 (0842…) must still get the country code
        XCTAssertEqual(ZolaClient.internationalPhone("842123456"), "84842123456")
        XCTAssertEqual(ZolaClient.internationalPhone("5551234567", countryCode: "1"), "15551234567")
    }

    func testFindUserByPhoneReturnsOnlyServerConfirmedProfile() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/profile/get"] = (0, [
            "uid": "555000111",
            "display_name": "Khách Thật",
            "zalo_name": "khachthat",
            "avatar": "https://s120-ava-talk.zadn.vn/a/b.jpg",
        ], "")

        let result = try await client.findUserByPhone("0901234567")
        guard case let .found(user) = result else { return XCTFail("Expected .found, got \(result)") }
        XCTAssertEqual(user.uid, 555_000_111)
        XCTAssertEqual(user.displayName, "Khách Thật")
        XCTAssertEqual(user.zaloName, "khachthat")
        XCTAssertEqual(user.phone, "0901234567")

        let inner = mock.inner("/api/friend/profile/get")
        XCTAssertEqual(inner["phone"] as? String, "84901234567")
        XCTAssertEqual(inner["reqSrc"] as? Int, 40)
        XCTAssertEqual(inner["imei"] as? String, ZolaConstants.defaultIDFA)
        XCTAssertEqual(inner["avatar_size"] as? Int, 240)
    }

    func testFindUserByPhoneNotFoundAndRefusals() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/profile/get"] = (216, nil, "Không tìm thấy")
        let notFound = try await client.findUserByPhone("0911222333")
        XCTAssertEqual(notFound, .notFound)

        mock.responses["/api/friend/profile/get"] = (-115, nil, "Param is invalid")
        let refused = try await client.findUserByPhone("0911222333")
        XCTAssertEqual(refused, .failed(code: -115, message: "Param is invalid"))
    }

    func testFriendServiceExpiryCodeIsReportedWithoutLoggingTheNickOut() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/profile/get"] = (102, nil, "Session expired")
        let result = try await client.findUserByPhone("0911222333")
        XCTAssertEqual(result, .failed(code: 102, message: "Session expired"))
        // The session is not latched: the next lookup still goes out.
        mock.responses["/api/friend/profile/get"] = (216, nil, "")
        let next = try await client.findUserByPhone("0911222333")
        XCTAssertEqual(next, .notFound)
    }

    func testFriendServiceRefusesSyntheticZcidSession() async throws {
        let (client, _) = try makeClient(native: false)
        do {
            _ = try await client.findUserByPhone("0901234567")
            XCTFail("Expected safetyGate")
        } catch ZolaError.safetyGate {
        }
        do {
            _ = try await client.sendFriendRequest(toUid: 555_000_111)
            XCTFail("Expected safetyGate: a write must not silently report success")
        } catch ZolaError.safetyGate {
        }
    }

    func testFetchFriendRequestsParsesReceivedSuggestionsAndSent() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/recommendsv2/list"] = (0, [
            "recommItems": [
                ["recommItemType": 1, "dataInfo": [
                    "userId": "700000001", "displayName": "Người Mời", "avatar": "https://a/1.jpg",
                    "recommType": 2, "recommTime": 1_761_700_000_000,
                    "recommInfo": ["message": "Chào bạn, kết bạn nhé"],
                ]],
                ["recommItemType": 1, "dataInfo": [
                    "userId": "700000002", "displayName": "Gợi Ý", "avatar": "https://a/2.jpg",
                    "recommType": 1,
                ]],
            ],
        ], "")
        mock.responses["/api/friend/requested/list"] = (0, [
            "700000003": [
                "userId": "700000003", "displayName": "Đã Gửi", "avatar": "https://a/3.jpg",
                "fReqInfo": ["message": "Mình là khách cũ", "src": 30, "time": 1_761_600_000],
            ],
        ], "")

        let list = try await client.fetchFriendRequests()
        let byUid = Dictionary(uniqueKeysWithValues: list.map { ($0.uid, $0) })
        XCTAssertEqual(byUid[700_000_001]?.direction, .incoming)
        XCTAssertEqual(byUid[700_000_001]?.message, "Chào bạn, kết bạn nhé")
        XCTAssertEqual(byUid[700_000_002]?.direction, .suggestion)
        XCTAssertEqual(byUid[700_000_003]?.direction, .outgoing)
        XCTAssertEqual(byUid[700_000_003]?.message, "Mình là khách cũ")
        XCTAssertEqual(byUid[700_000_003]?.timestampMs, 1_761_600_000_000)
        XCTAssertEqual(list.count, 3)
    }

    func testFetchFriendRequestsTreatsCode112AsNoSentRequestsAndThrowsOnRefusal() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/recommendsv2/list"] = (0, ["recommItems": []], "")
        mock.responses["/api/friend/requested/list"] = (112, nil, "No request")
        let empty = try await client.fetchFriendRequests()
        XCTAssertTrue(empty.isEmpty)

        mock.responses["/api/friend/recommendsv2/list"] = (-115, nil, "Param is invalid")
        do {
            _ = try await client.fetchFriendRequests()
            XCTFail("Expected server error")
        } catch let ZolaError.server(code, _) {
            XCTAssertEqual(code, -115)
        }
    }

    func testFriendWriteActionsSurfaceZaloAnswers() async throws {
        let (client, mock) = try makeClient()
        mock.responses["/api/friend/sendreq"] = (222, nil, "")
        let outcome = try await client.sendFriendRequest(toUid: 700_000_001, message: "Chào")
        XCTAssertEqual(outcome, .becameFriends)
        let sendInner = mock.inner("/api/friend/sendreq")
        XCTAssertEqual(sendInner["toid"] as? String, "700000001")
        XCTAssertEqual(sendInner["reqsrc"] as? Int, 30)

        mock.responses["/api/friend/sendreq"] = (0, nil, "")
        let sentOutcome = try await client.sendFriendRequest(toUid: 700_000_004)
        XCTAssertEqual(sentOutcome, .sent)

        mock.responses["/api/friend/accept"] = (215, nil, "Bạn đã bị chặn")
        do {
            _ = try await client.acceptFriendRequest(fromUid: 700_000_001)
            XCTFail("Expected server error")
        } catch let ZolaError.server(code, message) {
            XCTAssertEqual(code, 215)
            XCTAssertEqual(message, "Bạn đã bị chặn")
        }

        // dry-run never touches the network
        let dry = try await client.undoFriendRequest(toUid: 700_000_009, dryRun: true)
        XCTAssertTrue(dry)
        XCTAssertTrue(mock.inner("/api/friend/undo").isEmpty)
    }

    func testZCAJSApiSurfaceParityAndDryRunSafety() async throws {
        let (client, mock) = try makeClient()
        let ownId = await client.getOwnId()
        XCTAssertEqual(ownId, "100000001")

        // 1. findUser (returns ZolaUser? or nil on 216)
        mock.responses["/api/friend/profile/get"] = (0, [
            "uid": "888000111",
            "display_name": "ZCA User",
            "zalo_name": "zcauser",
        ], "")
        let found = try await client.findUser("0901234567")
        XCTAssertEqual(found?.uid, 888_000_111)
        XCTAssertEqual(found?.displayName, "ZCA User")

        mock.responses["/api/friend/profile/get"] = (216, nil, "Not found")
        let nilUser = try await client.findUser("0999888777")
        XCTAssertNil(nilUser)

        // 2. removeFriend / blockUser / unblockUser / changeFriendAlias
        mock.responses["/api/friend/remove"] = (0, [:], "")
        mock.responses["/api/friend/block"] = (0, [:], "")
        mock.responses["/api/friend/unblock"] = (0, [:], "")
        mock.responses["/api/alias/update"] = (0, [:], "")
        let removed = try await client.removeFriend(888_000_111)
        XCTAssertTrue(removed)
        XCTAssertEqual(mock.inner("/api/friend/remove")["fid"] as? String, "888000111")
        let blocked = try await client.blockUser(888_000_111)
        XCTAssertTrue(blocked)
        XCTAssertEqual(mock.inner("/api/friend/block")["fid"] as? String, "888000111")
        let unblocked = try await client.unblockUser(888_000_111)
        XCTAssertTrue(unblocked)
        let aliased = try await client.changeFriendAlias("Khách VIP", friendId: 888_000_111)
        XCTAssertTrue(aliased)
        XCTAssertEqual(mock.inner("/api/alias/update")["alias"] as? String, "Khách VIP")

        // 3. Group management (createGroup, addUserToGroup, removeUserFromGroup, changeGroupName, enableGroupLink)
        mock.responses["/api/group/create/v2"] = (0, ["groupId": "900100200"], "")
        mock.responses["/api/group/invite/v2"] = (0, ["errorMembers": []], "")
        mock.responses["/api/group/kickout"] = (0, ["errorMembers": []], "")
        mock.responses["/api/group/updateinfo"] = (0, [:], "")
        mock.responses["/api/group/link/new"] = (0, ["link": "https://zalo.me/g/testlink"], "")
        let created = try await client.createGroup(name: "Nhóm Test", members: [888_000_111, 888_000_222])
        XCTAssertEqual(created["groupId"] as? String, "900100200")
        XCTAssertEqual(mock.inner("/api/group/create/v2")["gname"] as? String, "Nhóm Test")
        _ = try await client.addUserToGroup(groupId: 900_100_200, memberIds: [888_000_333])
        _ = try await client.removeUserFromGroup(groupId: 900_100_200, memberIds: [888_000_333])
        let renamed = try await client.changeGroupName("Nhóm Mới", groupId: 900_100_200)
        XCTAssertTrue(renamed)
        let link = try await client.enableGroupLink(groupId: 900_100_200)
        XCTAssertEqual(link, "https://zalo.me/g/testlink")

        // 4. sendMessage (ExpressibleByStringLiteral) & dry-run actions
        let receipt = try await client.sendMessage("Xin chào từ ZCA-JS API!", threadId: 888_000_111, type: .user, dryRun: true)
        XCTAssertTrue(receipt.ok)
        XCTAssertTrue(receipt.dryRun)
        XCTAssertEqual(receipt.desId, 888_000_111)

        mock.responses["/api/message/typing"] = (0, [:], "")
        let typed = try await client.sendTypingEvent(threadId: 888_000_111, type: .user)
        XCTAssertTrue(typed)
        XCTAssertEqual(mock.inner("/api/message/typing")["toid"] as? String, "888000111")

        // 5. Zalo Labels (fetchLabels, updateLabels) & Mute List (fetchMuteList)
        let labelJsonString = """
        [{"id":1,"text":"Nhóm khách sỉ","textKey":"","conversations":["g_900100200"],"color":"#F31BC8","offset":0,"emoji":"","createTime":1762401479893}]
        """
        mock.responses["/api/convlabel/get"] = (0, [
            "labelData": labelJsonString,
            "version": 15,
            "lastUpdateTime": 1_762_401_479_893,
        ], "")
        let labelsResp = try await client.fetchLabels()
        XCTAssertEqual(labelsResp.version, 15)
        XCTAssertEqual(labelsResp.labelData.count, 1)
        XCTAssertEqual(labelsResp.labelData.first?.text, "Nhóm khách sỉ")
        XCTAssertEqual(labelsResp.labelData.first?.color, "#F31BC8")
        XCTAssertEqual(labelsResp.labelData.first?.conversations, ["g_900100200"])

        mock.responses["/api/convlabel/update"] = (0, [
            "labelData": labelJsonString,
            "version": 16,
            "lastUpdateTime": 1_762_401_500_000,
        ], "")
        let updatedLabels = try await client.updateLabels(labelData: labelsResp.labelData, version: 15, dryRun: false)
        XCTAssertEqual(updatedLabels.version, 16)

        mock.responses["/api/social/profile/getmute"] = (0, [
            "chatEntries": [["id": "888000111", "duration": -1]],
            "groupChatEntries": [["id": "900100200", "duration": -1]],
        ], "")
        let muteList = try await client.fetchMuteList()
        XCTAssertTrue(muteList.mutedUserIds.contains(888_000_111))
        XCTAssertTrue(muteList.mutedGroupIds.contains(900_100_200))
    }

    func testSendVoiceUsesNativeFailoverSubCmd31AndRejectsGroupHttp() async throws {
        let (client, mock) = try makeClient()

        // 1-1 voice must ride the native failover binary channel
        // (`failover.zingmp3.vn/api/message`, `cmd = 130`, `innerCmd = 113`, `subCmd = 31`
        // `chat.voice`) — never the retired Zalo Web `api/message/forward` JSON endpoint.
        mock.rawHandlers["/api/message"] = { req in
            guard let unpacked = try? ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data()) else {
                XCTFail("Expected a valid HTTP failover octet frame")
                return (500, Data())
            }
            XCTAssertEqual(unpacked.cmd, 130)
            XCTAssertEqual(unpacked.subCmd, ZolaConstants.subCmdSendVoice)
            let bodyText = String(decoding: unpacked.bodyData, as: UTF8.self)
            XCTAssertTrue(bodyText.contains(#""m4a":"https://files.catbox.moe/sample_voice.m4a""#))
            XCTAssertTrue(bodyText.contains(#""fileSize":12345"#))
            XCTAssertFalse(bodyText.contains("voiceUrl"))
            XCTAssertFalse(bodyText.contains("fileExt"))
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_222)] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }
        let sent = try await client.sendVoice(
            voiceUrl: "https://files.catbox.moe/sample_voice.m4a",
            threadId: 888_000_111,
            fileSize: 12_345
        )
        XCTAssertTrue(sent)
        XCTAssertFalse(
            mock.requests.contains { $0.url?.path == "/api/message/forward" || $0.url?.path == "/api/group/forward" },
            "sendVoice must never touch the retired Web forward endpoints"
        )

        // Group voice rides native `UXChatSocket` cmd207 with iOS properties (201 without properties)
        // (`msgType = 2`, `desType = 4`) — never HTTP failover or the retired Web group endpoints.
        let groupDry = try await client.sendVoiceGroup(
            gid: 900_100_200,
            voiceUrl: "https://files.catbox.moe/group_voice.m4a",
            durationMs: 4_300,
            fileSize: 5_000,
            dryRun: true
        )
        XCTAssertTrue(groupDry.ok)
        XCTAssertTrue(groupDry.dryRun)
        XCTAssertEqual(groupDry.cmd, 207)
        XCTAssertEqual(groupDry.subCmd, ZolaConstants.subCmdSendVoice)
        XCTAssertEqual(groupDry.endpoint, "UXChatSocket:207")
        XCTAssertFalse(groupDry.sent)

        // A live group send without `EncryptProtocolVer2` key material is still blocked by the
        // safety gate — it must never fall back to HTTP group endpoints.
        do {
            _ = try await client.sendVoice(
                voiceUrl: "https://files.catbox.moe/group_voice.m4a",
                threadId: 900_100_200,
                type: .group,
                fileSize: 5_000
            )
            XCTFail("Expected safetyGate — live group voice requires an authenticated UXChatSocket")
        } catch ZolaError.safetyGate {
            // Expected
        }
        XCTAssertFalse(
            mock.requests.contains { $0.url?.path == "/api/group/forward" || $0.url?.path == "/api/message/forward" },
            "group voice must never touch the retired Web forward endpoints"
        )
    }

    func testNativeIOSPhoneDiscoveryAndGetListNoneFriendDecryption() async throws {
        let (client, mock) = try makeClient()
        let uid = ownUid
        // Simulate iOS friend.talk.zing.vn returning HTTP 404 HTML for web friend endpoints
        mock.rawHandlers["/api/friend/profile/get"] = { _ in
            (404, Data("<html>404 Not Found</html>".utf8))
        }
        mock.rawHandlers["/api/friend/recommendsv2/list"] = { _ in
            (404, Data("<html>404 Not Found</html>".utf8))
        }
        mock.rawHandlers["/api/friend/requested/list"] = { _ in
            (404, Data("<html>404 Not Found</html>".utf8))
        }
        // Native iOS Mode 1 phone discovery on tapi.api.zaloapp.com
        mock.rawHandlers["/api/contact/discoverContact"] = { _ in
            let body: [String: Any] = [
                "error_code": 0,
                "data": [
                    "list": [
                        ["phone": "84901234567", "uid": 555_666_777]
                    ]
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
        mock.rawHandlers["/api/contact/getProfile"] = { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("555666777") {
                let body: [String: Any] = [
                    "error_code": 0,
                    "data": [
                        "uid": 555_666_777,
                        "dpn": "Nguyễn Văn An",
                        "zalo_name": "zolakit",
                        "avt": "https://s120.ava.talk.zdn.vn/a.jpg"
                    ]
                ]
                return (200, try! JSONSerialization.data(withJSONObject: body))
            }
            let body: [String: Any] = [
                "error_code": 0,
                "data": [
                    "uid": 777_888_999,
                    "dpn": "Khách Lạ Tương Tác",
                    "avt": "https://s120.ava.talk.zdn.vn/b.jpg"
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }
        // Native getpage.api.zaloapp.com/api/page/getListNoneFriend? with XOR-encrypted list_none_friends
        mock.rawHandlers["/api/page/getListNoneFriend"] = { _ in
            let plainJSON = try! JSONSerialization.data(withJSONObject: [
                ["uid": 777_888_999, "dpn": "Khách Lạ Tương Tác", "src": "Nhắn tin người lạ"]
            ])
            let xored = ZolaCrypto.encryptHTTPData(
                plainJSON,
                srcId: Int32(truncatingIfNeeded: uid),
                frameSize: UInt32(truncatingIfNeeded: plainJSON.count),
                keyData: ZolaConstants.noneFriendKeyData
            )
            let body: [String: Any] = [
                "error_code": 0,
                "data": [
                    "list_none_friends": xored.base64EncodedString()
                ]
            ]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        }

        let lookup = try await client.findUserByPhone("0901234567")
        guard case let .found(user) = lookup else {
            return XCTFail("Expected .found from native iOS contact discovery, got \(lookup)")
        }
        XCTAssertEqual(user.uid, 555_666_777)
        XCTAssertEqual(user.displayName, "Nguyễn Văn An")
        XCTAssertEqual(user.phone, "0901234567")

        let requests = try await client.fetchFriendRequests()
        XCTAssertTrue(requests.contains(where: { $0.uid == 777_888_999 && $0.accountUid == uid }))
    }

    func testBuild32NativeVoiceStickerMediaAndVoipCallBubbleBinaryPacking() async throws {
        // 1. Sticker binary body (`cmd = 113, subCmd = 36` / `0x24`)
        let sticker = ZolaCrypto.buildStickerMsgBodyData(stickerId: 18082, cateId: 10425, stickerType: 7)
        XCTAssertEqual(sticker.innerCmd, 113)
        XCTAssertEqual(sticker.subCmd, ZolaConstants.subCmdSendSticker)
        XCTAssertEqual(sticker.subCmd, 36)
        XCTAssertEqual(sticker.bodyData.count, 16)
        XCTAssertEqual([UInt8](sticker.bodyData.prefix(3)), [0x24, 0x00, 0x00])
        let stickerSocket = ZolaCrypto.buildStickerMsgBodyData(stickerId: 18082, cateId: 10425, stickerType: 7, includeIOSProps: true)
        XCTAssertGreaterThan(stickerSocket.bodyData.count, 16)
        let sampleQuote = ZolaQuote(
            ownerId: 888_000_111,
            cliMsgId: 1_793_100_000_001,
            globalMsgId: 75_123_456_789,
            text: "Trả lời bằng sticker",
            tsMs: 1_793_100_000_001
        )
        let quotedSticker = ZolaCrypto.buildStickerMsgBodyData(
            stickerId: 18082,
            cateId: 10425,
            stickerType: 7,
            quote: sampleQuote,
            includeIOSProps: true
        )
        XCTAssertEqual(quotedSticker.subCmd, 36)
        XCTAssertEqual([UInt8](quotedSticker.bodyData.prefix(4)), [0x24, 0x00, 0x02, 0x02])

        // 2. Voice message binary body (`cmd = 113, subCmd = 31`)
        let voice = ZolaCrypto.buildMediaMsgBodyData(
            subCmd: ZolaConstants.subCmdSendVoice,
            message: "",
            title: "",
            description: "",
            href: "https://files.catbox.moe/sample_voice.m4a",
            thumb: "",
            action: "chat.voice",
            param: #"{"duration":4000,"fileSize":12345,"m4a":"https://files.catbox.moe/sample_voice.m4a"}"#
        )
        XCTAssertEqual(voice.innerCmd, 113)
        XCTAssertEqual(voice.subCmd, 31)
        XCTAssertTrue(String(decoding: voice.bodyData, as: UTF8.self).contains("chat.voice"))
        XCTAssertTrue(String(decoding: voice.bodyData, as: UTF8.self).contains("https://files.catbox.moe/sample_voice.m4a"))

        // 3. Call bubble binary body (`cmd = 113, subCmd = 38`, `recommened.calltime`)
        let callBubble = ZolaCrypto.buildMediaMsgBodyData(
            subCmd: 38,
            message: #"{"title":"sendBubbleMessage","action":"recommened.calltime"}"#,
            title: "sendBubbleMessage",
            description: "Cuộc gọi thoại",
            href: "",
            thumb: "",
            action: "recommened.calltime",
            param: #"{"duration":0,"calltype":0,"isCaller":0,"errorCode":162,"callId":999111}"#
        )
        XCTAssertEqual(callBubble.innerCmd, 113)
        XCTAssertEqual(callBubble.subCmd, 38)
        XCTAssertTrue(String(decoding: callBubble.bodyData, as: UTF8.self).contains("recommened.calltime"))

        // 4. VoIP Finish Call Log (`cmd = 406, subCmd = 3` for ZRTP protocolVersion = 3)
        let finishLog = ZolaCrypto.packVoipFinishCallLogFrame(
            srcId: 100_000_101,
            partnerId: 100_000_106,
            callId: 999_111,
            status: 162,
            durationSeconds: 0,
            protocolVersion: 3,
            sendType: 1
        )
        let unpackedFinish = try ZolaCrypto.unpackChatElementFrame(finishLog.payload)
        XCTAssertEqual(unpackedFinish.cmd, 406)
        XCTAssertEqual(unpackedFinish.subCmd, 3)
        XCTAssertGreaterThan(unpackedFinish.bodyData.count, 20)
    }

    #if canImport(Network)
    #endif

    // MARK: - Voice upload → forward (native file service)

    private func mp4Box(_ type: String, _ payload: Data) -> Data {
        var b = Data()
        var size = UInt32(payload.count + 8).bigEndian
        b.append(Data(bytes: &size, count: 4))
        b.append(type.data(using: .utf8)!)
        b.append(payload)
        return b
    }

    /// Builds a minimal valid M4A: ftyp + mdat(frames) + moov(trak/mdia/minf/stbl(stsd mp4a+esds, stsz, stsc, stco)).
    private func makeSyntheticM4A(frames: [Data]) -> Data {
        var ftypPayload = Data("M4A ".utf8)
        ftypPayload.append(Data([0, 0, 0, 0]))
        ftypPayload.append(Data("M4A mp42".utf8))
        let ftyp = mp4Box("ftyp", ftypPayload)

        var mdatContent = Data()
        for f in frames { mdatContent.append(f) }
        let mdat = mp4Box("mdat", mdatContent)
        let mdatDataOffset = UInt32(ftyp.count + 8)

        // mp4a sample entry: 6 res + 2 dataref + 8 res + 2 channels + 2 ssize + 2 compr + 2 psize + 4 srate(16.16) = 28B, then esds
        var mp4aPayload = Data(count: 28)
        mp4aPayload[7] = 1 // dataReferenceIndex
        mp4aPayload[17] = 2 // channels = 2 (offset 16)
        mp4aPayload[19] = 16 // sampleSize
        mp4aPayload[24] = 0xBB; mp4aPayload[25] = 0x80 // sampleRate 48000<<16 int part
        // esds: ver/flags(4) + tag0x05 + len + ASC(0x12 0x10 = AAC-LC 44.1k stereo)
        let esdsPayload = Data([0, 0, 0, 0, 0x05, 0x02, 0x12, 0x10])
        let esds = mp4Box("esds", esdsPayload)
        mp4aPayload.append(esds)
        let mp4a = mp4Box("mp4a", mp4aPayload)

        var stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        stsdPayload.append(mp4a)
        let stsd = mp4Box("stsd", stsdPayload)

        // stsz: uniformSize=0, count=N, sizes[]
        var stszPayload = Data([0, 0, 0, 0])
        stszPayload.append(contentsOf: [0, 0, 0, 0])
        var cnt = UInt32(frames.count).bigEndian
        stszPayload.append(Data(bytes: &cnt, count: 4))
        for f in frames {
            var sz = UInt32(f.count).bigEndian
            stszPayload.append(Data(bytes: &sz, count: 4))
        }
        let stsz = mp4Box("stsz", stszPayload)

        // stsc: 1 entry — firstChunk=1, samplesPerChunk=N, descIndex=1
        var stscPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        var e1 = UInt32(1).bigEndian, e2 = UInt32(frames.count).bigEndian, e3 = UInt32(1).bigEndian
        stscPayload.append(Data(bytes: &e1, count: 4))
        stscPayload.append(Data(bytes: &e2, count: 4))
        stscPayload.append(Data(bytes: &e3, count: 4))
        let stsc = mp4Box("stsc", stscPayload)

        // stco: 1 offset → mdat data start
        var stcoPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        var off = mdatDataOffset.bigEndian
        stcoPayload.append(Data(bytes: &off, count: 4))
        let stco = mp4Box("stco", stcoPayload)

        var stblPayload = Data()
        stblPayload.append(stsd); stblPayload.append(stsz); stblPayload.append(stsc); stblPayload.append(stco)
        let stbl = mp4Box("stbl", stblPayload)
        let minf = mp4Box("minf", stbl)
        let mdia = mp4Box("mdia", minf)
        let trak = mp4Box("trak", mdia)
        let moov = mp4Box("moov", trak)

        var file = Data()
        file.append(ftyp); file.append(mdat); file.append(moov)
        return file
    }

    func testZolaADTSDemuxesAACFrames() {
        let frameA = Data([0x21, 0x22, 0x23, 0x24, 0x25])
        let frameB = Data([0x31, 0x32, 0x33])
        let m4a = makeSyntheticM4A(frames: [frameA, frameB])
        guard let aac = ZolaADTS.m4aToAdtsAac(m4a) else {
            XCTFail("m4aToAdtsAac returned nil for a valid synthetic M4A")
            return
        }
        XCTAssertEqual(aac.count, frameA.count + frameB.count + 14)
        XCTAssertEqual(aac[0], 0xFF)
        XCTAssertEqual(aac[1] & 0xF0, 0xF0)
        XCTAssertEqual(Data(aac[7..<12]), frameA)
        XCTAssertEqual(aac[12], 0xFF, "Second frame must also carry an ADTS header")
        XCTAssertEqual(Data(aac[19..<22]), frameB)
    }

    func testZolaADTSPassthroughAndRejectsGarbage() {
        var adts = Data([0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC])
        adts.append(Data(repeating: 0xAB, count: 40))
        XCTAssertEqual(ZolaADTS.m4aToAdtsAac(adts), adts, "ADTS input must pass through unchanged")
        XCTAssertNil(ZolaADTS.m4aToAdtsAac(Data("not an mp4 file at all".utf8)))
        XCTAssertNil(ZolaADTS.m4aToAdtsAac(Data()))
    }

    func testUploadAttachmentUsesNativeHttpUploadConfigAndChunkFallbackWithoutWebWpa() async throws {
        let (client, mock) = try makeClient()

        // 1. dryRun short-circuits locally without any network.
        let dry = try await client.uploadAttachment(
            fileName: "voice-1.aac",
            fileData: Data([0x01, 0x02, 0x03]),
            threadId: 888_000_111,
            dryRun: true
        )
        XCTAssertTrue(dry.isEmpty)
        XCTAssertTrue(mock.requests.isEmpty)

        // 2. Live upload calls `GET https://photo.talk.zing.vn/api/v1/video/upload-config?...` (`uploadFeature=2` for audio)
        //    then `POST` `UploadRawFile` (`Content-Type: raw`, `x-md-hv: f=1; v=<crc32>`).
        mock.rawHandlers["/api/v1/video/upload-config"] = { req in
            let urlStr = req.url?.absoluteString ?? ""
            XCTAssertTrue(urlStr.contains("uploadFeature=2"))
            XCTAssertTrue(urlStr.contains("numOfFiles=0"))
            XCTAssertTrue(urlStr.contains("subCmd=10"))
            XCTAssertTrue(urlStr.contains("httpVer=1"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "session_key"), "test_session_key_not_sent")
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "listUrls": ["https://voice.talk.zing.vn/upload/raw-test"],
                ] as [String: Any],
            ])
            return (200, resp)
        }
        let sampleBytes = Data([0xFF, 0xF1, 0x50, 0x40, 0x01, 0xBF, 0xFC])
        let expectedCrc = ZolaCrypto.crc32(sampleBytes)
        mock.rawHandlers["/upload/raw-test"] = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "raw")
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-md-hv"), "f=1; v=\(expectedCrc)")
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "aac": "https://voice.talk.zing.vn/cdn/v1.aac",
                    "m4a": "https://voice.talk.zing.vn/cdn/v1.m4a",
                    "fileId": "998877",
                ] as [String: Any],
            ])
            return (200, resp)
        }

        let uploaded = try await client.uploadAttachment(
            fileName: "voice-1.aac",
            fileData: sampleBytes,
            threadId: 888_000_111,
            dryRun: false
        )
        XCTAssertEqual(uploaded["fileUrl"] as? String, "https://voice.talk.zing.vn/cdn/v1.aac")
        XCTAssertEqual(uploaded["m4aUrl"] as? String, "https://voice.talk.zing.vn/cdn/v1.m4a")

        // 3. When `UploadRawFile` fails (e.g. HTTP 502), `uploadMediaNativeHTTP` automatically falls back
        //    to `UploadChunk` (`multipart/form-data; boundary=ZiNgMeMoBiLe` + ZCID-encrypted query params).
        mock.rawHandlers["/upload/raw-test"] = { req in
            let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            if ct == "raw" {
                return (502, Data())
            }
            XCTAssertTrue(ct.contains("ZiNgMeMoBiLe"))
            XCTAssertTrue(req.url?.query?.contains("encryptParams=1") == true)
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "m4a": "https://voice.talk.zing.vn/cdn/chunk-fallback.m4a",
                ] as [String: Any],
            ])
            return (200, resp)
        }
        let chunkUploaded = try await client.uploadAttachment(
            fileName: "voice-2.aac",
            fileData: sampleBytes,
            threadId: 888_000_111,
            dryRun: false
        )
        XCTAssertEqual(chunkUploaded["fileUrl"] as? String, "https://voice.talk.zing.vn/cdn/chunk-fallback.m4a")

        XCTAssertFalse(
            mock.requests.contains {
                $0.url?.absoluteString.contains("wpa.chat.zalo.me") == true
                    || $0.url?.path == "/api/message/asyncfile/upload"
            },
            "No upload request may ever target a Web wpa / asyncfile endpoint"
        )
        let sess = await client.session
        XCTAssertFalse(sess.isExpired)
    }

    func testSendVoiceFileDemuxesAdtsUploadsNativeHttpAndSendsSubCmd31ChatVoiceWithQuote() async throws {
        let (client, mock) = try makeClient()

        // 1. dryRun demuxes M4A -> ADTS AAC locally and returns true without touching network.
        let dryOk = try await client.sendVoiceFile(
            audioData: makeSyntheticM4A(frames: [Data([0x10, 0x11, 0x12])]),
            threadId: 888_000_111,
            durationMs: 3_000,
            dryRun: true
        )
        XCTAssertTrue(dryOk)
        XCTAssertTrue(mock.requests.isEmpty)

        // 2. Live send uploads ADTS AAC via native HTTP (`uploadFeature=2`) and sends `subCmd = 31` (`action = "chat.voice"`),
        //    preserving millisecond `duration` and optional `TLV tag = 2` reply quote.
        mock.rawHandlers["/api/v1/video/upload-config"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["listUrls": ["https://voice.talk.zing.vn/upload/v-live"]] as [String: Any],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/upload/v-live"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "aac": "https://voice.talk.zing.vn/live/test.aac",
                    "m4a": "https://voice.talk.zing.vn/live/test.m4a",
                ] as [String: Any],
            ])
            return (200, resp)
        }
        var capturedFailoverBody: Data?
        mock.rawHandlers["/api/message"] = { req in
            guard let unpacked = try? ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data()) else {
                XCTFail("Expected HTTP failover frame for voice message")
                return (500, Data())
            }
            XCTAssertEqual(unpacked.cmd, 130)
            XCTAssertEqual(unpacked.subCmd, ZolaConstants.subCmdSendVoice)
            capturedFailoverBody = unpacked.bodyData
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_333)] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }

        let voiceQuote = ZolaQuote(
            ownerId: 888_000_111,
            cliMsgId: 1_793_100_000_111,
            globalMsgId: 99_887_766,
            msgType: "webchat",
            text: "Gửi ghi âm cho mình nhé",
            tsMs: 1_793_100_000_111,
            senderName: "Nguyễn Đông",
            serverMsgType: 1
        )
        let sent = try await client.uploadAndSendVoiceFile(
            audioData: makeSyntheticM4A(frames: [Data([0x10, 0x11, 0x12])]),
            threadId: 888_000_111,
            durationMs: 3_400,
            quote: voiceQuote,
            dryRun: false,
            clientIdMs: 1_793_100_005_000
        )
        XCTAssertTrue(sent.receipt.ok)
        XCTAssertEqual(sent.receipt.subCmd, 31)
        XCTAssertEqual(sent.receipt.innerSocketCmd, 113)
        XCTAssertEqual(sent.receipt.serverGlobalMsgId, 75_000_000_333)
        XCTAssertEqual(sent.voiceUrl, "https://voice.talk.zing.vn/live/test.aac")
        XCTAssertEqual(sent.m4aUrl, "https://voice.talk.zing.vn/live/test.m4a")
        if let body = capturedFailoverBody {
            let bodyUtf8 = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyUtf8.contains("chat.voice"), "Voice RichMessageContent must set action = 'chat.voice'")
            XCTAssertTrue(bodyUtf8.contains("\"duration\":3400"), "Voice duration must be encoded in milliseconds")
            XCTAssertTrue(bodyUtf8.contains("\"m4a\":\"https://voice.talk.zing.vn/live/test.m4a\""), "Voice param must carry canonical 'm4a' link")
            XCTAssertFalse(bodyUtf8.contains("voiceUrl"), "Voice param must match _getParamForAudio without non-native keys")
            XCTAssertTrue(bodyUtf8.contains("Gửi ghi âm cho mình nhé"), "Attached TLV tag=2 quote must be encoded in body")
        } else {
            XCTFail("Expected captured failover body")
        }
        let sess = await client.session
        XCTAssertFalse(sess.isExpired)
    }

    func testSendVoiceFileRejectsGarbageAudioBeforeAnyNetwork() async throws {
        let (client, mock) = try makeClient()
        do {
            _ = try await client.sendVoiceFile(
                audioData: Data("garbage".utf8),
                threadId: 888_000_111,
                durationMs: 3_000,
                dryRun: true
            )
            XCTFail("sendVoiceFile must reject non-M4A/ADTS audio")
        } catch let ZolaError.invalidArgument(msg) {
            XCTAssertTrue(msg.contains("AAC") || msg.contains("M4A"))
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testNativeReplyStickerWpaBlockAndEmoticonSpriteNormalization() async throws {
        // 1. Web `*-wpa.chat.zalo.me` hosts are hard-blocked (root cause of error 602 `zpw_type`).
        XCTAssertTrue(ZolaClient.isForbiddenWebWpaURL("https://tt-chat1-wpa.chat.zalo.me/api/message/quote"))
        XCTAssertTrue(ZolaClient.isForbiddenWebWpaURL("https://tt-sticker-wpa.chat.zalo.me/api/message/sticker"))
        XCTAssertTrue(ZolaClient.isForbiddenWebWpaURL("https://tt-files-wpa.chat.zalo.me/api/message/asyncfile/upload"))
        XCTAssertTrue(ZolaClient.isForbiddenWebWpaURL("https://quickmessage.chat.zalo.me"))
        XCTAssertTrue(ZolaClient.isForbiddenWebWpaURL("https://auto-rep-msg.chat.zalo.me"))
        XCTAssertFalse(ZolaClient.isForbiddenWebWpaURL("https://failover.zingmp3.vn/api/message"))
        XCTAssertFalse(ZolaClient.isForbiddenWebWpaURL("https://group.api.zaloapp.com"))
        XCTAssertFalse(ZolaClient.isForbiddenWebWpaURL("https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=23285&size=130"))

        // 2. A poisoned service map saved by an older Web build is scrubbed at session load.
        let poisoned = try ZolaSession(
            uid: ownUid,
            sessionKey: "test_session_key_not_sent",
            cryptKey: Data("0123456789abcdef".utf8),
            zcid: ZolaDeviceIdentity.defaultProfile.zcid,
            zcidIsNative: true,
            serviceHosts: [
                "chat": "https://tt-chat1-wpa.chat.zalo.me",
                "group": "https://group.api.zaloapp.com",
            ]
        )
        XCTAssertNil(poisoned.serviceHosts?["chat"])
        XCTAssertEqual(poisoned.serviceHosts?["group"], "https://group.api.zaloapp.com")

        let (client, mock) = try makeClient()
        do {
            _ = try await client.custom(url: "https://tt-chat1-wpa.chat.zalo.me/api/message/quote")
            XCTFail("custom() into a Web wpa host must throw safetyGate")
        } catch ZolaError.safetyGate {
            // Expected — blocked before any packet leaves the device.
        }
        XCTAssertFalse(mock.requests.contains { $0.url?.absoluteString.contains("wpa.chat.zalo.me") == true })

        // 3. Native 1-1 reply (`sendQuotedText`) encodes Zalo iOS Native `TLV tag = 2` (`QuoteData`)
        //    inside `cmd = 130 / innerCmd = 113 / subCmd = 41` with plain reply text (never `"❝ "` hack!),
        //    and `decryptMcryptTextAndPropertiesBody` + `ZolaMessage.fromRawItem` round-trip `ZolaQuote` cleanly.
        let ck = Data("0123456789abcdef".utf8)
        mock.rawHandlers["/api/message"] = { req in
            guard let unpacked = try? ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data()),
                  let dec = try? ZolaCrypto.decryptMcryptTextAndPropertiesBody(
                      unpacked.bodyData,
                      cryptKey: ck
                  )
            else {
                XCTFail("Expected a valid HTTP failover octet frame with TLV tag=2 QuoteData")
                return (500, Data())
            }
            XCTAssertEqual(unpacked.cmd, 130)
            XCTAssertEqual(dec.subCmd, 41)
            XCTAssertEqual(dec.propCount, 3) // tag 2 (quote) + tag 7 (msgExtProp) + tag 5 (refData)
            XCTAssertEqual(dec.text, "Ok")
            XCTAssertFalse(dec.text.contains("❝"), "Native Zalo reply must never prepend '❝ ' onto message text")
            XCTAssertEqual(dec.quote?.ownerId, 888_000_111)
            XCTAssertEqual(dec.quote?.cliMsgId, 1_793_199_111_000)
            XCTAssertEqual(dec.quote?.globalMsgId, 74_918_273_645)
            XCTAssertEqual(dec.quote?.serverMsgType, 1)
            XCTAssertEqual(dec.quote?.text, "Alo")
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_444)] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }
        let replyQuote = ZolaQuote(
            ownerId: 888_000_111,
            cliMsgId: 1_793_199_111_000,
            globalMsgId: 74_918_273_645,
            msgType: "webchat",
            text: "Alo",
            tsMs: 1_793_199_111_000,
            senderName: "Nguyễn Đông",
            serverMsgType: 1
        )
        let replyReceipt = try await client.sendQuotedText(
            text: "Ok",
            threadId: 888_000_111,
            quote: replyQuote,
            dryRun: false
        )
        XCTAssertTrue(replyReceipt.ok)
        XCTAssertEqual(replyReceipt.serverGlobalMsgId, 75_000_000_444)
        XCTAssertEqual(replyReceipt.innerSocketCmd, 113)

        // Verify incoming `mcrypt = 1` message carrying `TLV tag = 2` (media quote `serverMsgType = 31`)
        // AND `TLV tag = 3` (mention) decodes cleanly via `ZolaMessage.fromRawItem`.
        let mediaQuote = ZolaQuote(
            ownerId: Int64(ownUid),
            cliMsgId: 1_793_199_222_000,
            globalMsgId: 74_918_273_999,
            msgType: "chat.voice",
            text: "",
            tsMs: 1_793_199_222_000,
            serverMsgType: 31,
            attachJson: #"{"action":"chat.voice","duration":4000,"href":"https://voice.talk.zing.vn/a.aac"}"#
        )
        var mcryptWire = Data()
        var subCmd41LE = Int16(41).littleEndian
        mcryptWire.append(Data(bytes: &subCmd41LE, count: 2))
        mcryptWire.append(0x02) // propCount = 2: tag 2 (quote) + tag 3 (mention)
        mcryptWire.append(0x02)
        mcryptWire.append(ZolaCrypto.buildQuotePropertyData(mediaQuote))
        mcryptWire.append(0x03)
        // tag 3 mention: u16_le(count=1) + i8(type=0) + i16_le(pos=0) + i16_le(len=3) + i32_le(uid=888000111)
        var mentionCountLE = UInt16(1).littleEndian
        mcryptWire.append(Data(bytes: &mentionCountLE, count: 2))
        mcryptWire.append(0x00) // mentionType = 0
        mcryptWire.append(contentsOf: [0x00, 0x00]) // pos = 0 (Int16LE)
        mcryptWire.append(contentsOf: [0x03, 0x00]) // len = 3 (Int16LE)
        var mentionUidLE = Int32(888_000_111).littleEndian
        mcryptWire.append(Data(bytes: &mentionUidLE, count: 4))

        let replyPlainUtf8 = Data("@Em nghe rõ nhé".utf8)
        let iv16 = Data(repeating: 0x2A, count: 16)
        let cipherReply = try ZolaCrypto.aesCBC(replyPlainUtf8, key: ck, iv: iv16, decrypt: false, pkcs7Padding: true)
        mcryptWire.append(0x01) // mcrypt v1 envelope
        mcryptWire.append(iv16)
        var clenLE = UInt16(cipherReply.count).littleEndian
        mcryptWire.append(Data(bytes: &clenLE, count: 2))
        mcryptWire.append(cipherReply)

        let incomingMcryptMsg = ZolaMessage.fromRawItem(
            [
                "text": [
                    "type": "webchat",
                    "data": [
                        "id": 75_000_000_001,
                        "cliMsgId": 1_793_199_333_000,
                        "fromU": 888_000_111,
                        "fromD": "Nguyễn Đông",
                        "to": ownUid,
                        "ts": 1_793_199_333_000,
                        "mcrypt": 1,
                        "msg": mcryptWire.base64EncodedString(),
                    ] as [String: Any],
                ] as [String: Any],
            ],
            selfUid: ownUid,
            cryptKey: ck
        )
        XCTAssertEqual(incomingMcryptMsg.text, "@Em nghe rõ nhé")
        XCTAssertEqual(incomingMcryptMsg.quote?.globalMsgId, 74_918_273_999)
        XCTAssertEqual(incomingMcryptMsg.quote?.serverMsgType, 31)
        XCTAssertEqual(incomingMcryptMsg.quote?.msgType, "chat.voice")
        XCTAssertTrue(incomingMcryptMsg.quote?.previewSummary.contains("[Tin nhắn thoại]") == true)

        // Legacy `"❝ "` cached message fallback still parses cleanly without breaking existing history
        let echoedLegacy = ZolaMessage.fromRawItem(
            [
                "text": [
                    "type": "webchat",
                    "data": [
                        "id": 4242, "cliMsgId": 777, "fromU": 888_000_111,
                        "to": ownUid, "ts": 1_793_200_000_000,
                        "msg": "❝ Sticker gì to đùng vậy?\nTest reply ZolaK",
                    ],
                ],
            ],
            selfUid: ownUid
        )
        XCTAssertEqual(echoedLegacy.text, "Test reply ZolaK")
        XCTAssertEqual(echoedLegacy.quote?.text, "Sticker gì to đùng vậy?")

        // 4. Native 1-1 sticker resolves its CDN 16-byte little-endian header
        //    (`[magic=20000, cateId, stickerId, stickerType]`) then sends `subCmd = 36`.
        var cdnHeader = Data()
        for value in [UInt32(20_000), UInt32(10_425), UInt32(23_285), UInt32(7)] {
            var le = value.littleEndian
            cdnHeader.append(Data(bytes: &le, count: 4))
        }
        cdnHeader.append(Data("PK\u{03}\u{04}".utf8))
        var staticCdnHeader = Data()
        for value in [UInt32(20_000), UInt32(10_398), UInt32(99_887), UInt32(3)] {
            var le = value.littleEndian
            staticCdnHeader.append(Data(bytes: &le, count: 4))
        }
        mock.rawHandlers["/api/emoticon/sticker"] = { req in
            if req.url?.absoluteString.contains("eid=99887") == true {
                return (200, staticCdnHeader)
            }
            return (200, cdnHeader)
        }
        mock.rawHandlers["/api/message"] = { req in
            guard let unpacked = try? ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data()) else {
                XCTFail("Expected a valid HTTP failover octet frame")
                return (500, Data())
            }
            XCTAssertEqual(unpacked.cmd, 130)
            XCTAssertEqual(unpacked.subCmd, ZolaConstants.subCmdSendSticker)
            XCTAssertEqual(unpacked.subCmd, 36)
            var sidLE = UInt32(23_285).littleEndian
            var cidLE = UInt32(10_425).littleEndian
            XCTAssertNotNil(unpacked.bodyData.range(of: Data(bytes: &sidLE, count: 4)))
            XCTAssertNotNil(unpacked.bodyData.range(of: Data(bytes: &cidLE, count: 4)))
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_555)] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }
        let stickerReceipt = try await client.sendStickerResolvingDetail(
            stickerId: 23_285,
            cateIdHint: 0,
            threadId: 888_000_111
        )
        XCTAssertTrue(stickerReceipt.ok)
        XCTAssertEqual(stickerReceipt.serverGlobalMsgId, 75_000_000_555)

        // Non-animated sticker (`stype = 3`) with known `cateIdHint = 10398` and `typeHint = 0`
        // must still resolve `stickerType = 3` from CDN instead of clobbering it to `7`.
        let staticMeta = await client.resolveStickerMetaNative(stickerId: 99_887, cateIdHint: 10_398, typeHint: 0)
        XCTAssertEqual(staticMeta.cateId, 10_398)
        XCTAssertEqual(staticMeta.stickerType, 3)

        // 5. `chat.photo` items pointing at the emoticon sprite CDN must be re-classified as
        //    `sticker` and normalized onto the single-frame `sticker/webpc` URL.
        let att = ZolaAttachment.fromRaw(
            msgType: "chat.photo",
            attach: [
                "href": "https://zalo-api.zadn.vn/api/emoticon/sprite?eid=23285&size=130",
                "thumb": "https://zalo-api.zadn.vn/api/emoticon/sprite?eid=23285&size=130",
            ]
        )
        XCTAssertEqual(att.kind, "sticker")
        XCTAssertEqual(att.stickerId, 23_285)
        XCTAssertEqual(att.url, "https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=23285&size=130")
    }

    func testFailoverSendRejectsFalsePositiveAckMissingDeliverGlobalMsgId() async throws {
        let (client, mock) = try makeClient()

        // 1. Empty `data: {}` despite `error_code: 0` (exact live failure mode when Zalo drops an inner frame)
        mock.rawHandlers["/api/message"] = { _ in
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0, "error_message": "Successful.", "data": [String: Any](),
            ])
            return (200, ack)
        }
        let droppedVoice = try await client.sendVoice1To1(
            to: 888_000_111,
            voiceUrl: "https://voice.talk.zing.vn/live/dropped.aac",
            durationMs: 2_000,
            fileSize: 4_096,
            dryRun: false,
            clientIdMs: 1_793_200_000_001
        )
        XCTAssertFalse(droppedVoice.ok, "Missing deliver.gmi must never produce false-positive receipt.ok == true")
        XCTAssertNil(droppedVoice.serverGlobalMsgId)

        let droppedText = try await client.sendText1To1(
            to: 888_000_111,
            text: "Tin bị rớt",
            dryRun: false,
            clientIdMs: 1_793_200_000_002
        )
        XCTAssertFalse(droppedText.ok, "Text send without deliver.gmi must also set receipt.ok == false")
        XCTAssertNil(droppedText.serverGlobalMsgId)

        // 2. `deliver` entry matching `cmi` with `gmi == 0` -> rejected (`ok == false`)
        mock.rawHandlers["/api/message"] = { _ in
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "deliver": [
                        "data": [
                            [
                                "di": 888_000_111,
                                "msg": [["cmi": Int64(1_793_200_000_003), "gmi": 0] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }
        let zeroGmiVoice = try await client.sendVoice1To1(
            to: 888_000_111,
            voiceUrl: "https://voice.talk.zing.vn/live/zerogmi.aac",
            durationMs: 2_000,
            dryRun: false,
            clientIdMs: 1_793_200_000_003
        )
        XCTAssertFalse(zeroGmiVoice.ok)
        XCTAssertNil(zeroGmiVoice.serverGlobalMsgId)

        // 3. String-encoded `data` JSON with positive `gmi` -> `ok == true` and `serverGlobalMsgId` populated,
        //    plus `normalUrl` + `m4a` separation in `uploadAndSendVoiceFile`.
        mock.rawHandlers["/api/v1/video/upload-config"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["listUrls": ["https://voice.talk.zing.vn/upload/v-b47"]] as [String: Any],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/upload/v-b47"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "normalUrl": "https://voice.talk.zing.vn/live/b47.amr",
                    "m4a": "https://voice.talk.zing.vn/live/b47.m4a",
                    "fileSize": 8_192,
                ] as [String: Any],
            ])
            return (200, resp)
        }
        var capturedHrefAndParamBody: Data?
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            capturedHrefAndParamBody = unpacked.bodyData
            let innerDataStr = #"{"type":0,"deliver":{"data":[{"di":888000111,"msg":[{"cmi":1793200000004,"gmi":75999888777}]}]}}"#
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": innerDataStr,
            ])
            return (200, ack)
        }
        let delivered = try await client.uploadAndSendVoiceFile(
            audioData: makeSyntheticM4A(frames: [Data([0x21, 0x22, 0x23])]),
            threadId: 888_000_111,
            durationMs: 2_500,
            dryRun: false,
            clientIdMs: 1_793_200_000_004
        )
        XCTAssertTrue(delivered.receipt.ok)
        XCTAssertEqual(delivered.receipt.subCmd, ZolaConstants.subCmdSendVoice)
        XCTAssertEqual(delivered.receipt.serverGlobalMsgId, 75_999_888_777)
        XCTAssertEqual(delivered.voiceUrl, "https://voice.talk.zing.vn/live/b47.amr")
        XCTAssertEqual(delivered.m4aUrl, "https://voice.talk.zing.vn/live/b47.m4a")
        let bodyStr = String(decoding: capturedHrefAndParamBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(bodyStr.contains("https://voice.talk.zing.vn/live/b47.amr"))
        XCTAssertTrue(bodyStr.contains(#""m4a":"https://voice.talk.zing.vn/live/b47.m4a""#))
        XCTAssertTrue(bodyStr.contains(#""fileSize":8192"#))

        // 4. Incoming/synced voice attachment resolves playable `.m4a` URL ahead of `.amr` `href` for iOS AVPlayer.
        let parsedVoiceAtt = ZolaAttachment.fromRaw(
            msgType: "chat.voice",
            attach: [
                "href": "https://voice.talk.zing.vn/live/b47.amr",
                "action": "chat.voice",
                "params": #"{"duration":2500,"fileSize":8192,"m4a":"https://voice.talk.zing.vn/live/b47.m4a"}"#,
            ]
        )
        XCTAssertEqual(parsedVoiceAtt.kind, "voice")
        XCTAssertEqual(parsedVoiceAtt.url, "https://voice.talk.zing.vn/live/b47.m4a")
        XCTAssertEqual(parsedVoiceAtt.thumbUrl, "https://voice.talk.zing.vn/live/b47.amr")
        XCTAssertEqual(parsedVoiceAtt.durationMs, 2_500)

        // 5. Batch `deliver` ack where our `cmi` failed (`error_code != 0`) MUST NOT steal another item's positive `gmi`.
        let batchFailedAck: [String: Any] = [
            "error_code": 0,
            "data": [
                "deliver": [
                    "data": [
                        [
                            "di": 888_000_111,
                            "msg": [
                                ["cmi": Int64(1_793_200_000_005), "gmi": 75_999_000_001, "error_code": 114] as [String: Any],
                                ["cmi": Int64(1_793_200_000_006), "gmi": 75_999_000_002, "error_code": 0] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]
        XCTAssertNil(ZolaClient.extractFailoverDeliveredGlobalMsgId(from: batchFailedAck, clientIdMs: 1_793_200_000_005))
        XCTAssertEqual(
            ZolaClient.extractFailoverDeliveredGlobalMsgId(from: batchFailedAck, clientIdMs: 1_793_200_000_006),
            75_999_000_002
        )

        // 6. Mixed anonymous (`cmi <= 0`) + older piggybacked `cmi != clientIdMs` with valid `offline`
        //    must return `(ok: true, gmi: nil)` without stealing the anonymous item's `gmi`.
        let mixedAnonAckData = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "data": [
                "offline": ["msg": [] as [Any], "last": 1_793_188_685_911, "e": 0] as [String: Any],
                "deliver": [
                    "data": [
                        [
                            "di": 888_000_111,
                            "msg": [
                                ["gmi": Int64(75_888_000_001)] as [String: Any],
                                ["cmi": Int64(1_793_200_000_001), "gmi": Int64(75_888_000_111)] as [String: Any],
                            ],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ])
        let mixedEval = ZolaClient.evaluateFailoverAck(
            httpStatus: 200,
            decodedAckData: mixedAnonAckData,
            clientIdMs: 1_793_200_000_999
        )
        XCTAssertTrue(mixedEval.ok)
        XCTAssertNil(mixedEval.serverGlobalMsgId)

        let sess = await client.session
        XCTAssertFalse(sess.isExpired)
    }

    func testSQLiteMessageStoreDeduplicationPaginationSearchAndPermissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zola-sqlite-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("history.sqlite3")

        let accountUid: Int64 = 100_000_101
        let threadId: Int64 = 888_111_222

        do {
            let store = try ZolaMessageStore(fileURL: dbURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(perms & 0o777, 0o600, "SQLite history file must enforce POSIX 0600 permissions")

            try store.upsertThread(
                ZolaStoredThreadRecord(
                    accountUid: accountUid,
                    threadId: threadId,
                    title: "Khách VIP Hà Nội",
                    lastTsMs: 1_795_000_999
                )
            )

            // 1. Insert 50 historical messages including Vietnamese diacritics at msg #2
            var history: [ZolaMessage] = []
            for idx in 1...50 {
                let text = (idx == 2)
                    ? " Đã ký hợp đồng bảo hành số HĐ-2026 tại Đà Nẵng "
                    : "Tin nhắn thứ \(idx)"
                history.append(
                    ZolaMessage(
                        id: Int64(90_000_000 + idx),
                        cliMsgId: Int64(1_795_000_000 + idx),
                        threadId: threadId,
                        senderId: idx % 2 == 0 ? accountUid : threadId,
                        senderName: idx % 2 == 0 ? "Văn An" : "Khách VIP",
                        toId: idx % 2 == 0 ? threadId : accountUid,
                        tsMs: Int64(1_795_000_000 + idx * 1000),
                        msgType: "webchat",
                        kind: "text",
                        text: text,
                        isSelf: idx % 2 == 0,
                        source: "sync"
                    )
                )
            }
            try store.upsertMessages(history, accountUid: accountUid, threadId: threadId)
            XCTAssertEqual(try store.messageCount(accountUid: accountUid, threadId: threadId), 50)

            // 2. Optimistic outgoing message (`c:<cliMsgId>`) upgraded to server `g:<globalId>` without duplicate row
            let cliId: Int64 = 1_795_900_123_456
            let optimistic = ZolaMessage(
                id: cliId,
                cliMsgId: cliId,
                threadId: threadId,
                senderId: accountUid,
                senderName: "Văn An",
                toId: threadId,
                tsMs: cliId,
                msgType: "webchat",
                kind: "text",
                text: "Gửi báo giá MacBook M4",
                isSelf: true,
                source: "sending"
            )
            try store.upsertMessages([optimistic], accountUid: accountUid, threadId: threadId)
            XCTAssertEqual(try store.messageCount(accountUid: accountUid, threadId: threadId), 51)

            let confirmed = ZolaMessage(
                id: 99_888_777,
                cliMsgId: cliId,
                threadId: threadId,
                senderId: accountUid,
                senderName: "Văn An",
                toId: threadId,
                tsMs: cliId + 120,
                msgType: "webchat",
                kind: "text",
                text: "Gửi báo giá MacBook M4",
                isSelf: true,
                source: "sent"
            )
            try store.upsertMessages([confirmed], accountUid: accountUid, threadId: threadId)
            XCTAssertEqual(try store.messageCount(accountUid: accountUid, threadId: threadId), 51, "Optimistic row must upgrade cleanly without duplicating")

            // Re-inserting stale optimistic row after confirmation must be ignored
            try store.upsertMessages([optimistic], accountUid: accountUid, threadId: threadId)
            XCTAssertEqual(try store.messageCount(accountUid: accountUid, threadId: threadId), 51)
        }

        // 3. Reopen SQLite from disk and verify pagination, folded Vietnamese search, and deletions
        let reopened = try ZolaMessageStore(fileURL: dbURL)
        XCTAssertEqual(try reopened.messageCount(accountUid: accountUid, threadId: threadId), 51)

        let recent10 = try reopened.messages(accountUid: accountUid, threadId: threadId, limit: 10)
        XCTAssertEqual(recent10.count, 10)
        XCTAssertEqual(recent10.last?.id, 99_888_777)

        let olderPage = try reopened.messages(
            accountUid: accountUid,
            threadId: threadId,
            limit: 15,
            beforeTsMs: recent10.first?.tsMs,
            beforeMsgId: recent10.first?.id
        )
        XCTAssertEqual(olderPage.count, 15)
        XCTAssertLessThan(olderPage.last?.tsMs ?? 0, recent10.first?.tsMs ?? 0)

        // Same-millisecond album cursor pagination + duplicate quick-reply echo safety
        let albumStore = try ZolaMessageStore.inMemory()
        try albumStore.upsertMessages([
            ZolaMessage(id: 7001, cliMsgId: 701, threadId: threadId, senderId: threadId, toId: accountUid, tsMs: 500_000, msgType: "chat.photo", kind: "photo", text: "Ảnh 1", isSelf: false),
            ZolaMessage(id: 7002, cliMsgId: 702, threadId: threadId, senderId: threadId, toId: accountUid, tsMs: 500_000, msgType: "chat.photo", kind: "photo", text: "Ảnh 2", isSelf: false),
            ZolaMessage(id: 7003, cliMsgId: 703, threadId: threadId, senderId: threadId, toId: accountUid, tsMs: 500_000, msgType: "chat.photo", kind: "photo", text: "Ảnh 3", isSelf: false),
        ], accountUid: accountUid, threadId: threadId)
        let latest2Album = try albumStore.messages(accountUid: accountUid, threadId: threadId, limit: 2)
        XCTAssertEqual(latest2Album.map(\.id), [7002, 7003])
        let olderAlbum = try albumStore.messages(
            accountUid: accountUid,
            threadId: threadId,
            limit: 2,
            beforeTsMs: latest2Album.first?.tsMs,
            beforeMsgId: latest2Album.first?.id
        )
        XCTAssertEqual(olderAlbum.map(\.id), [7001], "Compound (beforeTsMs, beforeMsgId) cursor must retain same-millisecond album siblings")

        let twoOks = [
            ZolaMessage(id: 1_700_000_900_001, cliMsgId: 1_700_000_900_001, threadId: threadId, senderId: accountUid, toId: threadId, tsMs: 1_700_000_900_001, text: "Ok", isSelf: true, source: "sending"),
            ZolaMessage(id: 1_700_000_900_800, cliMsgId: 1_700_000_900_800, threadId: threadId, senderId: accountUid, toId: threadId, tsMs: 1_700_000_900_800, text: "Ok", isSelf: true, source: "sending"),
        ]
        try albumStore.upsertMessages(twoOks, accountUid: accountUid, threadId: threadId)
        let firstServerEcho = ZolaMessage(id: 88_000_111, cliMsgId: 0, threadId: threadId, senderId: accountUid, toId: threadId, tsMs: 1_700_000_900_050, text: "Ok", isSelf: true, source: "poll")
        try albumStore.upsertMessages([firstServerEcho], accountUid: accountUid, threadId: threadId)
        XCTAssertEqual(try albumStore.messageCount(accountUid: accountUid, threadId: threadId), 5, "Echo window must retire only 1 closest optimistic 'Ok', keeping the second 'Ok'")

        let matched = try reopened.matchingThreadKeys(query: "hop dong bao hanh so hd-2026 tai da nang")
        XCTAssertTrue(matched.contains("\(accountUid):\(threadId)"))

        try reopened.deleteMessage(accountUid: accountUid, threadId: threadId, messageId: 90_000_002)
        XCTAssertEqual(try reopened.messageCount(accountUid: accountUid, threadId: threadId), 50)
        let matchedAfterDelete = try reopened.matchingThreadKeys(query: "hop dong bao hanh")
        XCTAssertFalse(matchedAfterDelete.contains("\(accountUid):\(threadId)"))

        try reopened.deleteThread(accountUid: accountUid, threadId: threadId)
        XCTAssertEqual(try reopened.messageCount(accountUid: accountUid, threadId: threadId), 0)
        XCTAssertTrue(try reopened.threads(accountUid: accountUid).isEmpty)
    }

    func testTelexAwareVietnameseStickerSuggesterAndNativeParallelStickerSearch() async throws {
        // 1. Telex mid-composition safety: `"buôn"` & `"buô"` (before typing `f` -> `"buồn"`) MUST NOT misfire!
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "buô"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "buôn"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "Hôm nay em buôn"))

        // 2. Completed accented `"buồn"` AND plain unaccented `"buon"` MUST both match `"buon"`!
        let accentedSad = ZolaStickerSuggester.instantMatch(for: "buồn")
        XCTAssertEqual(accentedSad?.canonicalKeyword, "buon")
        XCTAssertEqual(accentedSad?.matchedWholeInput, true)
        XCTAssertFalse(accentedSad?.presets.isEmpty ?? true)

        let asciiSad = ZolaStickerSuggester.instantMatch(for: "buon")
        XCTAssertEqual(asciiSad?.canonicalKeyword, "buon")
        XCTAssertEqual(asciiSad?.matchedWholeInput, true)

        // 3. Multi-word Vietnamese tail matching & slang/emoticon triggers
        let tailThanks = ZolaStickerSuggester.instantMatch(for: "Dạ em cảm ơn")
        XCTAssertEqual(tailThanks?.canonicalKeyword, "cam on")
        XCTAssertEqual(tailThanks?.matchedWholeInput, false)

        let mixedAsciiTail = ZolaStickerSuggester.instantMatch(for: "Chị ơi tks")
        XCTAssertEqual(mixedAsciiTail?.canonicalKeyword, "cam on")
        XCTAssertEqual(mixedAsciiTail?.matchedWholeInput, false)

        XCTAssertEqual(ZolaStickerSuggester.instantMatch(for: "hpbd")?.canonicalKeyword, "chuc mung")
        XCTAssertEqual(ZolaStickerSuggester.instantMatch(for: "g9")?.canonicalKeyword, "ngu ngon")
        XCTAssertEqual(ZolaStickerSuggester.instantMatch(for: "<3")?.canonicalKeyword, "yeu")
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "https://zalo.me/buon"))

        // Homograph & negation guards: never misfire on Vietnamese compounds or negated emotions
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "cong ty"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "thoi gian"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "doi xiu"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "hi vọng"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "không buồn"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "đừng khóc"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "chưa đói"))
        XCTAssertNil(ZolaStickerSuggester.instantMatch(for: "hết mệt"))
        XCTAssertEqual(ZolaStickerSuggester.instantMatch(for: "em hết pin")?.canonicalKeyword, "met qua")

        // 4. Native parallel `suggest/stickers` + `sticker/search` on `stickers.zaloapp.com` (zero `*-wpa.chat.zalo.me`)
        final class FakeStickerTransport: ZolaNetworkTransport, @unchecked Sendable {
            let lock = NSLock()
            var requestedURLs: [String] = []
            let zcid: String

            init(zcid: String) { self.zcid = zcid }

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let urlStr = request.url?.absoluteString ?? ""
                lock.withLock {
                    requestedURLs.append(urlStr)
                }

                if urlStr.contains("/api/message/sticker/suggest/stickers") {
                    let enc = try ZolaCrypto.encryptZCIDParams(["sids": [45601, 90001]], zcid: zcid)
                    let body = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": enc])
                    return (200, body)
                }
                if urlStr.contains("/api/message/sticker/search") {
                    let enc = try ZolaCrypto.encryptZCIDParams([
                        "stickers": [
                            ["id": 90001, "cateId": 12999, "type": 7],
                            ["id": 90002, "cateId": 12999, "type": 7],
                        ],
                    ], zcid: zcid)
                    let body = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": enc])
                    return (200, body)
                }
                let fallback = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": [:]])
                return (200, fallback)
            }
        }

        let zcid = "1_166DBF93CC1D91B465795984762712B0AA167703FF97280D3055408744E639F4F1408DC182A12753B9D08FC854AC79697DBCB304DA0B41582329736B39A00D2C0A80B69183E713FA16E48BF31233647D"
        let transport = FakeStickerTransport(zcid: zcid)
        let session = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "p-test-sticker-session",
            cryptKey: Data("0123456789abcdef".utf8),
            zcid: zcid,
            zcidIsNative: true
        )
        let client = ZolaClient(session: session, transport: transport)
        let suggested = await client.suggestContextualStickers(for: "cảm ơn", limit: 12)
        XCTAssertFalse(suggested.contains(where: { $0.stickerId == 18085 }),
                       "Unverified hand-labelled preset IDs must not appear in live suggestions")
        XCTAssertEqual(suggested.map(\.stickerId), [45601, 90001, 90002],
                       "Zalo's suggest/stickers order first, then search-only results")
        XCTAssertTrue(suggested.contains(where: { $0.stickerId == 90001 && $0.cateId == 12999 }), "Merged sticker 90001 must retain non-zero cateId from search response")
        XCTAssertTrue(suggested.contains(where: { $0.stickerId == 90002 && $0.cateId == 12999 }))
        XCTAssertEqual(Set(suggested.map(\.stickerId)).count, suggested.count, "Must deduplicate sticker IDs")
        XCTAssertTrue(transport.requestedURLs.contains(where: { $0.hasPrefix("https://stickers.zaloapp.com/api/message/sticker/suggest/stickers") }))
        XCTAssertTrue(transport.requestedURLs.contains(where: { $0.hasPrefix("https://stickers.zaloapp.com/api/message/sticker/search") }))
        XCTAssertFalse(transport.requestedURLs.contains(where: { ZolaClient.isForbiddenWebWpaURL($0) }))
        let afterSess = await client.session
        XCTAssertFalse(afterSess.isExpired)
    }

    func testBuild49LiveProductionEmptyDeliverAckStickerCateIdAndFriendApiHost() async throws {
        // 1. `defaultFriendHost` is `https://friend.api.zaloapp.com` and legacy `friend.talk.zing.vn` sessions migrate automatically
        XCTAssertEqual(ZolaConstants.defaultFriendHost, "https://friend.api.zaloapp.com")
        let migratedSession = try ZolaSession(
            uid: ownUid,
            sessionKey: "sk_b49",
            cryptKey: Data(repeating: 0x49, count: 16),
            zcid: "1_166DBF93CC1D91B465795984762712B0AA167703FF97280D3055408744E639F4F1408DC182A12753B9D08FC854AC79697DBCB304DA0B41582329736B39A00D2C0A80B69183E713FA16E48BF31233647D",
            zcidIsNative: true,
            friendHost: "https://friend.talk.zing.vn",
            serviceHosts: ["friend": "https://friend.talk.zing.vn"]
        )
        XCTAssertEqual(migratedSession.friendHost, "https://friend.api.zaloapp.com")
        XCTAssertEqual(migratedSession.serviceHosts?["friend"], "https://friend.api.zaloapp.com")

        let (client, mock) = try makeClient()

        // 2. Live production synchronous `cmd = 130` ACK (`{"error_code":0,"data":{"offline":{...,"e":0},"deliver":{}}}`)
        //    must mark Text, Sticker, and Voice receipts `ok == true` (`serverGlobalMsgId == nil`).
        var capturedStickerCateId: Int32 = 0
        mock.rawHandlers["/api/emoticon/sticker"] = { _ in
            // 16-byte header `[magic=20000, cid=11711, sid=42158, stype=7]` + 5-byte prefix (`eid=42158`)
            var hdr = Data()
            func appendLE32(_ v: UInt32) {
                var le = v.littleEndian
                withUnsafeBytes(of: &le) { hdr.append(contentsOf: $0) }
            }
            appendLE32(20_000)
            appendLE32(11_711)
            appendLE32(42_158)
            appendLE32(7)
            hdr.append(contentsOf: [0x00, 0xA8, 0x4B, 0x02, 0x00])
            return (200, hdr)
        }
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            if unpacked.subCmd == ZolaConstants.subCmdSendSticker, unpacked.bodyData.count >= 13 {
                let b = [UInt8](unpacked.bodyData)
                let off = b.count - 9
                let cid = UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
                capturedStickerCateId = Int32(bitPattern: cid)
            }
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "error_message": "Successful.",
                "data": [
                    "offline": ["msg": [] as [Any], "last": Int64(1_793_188_685_911), "e": 0] as [String: Any],
                    "deliver": [String: Any](),
                ] as [String: Any],
            ])
            return (200, ack)
        }

        // Even when `cateIdHint == 10425`, `resolveStickerMetaNative` queries the CDN header and sends real `cateId = 11711`
        let stickerReceipt = try await client.sendStickerResolvingDetail(
            stickerId: 42_158,
            cateIdHint: 10_425,
            threadId: 888_000_111,
            clientIdMs: 1_793_300_000_001
        )
        XCTAssertTrue(stickerReceipt.ok)
        XCTAssertNil(stickerReceipt.serverGlobalMsgId)
        XCTAssertEqual(capturedStickerCateId, 11_711, "Sticker #42158 must resolve real cateId 11711 instead of generic 10425")

        let voiceReceipt = try await client.sendVoice1To1(
            to: 888_000_111,
            voiceUrl: "https://voice.talk.zing.vn/live/b49.amr",
            durationMs: 1_500,
            fileSize: 4_096,
            m4aUrl: "https://voice.talk.zing.vn/live/b49.m4a",
            dryRun: false,
            clientIdMs: 1_793_300_000_002
        )
        XCTAssertTrue(voiceReceipt.ok)
        XCTAssertNil(voiceReceipt.serverGlobalMsgId)

        let textReceipt = try await client.sendText1To1(
            to: 888_000_111,
            text: "Tin nhắn live deliver rỗng",
            dryRun: false,
            clientIdMs: 1_793_300_000_003
        )
        XCTAssertTrue(textReceipt.ok)
        XCTAssertNil(textReceipt.serverGlobalMsgId)

        // Empty `deliver: {}` WITHOUT `offline` must NOT false-positive as ok
        let bareEmptyDeliver = try JSONSerialization.data(withJSONObject: [
            "error_code": 0, "data": ["deliver": [String: Any]()],
        ])
        let bareEval = ZolaClient.evaluateFailoverAck(httpStatus: 200, decodedAckData: bareEmptyDeliver, clientIdMs: 123)
        XCTAssertFalse(bareEval.ok)

        // Piggybacked `deliver` receipts for EARLIER messages (`cmi != clientIdMs`) in an active chat
        // MUST succeed (`ok == true`) without stealing the earlier message's `gmi`.
        let piggybackedOlderDeliver = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "error_message": "Successful.",
            "data": [
                "offline": ["msg": [] as [Any], "last": Int64(1_793_188_685_911), "e": 0] as [String: Any],
                "deliver": [
                    "data": [
                        [
                            "di": 888_000_111,
                            "msg": [["cmi": Int64(1_793_300_000_001), "gmi": Int64(75_888_000_111)] as [String: Any]],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ])
        let piggybackedEval = ZolaClient.evaluateFailoverAck(
            httpStatus: 200,
            decodedAckData: piggybackedOlderDeliver,
            clientIdMs: 1_793_300_000_999
        )
        XCTAssertTrue(piggybackedEval.ok, "Piggybacked older deliver cmi must never mark a valid send as failed")
        XCTAssertNil(piggybackedEval.serverGlobalMsgId, "Must never steal an older message's gmi")

        // Direct JSON Codable roundtrip of legacy `friend.talk.zing.vn` must normalize to `friend.api.zaloapp.com`
        let legacyJson = #"{"uid":100000101,"sessionKey":"sk_json","friendHost":"https://friend.talk.zing.vn","serviceHosts":{"friend":"https://friend.talk.zing.vn"}}"#.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(ZolaSession.self, from: legacyJson)
        XCTAssertEqual(decodedLegacy.friendHost, "https://friend.api.zaloapp.com")
        XCTAssertEqual(decodedLegacy.serviceHosts?["friend"], "https://friend.api.zaloapp.com")

        // 3. `sendFriendRequest` targets `https://friend.api.zaloapp.com/api/friend/sendreq` and throws on HTTP 404 instead of faking `.sent`
        var friendReqURL: String = ""
        mock.rawHandlers["/api/friend/sendreq"] = { req in
            friendReqURL = req.url?.absoluteString ?? ""
            return (404, Data("<html>404 Not Found</html>".utf8))
        }
        do {
            _ = try await client.sendFriendRequest(toUid: 700_123_456, message: "Xin chào", dryRun: false)
            XCTFail("Expected sendFriendRequest to throw on HTTP 404 instead of swallowing error")
        } catch ZolaError.safetyGate {
            XCTAssertTrue(friendReqURL.hasPrefix("https://friend.api.zaloapp.com/api/friend/sendreq"))
        }
    }

    func testWave1ReactionHostWireCodesAndLegacyMessageDecoding() async throws {
        XCTAssertEqual(ZolaClient.defaultReactionHost, "https://reaction.api.zaloapp.com")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "❤️")?.rIcon, "/-heart")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "👍")?.rIcon, "/-strong")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "😆")?.rIcon, ":>")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "😮")?.rIcon, ":-o")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "😢")?.rIcon, ":-((")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "😡")?.rIcon, ":-h")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "😠")?.rIcon, ":-h")
        XCTAssertEqual(ZolaClient.zaloReactionIcon(for: "")?.rIcon, "")
        XCTAssertNil(ZolaClient.zaloReactionIcon(for: "🎉"))

        let zcid = "1_166DBF93CC1D91B465795984762712B0AA167703FF97280D3055408744E639F4F1408DC182A12753B9D08FC854AC79697DBCB304DA0B41582329736B39A00D2C0A80B69183E713FA16E48BF31233647D"
        final class ReactionCaptureTransport: ZolaNetworkTransport, @unchecked Sendable {
            let zcid: String
            var capturedURL: String = ""
            var capturedParams: [String: Any] = [:]
            var capturedSubCmd: Int8 = 0
            var capturedBodyData: Data = Data()
            init(zcid: String) { self.zcid = zcid }
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                capturedURL = request.url?.absoluteString ?? ""
                if capturedURL.contains("failover.zingmp3.vn/api/message"),
                   let body = request.httpBody,
                   let unpacked = try? ZolaCrypto.unpackHttpFailoverFrame(body)
                {
                    capturedSubCmd = unpacked.subCmd
                    capturedBodyData = unpacked.bodyData
                    let ack = try JSONSerialization.data(withJSONObject: [
                        "error_code": 0,
                        "data": [
                            "offline": ["msg": [] as [Any], "last": Int64(1_793_500_000_000), "e": 0] as [String: Any],
                            "deliver": [
                                "data": [
                                    [
                                        "di": Int(unpacked.desId),
                                        "msg": [["cmi": unpacked.globalMsgId, "gmi": NSNull(), "err": 0] as [String: Any]],
                                    ] as [String: Any],
                                ],
                            ] as [String: Any],
                        ] as [String: Any],
                    ])
                    return (200, ack)
                }
                if let body = request.httpBody,
                   let formStr = String(data: body, encoding: .utf8),
                   let comps = URLComponents(string: "https://x.local?\(formStr)"),
                   let encParams = comps.queryItems?.first(where: { $0.name == "data" })?.value
                {
                    capturedParams = (try? ZolaCrypto.decryptZCIDParams(encParams, zcid: zcid)) ?? [:]
                }
                let ok = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["msgId": 9001]])
                return (200, ok)
            }
        }

        let transport = ReactionCaptureTransport(zcid: zcid)
        let session = try ZolaSession(
            uid: ownUid,
            sessionKey: "sk_wave1_react",
            cryptKey: Data(repeating: 0x33, count: 16),
            zcid: zcid,
            zcidIsNative: true
        )
        let client = ZolaClient(session: session, transport: transport)
        let targetMsg = ZolaMessage(
            id: 9001,
            cliMsgId: 9002,
            threadId: 888_000_111,
            isGroup: false,
            senderId: 888_000_111,
            senderName: "Khách",
            toId: ownUid,
            tsMs: 1_700_000_000_000,
            kind: "text",
            text: "Alo",
            attachments: [],
            isSelf: false,
            isCloud: false,
            source: "live"
        )
        let reactOk = try await client.addReaction(
            "❤️",
            message: targetMsg,
            type: .user,
            dryRun: false
        )
        XCTAssertTrue(reactOk)
        XCTAssertTrue(transport.capturedURL.hasPrefix("https://failover.zingmp3.vn/api/message"))
        XCTAssertEqual(transport.capturedSubCmd, ZolaConstants.subCmdSendReaction)
        XCTAssertFalse(ZolaClient.isForbiddenWebWpaURL(transport.capturedURL))
        let reactWireStr = String(decoding: transport.capturedBodyData, as: UTF8.self)
        XCTAssertTrue(reactWireStr.contains("\"rIcon\":\"/-heart\""))
        XCTAssertTrue(reactWireStr.contains("\"rType\":5"))
        XCTAssertTrue(reactWireStr.contains("\"gMsgID\":9001"))
        XCTAssertTrue(reactWireStr.contains("\"cMsgID\":9002"))
        XCTAssertTrue(reactWireStr.contains("\"msgSender\":\"888000111\""))

        // Group reaction still routes via `reaction.api.zaloapp.com/api/message/reaction`
        let groupMsg = ZolaMessage(
            id: 9101,
            cliMsgId: 9102,
            threadId: 900_000_201,
            isGroup: true,
            senderId: 888_000_111,
            senderName: "Khách",
            toId: 900_000_201,
            tsMs: 1_700_000_000_500,
            kind: "text",
            text: "Nhóm",
            attachments: [],
            isSelf: false,
            isCloud: false,
            source: "live"
        )
        let groupReactOk = try await client.addReaction("👍", message: groupMsg, type: .group, dryRun: false)
        XCTAssertTrue(groupReactOk)
        XCTAssertTrue(transport.capturedURL.hasPrefix("https://reaction.api.zaloapp.com/api/group/reaction"))
        let reactInfo = transport.capturedParams["reactInfo"] as? [String: Any]
        XCTAssertEqual(reactInfo?["rIcon"] as? String, "/-strong")

        // Legacy ZolaMessage JSON without `reactions` field decodes cleanly
        let legacyMsgJSON = #"{"id":555,"cliMsgId":556,"threadId":888000111,"isGroup":false,"isCloud":false,"senderId":888000111,"senderName":"Khách","isSelf":false,"tsMs":1700000000000,"kind":"text","text":"Xin chào","attachments":[],"source":"live"}"#.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(ZolaMessage.self, from: legacyMsgJSON)
        XCTAssertEqual(decodedLegacy.id, 555)
        XCTAssertEqual(decodedLegacy.reactions, [])

        // Incoming chat.undo -> recalled; sendToMeId -> strict isCloud isolation; sendBubbleMessage noise stripped
        let recalledMsg = ZolaMessage.fromRawItem(
            [
                "msgId": "7001",
                "cliMsgId": "7002",
                "uidFrom": "\(ownUid)",
                "idTo": "999888777",
                "msgType": "chat.undo",
                "content": "sendBubbleMessage",
                "ts": "1700000001000",
                "reactions": [["rIcon": "/-strong"]],
            ],
            selfUid: ownUid,
            sendToMeId: 123_456_789
        )
        XCTAssertEqual(recalledMsg.kind, "recalled")
        XCTAssertEqual(recalledMsg.isCloud, false)
        XCTAssertEqual(recalledMsg.reactions, ["👍"])

        let cloudMsg = ZolaMessage.fromRawItem(
            [
                "msgId": "7003",
                "cliMsgId": "7004",
                "uidFrom": "\(ownUid)",
                "idTo": "123456789",
                "msgType": "webchat",
                "content": "Ghi chú Cloud",
                "ts": "1700000002000",
            ],
            selfUid: ownUid,
            sendToMeId: 123_456_789
        )
        XCTAssertEqual(cloudMsg.isCloud, true)
    }

    func testWave1OnionStickerStoreLinkCardSubCmd38FileSubCmd46AndAvatarFreshness() async throws {
        // 1. Onion classic pack (cateId = 0, 1..30)
        XCTAssertEqual(ZolaStickerCatalog.onionPack.stickers.count, 30)
        XCTAssertEqual(
            ZolaAttachment.stickerCdnUrl(stickerId: 7, cateId: 0),
            "https://stc-chat.zdn.vn/images/stickers/default/thumb/7.png"
        )
        XCTAssertTrue(ZolaAttachment.isEmoticonStickerURL("https://stc-chat.zdn.vn/images/stickers/default/thumb/12.png"))
        XCTAssertEqual(ZolaAttachment.extractStickerEid(from: "https://stc-chat.zdn.vn/images/stickers/default/thumb/12.png"), 12)

        // 2. Sticker Store catalog parser filters "test" packs and sorts newest first
        let sampleCatalogJSON = try JSONSerialization.data(withJSONObject: [
            "all": [
                ["id": 1001, "name": "Bộ Test nội bộ", "totalImage": 12],
                ["id": 1050, "name": "Ami Bụng Bự", "desc": "Dễ thương", "totalImage": 24, "iconUrl": "https://zalo-api.zadn.vn/icon1050.png"],
                ["id": 1200, "name": "Mèo Mốc Mới", "desc": "Hài hước", "totalImage": 16, "iconUrl": "https://zalo-api.zadn.vn/icon1200.png"],
            ]
        ])
        let parsedPacks = ZolaStickerStorePack.parseCatalog(from: sampleCatalogJSON)
        XCTAssertEqual(parsedPacks.map(\.id), [1200, 1050])

        // 3. Avatar freshness ?time= comparison
        let olderAva = "https://s120-ava-talk.zadn.vn/a/b/c.jpg?time=1700000100"
        let newerAva = "https://s120-ava-talk.zadn.vn/a/b/c.jpg?time=1750000900"
        XCTAssertEqual(ZolaUser.preferFresherAvatarUrl(existing: newerAva, incoming: olderAva), newerAva)
        XCTAssertEqual(ZolaUser.preferFresherAvatarUrl(existing: olderAva, incoming: newerAva), newerAva)

        // 4. Link extraction, placeholder thumb filtering, subCmd=38 sendLink1To1, and subCmd=46 sendFile1To1
        XCTAssertEqual(
            ZolaClient.extractFirstURL(in: "Xem báo giá tại https://example.vn/bao-gia?ref=vip nhé!"),
            "https://example.vn/bao-gia?ref=vip"
        )
        XCTAssertTrue(ZolaLinkMetadata.isPlaceholderThumb("https://stc-zalo.zadn.vn/im_parselink_default.png"))
        XCTAssertTrue(ZolaLinkMetadata.isPlaceholderThumb("https://stc-zalo.zadn.vn/feed_thumb_link.png"))
        XCTAssertFalse(ZolaLinkMetadata.isPlaceholderThumb("https://cdn.example.vn/og-banner.jpg"))

        let (client, mock) = try makeClient()
        var capturedSubCmds: [Int8] = []
        var capturedPayloads: [Data] = []
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            capturedSubCmds.append(unpacked.subCmd)
            capturedPayloads.append(unpacked.bodyData)
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": Int64(1_793_188_685_999), "e": 0] as [String: Any],
                    "deliver": [String: Any](),
                ] as [String: Any],
            ])
            return (200, ack)
        }

        // SSRF guard must block loopback private URL completely
        let loopbackMeta = await client.resolveLinkMetadata("http://127.0.0.1:8080/internal")
        XCTAssertNil(loopbackMeta)

        // Onion sticker send uses subCmd = 36 (`subCmdSendSticker`), cateId = 0, stickerType = 2 (`ZAStickerSendModel` `0x100b7fcec`)
        let onionReceipt = try await client.sendStickerResolvingDetail(
            stickerId: 5,
            cateIdHint: 0,
            threadId: 888_000_111,
            clientIdMs: 1_793_400_000_001
        )
        XCTAssertTrue(onionReceipt.ok)
        XCTAssertEqual(capturedSubCmds.first, ZolaConstants.subCmdSendSticker)
        XCTAssertEqual(capturedSubCmds.first, 36)
        if let stickerBody = capturedPayloads.first, stickerBody.count >= 9 {
            let b = [UInt8](stickerBody)
            let off = b.count - 9
            let cid = UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
            let stype = b[b.count - 5]
            XCTAssertEqual(cid, 0)
            XCTAssertEqual(stype, 2)
        }

        // Link card subCmd = 38 (`recommened.link`)
        let linkMeta = ZolaLinkMetadata(
            url: "https://example.vn/san-pham",
            title: "Bảng giá Demo",
            descriptionText: "Giải pháp nhắn tin tốc độ cao",
            thumbUrl: "https://stc-zalo.zadn.vn/feed_thumb_link.png",
            domain: "example.vn"
        )
        let linkReceipt = try await client.sendLink1To1(
            to: 888_000_111,
            url: linkMeta.url,
            title: linkMeta.title,
            descriptionText: linkMeta.descriptionText,
            thumbUrl: linkMeta.thumbUrl,
            domain: linkMeta.domain,
            caption: "Gửi Sếp xem",
            dryRun: false,
            clientIdMs: 1_793_400_000_002
        )
        XCTAssertTrue(linkReceipt.ok)
        XCTAssertTrue(capturedSubCmds.contains(ZolaConstants.subCmdSendLinkBubble))
        if let linkBody = capturedPayloads.last, let bodyStr = String(data: linkBody, encoding: .utf8) {
            XCTAssertTrue(bodyStr.contains("recommened.link"))
            XCTAssertTrue(bodyStr.contains("https://example.vn/san-pham"))
            XCTAssertFalse(bodyStr.contains("feed_thumb_link"), "Placeholder thumb must be stripped before packing subCmd=38")
        }

        // Document file subCmd = 46 (`share.file`) + 25MB limit enforcement
        let fileReceipt = try await client.sendFile1To1(
            to: 888_000_111,
            fileUrl: "https://f10-zfcloud.zdn.vn/doc/bao-gia.pdf",
            fileName: "bao-gia.pdf",
            fileSize: 128_000,
            fileExt: "pdf",
            checksumMd5: "d41d8cd98f00b204e9800998ecf8427e",
            dryRun: false,
            clientIdMs: 1_793_400_000_003
        )
        XCTAssertTrue(fileReceipt.ok)
        XCTAssertEqual(capturedSubCmds.last, ZolaConstants.subCmdSendFile)
        if let fileBody = capturedPayloads.last, let bodyStr = String(data: fileBody, encoding: .utf8) {
            XCTAssertTrue(bodyStr.contains("share.file"))
            XCTAssertTrue(bodyStr.contains("bao-gia.pdf"))
        }

        let rawShareFileAtt = ZolaAttachment.fromRaw(
            msgType: "share.file",
            attach: [
                "action": "share.file",
                "title": "hop-dong.docx",
                "href": "https://f10-zfcloud.zdn.vn/doc/hop-dong.docx",
                "params": #"{"fileSize":65536,"fileExt":"docx"}"#,
            ]
        )
        XCTAssertEqual(rawShareFileAtt.kind, "file")
        XCTAssertEqual(rawShareFileAtt.fileExt, "docx")
        XCTAssertEqual(rawShareFileAtt.fileSize, 65_536)
    }

    func testWave1AdversarialStoreLandingSQLiteRecallAndUTF8Clamping() async throws {
        // 1. Live `stickers.zaloapp.com/sticker` + `/cate-stickers?cid=` parsing & resolution + Data slice safety
        let (client, mock) = try makeClient()
        mock.rawHandlers["/sticker"] = { _ in
            let json = #"""
            {
              "value": {
                "hot": [
                  {
                    "id": "02489a90a6d54f8b16c4",
                    "name": "Sẻ Chia PEPERO",
                    "source": "Zalo Sticker",
                    "totalImage": "12 sticker",
                    "iconUrl": "https://zalo-api.zadn.vn/e/4/0/1/7/12820/icon/sechiapepero_icon.png",
                    "thumbImg": "https://zalo-api.zadn.vn/e/4/0/1/7/12820/preview/440x440.png"
                  },
                  {
                    "id": "deadbeef000000000000",
                    "name": "Bộ Test nội bộ",
                    "totalImage": "4 sticker",
                    "iconUrl": "https://zalo-api.zadn.vn/e/4/0/1/7/99999/icon/test.png"
                  }
                ]
              }
            }
            """#
            return (200, Data(json.utf8))
        }
        mock.rawHandlers["/cate-stickers"] = { req in
            XCTAssertTrue(req.url?.query?.contains("cid=02489a90a6d54f8b16c4") == true)
            let json = #"""
            {
              "error": 0,
              "value": [
                {"id": "a1", "url": "https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=101087&size=130&version=2"},
                {"id": "a2", "url": "https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid=101088&size=130&version=2"}
              ]
            }
            """#
            return (200, Data(json.utf8))
        }
        // Return a non-zero startIndex Data slice for `magic = 20000` header check
        mock.rawHandlers["/api/emoticon/sticker"] = { _ in
            var full = Data([0xAA, 0xBB, 0xCC, 0xDD])
            var hdr = Data()
            func appendU32(_ v: UInt32) {
                var le = v.littleEndian
                withUnsafeBytes(of: &le) { hdr.append(contentsOf: $0) }
            }
            appendU32(20_000)
            appendU32(12_820)
            appendU32(1)
            appendU32(7)
            full.append(hdr)
            let slice = full[4..<full.count]
            XCTAssertNotEqual(slice.startIndex, 0)
            return (200, slice)
        }

        let landingPacks = await client.fetchStickerStorePacks()
        XCTAssertEqual(landingPacks.map(\.id), [12_820])
        XCTAssertEqual(landingPacks.first?.storeCid, "02489a90a6d54f8b16c4")
        XCTAssertEqual(landingPacks.first?.totalImage, 12)

        let packItems = await client.fetchStickerPackItems(cateId: 12_820, fallbackTitle: "Sẻ Chia PEPERO")
        XCTAssertEqual(packItems.map(\.stickerId), [101_087, 101_088])
        XCTAssertEqual(packItems.first?.cateId, 12_820)

        let sliceMeta = await client.resolveStickerMetaNative(stickerId: 101_087, cateIdHint: 0)
        XCTAssertEqual(sliceMeta.cateId, 12_820)
        XCTAssertEqual(sliceMeta.stickerType, 7)

        // 2. `buildMediaMsgBodyData` clamps huge multi-byte Vietnamese strings safely (< Int16.max)
        let hugeDesc = String(repeating: "Đợt 1 kiểm thử tràn số nguyên ", count: 600) // > 40,000 UTF-8 bytes
        let mediaPacked = ZolaCrypto.buildMediaMsgBodyData(
            subCmd: ZolaConstants.subCmdSendLinkBubble,
            title: String(repeating: "Tiêu đề tiếng Việt ", count: 200),
            description: hugeDesc,
            href: "https://example.vn",
            action: "recommened.link",
            param: "{}"
        )
        XCTAssertLessThan(mediaPacked.bodyData.count, 32_000)

        // 3. SQLite `ZolaMessageStore` never overwrites a `recalled` message with a stale non-recalled copy
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("zola-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sqlStore = try ZolaMessageStore(fileURL: tmpDir.appendingPathComponent("messages.sqlite"))
        let recalled = ZolaMessage(
            id: 9001,
            cliMsgId: 8001,
            threadId: 555,
            senderId: ownUid,
            toId: 555,
            tsMs: 1_793_500_000_000,
            msgType: "chat.undo",
            kind: "recalled",
            text: "Tin nhắn đã được thu hồi",
            isSelf: true
        )
        let staleOriginal = ZolaMessage(
            id: 9001,
            cliMsgId: 8001,
            threadId: 555,
            senderId: ownUid,
            toId: 555,
            tsMs: 1_793_500_000_000,
            msgType: "webchat",
            kind: "text",
            text: "Nội dung nhạy cảm đã thu hồi",
            isSelf: true
        )
        _ = try sqlStore.upsertMessages([recalled], accountUid: ownUid, threadId: 555)
        _ = try sqlStore.upsertMessages([staleOriginal], accountUid: ownUid, threadId: 555)
        let loaded = try sqlStore.messages(accountUid: ownUid, threadId: 555, limit: 10)
        XCTAssertEqual(loaded.first?.kind, "recalled")
        XCTAssertEqual(loaded.first?.text, "Tin nhắn đã được thu hồi")
        let searchHits = try sqlStore.matchingThreadKeys(query: "nhạy cảm", accountUid: ownUid)
        XCTAssertTrue(searchHits.isEmpty)
    }

    func testLiveProductionFixesFriendsArrayUploadFeature2PhotoReactionAckAndSessionNormalization() async throws {
        // 1. `sendToMeId <= 0` normalizes to `204_278_670` (`defaultSendToMeId`) in `init` & `Decodable`
        let zeroSession = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_live_le_chi",
            cryptKey: Data(repeating: 0x11, count: 16),
            zcid: try ZolaCrypto.generateZCID(
                idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
                platform: "iP16Pro_@26.3.1_@NJ",
                timestampMs: 1_793_600_000_000
            ),
            zcidIsNative: true,
            sendToMeId: 0
        )
        XCTAssertEqual(zeroSession.sendToMeId, ZolaConstants.defaultSendToMeId)

        let zeroJson = Data(#"{"uid":100000103,"sessionKey":"sk_json","cryptKey":"MTIzNDU2Nzg5MDEyMzQ1Ng==","zcid":"0102030405060708","sendToMeId":0}"#.utf8)
        let decodedZero = try JSONDecoder().decode(ZolaSession.self, from: zeroJson)
        XCTAssertEqual(decodedZero.sendToMeId, ZolaConstants.defaultSendToMeId)

        // 2. `ZolaLoginResult.makeSession()` preserves `serviceHosts`, `socketServers`, and `keySet`
        let loginRes = ZolaLoginResult(
            userId: 100_000_103,
            token: "tok_live",
            sessionKey: "sk_login_res",
            zcid: zeroSession.zcid,
            cryptKey: Data(repeating: 0x22, count: 16),
            displayName: "Lê Chi",
            avatarUrl: "https://ava.zalo.me/da.jpg",
            sendToMeId: 0,
            serviceHosts: ["friend": "https://friend.api.zaloapp.com", "chat": "https://failover.zingmp3.vn"],
            socketServers: [ZolaSocketServer(hostName: "49.213.95.89", hostPort: 443, key: 5, pubKey: "pub_b64", tagName: "chat")],
            keySetId: "ks_16_chars_live",
            keySetValue: Data(repeating: 0x77, count: 32).base64EncodedString(),
            aesPublicId: 111_222_333,
            aesPrivateId: 444_555_666
        )
        let builtSession = try loginRes.makeSession()
        XCTAssertEqual(builtSession.sendToMeId, ZolaConstants.defaultSendToMeId)
        XCTAssertEqual(builtSession.serviceHosts?["friend"], "https://friend.api.zaloapp.com")
        XCTAssertEqual(builtSession.socketServers?.first?.hostName, "49.213.95.89")
        XCTAssertEqual(builtSession.keySetId, "ks_16_chars_live")
        XCTAssertEqual(builtSession.aesPublicId, 111_222_333)
        XCTAssertEqual(builtSession.aesPrivateId, 444_555_666)

        // 3. `evaluateFailoverAck` accepts matching `cmi` with `"gmi": NSNull(), "err": 0` while rejecting missing/null/non-zero `err`
        let cid: Int64 = 1_793_600_123_456
        let liveDeliverAck = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "data": [
                "offline": ["msg": [] as [Any], "last": cid, "e": 0] as [String: Any],
                "deliver": [
                    "data": [
                        [
                            "di": 100_000_102,
                            "msg": [["cmi": cid, "gmi": NSNull(), "err": 0] as [String: Any]],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ])
        let okEval = ZolaClient.evaluateFailoverAck(httpStatus: 200, decodedAckData: liveDeliverAck, clientIdMs: cid)
        XCTAssertTrue(okEval.ok)
        XCTAssertNil(okEval.serverGlobalMsgId)

        let nullErrAck = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "data": [
                "offline": ["msg": [] as [Any], "last": cid, "e": 0] as [String: Any],
                "deliver": [
                    "data": [
                        [
                            "di": 100_000_102,
                            "msg": [["cmi": cid, "gmi": NSNull(), "err": NSNull()] as [String: Any]],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertFalse(ZolaClient.evaluateFailoverAck(httpStatus: 200, decodedAckData: nullErrAck, clientIdMs: cid).ok)

        let negErrAck = try JSONSerialization.data(withJSONObject: [
            "error_code": 0,
            "data": [
                "offline": ["msg": [] as [Any], "last": cid, "e": 0] as [String: Any],
                "deliver": [
                    "data": [
                        [
                            "di": 100_000_102,
                            "msg": [["cmi": cid, "gmi": NSNull(), "err": -5] as [String: Any]],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ])
        XCTAssertFalse(ZolaClient.evaluateFailoverAck(httpStatus: 200, decodedAckData: negErrAck, clientIdMs: cid).ok)
        for badRawErr: Any in [false, 0.4, "ERR_DROP"] {
            let badAck = try JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": cid, "e": 0] as [String: Any],
                    "deliver": [
                        "data": [
                            [
                                "di": 100_000_102,
                                "msg": [["cmi": cid, "gmi": NSNull(), "err": badRawErr] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            XCTAssertFalse(ZolaClient.evaluateFailoverAck(httpStatus: 200, decodedAckData: badAck, clientIdMs: cid).ok)
        }
        // VP8L minimal 25-byte lossless WebP header (`width = 16`, `height = 32`)
        var vp8l = Data("RIFF\u{14}\u{00}\u{00}\u{00}WEBPVP8L\u{08}\u{00}\u{00}\u{00}".utf8)
        let vp8lBits: UInt32 = UInt32(16 - 1) | (UInt32(32 - 1) << 14)
        vp8l.append(0x2F)
        vp8l.append(contentsOf: [
            UInt8(vp8lBits & 0xFF),
            UInt8((vp8lBits >> 8) & 0xFF),
            UInt8((vp8lBits >> 16) & 0xFF),
            UInt8((vp8lBits >> 24) & 0xFF),
        ])
        XCTAssertEqual(vp8l.count, 25)
        XCTAssertEqual(ZolaCrypto.sniffImageDimensions(vp8l)?.width, 16)
        XCTAssertEqual(ZolaCrypto.sniffImageDimensions(vp8l)?.height, 32)
        // Secret redaction on `ZolaLoginResult`, `ZolaKeySet`, and `ZolaSocketServer`
        let keySetObj = ZolaKeySet(keySetId: "KS00000000000001", keySetValue: "SUPER_SECRET_KEYSET_VALUE_32BYTE")
        XCTAssertFalse("\(keySetObj)".contains("SUPER_SECRET_KEYSET_VALUE_32BYTE"))
        XCTAssertFalse("\(loginRes)".contains("sk_native_test"))
        XCTAssertFalse("\(loginRes)".contains("tok_123"))

        // 4. `decryptZCIDAny` + `listFriends()` top-level JSON array + `uname` fallback + `syncInbox` contact caching
        let (client, mock) = try makeClient()
        let zcid = (await client.session).zcid
        let topLevelFriendsArray: [[String: Any]] = [
            [
                "userId": "100000102",
                "displayName": "Minh Anh -demo",
                "uname": "minhanh_nd",
                "avatar": "https://ava.zalo.me/ma.jpg",
            ],
            [
                "userId": "555666777",
                "uname": "only_uname_friend",
            ],
        ]
        let arrayPlain = try JSONSerialization.data(withJSONObject: topLevelFriendsArray)
        let arrayEncHex = try ZolaCrypto.aesCBC(
            arrayPlain,
            key: ZolaCrypto.paramKey(zcid: zcid),
            iv: ZolaCrypto.zeroIV16,
            decrypt: false,
            pkcs7Padding: true
        ).map { String(format: "%02X", $0) }.joined()
        let decAny = try ZolaCrypto.decryptZCIDAny(arrayEncHex, zcid: zcid)
        XCTAssertEqual((decAny as? [[String: Any]])?.count, 2)

        mock.rawHandlers["/api/friend/loginfriend"] = { _ in
            let out = try! JSONSerialization.data(withJSONObject: ["error_code": 0, "data": arrayEncHex])
            return (200, out)
        }
        let parsedFriends = try await client.listFriends()
        XCTAssertEqual(parsedFriends.map(\.uid), [100_000_102, 555_666_777])
        XCTAssertEqual(parsedFriends.first?.zaloName, "minhanh_nd")
        XCTAssertEqual(parsedFriends.last?.displayName, "only_uname_friend")

        // 5. `uploadAndSendFile` (`uploadFeature=2` + `x-md-hv` + `subCmd=46`) & `uploadAndSendPhoto` (`uploadFeature=0` + `sniffImageDimensions` + `subCmd=32`)
        var seenUploadFeatures: [String] = []
        var seenSubCmds: [Int8] = []
        var seenPayloads: [Data] = []
        mock.rawHandlers["/api/v1/video/upload-config"] = { req in
            let q = req.url?.query ?? ""
            seenUploadFeatures.append(q)
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["listUrls": ["https://up-f24-zpc.zdn.vn/upload/live-bin"]],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/upload/live-bin"] = { req in
            XCTAssertNotNil(req.value(forHTTPHeaderField: "x-md-hv"))
            let enc = try! ZolaCrypto.encryptZCIDParams([
                "normalUrl": "https://f10-zfcloud.zdn.vn/live/item.bin",
                "hdUrl": "https://f10-zfcloud.zdn.vn/live/item-hd.jpg",
                "thumbUrl": "https://f10-zfcloud.zdn.vn/live/item-th.jpg",
                "fileId": "881199",
            ], zcid: zcid)
            return (200, try! JSONSerialization.data(withJSONObject: ["error_code": 0, "data": enc]))
        }
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            seenSubCmds.append(unpacked.subCmd)
            seenPayloads.append(unpacked.bodyData)
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": unpacked.globalMsgId, "e": 0] as [String: Any],
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": NSNull(), "err": 0] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }

        let docBytes = Data("Tài liệu kiểm thử ZolaKit".utf8)
        let docReceipt = try await client.uploadAndSendFile(
            fileData: docBytes,
            fileName: "kiem-tra-zolakit.txt",
            threadId: 100_000_102,
            dryRun: false
        )
        XCTAssertTrue(docReceipt.receipt.ok)
        XCTAssertTrue(seenUploadFeatures.first?.contains("uploadFeature=2") == true)
        XCTAssertEqual(seenSubCmds.first, ZolaConstants.subCmdSendFile)

        // Minimal valid PNG header (width = 640, height = 480)
        var pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        pngHeader.append(contentsOf: [0x00, 0x00, 0x02, 0x80]) // 640
        pngHeader.append(contentsOf: [0x00, 0x00, 0x01, 0xE0]) // 480
        pngHeader.append(contentsOf: [0x08, 0x06, 0x00, 0x00, 0x00])
        XCTAssertEqual(ZolaCrypto.sniffImageDimensions(pngHeader)?.width, 640)
        XCTAssertEqual(ZolaCrypto.sniffImageDimensions(pngHeader)?.height, 480)

        let photoReceipt = try await client.uploadAndSendPhoto(
            imageData: pngHeader,
            fileName: "anh-test.png",
            threadId: 100_000_102,
            caption: "Ảnh native subCmd=32",
            dryRun: false
        )
        XCTAssertTrue(photoReceipt.receipt.ok)
        XCTAssertTrue(seenUploadFeatures.last?.contains("uploadFeature=0") == true)
        XCTAssertEqual(seenSubCmds.last, ZolaConstants.subCmdSendPhoto)
        let photoWire = String(decoding: seenPayloads.last ?? Data(), as: UTF8.self)
        XCTAssertTrue(photoWire.contains("chat.photo"))
        XCTAssertTrue(photoWire.contains("\"width\":640"))
        XCTAssertTrue(photoWire.contains("\"height\":480"))
        XCTAssertTrue(photoWire.contains("\"thumb_width\":640"))

        // 6. `extractHTMLMetaContent` preserves apostrophes inside double-quoted OpenGraph attributes
        let ogHTML = #"<meta property="og:title" content="Apple's Mac mini M4 — Hiệu năng vượt trội" />"#
        XCTAssertEqual(
            ZolaClient.extractHTMLMetaContent(in: ogHTML, keys: ["og:title"]),
            "Apple's Mac mini M4 — Hiệu năng vượt trội"
        )

        // 7. HTML error body on friend/encrypted endpoint throws `.safetyGate` instead of transport JSON error
        mock.rawHandlers["/api/friend/sendreq"] = { _ in
            return (200, Data("<!DOCTYPE html><html><body>404 Not Found</body></html>".utf8))
        }
        do {
            _ = try await client.sendFriendRequest(toUid: 100_000_102, message: "Test", dryRun: false)
            XCTFail("Expected safetyGate on HTML error response")
        } catch ZolaError.safetyGate {
            // Expected
        }
    }

    func testV115NativeVideoUploadSendAndFriendSocketLifecycle() async throws {
        // 1. Verify `ZolaPeerFriendStatus` flag perspective (`0x100e84800`–`0x100e848fc`):
        //    `isRequesting == 1` -> peer is requesting us (`.incomingRequest`)
        //    `isRequested == 1`  -> peer was requested by us (`.outgoingRequest`)
        let stIncoming = ZolaPeerFriendStatus.fromServerDict(
            ["isFriend": 0, "isRequesting": 1, "isRequested": 0, "addFriendPrivacy": 1],
            uid: 100_000_102
        )
        XCTAssertEqual(stIncoming.relationship, .incomingRequest)

        let stOutgoing = ZolaPeerFriendStatus.fromServerDict(
            ["isFriend": 0, "isRequesting": 0, "isRequested": 1, "addFriendPrivacy": 1],
            uid: 100_000_102
        )
        XCTAssertEqual(stOutgoing.relationship, .outgoingRequest)

        let stFriends = ZolaPeerFriendStatus.fromServerDict(
            ["isFriend": 1, "isRequesting": 0, "isRequested": 1],
            uid: 100_000_102
        )
        XCTAssertEqual(stFriends.relationship, .friends)

        // 2. Verify all 7 `FriendRequestManager` binary frame layouts
        let src: Int32 = 100_000_103
        let peer: Int32 = 100_000_102
        let f1584 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendListRequestsFrame(srcId: src).payload)
        XCTAssertEqual(f1584.cmd, 1584)
        XCTAssertEqual(f1584.subCmd, 2)
        XCTAssertEqual(f1584.bodyData.count, 19)

        let f396 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendListSentFrame(srcId: src).payload)
        XCTAssertEqual(f396.cmd, 396)
        XCTAssertEqual(f396.subCmd, 4)
        XCTAssertEqual(f396.bodyData.count, 22)
        XCTAssertEqual(f396.bodyData.last, 2) // requestType = 2

        let f378 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendRequestStatusFrame(srcId: src, targetUid: peer).payload)
        XCTAssertEqual(f378.cmd, 378)
        XCTAssertEqual(f378.subCmd, 1)
        XCTAssertEqual(f378.bodyData.count, 13)
        XCTAssertEqual(try f378.bodyData.readInt32LE(at: 0), peer)

        let f373 = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packFriendSendRequestFrame(srcId: src, toUid: peer, message: "Chào", alias: "Minh Anh").payload
        )
        XCTAssertEqual(f373.cmd, 373)
        XCTAssertEqual(f373.subCmd, 3)
        XCTAssertEqual(try f373.bodyData.readInt32LE(at: 5), peer)

        let f374 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendAcceptRequestFrame(srcId: src, fromUid: peer).payload)
        XCTAssertEqual(f374.cmd, 374)
        XCTAssertEqual(f374.subCmd, 1)
        XCTAssertEqual(f374.bodyData.count, 14)

        let f375 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendRejectRequestFrame(srcId: src, fromUid: peer).payload)
        XCTAssertEqual(f375.cmd, 375)
        XCTAssertEqual(f375.subCmd, 2)
        XCTAssertEqual(f375.bodyData.count, 15)

        let f397 = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packFriendUndoRequestFrame(srcId: src, toUid: peer).payload)
        XCTAssertEqual(f397.cmd, 397)
        XCTAssertEqual(f397.subCmd, 1)
        XCTAssertEqual(f397.bodyData.count, 17)
        XCTAssertEqual(try f397.bodyData.readInt32LE(at: 9), 1)
        XCTAssertEqual(try f397.bodyData.readInt32LE(at: 13), peer)

        // 3. Verify `ZolaAttachment.fromRaw` keeps `video`/`file` `thumbUrl` pure while keeping `voice` `.amr` fallback
        let videoAttNoThumb = ZolaAttachment.fromRaw(
            msgType: "chat.video.msg",
            attach: [
                "href": "https://video-stal-12.dlmd.me/no/clip.mp4",
                "action": "chat.video.msg",
                "params": #"{"video_width":1280,"video_height":720,"duration":3000,"fileSize":161802}"#,
            ]
        )
        XCTAssertEqual(videoAttNoThumb.kind, "video")
        XCTAssertEqual(videoAttNoThumb.url, "https://video-stal-12.dlmd.me/no/clip.mp4")
        XCTAssertEqual(videoAttNoThumb.thumbUrl, "", "Video without poster must NOT copy .mp4 href into thumbUrl")
        XCTAssertEqual(videoAttNoThumb.width, 1280)
        XCTAssertEqual(videoAttNoThumb.height, 720)
        XCTAssertEqual(videoAttNoThumb.durationMs, 3000)

        let voiceAttDual = ZolaAttachment.fromRaw(
            msgType: "chat.voice",
            attach: [
                "href": "https://voice.talk.zing.vn/clip.amr",
                "m4a": "https://voice.talk.zing.vn/clip.m4a",
                "params": #"{"duration":2}"#,
            ]
        )
        XCTAssertEqual(voiceAttDual.kind, "voice")
        XCTAssertEqual(voiceAttDual.url, "https://voice.talk.zing.vn/clip.m4a")
        XCTAssertEqual(voiceAttDual.thumbUrl, "https://voice.talk.zing.vn/clip.amr")

        // 4. Verify `uploadAndSendVideo` (`uploadFeature=2` + poster `uploadFeature=0` -> `subCmd=44` `chat.video.msg`)
        let (videoClient, mock) = try makeClient()
        var videoFeatures: [String] = []
        var sentVideoSubCmd: Int8 = 0
        var sentVideoWire: String = ""
        mock.rawHandlers["/api/v1/video/upload-config"] = { req in
            let q = req.url?.query ?? ""
            videoFeatures.append(q)
            let isPhotoPoster = q.contains("uploadFeature=0")
            let uploadUrl = isPhotoPoster
                ? "https://photo-stal-14.zdn.vn/u/poster-bin"
                : "https://video-stal-12.dlmd.me/u/video-bin"
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["listUrls": [uploadUrl]],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/u/video-bin"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["org": "https://video-stal-12.dlmd.me/no/live-clip.mp4"],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/u/poster-bin"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "org": "https://photo-stal-14.zdn.vn/no/live-poster.jpg",
                    "thumb": "https://photo-stal-14.zdn.vn/no/live-poster-th.jpg",
                ],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            sentVideoSubCmd = unpacked.subCmd
            sentVideoWire = String(decoding: unpacked.bodyData, as: UTF8.self)
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": unpacked.globalMsgId, "e": 0] as [String: Any],
                    "deliver": [
                        "data": [
                            [
                                "di": Int(unpacked.desId),
                                "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(8_439_645_571_102), "err": 0] as [String: Any]],
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }

        let fakeMp4 = Data("fake-mp4-stream".utf8)
        let fakePoster = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let videoRes = try await videoClient.uploadAndSendVideo(
            videoData: fakeMp4,
            fileName: "demo.mp4",
            posterData: fakePoster,
            width: 1280,
            height: 720,
            durationMs: 3000,
            threadId: 100_000_102,
            caption: "Video kiểm thử",
            dryRun: false,
            clientIdMs: 1_793_525_227_712
        )
        XCTAssertTrue(videoRes.receipt.ok)
        XCTAssertEqual(videoRes.receipt.serverGlobalMsgId, 8_439_645_571_102)
        XCTAssertEqual(videoRes.videoUrl, "https://video-stal-12.dlmd.me/no/live-clip.mp4")
        XCTAssertEqual(videoRes.thumbUrl, "https://photo-stal-14.zdn.vn/no/live-poster-th.jpg")
        XCTAssertEqual(sentVideoSubCmd, ZolaConstants.subCmdSendVideo)
        XCTAssertTrue(sentVideoWire.contains("chat.video.msg"))
        XCTAssertTrue(sentVideoWire.contains(#""video_width":1280"#))
        XCTAssertTrue(sentVideoWire.contains(#""video_height":720"#))
        XCTAssertTrue(sentVideoWire.contains(#""duration":3000"#))
        XCTAssertEqual(videoFeatures.count, 2)
        XCTAssertTrue(videoFeatures[0].contains("uploadFeature=2"))
        XCTAssertTrue(videoFeatures[1].contains("uploadFeature=0"))

        // 5. Loopback Encrypted `UXChatSocket` (`0x7d0`) test verifying:
        //    - Two-frame server response (`msgType = 4` empty receipt ACK + `msgType = 3` gzip JSON)
        //    - `getPeerFriendStatus` (`378/1`), `fetchFriendRequests` (`1584/2` + `396/4`),
        //      `sendFriendRequest` (`373/3`), `acceptFriendRequest` (`374/1`),
        //      `rejectFriendRequest` (`375/2`), `undoFriendRequest` (`397/1`)
        #if canImport(Network)
        let serverPriv = Curve25519.KeyAgreement.PrivateKey()
        let ksId = "ksFriendTest0115"
        let ksKey = Data((0..<32).map { UInt8(0x30 + $0) })
        let listenerQueue = DispatchQueue(label: "test.zolakit.friend.socket.v115")
        let listener = try NWListener(using: .tcp, on: .any)
        let readyExp = expectation(description: "Friend loopback listener ready")

        listener.stateUpdateHandler = { state in
            if case .ready = state { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { serverConn in
            serverConn.start(queue: listenerQueue)
            var rxBuf = Data()
            var strippedPreamble = false
            var sessionCrypto: ZolaSocketCrypto?

            func sendAckAndJsonResponse(srvCrypto: ZolaSocketCrypto, cmd: Int16, subCmd: Int8, seqId: Int32, jsonString: String) {
                // Frame 1: `msgType = 4` empty transport receipt ACK (exact Zalo production behavior!)
                let ack4 = ZolaCrypto.packServerChatElementFrame(
                    bodyData: Data(),
                    srcId: 100_000_103,
                    msgType: 4,
                    cmd: cmd,
                    subCmd: subCmd,
                    seqId: seqId,
                    retCode: 0
                )
                let gz = ZolaCrypto.gzipCompress(Data(jsonString.utf8)) ?? Data(jsonString.utf8)
                let resp3 = ZolaCrypto.packServerChatElementFrame(
                    bodyData: gz,
                    srcId: 100_000_103,
                    msgType: 3,
                    cmd: cmd,
                    subCmd: subCmd,
                    seqId: seqId,
                    retCode: 0
                )
                if let s4 = try? srvCrypto.sealFrame(ack4.payload),
                   let s3 = try? srvCrypto.sealFrame(resp3.payload) {
                    serverConn.send(content: s4 + s3, completion: .contentProcessed { _ in })
                }
            }

            func pump() {
                serverConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, err in
                    if let chunk, !chunk.isEmpty {
                        rxBuf.append(chunk)
                        if !strippedPreamble, let marker = rxBuf.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            rxBuf.removeSubrange(rxBuf.startIndex..<marker.upperBound)
                            strippedPreamble = true
                        }
                        while strippedPreamble, rxBuf.count >= 51 {
                            guard let totalLen = try? Data(rxBuf.prefix(4)).readUInt32LE(at: 0),
                                  rxBuf.count >= Int(totalLen)
                            else { break }
                            let wire = Data(rxBuf.prefix(Int(totalLen)))
                            rxBuf.removeFirst(Int(totalLen))
                            let wType = wire[4]
                            if wType == 0x08 {
                                guard let opened = try? ZolaSocketCrypto.openAuthenFrame(
                                    wire,
                                    serverPrivateKeyRaw32: serverPriv.rawRepresentation,
                                    resolveKeySetValue: { $0 == ksId ? ksKey : nil }
                                ),
                                let authElem = try? ZolaCrypto.unpackChatElementFrame(opened.chatElementPayload),
                                let srvCrypto = try? ZolaSocketCrypto(
                                    keySetId: ksId,
                                    keySetValueBase64: ksKey.base64EncodedString()
                                ) else { continue }
                                sessionCrypto = srvCrypto
                                let okBody = ZolaCrypto.gzipCompress(Data(#"{"data":{"type":1}}"#.utf8)) ?? Data()
                                let okCE = ZolaCrypto.packServerChatElementFrame(
                                    bodyData: okBody,
                                    srcId: 100_000_103,
                                    msgType: 3,
                                    cmd: 1,
                                    subCmd: 5,
                                    seqId: authElem.seqId,
                                    retCode: 0
                                )
                                if let sealed = try? srvCrypto.sealFrame(okCE.payload) {
                                    serverConn.send(content: sealed, completion: .contentProcessed { _ in })
                                }
                            } else if wType == 0x04, let srvCrypto = sessionCrypto {
                                guard let rawCE = try? srvCrypto.openFrame(wire),
                                      let elem = try? ZolaCrypto.unpackChatElementFrame(rawCE)
                                else { continue }
                                switch elem.cmd {
                                case 378:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 378, subCmd: 1, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"addFriendPrivacy":1,"isFriend":0,"isRequesting":1,"isRequested":0}}"#
                                    )
                                case 1584:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 1584, subCmd: 2, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"requestList":{"list":[{"userId":100000102,"displayName":"Minh Anh","msg":"Kết bạn nhé","time":1793526000}]},"suggestList":{"list":[]}}}"#
                                    )
                                case 396:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 396, subCmd: 4, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"data":[{"userId":700111222,"displayName":"Bạn Test","msg":"Xin chào","time":1793526100}]}}"#
                                    )
                                case 373:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 373, subCmd: 3, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"code":0}}"#
                                    )
                                case 374:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 374, subCmd: 1, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"code":0}}"#
                                    )
                                case 375:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 375, subCmd: 2, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":{"code":0}}"#
                                    )
                                case 397:
                                    sendAckAndJsonResponse(
                                        srvCrypto: srvCrypto, cmd: 397, subCmd: 1, seqId: elem.seqId,
                                        jsonString: #"{"error_code":0,"data":[{"errorCode":0,"uIds":[700111222]}]}"#
                                    )
                                default:
                                    break
                                }
                            }
                        }
                    }
                    if !isComplete && err == nil { pump() }
                }
            }
            pump()
        }
        listener.start(queue: listenerQueue)
        defer { listener.cancel() }
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let sockSession = try ZolaSession(
            uid: 100_000_103,
            sessionKey: String(repeating: "K", count: 61),
            cryptKey: Data(repeating: 0x33, count: 16),
            zcid: try ZolaCrypto.generateZCID(
                idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
                platform: "iP16Pro_@26.3.1_@NJ",
                timestampMs: 1_793_526_000_000
            ),
            zcidIsNative: true,
            socketServers: [
                ZolaSocketServer(
                    hostName: "127.0.0.1",
                    hostPort: Int(port),
                    key: 5,
                    pubKey: serverPriv.publicKey.rawRepresentation.base64EncodedString(),
                    tagName: "chat"
                ),
            ],
            keySetId: ksId,
            keySetValue: ksKey.base64EncodedString()
        )
        let sockTransport = FriendServiceMockTransport(zcid: sockSession.zcid)
        sockTransport.rawHandlers["/api/page/getListNoneFriend"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0, "data": ["list_none_friends": [] as [Any]],
            ])
            return (200, resp)
        }
        let sockClient = ZolaClient(session: sockSession, transport: sockTransport, minPollIntervalSeconds: 0)

        let peerStatus = try await sockClient.getPeerFriendStatus(100_000_102)
        XCTAssertEqual(peerStatus.relationship, .incomingRequest)

        let allReqs = try await sockClient.fetchFriendRequests()
        XCTAssertEqual(allReqs.count, 2)
        XCTAssertTrue(allReqs.contains(where: { $0.uid == 100_000_102 && $0.direction == .incoming }))
        XCTAssertTrue(allReqs.contains(where: { $0.uid == 700_111_222 && $0.direction == .outgoing }))

        let sentOnly = try await sockClient.getSentFriendRequest()
        XCTAssertEqual(sentOnly.map(\.uid), [700_111_222])

        let sendOut = try await sockClient.sendFriendRequest(toUid: 700_111_222, message: "Xin chào")
        XCTAssertEqual(sendOut, .sent)
        let accepted = try await sockClient.acceptFriendRequest(fromUid: 100_000_102)
        XCTAssertTrue(accepted)
        let rejected = try await sockClient.rejectFriendRequest(fromUid: 100_000_102)
        XCTAssertTrue(rejected)
        let undone = try await sockClient.undoFriendRequest(toUid: 700_111_222)
        XCTAssertTrue(undone)
        #endif
    }

    func testVoiceDlmdPathExtensionQuickTimeVersion1AdtsAndWaveformSamples() async throws {
        // 1. `ensureAudioPathExtension` appends `/<fileName>` onto extensionless `*.dlmd.me` URLs while preserving existing extensions & non-dlmd hosts.
        let rawDlmd = "https://video-stal-20.dlmd.me/no/0123456789abcdef0123/SyntheticVideoPathForUnitTests000000000"
        XCTAssertEqual(
            ZolaClient.ensureAudioPathExtension(rawDlmd, fileName: "c3d662b16e0990fdcae9e2ed7336a404.aac"),
            "\(rawDlmd)/c3d662b16e0990fdcae9e2ed7336a404.aac"
        )
        XCTAssertEqual(
            ZolaClient.ensureAudioPathExtension("\(rawDlmd)/already.aac", fileName: "other.aac"),
            "\(rawDlmd)/already.aac"
        )
        XCTAssertEqual(
            ZolaClient.ensureAudioPathExtension("\(rawDlmd)?tok=123", fileName: "clip.aac"),
            "\(rawDlmd)/clip.aac?tok=123"
        )
        XCTAssertEqual(
            ZolaClient.ensureAudioPathExtension("https://voice.talk.zing.vn/no-ext", fileName: "clip.aac"),
            "https://voice.talk.zing.vn/no-ext"
        )

        // 2. QuickTime `mp4a` SoundSampleDescription `version == 1` (44-byte header + nested `wave/esds`) + `ES_Descriptor` URL_Flag + `96000 Hz` (`freqIdx == 0`).
        let frame1 = Data([0x21, 0x45, 0x9A, 0x10, 0xF0, 0x33])
        let frame2 = Data([0x80, 0x7F, 0x01, 0xFE, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        var ftypPayload = Data("M4A ".utf8)
        ftypPayload.append(Data([0, 0, 0, 0]))
        ftypPayload.append(Data("qt  mp42".utf8))
        let ftyp = mp4Box("ftyp", ftypPayload)
        var mdatRaw = Data()
        mdatRaw.append(frame1)
        mdatRaw.append(frame2)
        let mdat = mp4Box("mdat", mdatRaw)
        let mdatOffset = UInt32(ftyp.count + 8)

        // mp4a v1: 44-byte header + `wave` container with `frma` + `esds` (tag 0x03 with URL_Flag 0x40 + tag 0x04 + tag 0x05 ASC 0x10 0x08 = AAC-LC, freqIdx=0 [96kHz], mono)
        var mp4aV1 = Data(count: 44)
        mp4aV1[7] = 1   // dataRefIndex = 1
        mp4aV1[9] = 1   // version = 1 (44-byte header)
        mp4aV1[17] = 1  // channels = 1
        mp4aV1[19] = 16 // sampleSize = 16
        let decSpecific = Data([0x05, 0x02, 0x10, 0x08]) // AOT=2 (AAC-LC), freqIdx=0 (96kHz), chanCfg=1
        var decConfig = Data([0x04, UInt8(13 + decSpecific.count)])
        decConfig.append(Data(repeating: 0, count: 13))
        decConfig.append(decSpecific)
        // ES_Descriptor (tag 0x03) with URL_Flag (0x40) and 3-byte URL "aac"
        var esDescBody = Data([0x00, 0x01, 0x40, 0x03])
        esDescBody.append(Data("aac".utf8))
        esDescBody.append(decConfig)
        var esdsBody = Data([0, 0, 0, 0, 0x03, UInt8(esDescBody.count)])
        esdsBody.append(esDescBody)
        let frma = mp4Box("frma", Data("mp4a".utf8))
        let esds = mp4Box("esds", esdsBody)
        var waveBody = Data()
        waveBody.append(frma)
        waveBody.append(esds)
        let wave = mp4Box("wave", waveBody)
        mp4aV1.append(wave)
        let mp4a = mp4Box("mp4a", mp4aV1)

        var stsdPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        stsdPayload.append(mp4a)
        let stsd = mp4Box("stsd", stsdPayload)
        var stszPayload = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2])
        var s1 = UInt32(frame1.count).bigEndian, s2 = UInt32(frame2.count).bigEndian
        stszPayload.append(Data(bytes: &s1, count: 4))
        stszPayload.append(Data(bytes: &s2, count: 4))
        let stsz = mp4Box("stsz", stszPayload)
        var stscPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        var c1 = UInt32(1).bigEndian, c2 = UInt32(2).bigEndian, c3 = UInt32(1).bigEndian
        stscPayload.append(Data(bytes: &c1, count: 4))
        stscPayload.append(Data(bytes: &c2, count: 4))
        stscPayload.append(Data(bytes: &c3, count: 4))
        let stsc = mp4Box("stsc", stscPayload)
        var stcoPayload = Data([0, 0, 0, 0, 0, 0, 0, 1])
        var co = mdatOffset.bigEndian
        stcoPayload.append(Data(bytes: &co, count: 4))
        let stco = mp4Box("stco", stcoPayload)

        var stblBody = Data()
        stblBody.append(stsd); stblBody.append(stsz); stblBody.append(stsc); stblBody.append(stco)
        let moov = mp4Box("moov", mp4Box("trak", mp4Box("mdia", mp4Box("minf", mp4Box("stbl", stblBody)))))
        var qtM4a = Data()
        qtM4a.append(ftyp); qtM4a.append(mdat); qtM4a.append(moov)

        let adts = try XCTUnwrap(ZolaADTS.m4aToAdtsAac(qtM4a))
        XCTAssertEqual(adts.count, frame1.count + frame2.count + 14)
        // ADTS byte 2: profile=1 (01) << 6 | freqIdx=0 (0000) << 2 | (chanCfg>>2)=0 -> 0x40
        XCTAssertEqual(adts[2], 0x40, "freqIdx=0 (96000 Hz) must not be overwritten by fallback sample rate")
        let bars = ZolaADTS.extractWaveformSamples(adts, barCount: 24)
        XCTAssertEqual(bars.count, 24)
        XCTAssertTrue(bars.allSatisfy { (10...96).contains($0) })

        // 2b. Non-zero startIndex Data slices (e.g. HTTP/multipart subdata) must never trap
        var paddedM4a = Data(repeating: 0xAA, count: 19)
        paddedM4a.append(qtM4a)
        let m4aSlice = paddedM4a[19..<paddedM4a.count]
        XCTAssertEqual(m4aSlice.startIndex, 19)
        XCTAssertEqual(ZolaADTS.m4aToAdtsAac(m4aSlice), adts)
        XCTAssertEqual(ZolaADTS.extractWaveformSamples(m4aSlice, barCount: 24), bars)

        var paddedAdts = Data(repeating: 0xBB, count: 11)
        paddedAdts.append(adts)
        let adtsSlice = paddedAdts[11..<paddedAdts.count]
        XCTAssertEqual(adtsSlice.startIndex, 11)
        XCTAssertEqual(ZolaADTS.m4aToAdtsAac(adtsSlice), adts)
        XCTAssertEqual(ZolaADTS.extractWaveformSamples(adtsSlice, barCount: 24), bars)

        // 2c. Oversized 64-bit box header must return nil cleanly without overflow
        let bogus64 = Data([0, 0, 0, 1] + Array("ftyp".utf8) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 32))
        XCTAssertNil(ZolaADTS.m4aToAdtsAac(bogus64))

        // 3. End-to-end `uploadAndSendVoiceFile` with real `dlmd.me` extensionless response -> `uploadFeature=2` + `/<md5>.aac` + `waveformSamples`
        let (client, mock) = try makeClient()
        var capturedUploadQuery = ""
        mock.rawHandlers["/api/v1/video/upload-config"] = { req in
            capturedUploadQuery = req.url?.query ?? ""
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": ["listUrls": ["https://qos-up.dlmd.me/zalo/upload/v-dlmd"]] as [String: Any],
            ])
            return (200, resp)
        }
        mock.rawHandlers["/zalo/upload/v-dlmd"] = { _ in
            let resp = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "normalUrl": rawDlmd,
                    "fileId": "778899",
                    "fileSize": adts.count,
                ] as [String: Any],
            ])
            return (200, resp)
        }
        var sentBody: Data?
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            sentBody = unpacked.bodyData
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "deliver": [
                        "data": [
                            ["di": Int(unpacked.desId), "msg": [["cmi": unpacked.globalMsgId, "gmi": Int64(75_000_000_999)] as [String: Any]]] as [String: Any],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ])
            return (200, ack)
        }

        let expectedMd5Name = "\(ZolaCrypto.md5Hex(adts)).aac"
        let voiceOut = try await client.uploadAndSendVoiceFile(
            audioData: qtM4a,
            threadId: 100_000_102,
            durationMs: 3_654,
            dryRun: false
        )
        XCTAssertTrue(capturedUploadQuery.contains("uploadFeature=2"))
        XCTAssertEqual(voiceOut.voiceUrl, "\(rawDlmd)/\(expectedMd5Name)")
        XCTAssertEqual(voiceOut.m4aUrl, "\(rawDlmd)/\(expectedMd5Name)")
        let bodyStr = String(decoding: try XCTUnwrap(sentBody), as: UTF8.self)
        XCTAssertTrue(bodyStr.contains("\(rawDlmd)/\(expectedMd5Name)"))
        XCTAssertTrue(bodyStr.contains("waveformSamples"))
    }

    // MARK: - Voice receive normalization (`ZolaAudioNormalizer` / `ZolaAMR` / ADTS)

    private func makeAmrFrames(_ frameCount: Int) -> Data {
        // RFC 4867 AMR-NB: header + `frameCount` frames at FT=5 (19-byte payload + 1 TOC byte).
        var d = Data("#!AMR\n".utf8)
        for _ in 0..<frameCount {
            d.append(0x28) // TOC: FT=5
            d.append(Data(count: 19))
        }
        return d
    }

    func testAudioNormalizerSniffsMagicBytesAndPreparesPlayableAudio() throws {
        let amrNB = makeAmrFrames(2)
        let amrWB = Data("#!AMR-WB\n".utf8) + Data([0x48]) + Data(count: 40)
        XCTAssertTrue(ZolaAudioNormalizer.isAMR(amrNB))
        XCTAssertTrue(ZolaAudioNormalizer.isAMR(amrWB))
        XCTAssertTrue(ZolaAudioNormalizer.isAMRWB(amrWB))
        XCTAssertFalse(ZolaAudioNormalizer.isAMRWB(amrNB))
        XCTAssertFalse(ZolaAudioNormalizer.isAMR(Data([0xFF, 0xF1, 0x50])))
        XCTAssertTrue(ZolaAMR.isAMR(amrNB))
        XCTAssertEqual(ZolaAudioNormalizer.amrSpeechFrameCount(amrNB), 2)
        XCTAssertEqual(ZolaAudioNormalizer.estimatedAmrDurationMs(amrNB), 40)

        // ADTS AAC syncword, ISO-BMFF `ftyp`, ID3 / MPEG frame sync, RIFF, CAF, Ogg.
        XCTAssertEqual(
            ZolaAudioNormalizer.sniffAudioFileExtension(Data([0xFF, 0xF1, 0x50, 0x80]) + Data(count: 32)),
            "aac"
        )
        XCTAssertEqual(
            ZolaAudioNormalizer.sniffAudioFileExtension(Data([0xFF, 0xF9, 0x40]) + Data(count: 16)),
            "aac"
        )
        var ftyp = Data(count: 4)
        ftyp.append(contentsOf: "ftypM4A ".utf8)
        ftyp.append(Data(count: 8))
        XCTAssertEqual(ZolaAudioNormalizer.sniffAudioFileExtension(ftyp), "m4a")
        XCTAssertEqual(ZolaAudioNormalizer.sniffAudioFileExtension(Data("ID3".utf8) + Data(count: 16)), "mp3")
        XCTAssertEqual(ZolaAudioNormalizer.sniffAudioFileExtension(Data([0xFF, 0xFB, 0x90]) + Data(count: 8)), "mp3")
        let wav = ZolaAudioNormalizer.wrapPcm16AsWav(Data(count: 64), sampleRate: 8_000, channels: 1)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(ZolaAudioNormalizer.sniffAudioFileExtension(wav), "wav")
        XCTAssertEqual(ZolaAudioNormalizer.sniffAudioFileExtension(Data("caff".utf8) + Data(count: 8)), "caf")
        XCTAssertNil(ZolaAudioNormalizer.sniffAudioFileExtension(Data([0x00, 0x11, 0x22])))

        // `preparePlayableAudio`: containers pass through with canonical extensions.
        let adts = Data([0xFF, 0xF1, 0x50, 0x80]) + Data(count: 100)
        let prepAac = ZolaAudioNormalizer.preparePlayableAudio(data: adts, fallbackExtension: "amr")
        XCTAssertEqual(prepAac.fileExtension, "aac")
        XCTAssertEqual(prepAac.data, adts)

        // AMR → WAV when the OS decoder exists, untouched `.amr` otherwise — never crashes.
        let prepAmr = ZolaAudioNormalizer.preparePlayableAudio(data: amrNB, fallbackExtension: "aac")
        XCTAssertTrue(["wav", "amr"].contains(prepAmr.fileExtension))
        XCTAssertFalse(prepAmr.data.isEmpty)
        if prepAmr.fileExtension == "wav" {
            XCTAssertEqual(String(decoding: prepAmr.data.prefix(4), as: UTF8.self), "RIFF")
        }

        let unknown = ZolaAudioNormalizer.preparePlayableAudio(data: Data([0x12, 0x34, 0x56]), fallbackExtension: ".m4a")
        XCTAssertEqual(unknown.fileExtension, "m4a")
        XCTAssertEqual(unknown.data, Data([0x12, 0x34, 0x56]))
        let empty = ZolaAudioNormalizer.preparePlayableAudio(data: Data(), fallbackExtension: "")
        XCTAssertEqual(empty.fileExtension, "aac")
    }

    func testConvertToAdtsDataPassthroughAdtsAndTranscodeWav() async throws {
        // ADTS input passes through verbatim.
        let adts = Data([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC]) + Data(count: 128)
        let passthroughOpt = await ZolaADTS.convertToAdtsData(adts)
        let passthrough = try XCTUnwrap(passthroughOpt)
        XCTAssertEqual(passthrough.first, 0xFF)
        XCTAssertEqual(passthrough[1] & 0xF0, 0xF0)

        // LinearPCM WAV must transcode to an ADTS `0xFF 0xF1` stream, never raw bytes.
        var pcm = Data()
        for i in 0..<4_000 {
            let s = Int16(sin(Double(i) * 0.1) * 12_000)
            pcm.append(UInt8(s & 0xFF))
            pcm.append(UInt8((s >> 8) & 0xFF))
        }
        let wav = ZolaAudioNormalizer.wrapPcm16AsWav(pcm, sampleRate: 16_000, channels: 1)
        let convertedOpt = await ZolaADTS.convertToAdtsData(wav)
        let converted = try XCTUnwrap(convertedOpt)
        XCTAssertEqual(converted.first, 0xFF)
        XCTAssertEqual(converted[1] & 0xF6, 0xF0, "output must start with an ADTS syncword")

        // Truly undecodable junk returns nil instead of throwing.
        let junk = await ZolaADTS.convertToAdtsData(Data([0x00, 0x11, 0x22, 0x33]))
        XCTAssertNil(junk)
    }

    func testVoiceAttachmentPrefersAacUrlKeepsRawFallbackAndNormalizesDuration() throws {
        // `params.m4a` wins over the raw `href` (usually `.amr`); the fallback stays in `thumbUrl`.
        let attach: [String: Any] = [
            "href": "https://v1.dlmd.me/raw-amr-file",
            "params": #"{"m4a":"https://v1.dlmd.me/voice-m4a","duration":4.3,"fileSize":9876}"#,
        ]
        let att = ZolaAttachment.fromRaw(msgType: "chat.voice", attach: attach)
        XCTAssertEqual(att.kind, "voice")
        XCTAssertTrue(att.url.contains("voice-m4a"))
        XCTAssertTrue(att.url.hasSuffix(".aac"), "extensionless dlmd.me URL must gain a playable .aac leaf")
        XCTAssertEqual(att.thumbUrl, "https://v1.dlmd.me/raw-amr-file/voice.aac")
        XCTAssertEqual(att.durationMs, 4_300)
        XCTAssertEqual(att.fileSize, 9_876)

        // Integer seconds (`4` → `4000`), millisecond passthrough (`4300` → `4300`).
        let secs = ZolaAttachment.fromRaw(
            msgType: "chat.voice",
            attach: ["href": "https://v1.dlmd.me/x.m4a", "duration": 4]
        )
        XCTAssertEqual(secs.durationMs, 4_000)
        let millis = ZolaAttachment.fromRaw(
            msgType: "chat.voice",
            attach: ["href": "https://v1.dlmd.me/x.m4a", "duration": 4_300]
        )
        XCTAssertEqual(millis.durationMs, 4_300)

        // `attach["aac"]`/`voiceUrl` also outrank `href`; `voice-*.zadn.vn` gains `.aac` too.
        let aacKeyed = ZolaAttachment.fromRaw(
            msgType: "chat.voice",
            attach: [
                "aac": "https://voice-1.zadn.vn/abc123",
                "href": "https://v1.dlmd.me/backup.amr",
                "duration": "2.5",
            ]
        )
        XCTAssertEqual(aacKeyed.url, "https://voice-1.zadn.vn/abc123/voice.aac")
        XCTAssertEqual(aacKeyed.durationMs, 2_500)
    }

    // MARK: - VoIP verified endpoints & binary `cmd=402/405/409/415` interpretation

    #if canImport(Network)
    #endif

    #if canImport(Network)

    #if canImport(AVFoundation) && canImport(AudioToolbox)

    #endif
    #endif

    // MARK: - Build 59 Regression Tests (`getKeySet` Mode 2 + Legacy Session Safety + `ZolaEmoticon`)

    func testFetchKeySetFastFailsForLegacySessionWithoutNetworkAndKeepsChatAlive() async throws {
        let legacySess = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "p-5E.100000103.a1.LEGACY_NO_TOKEN",
            cryptKey: Data(repeating: 0x33, count: 16),
            zcidIsNative: true
        )
        let mock = MockZolaTransport(session: legacySess)
        let client = ZolaClient(session: legacySess, transport: mock, minPollIntervalSeconds: 0)

        do {
            _ = try await client.fetchKeySet()
            XCTFail("Expected fetchKeySet without accessToken/loginPhone to fast-fail with safetyGate")
        } catch let ZolaError.safetyGate(msg) {
            XCTAssertEqual(msg, ZolaClient.legacyMissingVoipKeySetMessage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mock.keySetAttempts, 0, "Legacy session without accessToken must never hit /api/helper/getKeySet")
        let afterFail = await client.session
        XCTAssertFalse(afterFail.isExpired, "Missing VoIP keySet must never mark chat session expired")

        let groups = try await client.listJoinedGroups()
        XCTAssertFalse(groups.isEmpty)
    }

    func testFetchKeySetError102ClearsStaleTokenWithoutLatchingSessionExpired() async throws {
        let sess = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "p-5E.100000103.a1.STALE_ACCESS_TOK",
            cryptKey: Data(repeating: 0x44, count: 16),
            zcidIsNative: true,
            accessToken: "zk_stale_token_do_not_log",
            loginPhone: "+84909111222"
        )
        let mock = MockZolaTransport(session: sess)
        mock.mockKeySetErrorCode = 102
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        do {
            _ = try await client.fetchKeySet()
            XCTFail("Expected getKeySet error_code=102 to throw safetyGate")
        } catch let ZolaError.safetyGate(msg) {
            XCTAssertEqual(msg, ZolaClient.legacyMissingVoipKeySetMessage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(mock.keySetAttempts, 1, "Rejected accessToken must not retry getKeySet")
        let updated = await client.session
        XCTAssertFalse(updated.isExpired, "getKeySet 102 must NEVER latch session.markExpired on live chat session")
        XCTAssertNil(updated.accessToken, "Stale accessToken must be cleared after 102 rejection")

        let groups = try await client.listJoinedGroups()
        XCTAssertFalse(groups.isEmpty)
    }

    func testFetchKeySetRejectsInvalidKeyLengthWithoutOverwritingExistingKeySet() async throws {
        let existingKey = Data(repeating: 0x77, count: 32).base64EncodedString()
        let sess = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "p-5E.100000103.a1.KEEP_GOOD_KEY",
            cryptKey: Data(repeating: 0x22, count: 16),
            zcidIsNative: true,
            keySetId: "existingGoodKey1",
            keySetValue: existingKey,
            accessToken: "zk_valid_tok",
            loginPhone: "+84909333444"
        )
        let mock = MockZolaTransport(session: sess)
        mock.mockKeySetId = "badShortKeyId123"
        mock.mockKeySetValue = Data(repeating: 0x11, count: 16).base64EncodedString() // 16B != required 32B
        let client = ZolaClient(session: sess, transport: mock, minPollIntervalSeconds: 0)

        do {
            _ = try await client.fetchKeySet()
            XCTFail("Expected non-32B keySetValue to fail validation")
        } catch {
            // Expected transport validation error
        }

        let preserved = await client.session
        XCTAssertEqual(preserved.keySetId, "existingGoodKey1")
        XCTAssertEqual(preserved.keySetValue, existingKey)
    }

    func testSessionRedactsAccessTokenAndLoginPhoneAndDecodesLegacyJSON() throws {
        let sess = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "SECRET_SK_NEVER_PRINT",
            cryptKey: Data(repeating: 0xAB, count: 16),
            accessToken: "SECRET_ACCESS_TOKEN_999",
            loginPhone: "+84909999888"
        )
        XCTAssertFalse(sess.description.contains("SECRET_ACCESS_TOKEN_999"))
        XCTAssertFalse(sess.debugDescription.contains("SECRET_ACCESS_TOKEN_999"))
        XCTAssertFalse(sess.description.contains("+84909999888"))
        XCTAssertFalse(sess.description.contains("909999888"))

        let legacyJson = Data(#"{"uid":100000103,"sessionKey":"LEGACY_BUILD_52_SK"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ZolaSession.self, from: legacyJson)
        XCTAssertEqual(decodedLegacy.uid, 100_000_103)
        XCTAssertNil(decodedLegacy.accessToken)
        XCTAssertNil(decodedLegacy.loginPhone)
        XCTAssertFalse(decodedLegacy.canRefreshKeySet)
    }

    func testZolaEmoticonExpandsShortcodesWithoutCorruptingURLsOrPaths() {
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "/-strong"), "👍")
        XCTAssertTrue(ZolaEmoticon.isStandaloneEmojiText("👍"))
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "/-strong/-heart"), "👍❤️")
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "Ok anh /-strong! Mai gặp nhé :d"), "Ok anh 👍! Mai gặp nhé 😁")
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "(/-heart)"), "(❤️)")
        XCTAssertEqual(
            ZolaEmoticon.expandingZaloShortcodes(in: "Xem link https://zalo.me/-strong/demo?x=:d nhé /-ok"),
            "Xem link https://zalo.me/-strong/demo?x=:d nhé 👌"
        )
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "www.shop.vn/-strong"), "www.shop.vn/-strong")
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "/-strongly"), "/-strongly")
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "foo/-strong"), "foo/-strong")
        XCTAssertEqual(ZolaEmoticon.expandingZaloShortcodes(in: "Hẹn 10:30 sáng"), "Hẹn 10:30 sáng")

        let msg = ZolaMessage(
            id: 1,
            cliMsgId: 2,
            threadId: 3,
            senderId: 4,
            toId: 5,
            tsMs: 1_000,
            text: "/-strong",
            isSelf: false
        )
        XCTAssertEqual(msg.text, "/-strong", "Wire message.text must remain raw")
        XCTAssertEqual(msg.previewText, "👍", "Inbox previewText must expand /-strong to 👍")
        let quote = ZolaQuote.fromMessage(msg)
        XCTAssertEqual(quote.text, "/-strong", "Wire quote.text must remain raw")
        XCTAssertEqual(quote.previewSummary, "👍", "Quote previewSummary must expand /-strong to 👍")
    }

    func testEmptyAttachHrefDoesNotShadowParamsNotifyTxtOrRenderBlankLinkAndSupportsEcardLocationContactCard() async throws {
        // 1. Exact Screenshot 1 regression (`125444-anh-125443-1.jpg`):
        // Friend-connected payload where `attach` has `"href": ""`, `"title": ""`, `"description": ""`
        // and `params` carries `notifyTxt` / `action = "recommened.fst"`.
        let friendConnectedRaw: [String: Any] = [
            "msgId": "9900112233",
            "cliMsgId": "1730524740000",
            "uidFrom": "100000102",
            "idTo": "100000103",
            "ts": "1730524740000",
            "msgType": "chat.recommended",
            "content": [
                "title": "",
                "description": "",
                "href": "",
                "thumb": "",
                "action": "recommened.fst",
                "params": #"{"notifyTxt":"Minh Anh -demo đã kết bạn với bạn. Hãy trò chuyện ngay!"}"#,
            ] as [String: Any],
        ]
        let parsedNotice = ZolaMessage.fromRawItem(friendConnectedRaw, selfUid: 100_000_103)
        XCTAssertEqual(parsedNotice.kind, "system", "Friend-connected recommended card must parse as system notice, not blank link")
        XCTAssertTrue(parsedNotice.attachments.isEmpty, "System notice must not leave behind an empty link attachment")
        XCTAssertEqual(parsedNotice.text, "Minh Anh -demo đã kết bạn với bạn. Hãy trò chuyện ngay!")
        XCTAssertNotEqual(parsedNotice.previewText, "[Liên kết]")

        // Even when action is missing and content only has empty href/title/thumb, it must never become `[Liên kết]`
        let emptyEnvelopeRaw: [String: Any] = [
            "msgId": "9900112234",
            "cliMsgId": "1730524741000",
            "uidFrom": "100000102",
            "idTo": "100000103",
            "ts": "1730524741000",
            "msgType": "chat.recommended",
            "content": [
                "title": "",
                "description": "",
                "href": "",
                "thumb": "",
                "params": "{}",
            ] as [String: Any],
        ]
        let parsedEmpty = ZolaMessage.fromRawItem(emptyEnvelopeRaw, selfUid: 100_000_103)
        XCTAssertEqual(parsedEmpty.kind, "system")
        XCTAssertTrue(parsedEmpty.attachments.isEmpty)
        XCTAssertNotEqual(parsedEmpty.previewText, "[Liên kết]")

        // 2. Greeting ecard (`chat.ecard`) is distinct from contact card (`recommened.user`)
        let ecardRaw: [String: Any] = [
            "msgId": "9900112235",
            "cliMsgId": "1730524742000",
            "uidFrom": "100000102",
            "idTo": "100000103",
            "ts": "1730524742000",
            "msgType": "chat.ecard",
            "content": [
                "title": "",
                "href": "https://f10-zpcloud.zdn.vn/ecard-banner.jpg",
                "thumb": "https://f10-zpcloud.zdn.vn/ecard-thumb.jpg",
                "params": #"{"title":"Chúc mừng kết bạn mới","description":"Gửi lời chào đầu tiên"}"#,
            ] as [String: Any],
        ]
        let parsedEcard = ZolaMessage.fromRawItem(ecardRaw, selfUid: 100_000_103)
        XCTAssertEqual(parsedEcard.kind, "ecard")
        XCTAssertEqual(parsedEcard.attachments.first?.kind, "ecard")
        XCTAssertEqual(parsedEcard.attachments.first?.title, "Chúc mừng kết bạn mới")
        XCTAssertTrue(parsedEcard.previewText.contains("[Thiệp] Chúc mừng kết bạn mới"))

        // 3. Location message (`chat.location.new`) parses `geo:lat,lon`
        let locRaw: [String: Any] = [
            "msgId": "9900112236",
            "cliMsgId": "1730524743000",
            "uidFrom": "100000102",
            "idTo": "100000103",
            "ts": "1730524743000",
            "msgType": "chat.location.new",
            "content": [
                "title": "",
                "params": #"{"lat":21.028800,"lon":105.852000,"title":"Hồ Gươm","address":"Hoàn Kiếm, Hà Nội"}"#,
            ] as [String: Any],
        ]
        let parsedLoc = ZolaMessage.fromRawItem(locRaw, selfUid: 100_000_103)
        XCTAssertEqual(parsedLoc.kind, "location")
        XCTAssertEqual(parsedLoc.attachments.first?.kind, "location")
        XCTAssertTrue(parsedLoc.attachments.first?.url.hasPrefix("geo:21.028800,105.852000") == true)
        XCTAssertEqual(parsedLoc.previewText, "📍 Hồ Gươm")

        // 4. sendContactCard1To1 (`subCmd = 38`, `recommened.user` with caption preserved in wire frame) & sendLocation1To1 (`subCmd = 38` map card)
        let (client, mock) = try makeClient()
        var capturedCardBody = Data()
        mock.rawHandlers["/api/message"] = { req in
            let unpacked = try! ZolaCrypto.unpackHttpFailoverFrame(req.httpBody ?? Data())
            capturedCardBody = unpacked.bodyData
            let ack = try! JSONSerialization.data(withJSONObject: [
                "error_code": 0,
                "data": [
                    "offline": ["msg": [] as [Any], "last": Int64(1_793_188_685_999), "e": 0] as [String: Any],
                    "deliver": [String: Any](),
                ] as [String: Any],
            ])
            return (200, ack)
        }

        let cardRec = try await client.sendContactCard1To1(
            to: 100_000_102,
            contactUid: 100_000_101,
            contactName: "Anh Hoà Shop",
            avatarUrl: "https://s120.ava.talk.zdn.vn/a.jpg",
            phone: "0988112233",
            caption: "Liên hệ kỹ thuật nhé",
            dryRun: false
        )
        XCTAssertTrue(cardRec.ok)
        XCTAssertEqual(cardRec.subCmd, ZolaConstants.subCmdSendLinkBubble)
        let cardBodyUtf8 = String(decoding: capturedCardBody, as: UTF8.self)
        XCTAssertTrue(cardBodyUtf8.contains("Liên hệ kỹ thuật nhé"), "Contact card wire frame must carry caption")

        let locRec = try await client.sendLocation1To1(
            to: 100_000_102,
            latitude: 21.028800,
            longitude: 105.852000,
            title: "Hồ Gươm",
            address: "Hoàn Kiếm, Hà Nội",
            dryRun: true
        )
        XCTAssertTrue(locRec.ok)
        XCTAssertTrue(locRec.dryRun)
        XCTAssertEqual(locRec.subCmd, ZolaConstants.subCmdSendLinkBubble)

        // 5. SQLite full-history search inside a thread (`searchMessagesInThread` returns newest `limit` in chronological order)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zola-thread-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = try ZolaMessageStore(fileURL: tempDir.appendingPathComponent("history.sqlite3"))
        try store.upsertMessages(
            [
                ZolaMessage(
                    id: 100,
                    cliMsgId: 100,
                    threadId: 100_000_102,
                    senderId: 100_000_102,
                    toId: 100_000_103,
                    tsMs: 1_730_499_990_000,
                    text: "Mã vận đơn VD-000123 đợt 1",
                    isSelf: false
                ),
                ZolaMessage(
                    id: 101,
                    cliMsgId: 101,
                    threadId: 100_000_102,
                    senderId: 100_000_102,
                    toId: 100_000_103,
                    tsMs: 1_730_500_000_000,
                    text: "Mã vận đơn VD-000123 giao chiều nay",
                    isSelf: false
                ),
                ZolaMessage(
                    id: 102,
                    cliMsgId: 102,
                    threadId: 100_000_102,
                    senderId: 100_000_103,
                    toId: 100_000_102,
                    tsMs: 1_730_500_010_000,
                    text: "Đã nhận thông tin nhé",
                    isSelf: true
                ),
                ZolaMessage(
                    id: 103,
                    cliMsgId: 103,
                    threadId: 100_000_102,
                    senderId: 100_000_102,
                    toId: 100_000_103,
                    tsMs: 1_730_500_020_000,
                    text: "Mã vận đơn VD-000123 đã ký nhận",
                    isSelf: false
                ),
            ],
            accountUid: 100_000_103,
            threadId: 100_000_102
        )
        let hits = try store.searchMessagesInThread(
            accountUid: 100_000_103,
            threadId: 100_000_102,
            query: "000123",
            limit: 2
        )
        XCTAssertEqual(hits.map(\.id), [101, 103], "searchMessagesInThread(limit: 2) must return the 2 newest matches in chronological order")
    }

    #if canImport(AVFoundation) && canImport(AudioToolbox)

    func testSocketGetOfflineAndDeliveredAckBinaryVectorsAndTruncatedGzipRejection() throws {
        // 1. Live capture vector `0015-chat-cmd224.bin`: `Int64LE(8_424_854_295_636) + UInt8(50)` = `54947290a907000032`
        let getOffline224 = ZolaCrypto.packSocketGetOfflineFrame(
            srcId: 100_000_101,
            lastGlobalMsgId: 8_424_854_295_636,
            counter: 50,
            isGroup: true,
            subCmd: 1,
            seqId: 2
        )
        let unpacked224 = try ZolaCrypto.unpackChatElementFrame(getOffline224.payload)
        XCTAssertEqual(unpacked224.cmd, 224)
        XCTAssertEqual(unpacked224.subCmd, 1)
        XCTAssertEqual(unpacked224.msgType, 1)
        XCTAssertEqual(unpacked224.needAck, 0)
        XCTAssertEqual(ZolaCrypto.hex(unpacked224.bodyData), "54947290a907000032")

        // 2. Delivered ACK (`cmd = 102, subCmd = 3`) JSON body matches `0017-chat-cmd102.bin`
        let ackFrame = try XCTUnwrap(
            ZolaCrypto.packSocketDeliveredAckFrame(
                srcId: 100_000_101,
                items: [[
                    "gmi": Int64(8_425_001_122_334),
                    "cmi": Int64(1_730_538_720_000),
                    "at": 5,
                    "fromDI": 0,
                    "ts": Int64(1_730_538_720_000),
                    "si": Int64(100_000_104),
                    "cmd": 113,
                    "mt": 1,
                    "st": 5,
                    "di": Int64(100_000_101),
                ]],
                isGroup: false,
                isSeen: 0,
                seqId: 9
            )
        )
        let unpackedAck = try ZolaCrypto.unpackChatElementFrame(ackFrame.payload)
        XCTAssertEqual(unpackedAck.cmd, 102)
        XCTAssertEqual(unpackedAck.subCmd, 3)
        XCTAssertEqual(unpackedAck.msgType, 1)
        XCTAssertEqual(unpackedAck.needAck, 1)
        let ackJson = try XCTUnwrap(JSONSerialization.jsonObject(with: unpackedAck.decodedBodyData) as? [String: Any])
        XCTAssertEqual(ackJson["seen"] as? Int, 0)
        let ackDataArr = try XCTUnwrap(ackJson["data"] as? [[String: Any]])
        XCTAssertEqual(ackDataArr.count, 1)
        XCTAssertEqual((ackDataArr[0]["gmi"] as? NSNumber)?.int64Value, 8_425_001_122_334)
        XCTAssertEqual((ackDataArr[0]["st"] as? NSNumber)?.intValue, 5)

        // 3. Truncated gzip payload MUST return `nil` from `gunzipOrInflate` instead of partial stream bytes
        let validJson = Data(#"{"msgs":[{"id":8425001122335,"cliMsgId":1730538721000,"fromU":100000104,"to":100000101,"msg":"Xin chào"}]}"#.utf8)
        let gzipped = try XCTUnwrap(ZolaCrypto.gzipCompress(validJson))
        XCTAssertEqual(ZolaCrypto.gunzipOrInflate(gzipped), validJson)
        let truncated = gzipped.prefix(max(4, gzipped.count - 6))
        XCTAssertNil(ZolaCrypto.gunzipOrInflate(Data(truncated)), "Truncated gzip without Z_STREAM_END must be rejected")
    }

    func testRealtimeUXChatSocketLivePush113Sticker101Offline121AndDeliveredAck102() async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.zolakit.test.chatsocket")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let readyExp = expectation(description: "0x7d0 chat server ready")
        let gotInitial121Exp = expectation(description: "Client sent initial cmd=121 subCmd=1 GetOffline")
        let receivedThreeMsgsExp = expectation(description: "Client emitted offline + sticker + mcrypt Alo")
        let gotThreeDeliveredAcksExp = expectation(description: "Server received cmd=102 subCmd=3 ACKs for all 3 + duplicate re-ACK")

        final class ChatServerBox: @unchecked Sendable {
            var activeConn: NWConnection?
            var ackedGmis: [Int64] = []
            var count102Frames = 0
            var initial121BodyHex = ""
        }
        let box = ChatServerBox()

        let cryptKey = Data((0..<16).map { UInt8(0x20 + $0) })
        let iv16 = Data((0..<16).map { UInt8(0x40 + $0) })
        let encryptedAloCt = try ZolaCrypto.aesCBC(Data("Alo".utf8), key: cryptKey, iv: iv16, decrypt: false, pkcs7Padding: true)
        var mcryptEnvelope = Data([0x01])
        mcryptEnvelope.append(iv16)
        mcryptEnvelope.appendUInt16LE(UInt16(encryptedAloCt.count))
        mcryptEnvelope.append(encryptedAloCt)
        let mcryptAloB64 = mcryptEnvelope.base64EncodedString()

        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            box.activeConn = conn
            conn.start(queue: serverQueue)
            var buf = Data()
            var upgraded = false
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, isComplete, _ in
                    if let chunk, !chunk.isEmpty {
                        buf.append(chunk)
                        if !upgraded, let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                            buf.removeSubrange(buf.startIndex..<r.upperBound)
                            upgraded = true
                            conn.send(content: Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        if upgraded {
                            while buf.count >= 23, let fLen = try? Data(buf.prefix(4)).readUInt32LE(at: 0), buf.count >= Int(fLen) {
                                let raw = Data(buf.prefix(Int(fLen)))
                                buf.removeFirst(Int(fLen))
                                guard let el = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }
                                switch el.cmd {
                                case 1:
                                    let ack = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 1, subCmd: 5, seqId: el.seqId)
                                    conn.send(content: ack.payload, completion: .contentProcessed { _ in })
                                case 121 where el.subCmd == 1:
                                    box.initial121BodyHex = ZolaCrypto.hex(el.bodyData)
                                    // Reply with gzipped `cmd = 121, msgType = 3` offline batch before signaling initial drain sent!
                                    let batchJson = Data(#"{"more":0,"msgs":[{"id":8425000001001,"cliMsgId":1730538700001,"fromU":100000104,"fromD":"Văn An","to":100000101,"ts":1730538700001,"msgType":"webchat","msg":"Tin nhắn chờ offline"}]}"#.utf8)
                                    let gzBatch = ZolaCrypto.gzipCompress(batchJson) ?? batchJson
                                    let resp121 = ZolaCrypto.packServerChatElementFrame(bodyData: gzBatch, srcId: el.srcId, msgType: 3, cmd: 121, subCmd: 1, seqId: el.seqId)
                                    conn.send(content: resp121.payload, completion: .contentProcessed { _ in
                                        gotInitial121Exp.fulfill()
                                    })
                                case 102 where el.subCmd == 3:
                                    box.count102Frames += 1
                                    if let j = try? JSONSerialization.jsonObject(with: el.decodedBodyData) as? [String: Any],
                                       let items = j["data"] as? [[String: Any]] {
                                        for it in items {
                                            if let g = (it["gmi"] as? NSNumber)?.int64Value {
                                                box.ackedGmis.append(g)
                                            }
                                        }
                                    }
                                    // Server sends `cmd = 102, msgType = 3` receipt — client MUST NOT ACK-loop!
                                    let receipt102 = ZolaCrypto.packServerChatElementFrame(bodyData: Data(#"{"error_code":0}"#.utf8), srcId: el.srcId, msgType: 3, cmd: 102, subCmd: 3, seqId: el.seqId)
                                    conn.send(content: receipt102.payload, completion: .contentProcessed { _ in })
                                    if box.ackedGmis.count == 4 {
                                        gotThreeDeliveredAcksExp.fulfill()
                                    }
                                default:
                                    break
                                }
                            }
                        }
                    }
                    if !isComplete { pump() }
                }
            }
            pump()
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let wmURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-socket-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: wmURL) }

        let session = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "sk_live_chat_socket_test",
            cryptKey: cryptKey,
            zcid: "native_zcid_chat_socket",
            zcidIsNative: true
        )
        let client = ZolaClient(
            session: session,
            watermarkFileURL: wmURL,
            voipLoopbackEndpoints: [("127.0.0.1", port)]
        )

        final class EmittedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [ZolaMessage] = []
            func append(_ m: ZolaMessage) -> Int {
                lock.lock()
                defer { lock.unlock() }
                items.append(m)
                return items.count
            }
            func snapshot() -> [ZolaMessage] {
                lock.lock()
                defer { lock.unlock() }
                return items
            }
        }
        let emitted = EmittedBox()

        await client.setRealtimeEventHandler { ev in
            guard ev.type == "message.new", let m = ev.message else { return }
            if emitted.append(m) == 3 {
                receivedThreeMsgsExp.fulfill()
            }
        }
        try await client.startVoipIncomingListener()
        await fulfillment(of: [gotInitial121Exp], timeout: 3.0)
        XCTAssertEqual(box.initial121BodyHex, "000000000000000032")

        // Push truncated gzip `cmd = 101` (must be ignored without ACK), live sticker `cmd = 101`, live mcrypt `"Alo"` `cmd = 113`, and duplicate `"Alo"` re-push
        serverQueue.async {
            let validGz = ZolaCrypto.gzipCompress(Data(#"{"id":8425000001099,"cliMsgId":1730538700099,"fromU":100000104,"to":100000101,"msg":"Bị cắt cụt"}"#.utf8))!
            let corruptGz = Data(validGz.prefix(max(4, validGz.count - 5)))
            let badPush = ZolaCrypto.packChatElementFrame(bodyData: corruptGz, srcId: 100_000_104, srcType: 3, msgType: 2, cmd: 101, subCmd: 1, seqId: 20, desId: 100_000_101)
            box.activeConn?.send(content: badPush.payload, completion: .contentProcessed { _ in })

            let stickerJson = Data(#"{"id":8425000001002,"cliMsgId":1730538720001,"fromU":100000104,"fromD":"Văn An","to":100000101,"ts":1730538720001,"msgType":"chat.sticker","content":{"id":23051,"catId":10425}}"#.utf8)
            let stickerPush = ZolaCrypto.packChatElementFrame(bodyData: stickerJson, srcId: 100_000_104, srcType: 3, msgType: 2, cmd: 101, subCmd: 1, seqId: 21, desId: 100_000_101, globalMsgId: 8_425_000_001_002)
            box.activeConn?.send(content: stickerPush.payload, completion: .contentProcessed { _ in })

            let aloJson = Data(#"{"id":8425000001003,"cliMsgId":1730538722000,"fromU":100000104,"fromD":"Văn An","to":100000101,"ts":1730538722000,"msgType":"webchat","mcrypt":1,"msg":"\#(mcryptAloB64)"}"#.utf8)
            let aloPush = ZolaCrypto.packChatElementFrame(bodyData: aloJson, srcId: 100_000_104, srcType: 3, msgType: 2, cmd: 113, subCmd: 41, seqId: 22, desId: 100_000_101, globalMsgId: 8_425_000_001_003)
            box.activeConn?.send(content: aloPush.payload, completion: .contentProcessed { _ in })

            // Duplicate re-delivery of `8425000001003`: must NOT emit a 2nd UI event, MUST still re-ACK `102`!
            let dupAloPush = ZolaCrypto.packChatElementFrame(bodyData: aloJson, srcId: 100_000_104, srcType: 3, msgType: 2, cmd: 113, subCmd: 41, seqId: 23, desId: 100_000_101, globalMsgId: 8_425_000_001_003)
            box.activeConn?.send(content: dupAloPush.payload, completion: .contentProcessed { _ in })
        }

        await fulfillment(of: [receivedThreeMsgsExp, gotThreeDeliveredAcksExp], timeout: 4.0)
        try await Task.sleep(nanoseconds: 150_000_000)

        let msgs = emitted.snapshot()
        XCTAssertEqual(msgs.count, 3, "Duplicate re-push must be deduplicated while still sending Delivered ACK")
        XCTAssertEqual(msgs[0].text, "Tin nhắn chờ offline")
        XCTAssertEqual(msgs[1].kind, "sticker")
        XCTAssertEqual(msgs[1].attachments.first?.stickerId, 23_051)
        XCTAssertEqual(msgs[2].text, "Alo")
        XCTAssertEqual(box.ackedGmis, [8_425_000_001_001, 8_425_000_001_002, 8_425_000_001_003, 8_425_000_001_003])
        XCTAssertFalse(box.ackedGmis.contains(8_425_000_001_099), "Truncated gzip frame must never be ACKed")
        XCTAssertEqual(box.count102Frames, 4, "Server cmd=102 receipts must never trigger an ACK loop")

        await client.stopVoipIncomingListener()
    }
    #endif

    func testPollOnceSurvivesPartialEndpointFailureAndRotatesOver60SingleCursors() async throws {
        let wmURL = FileManager.default.temporaryDirectory.appendingPathComponent("wm-poll-partial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: wmURL) }

        // Register 75 single peers so we exceed the 60-UID `/api/preload` window
        var initialWm = ZolaWatermarkState(initialized: true)
        for i in 1...75 {
            let uid = Int64(500_000_000 + i)
            initialWm.singleCursors[uid] = (i == 74) ? 8_425_999_000_001 : 1
        }
        try ZolaFileSessionStore.saveWatermark(initialWm, to: wmURL)

        let zcid = ZolaDeviceIdentity.defaultProfile.zcid
        let sess = try ZolaSession(
            uid: ownUid,
            sessionKey: "test_session_key_not_sent",
            cryptKey: Data("0123456789abcdef".utf8),
            zcid: zcid,
            zcidIsNative: true
        )
        let mock75 = FriendServiceMockTransport(zcid: zcid)
        let clientWith75 = ZolaClient(
            session: sess,
            watermarks: try ZolaFileSessionStore.loadWatermark(from: wmURL),
            watermarkFileURL: wmURL,
            transport: mock75,
            minPollIntervalSeconds: 0
        )

        // 1. `/api/message` (`cmd = 115` GetOffline) pops 1 message while `/api/cm/femc` fails with e = -500:
        //    `pollOnce` MUST still emit the popped offline message and persist watermarks!
        mock75.rawHandlers["/api/message"] = { _ in
            let payload: [String: Any] = [
                "error_code": 0,
                "data": [
                    "offline": [
                        "e": 0,
                        "msg": [
                            [
                                "text": [
                                    "type": "webchat",
                                    "data": [
                                        "id": 8_425_888_000_111,
                                        "cliMsgId": 1_730_538_800_000,
                                        "fromU": 100_000_104,
                                        "fromD": "Văn An",
                                        "to": 100_000_001,
                                        "ts": 1_730_538_800_000,
                                        "msgType": "webchat",
                                        "msg": "Alo từ hàng đợi offline",
                                    ] as [String: Any],
                                ] as [String: Any],
                            ],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ]
            return (200, try! JSONSerialization.data(withJSONObject: payload))
        }
        mock75.rawHandlers["/api/cm/femc"] = { _ in
            let errBody = try! JSONSerialization.data(withJSONObject: ["e": -500, "errMessage": "Transient error"])
            return (200, errBody)
        }

        final class SeenUidsBox: @unchecked Sendable {
            private let lock = NSLock()
            private var set: Set<Int64> = []
            func insert(_ uid: Int64) { lock.lock(); defer { lock.unlock() }; set.insert(uid) }
            func snapshot() -> Set<Int64> { lock.lock(); defer { lock.unlock() }; return set }
        }
        let seenBox = SeenUidsBox()

        mock75.rawHandlers["/api/preload"] = { _ in
            let inner = mock75.inner("/api/preload")
            if let dataStr = inner["data"] as? String,
               let dataObj = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any],
               let singles = dataObj["single"] as? [[String: Any]] {
                for s in singles {
                    if let u = (s["uid"] as? NSNumber)?.int64Value {
                        seenBox.insert(u)
                    }
                }
            }
            let enc = try! ZolaCrypto.encryptZCIDParams(["infoJoinGroup": [], "lastMsgs": []], zcid: zcid)
            return (200, try! JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc]))
        }

        let evs1 = try await clientWith75.pollOnce(includePreload: true, includeOffline: true)
        XCTAssertEqual(evs1.count, 1, "Popped offline message must survive transient femc error")
        XCTAssertEqual(evs1.first?.message?.text, "Alo từ hàng đợi offline")

        let savedWm = try ZolaFileSessionStore.loadWatermark(from: wmURL)
        XCTAssertTrue(
            savedWm.seenIds.contains("u:100000104:8425888000111:1730538800000:100000104"),
            "Watermark must be saved even when femc failed"
        )

        // Next poll rotates through the remaining singleCursors so peer #75 (`500_000_075`) is polled too!
        mock75.rawHandlers["/api/message"] = { _ in
            let empty = try! JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["offline": ["e": 0, "msg": []]]])
            return (200, empty)
        }
        _ = try await clientWith75.pollOnce(includePreload: true, includeOffline: true)
        let seenPreloadUidsAcrossPolls = seenBox.snapshot()
        XCTAssertTrue(seenPreloadUidsAcrossPolls.contains(500_000_074), "Recently active cursor > 1 must be prioritized")
        XCTAssertTrue(seenPreloadUidsAcrossPolls.contains(500_000_075), "Round-robin rotation must reach peer #75 beyond sorted prefix(60)")
    }

    func testFriendConnectedSystemNoticeWithEmptyAttachAndJsonMsg() throws {
        // Case 1: `attach` is `{}` (non-nil empty dictionary) while `msg` holds JSON friend-accepted notice
        let rawFriendNotice: [String: Any] = [
            "id": 8_425_123_456_789,
            "cliMsgId": 1_730_524_740_123,
            "fromU": 100_000_102,
            "fromD": "Minh Anh -demo",
            "to": 100_000_101,
            "ts": 1_730_524_740_123,
            "msgType": "webchat",
            "attach": [:] as [String: Any],
            "msg": #"{"action":"recommened.fst","title":"","description":"","params":"{}"}"#,
        ]
        let parsed = ZolaMessage.fromRawItem(rawFriendNotice, selfUid: 100_000_101)
        XCTAssertEqual(parsed.kind, "system")
        XCTAssertTrue(parsed.attachments.isEmpty)
        XCTAssertEqual(parsed.text, "Bạn vừa kết bạn với Minh Anh -demo")

        // Case 2: Group `msginfo.actionlist` system notice must NEVER be mislabeled as 1-1 friend connection
        let rawGroupSys: [String: Any] = [
            "id": 8_425_123_456_790,
            "cliMsgId": 1_730_524_740_124,
            "fromU": 100_000_102,
            "fromD": "Minh Anh -demo",
            "to": 900_111_222,
            "ts": 1_730_524_740_124,
            "msgType": "webchat",
            "attach": [:] as [String: Any],
            "msg": #"{"action":"msginfo.actionlist","params":"{}"}"#,
        ]
        let parsedGroup = ZolaMessage.fromRawItem(
            rawGroupSys,
            selfUid: 100_000_101,
            knownGroupIds: [900_111_222]
        )
        XCTAssertEqual(parsedGroup.kind, "system")
        XCTAssertEqual(parsedGroup.msgType, "msginfo.actionlist")
        XCTAssertEqual(parsedGroup.text, "Thông báo hệ thống Zalo")

        // Case 3: 1-1 `msginfo.pin` preserves `msgType = "msginfo.pin"` and pin text (never misclassified as friend notice)
        let rawPin1To1: [String: Any] = [
            "id": 8_425_123_456_791,
            "cliMsgId": 1_730_524_740_125,
            "fromU": 100_000_102,
            "fromD": "Minh Anh -demo",
            "to": 100_000_101,
            "ts": 1_730_524_740_125,
            "msgType": "webchat",
            "msg": #"{"action":"msginfo.pin","params":"{}"}"#,
        ]
        let parsedPin = ZolaMessage.fromRawItem(rawPin1To1, selfUid: 100_000_101)
        XCTAssertEqual(parsedPin.kind, "system")
        XCTAssertEqual(parsedPin.msgType, "msginfo.pin")
        XCTAssertEqual(parsedPin.text, "Đã ghim một tin nhắn")

        // Case 4: Plain `webchat` user text containing JSON `{"params":{"invoice":123}}` must remain `kind = "text"` with exact text
        let rawPlainJsonText: [String: Any] = [
            "id": 8_425_123_456_792,
            "cliMsgId": 1_730_524_740_126,
            "fromU": 100_000_102,
            "fromD": "Minh Anh -demo",
            "to": 100_000_101,
            "ts": 1_730_524_740_126,
            "msgType": "webchat",
            "msg": #"{"params":{"invoice":123}}"#,
        ]
        let parsedPlainJson = ZolaMessage.fromRawItem(rawPlainJsonText, selfUid: 100_000_101)
        XCTAssertEqual(parsedPlainJson.kind, "text")
        XCTAssertEqual(parsedPlainJson.text, #"{"params":{"invoice":123}}"#)
    }

    #if canImport(Network)
    func testSocketEmptyBodyRetCode102TripsSessionExpiredCircuitBreaker() async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.test.socket-ret102")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let readyExp = expectation(description: "Loopback ready")
        let expiredEventExp = expectation(description: "Received session.expired event on retCode=102")
        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            conn.start(queue: serverQueue)
            var buf = Data()
            var upgraded = false
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, isComplete, _ in
                    if let chunk, !chunk.isEmpty {
                        buf.append(chunk)
                        if !upgraded, let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                            buf.removeSubrange(buf.startIndex..<r.upperBound)
                            upgraded = true
                            conn.send(content: Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        if upgraded {
                            while buf.count >= 23, let fLen = try? Data(buf.prefix(4)).readUInt32LE(at: 0), buf.count >= Int(fLen) {
                                let raw = Data(buf.prefix(Int(fLen)))
                                buf.removeFirst(Int(fLen))
                                guard let el = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }
                                if el.cmd == 1 {
                                    let ack = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 1, subCmd: 5, seqId: el.seqId)
                                    conn.send(content: ack.payload, completion: .contentProcessed { _ in })
                                } else if el.cmd == 121 {
                                    // Reply with empty bodyData and header `retCode = 102` (`msgType = 3`)
                                    let errResp = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 121, subCmd: 1, seqId: el.seqId, retCode: 102)
                                    conn.send(content: errResp.payload, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    if !isComplete { pump() }
                }
            }
            pump()
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let session = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "sk_ret102_test",
            cryptKey: Data(repeating: 0x22, count: 16),
            zcid: ZolaDeviceIdentity.defaultProfile.zcid,
            zcidIsNative: true
        )
        let client = ZolaClient(session: session, voipLoopbackEndpoints: [("127.0.0.1", port)])
        await client.setRealtimeEventHandler { ev in
            if ev.type == "session.expired" && ev.errorCode == 102 {
                expiredEventExp.fulfill()
            }
        }
        try await client.startVoipIncomingListener()
        await fulfillment(of: [expiredEventExp], timeout: 3.0)
        let afterSession = await client.session
        XCTAssertTrue(afterSession.isExpired)
        XCTAssertEqual(afterSession.expiredCode, 102)
    }
    #endif

    // MARK: - Group text + `@mention` (`cmd = 201/207`, TLV tag 11). No test here reaches a Zalo host.

    private func groupTestClient() throws -> ZolaClient {
        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_group_text_test",
            zcid: "native_zcid_group_text",
            zcidIsNative: true
        )
        return ZolaClient(session: session)
    }

    private func hexBytes(_ text: String) -> Data {
        Data(text.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    func testGroupTextFrameGoldenBytesCmd207WithMentionTagFirst() async throws {
        let client = try groupTestClient()
        let frame = try await client.buildGroupSendSocketFrame(
            gid: 900_000_201,
            text: "Chào @Lan",
            mentions: [ZolaMention(type: 0, uid: 100_000_102, pos: 5, len: 4)],
            seqId: 7,
            clientIdMs: 1_793_000_000_123
        )
        let parsed = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(parsed.cmd, 207)
        XCTAssertEqual(parsed.subCmd, 1)
        XCTAssertEqual(parsed.msgType, 2)
        XCTAssertEqual(parsed.srcType, 3)
        XCTAssertEqual(parsed.srcId, 100_000_103)
        XCTAssertEqual(parsed.needAck, 1)
        XCTAssertEqual(parsed.seqId, 7)
        XCTAssertEqual(parsed.desId, 900_000_201)
        XCTAssertEqual(parsed.desType, 4)
        XCTAssertEqual(parsed.globalMsgId, 1_793_000_000_123)
        // i16 subCmd, u8 propCount, 0x0B, u16 count, i8 type, i16 pos, i16 len, i32 uid, then plain UTF-8.
        XCTAssertEqual(
            parsed.bodyData,
            hexBytes("01 00 01 0b 01 00 00 05 00 04 00 66 e1 f5 05") + Data("Chào @Lan".utf8)
        )
    }

    func testOversizedEncryptedDirectTextThrowsInsteadOfTrapping() throws {
        let key = Data(repeating: 0x44, count: 16)
        let iv = Data(repeating: 0x01, count: 16)
        // Pasted call log in an earlier crash was ~70KB; ciphertext > u16 must throw, not trap.
        let huge = String(repeating: "nhật ký cuộc gọi ", count: 4_000)
        XCTAssertGreaterThan(huge.utf8.count, Int(UInt16.max))
        XCTAssertThrowsError(
            try ZolaCrypto.buildTextMsgBodyData(text: huge, includeIOSProps: true, cryptKey: key, iv16: iv)
        ) { error in
            guard case ZolaError.invalidArgument(let message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(message.contains("quá dài"))
        }
        // Largest plaintext whose PKCS7 ciphertext still fits u16 (65520 bytes) keeps working.
        let edge = String(repeating: "a", count: 65_519)
        let built = try ZolaCrypto.buildTextMsgBodyData(text: edge, cryptKey: key, iv16: iv)
        XCTAssertEqual(built.subCmd, 41)
    }

    func testGroupTextMentionOffsetsAreUTF16WithEmoji() throws {
        // The emoji is 2 UTF-16 units but 4 UTF-8 bytes, so `@Lan` starts at 3, never 5.
        let text = "😀 @Lan"
        let built = try ZolaCrypto.buildTextMsgBodyData(
            text: text,
            isGroup: true,
            mentions: [ZolaMention(type: 0, uid: 1, pos: 3, len: 4)]
        )
        XCTAssertEqual(built.bodyData, hexBytes("01 00 01 0b 01 00 00 03 00 04 00 01 00 00 00") + Data(text.utf8))

        XCTAssertThrowsError(
            try ZolaCrypto.buildTextMsgBodyData(
                text: text,
                isGroup: true,
                mentions: [ZolaMention(type: 0, uid: 1, pos: 5, len: 4)]
            )
        ) { error in
            guard case ZolaError.invalidArgument = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testGroupTextMentionAllOmitsUidOnWire() throws {
        let all = ZolaMention(type: 1, uid: -1, pos: 0, len: 4)
        XCTAssertEqual(ZolaCrypto.buildMentionPropertyData([all]), hexBytes("01 00 01 00 00 04 00"))

        let built = try ZolaCrypto.buildTextMsgBodyData(text: "@All họp", isGroup: true, mentions: [all])
        XCTAssertEqual(built.innerCmd, 207)
        XCTAssertEqual(built.bodyData, hexBytes("01 00 01 0b 01 00 01 00 00 04 00") + Data("@All họp".utf8))

        var pos = 0
        XCTAssertEqual(try ZolaCrypto.parseMentionPropertyData(ZolaCrypto.buildMentionPropertyData([all]), at: &pos), [all])
        XCTAssertEqual(pos, 7)
    }

    func testGroupTextWithoutPropertiesIsRawCmd201() async throws {
        let client = try groupTestClient()
        let frame = try await client.buildGroupSendSocketFrame(gid: 900_000_201, text: "Xin chào", clientIdMs: 1)
        let parsed = try ZolaCrypto.unpackChatElementFrame(frame.payload)
        XCTAssertEqual(parsed.cmd, 201)
        XCTAssertEqual(parsed.subCmd, 1)
        XCTAssertEqual(parsed.srcType, 3)
        // No `i16 subCmd + u8 propCount` header when there are no properties (`0x100c875a4`).
        XCTAssertEqual(parsed.bodyData, Data("Xin chào".utf8))
    }

    func testGroupTextNeverUsesCryptKeyEvenWhenProvided() throws {
        let built = try ZolaCrypto.buildTextMsgBodyData(
            text: "Rõ chữ",
            isGroup: true,
            cryptKey: Data(repeating: 0x11, count: 16)
        )
        XCTAssertEqual(built.subCmd, 1)
        XCTAssertEqual(built.bodyData, Data("Rõ chữ".utf8))
    }

    func testGroupTextMentionAndQuoteShareCmd207InTagOrder() throws {
        let quote = ZolaQuote(ownerId: 100_000_102, cliMsgId: 11, globalMsgId: 22, text: "Gốc", tsMs: 33)
        let mention = ZolaMention(type: 0, uid: 100_000_102, pos: 0, len: 4)
        let built = try ZolaCrypto.buildTextMsgBodyData(text: "@Lan ok", isGroup: true, quote: quote, mentions: [mention])
        XCTAssertEqual(built.innerCmd, 207)

        var expected = hexBytes("01 00 02 0b")
        expected.append(ZolaCrypto.buildMentionPropertyData([mention]))
        expected.append(0x02)
        expected.append(ZolaCrypto.buildQuotePropertyData(quote))
        expected.append(Data("@Lan ok".utf8))
        XCTAssertEqual(built.bodyData, expected)

        let decoded = try ZolaCrypto.decryptMcryptTextAndPropertiesBody(built.bodyData, cryptKey: Data())
        XCTAssertEqual(decoded.propCount, 2)
        XCTAssertEqual(decoded.text, "@Lan ok")
        XCTAssertEqual(decoded.mentions, [mention])
        XCTAssertEqual(decoded.quote?.cliMsgId, 11)
    }

    #if canImport(Network)
    func testSendGroupTextDryRunEmitsNoPacket() async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.test.group-dryrun")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let readyExp = expectation(description: "Loopback ready")
        let noConnection = expectation(description: "No socket opened")
        noConnection.isInverted = true
        listener.stateUpdateHandler = { if case .ready = $0 { readyExp.fulfill() } }
        listener.newConnectionHandler = { conn in
            noConnection.fulfill()
            conn.cancel()
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_group_dry_run",
            zcid: "native_zcid_group_dry_run",
            zcidIsNative: true
        )
        let mock = MockZolaTransport(session: session)
        let client = ZolaClient(session: session, transport: mock, voipLoopbackEndpoints: [("127.0.0.1", port)])

        let plain = try await client.sendGroupText(gid: 900_000_201, text: "Thử", clientIdMs: 99)
        XCTAssertTrue(plain.ok)
        XCTAssertTrue(plain.dryRun)
        XCTAssertFalse(plain.sent)
        XCTAssertEqual(plain.cmd, 201)
        XCTAssertEqual(plain.endpoint, "UXChatSocket:201")
        XCTAssertEqual(plain.desId, 900_000_201)
        XCTAssertEqual(plain.clientIdMs, 99)

        let mentioned = try await client.sendGroupText(
            gid: 900_000_201,
            text: "@All",
            mentions: [ZolaMention(type: 1, uid: -1, pos: 0, len: 4)],
            dryRun: true
        )
        XCTAssertEqual(mentioned.cmd, 207)
        XCTAssertFalse(mentioned.sent)

        await fulfillment(of: [noConnection], timeout: 0.3)
        XCTAssertTrue(mock.requests.isEmpty)
    }

    func testSendGroupTextRefusesExpiredSessionBeforeBuildingAnything() async throws {
        let client = try groupTestClient()
        let revoked = ZolaUnpackedChatElement(
            frameSize: 27,
            version: 2,
            checksum: 0,
            needAck: 0,
            msgType: 3,
            seqId: 9,
            srcId: 1,
            srcType: 3,
            cmd: 201,
            subCmd: 1,
            bodyData: Data(),
            retCode: -96
        )
        _ = try? await client.evaluateGroupTextAck(revoked)
        do {
            _ = try await client.sendGroupText(gid: 900_000_201, text: "Thử", dryRun: true)
            XCTFail("Expected sessionExpired")
        } catch ZolaError.sessionExpired {
            // Expected
        }
    }

    /// Authenticates a plaintext loopback session and lets `reply` answer each chat frame from the client.
    private func withGroupAckLoopback(
        reply: @escaping @Sendable (ZolaUnpackedChatElement, NWConnection) -> Void,
        _ body: (ZolaVoipSocketSession) async throws -> Void
    ) async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.test.group-ack")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let readyExp = expectation(description: "Loopback ready")
        listener.stateUpdateHandler = { if case .ready = $0 { readyExp.fulfill() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: serverQueue)
            var buf = Data()
            var upgraded = false
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { chunk, _, isComplete, _ in
                    if let chunk, !chunk.isEmpty {
                        buf.append(chunk)
                        if !upgraded, let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                            buf.removeSubrange(buf.startIndex..<r.upperBound)
                            upgraded = true
                            conn.send(content: Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        while upgraded, buf.count >= 23, let fLen = try? Data(buf.prefix(4)).readUInt32LE(at: 0), buf.count >= Int(fLen) {
                            let raw = Data(buf.prefix(Int(fLen)))
                            buf.removeFirst(Int(fLen))
                            guard let el = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }
                            if el.cmd == 1 {
                                let ack = ZolaCrypto.packServerChatElementFrame(srcId: el.srcId, msgType: 3, cmd: 1, subCmd: 5, seqId: el.seqId)
                                conn.send(content: ack.payload, completion: .contentProcessed { _ in })
                            } else if el.cmd != 2 {
                                reply(el, conn)
                            }
                        }
                    }
                    if !isComplete { pump() }
                }
            }
            pump()
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let srcId = Int32(100_000_103)
        let authen = ZolaCrypto.packChatElementFrame(
            bodyData: Data(),
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 1,
            subCmd: 5,
            seqId: 1
        )
        let sock = ZolaVoipSocketSession(
            selfUid: 100_000_103,
            authenPayload: authen.payload,
            endpoints: [("127.0.0.1", port)],
            onEvent: nil
        )
        try await sock.connectAndAuthenticate(perHostTimeout: 2.0)
        do {
            try await body(sock)
        } catch {
            await sock.close()
            throw error
        }
        await sock.close()
    }

    func testGroupTextEmptyMsgType4AckIsMatchedBySeqId() async throws {
        let client = try groupTestClient()
        try await withGroupAckLoopback(reply: { el, conn in
            let ack = ZolaCrypto.packServerChatElementFrame(srcId: el.srcId, msgType: 4, cmd: el.cmd, subCmd: el.subCmd, seqId: el.seqId)
            conn.send(content: ack.payload, completion: .contentProcessed { _ in })
        }) { sock in
            let seq = await sock.nextSeqId()
            let frame = try await client.buildGroupSendSocketFrame(gid: 900_000_201, text: "Thử", seqId: seq, clientIdMs: 5)
            let ack = try await sock.sendAndWait(
                rawPayload: frame.payload,
                expectedCmd: 201,
                timeoutSeconds: 2.0,
                ackSeqId: seq,
                ackCmds: [201, 207]
            )
            XCTAssertEqual(ack.msgType, 4)
            XCTAssertEqual(ack.seqId, seq)
            let evaluated = try await client.evaluateGroupTextAck(ack)
            XCTAssertTrue(evaluated.ok)
            XCTAssertNil(evaluated.serverErrorCode)
        }
    }

    func testGroupTextAckTimeoutIgnoresPushAndForeignSeqAndNeverReportsSuccess() async throws {
        let client = try groupTestClient()
        try await withGroupAckLoopback(reply: { el, conn in
            // A group push reusing our seqId/cmd, then a real ACK belonging to another request.
            let push = ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"data":{}}"#.utf8),
                srcId: 1,
                msgType: 1,
                cmd: 201,
                subCmd: 1,
                seqId: el.seqId
            )
            let foreign = ZolaCrypto.packServerChatElementFrame(srcId: el.srcId, msgType: 4, cmd: 201, subCmd: 1, seqId: el.seqId &+ 100)
            conn.send(content: push.payload + foreign.payload, completion: .contentProcessed { _ in })
        }) { sock in
            let seq = await sock.nextSeqId()
            let frame = try await client.buildGroupSendSocketFrame(gid: 900_000_201, text: "Thử", seqId: seq, clientIdMs: 5)
            do {
                let ack = try await sock.sendAndWait(
                    rawPayload: frame.payload,
                    expectedCmd: 201,
                    timeoutSeconds: 0.5,
                    ackSeqId: seq,
                    ackCmds: [201, 207]
                )
                XCTFail("Expected timeout, got \(ack)")
            } catch ZolaError.transport(let detail) {
                XCTAssertTrue(detail.contains("Quá thời gian"), detail)
            }
        }
    }

    func testGroupTextAckEvaluationFailsClosed() async throws {
        func element(msgType: Int8, cmd: Int16 = 207, retCode: Int32 = 0) -> ZolaUnpackedChatElement {
            ZolaUnpackedChatElement(
                frameSize: 27,
                version: 2,
                checksum: 0,
                needAck: 0,
                msgType: msgType,
                seqId: 9,
                srcId: 1,
                srcType: 3,
                cmd: cmd,
                subCmd: 1,
                bodyData: Data(),
                retCode: retCode
            )
        }
        let client = try groupTestClient()

        let confirmed = try await client.evaluateGroupTextAck(element(msgType: 4))
        XCTAssertTrue(confirmed.ok)

        // `checkValidResult:` only accepts `msgType = 4`.
        let wrongType = try await client.evaluateGroupTextAck(element(msgType: 3))
        XCTAssertFalse(wrongType.ok)
        XCTAssertNil(wrongType.serverErrorCode)

        let rejected = try await client.evaluateGroupTextAck(element(msgType: 3, retCode: 165))
        XCTAssertFalse(rejected.ok)
        XCTAssertEqual(rejected.serverErrorCode, 165)

        for code: Int32 in [102, -96] {
            let expiring = try groupTestClient()
            do {
                _ = try await expiring.evaluateGroupTextAck(element(msgType: 4, retCode: code))
                XCTFail("Expected sessionExpired for \(code)")
            } catch ZolaError.sessionExpired(let thrown, _, _) {
                XCTAssertEqual(thrown, Int(code))
            }
            let after = await expiring.session
            XCTAssertTrue(after.isExpired)
            XCTAssertEqual(after.expiredCode, Int(code))
        }
    }
    #endif

    func testIncomingMentionsDecodeFromServerJSON() throws {
        func message(_ extra: [String: Any]) -> ZolaMessage {
            var item: [String: Any] = [
                "msgId": "9001",
                "cliMsgId": "9002",
                "uidFrom": "100000102",
                "idTo": "900000201",
                "msgType": "webchat",
                "content": "😀 @Lan @All",
                "ts": "1793000000000",
            ]
            extra.forEach { item[$0.key] = $0.value }
            return ZolaMessage.fromRawItem(item, selfUid: 100_000_103, knownGroupIds: [900_000_201])
        }
        let lan = ZolaMention(type: 0, uid: 100_000_102, pos: 3, len: 4)
        let all = ZolaMention(type: 1, uid: -1, pos: 8, len: 4)
        let lanJSON: [String: Any] = ["type": 0, "uid": "100000102", "pos": 3, "len": 4]
        let allJSON: [String: Any] = ["type": 1, "uid": "-1", "gUid": "-1", "pos": 8, "len": 4]

        XCTAssertEqual(message(["mentions": [allJSON, lanJSON]]).mentions, [lan, all])
        XCTAssertEqual(
            message(["mentions": #"[{"type":0,"uid":100000102,"pos":3,"len":4}]"#]).mentions,
            [lan]
        )
        XCTAssertEqual(message(["mention": ["0_100000102": lanJSON, "1_-1": allJSON]]).mentions, [lan, all])
        XCTAssertEqual(message(["mentions": [["type": 0, "uid": "0", "gUid": "enc", "pos": 3, "len": 4]]]).mentions, [])
        XCTAssertEqual(message([:]).mentions, [])
    }

    func testMessageCacheWithoutMentionsStillDecodes() throws {
        let legacy = #"{"id":1,"threadId":2,"text":"Cũ"}"#
        let decoded = try JSONDecoder().decode(ZolaMessage.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.mentions, [])

        let withMention = ZolaMessage(
            id: 1,
            cliMsgId: 2,
            threadId: 3,
            isGroup: true,
            senderId: 4,
            toId: 3,
            tsMs: 5,
            text: "@All",
            isSelf: false,
            mentions: [ZolaMention(type: 1, uid: -1, pos: 0, len: 4)]
        )
        let round = try JSONDecoder().decode(ZolaMessage.self, from: JSONEncoder().encode(withMention))
        XCTAssertEqual(round, withMention)
    }

    func testGroupSettingFlagsAreOptionalAndParsed() throws {
        let full = ZolaGroup.fromServerDict([
            "groupId": "900000201",
            "name": "Nhóm",
            "setting": ["lockSendMsg": 1, "lockViewMember": 0, "joinAppr": 1, "signAdminMsg": 1, "setTopicOnly": 0],
            "extraInfo": ["mentionAll": 2],
        ])
        XCTAssertEqual(full.lockSendMsg, true)
        XCTAssertEqual(full.lockViewMember, false)
        XCTAssertEqual(full.joinAppr, 1)
        XCTAssertEqual(full.signAdminMsg, true)
        XCTAssertEqual(full.setTopicOnly, false)
        XCTAssertEqual(full.ruleMentionAll, 2)

        let fromString = ZolaGroup.fromServerDict(["groupId": "1", "groupSetting": #"{"lockViewMember":1}"#])
        XCTAssertEqual(fromString.lockViewMember, true)

        let bare = ZolaGroup.fromServerDict(["groupId": "1"])
        XCTAssertNil(bare.lockSendMsg)
        XCTAssertNil(bare.joinAppr)
        XCTAssertNil(bare.ruleMentionAll)

        let legacy = #"{"gid":1,"name":"Cũ","desc":"","avatarUrl":"","fullAvatarUrl":"","totalMembers":0,"creatorId":0,"adminIds":[],"memberIds":[],"members":[],"isE2ee":false,"groupType":0,"versionTs":0}"#
        let decoded = try JSONDecoder().decode(ZolaGroup.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.lockSendMsg)
    }

    /// Expected bytes are `getRequestData` dumped from the real Zalo iOS 261002802 client.
    func testChatTagFramesMatchRealClientRequestBytes() throws {
        func body(_ frame: ZolaChatElementFrame) throws -> Data {
            let parsed = try ZolaCrypto.unpackChatElementFrame(frame.payload)
            return parsed.decodedBodyData
        }
        func hex(_ text: String) -> Data {
            Data(text.split(separator: " ").map { UInt8($0, radix: 16)! })
        }
        let prefix = "02 32 96 8e 0f 00 00 00 00 01 00"

        let list = ZolaCrypto.packChatTagListFrame(version: 7, loadedTagIds: [3], srcId: 1, seqId: 1)
        XCTAssertEqual(try body(list), hex("\(prefix) 07 00 00 00 01 00 00 00 03 00 00 00"))

        let update = ZolaCrypto.packChatTagUpdateConversationFrame(
            threadId: Int32(100_000_102),
            messageType: 0,
            addTagIds: [3, 4],
            removeTagIds: [9],
            srcId: 1,
            seqId: 1
        )
        XCTAssertEqual(try body(update), hex("\(prefix) 66 e1 f5 05 00 02 00 00 00 03 00 00 00 04 00 00 00 01 00 00 00 09 00 00 00"))

        let create = try ZolaCrypto.packChatTagCreateFrame(text: "Khach moi", color: "#0068FF", srcId: 1, seqId: 1)
        XCTAssertEqual(
            try body(create),
            hex("\(prefix) 01 00 00 00 26 00 00 00") + Data(##"{"color":"#0068FF","text":"Khach moi"}"##.utf8)
        )

        let delete = ZolaCrypto.packChatTagDeleteFrame(tagIds: [5, 6], srcId: 1, seqId: 1)
        XCTAssertEqual(try body(delete), hex("\(prefix) 02 00 00 00 05 00 00 00 06 00 00 00"))
    }

    #if canImport(Network) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)

    #endif

    // MARK: - Per-Device Identity, ZDK 2001.* Minting & OTP 2003 Regression Tests

    func testPerDeviceIdentityPersistencePkcs7ZcidAndUserAgentCompatibility() throws {
        // 1. Legacy defaultProfile.zcid continues to yield exact defaultIDFA & userAgentNative byte-for-byte
        let legacyExtracted = ZolaCrypto.extractZCIDIdentity(zcid: ZolaDeviceIdentity.defaultProfile.zcid)
        XCTAssertEqual(legacyExtracted.imei, ZolaConstants.defaultIDFA)
        XCTAssertEqual(legacyExtracted.platform, "iP16Pro_@26.3.1_@NJ")
        XCTAssertEqual(
            ZolaCrypto.userAgent(forZCID: ZolaDeviceIdentity.defaultProfile.zcid),
            ZolaConstants.userAgentNative
        )

        // 2. PKCS#7 generateZCID + extractZCIDIdentity round-trips cleanly across all 16 byte-alignment remainders
        for extraLen in 0..<16 {
            let modelSuffix = String(repeating: "X", count: extraLen)
            let idfa = UUID().uuidString.uppercased()
            let platform = ZolaCrypto.platformString(shortModel: "iP17Pro,Test\(modelSuffix)", osVersion: "26.1.2")
            XCTAssertFalse(platform.contains(","), "Platform string must never contain commas")
            let zcid = try ZolaCrypto.generateZCID(idfa: idfa, platform: platform, timestampMs: 1_793_550_000_123)
            let roundTrip = ZolaCrypto.extractZCIDIdentity(zcid: zcid)
            XCTAssertEqual(roundTrip.imei, idfa)
            XCTAssertEqual(roundTrip.platform, platform)
        }

        // 3. Per-device identity store persists stable IDFA + ZCID per hardware and reflects device family in User-Agent
        let store = ZolaDeviceIdentityStore(inMemory: true)
        let dev1 = ZolaDeviceIdentity.currentDevice(
            store: store,
            rawMachineOverride: "iPhone16,1",
            osVersionOverride: "18.4.1",
            nowMs: 1_793_550_001_000
        )
        XCTAssertNotEqual(dev1.idfa, ZolaConstants.defaultIDFA)
        XCTAssertNotEqual(dev1.zcid, ZolaDeviceIdentity.defaultProfile.zcid)
        XCTAssertEqual(dev1.hardwareModel, "iPhone16,1")
        XCTAssertEqual(dev1.deviceName, "iPhone 15 Pro")
        XCTAssertEqual(dev1.model, "iP15Pro_@18.4.1_@NJ")
        XCTAssertEqual(ZolaCrypto.userAgent(forZCID: dev1.zcid), "Zalo/261002 (iPhone; iOS 18.4.1; Scale/3.00)")

        let dev2 = ZolaDeviceIdentity.currentDevice(
            store: store,
            rawMachineOverride: "iPhone16,1",
            osVersionOverride: "18.5",
            nowMs: 1_793_600_000_000
        )
        XCTAssertEqual(dev2.idfa, dev1.idfa, "IDFA must persist across launches and OS updates")
        XCTAssertEqual(dev2.zcid, dev1.zcid, "zcid must remain stable once generated in Keychain")
        XCTAssertEqual(dev2.model, dev1.model, "model must stay aligned with persisted zcid platform")

        // 4. iPad hardware produces iPad User-Agent & Scale/2.00; ZolaRequestBuilder honors session.zcid
        let padStore = ZolaDeviceIdentityStore(inMemory: true)
        let padDev = ZolaDeviceIdentity.currentDevice(
            store: padStore,
            rawMachineOverride: "iPad16,3",
            osVersionOverride: "18.4",
            nowMs: 1_793_550_002_000
        )
        XCTAssertEqual(padDev.deviceName, "iPad Pro")
        XCTAssertEqual(ZolaCrypto.userAgent(forZCID: padDev.zcid), "Zalo/261002 (iPad; iOS 18.4; Scale/2.00)")

        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "p-5E.100000103.a1.PAD_SK",
            cryptKey: Data(repeating: 0x55, count: 16),
            zcid: padDev.zcid,
            zcidIsNative: true
        )
        let req = try ZolaRequestBuilder.buildEncryptedRequest(
            url: "https://friend-m.zaloapp.com/api/friend/getlist",
            innerParams: ["imei": ZolaCrypto.extractZCIDIdentity(zcid: session.zcid).imei],
            session: session,
            method: "GET"
        )
        XCTAssertEqual(req.value(forHTTPHeaderField: "user-agent"), "Zalo/261002 (iPad; iOS 18.4; Scale/2.00)")
    }

    func testZdkDeviceTrackerTwoStepMintingAndCaching() async throws {
        final class MockZdkAndLoginTransport: ZolaNetworkTransport, @unchecked Sendable {
            var sdkCallCount = 0
            var idCallCount = 0
            var capturedPrecheckDevid: String?

            private func parseForm(_ req: URLRequest) -> [String: String] {
                guard let body = req.httpBody,
                      let str = String(data: body, encoding: .utf8) else { return [:] }
                var out: [String: String] = [:]
                for pair in str.split(separator: "&", omittingEmptySubsequences: false) {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    if kv.count == 2 {
                        let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                        let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        out[k] = v
                    }
                }
                return out
            }

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                let form = parseForm(request)
                let resp: [String: Any]
                switch path {
                case "/sdk/mobile/ios":
                    sdkCallCount += 1
                    XCTAssertEqual(form["pl"], "ios")
                    XCTAssertEqual(form["appId"], "0")
                    XCTAssertEqual(form["sdkv"], "4.3.0730")
                    resp = [
                        "error": 0,
                        "data": [
                            "sdkId": "sdk_unit_9911",
                            "privateKey": "unused_priv_key",
                        ] as [String: Any],
                    ]
                case "/id/mobile/ios":
                    idCallCount += 1
                    let sigParams: [String: String] = [
                        "pl": form["pl"] ?? "",
                        "appId": form["appId"] ?? "",
                        "device": form["device"] ?? "",
                        "data": form["data"] ?? "",
                        "viewer": form["viewer"] ?? "",
                        "ts": form["ts"] ?? "",
                        "sdkId": form["sdkId"] ?? "",
                    ]
                    let expectedSig = ZolaCrypto.makeSignature(params: sigParams, apiSecret: "@#centralize#@")
                    XCTAssertEqual(form["sig"], expectedSig, "ZDK /id/mobile/ios signature must match @#centralize#@")
                    let futureExp = Int64(Date().timeIntervalSince1970 * 1000) + 86_400_000
                    resp = [
                        "error": 0,
                        "data": [
                            "deviceId": "2001.SSZ-MintedPerDeviceUnitToken-99.1",
                            "expire": futureExp,
                        ] as [String: Any],
                    ]
                case "/api/register/verifyClientInfo":
                    let zcidHeader = "1_" + (request.value(forHTTPHeaderField: "zcid") ?? "")
                    if let hex = form["data"],
                       let clear = try? ZolaCrypto.decryptZCIDParams(hex, zcid: zcidHeader) {
                        capturedPrecheckDevid = clear["device_identifier"] as? String
                    }
                    resp = [
                        "error_code": 0,
                        "data": ["sessionToken": "zk000.precheck_zdk_ok"] as [String: Any],
                    ]
                default:
                    resp = ["error_code": 0, "data": [:] as [String: Any]]
                }
                return (200, try JSONSerialization.data(withJSONObject: resp))
            }
        }

        let store = ZolaDeviceIdentityStore(inMemory: true)
        _ = ZolaDeviceIdentity.currentDevice(
            store: store,
            rawMachineOverride: "iPhone18,1",
            osVersionOverride: "26.1",
            nowMs: 1_793_550_010_000
        )
        let transport = MockZdkAndLoginTransport()
        let cfg = ZolaLoginConfig(enableZDKMintingOnCustomTransport: true)
        let client = ZolaLoginClient(config: cfg, identity: nil, identityStore: store, transport: transport)

        let pre1 = try await client.precheck(phone: "0901234567")
        XCTAssertEqual(pre1.sessionToken, "zk000.precheck_zdk_ok")
        XCTAssertEqual(transport.sdkCallCount, 1)
        XCTAssertEqual(transport.idCallCount, 1)
        XCTAssertEqual(transport.capturedPrecheckDevid, "2001.SSZ-MintedPerDeviceUnitToken-99.1")
        XCTAssertEqual(store.load()?.deviceIdentifier, "2001.SSZ-MintedPerDeviceUnitToken-99.1")

        // Second precheck on a fresh ZolaLoginClient sharing the same store must reuse cached 2001.* without re-minting
        let client2 = ZolaLoginClient(config: cfg, identity: nil, identityStore: store, transport: transport)
        _ = try await client2.precheck(phone: "0901234567")
        XCTAssertEqual(transport.sdkCallCount, 1)
        XCTAssertEqual(transport.idCallCount, 1)
    }

    func testMultiBlockCbcZotpUnwrapAnd2003FallthroughPrevention() async throws {
        let zcid = ZolaDeviceIdentity.defaultProfile.zcid
        let multiBlockZotp: [String: Any] = [
            "activationToken": "zk2fav2.cbc_zotp_activation_tok_8888",
            "activationType": 6,
            "activationNumber": 6,
            "timeout": 90,
            "title": "Xác minh đăng nhập từ thiết bị gần đây trên Zalo",
        ]
        let encryptedZotpHex = try ZolaCrypto.encryptZCIDPrefixCBC(multiBlockZotp, zcid: zcid)
        XCTAssertGreaterThan(encryptedZotpHex.count, 64, "Must span multiple 16-byte AES blocks so ECB alone would fail")

        final class ZotpAnd2003Transport: ZolaNetworkTransport, @unchecked Sendable {
            let zotpHex: String
            var paths: [String] = []
            init(zotpHex: String) { self.zotpHex = zotpHex }

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                paths.append(path)
                let resp: [String: Any]
                switch path {
                case "/api/register/verifyClientInfo":
                    resp = ["error_code": 0, "data": ["sessionToken": "zk000.req_tok_zotp"] as [String: Any]]
                case "/api/register/getActivationCode":
                    resp = [
                        "error_code": 0,
                        "zotp": zotpHex,
                        "data": [:] as [String: Any],
                    ]
                case "/api/register/activeAccountByActivationCode":
                    // Simulate server returning error_code = 0 with a non-verification `token` and no `session_key`:
                    // previously this fell through to `/api/register/verifyAccount` and produced `Invalid token (mã 2003)`.
                    resp = [
                        "error_code": 0,
                        "data": ["token": "unrelated_tok_not_verif"] as [String: Any],
                    ]
                case "/api/register/verifyAccount":
                    resp = ["error_code": 2003, "error_message": "Invalid token"]
                default:
                    resp = ["error_code": 0, "data": [:] as [String: Any]]
                }
                return (200, try JSONSerialization.data(withJSONObject: resp))
            }
        }

        let transport = ZotpAnd2003Transport(zotpHex: encryptedZotpHex)
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        let reqRes = try await client.requestVerificationCode(phone: "0901234567", method: .recentDevice)
        XCTAssertTrue(reqRes.sent)
        XCTAssertEqual(reqRes.challenge.activationToken, "zk2fav2.cbc_zotp_activation_tok_8888")
        XCTAssertEqual(reqRes.challenge.timeoutSeconds, 90)
        XCTAssertFalse(reqRes.challenge.isForgotPassword)

        let submitOutcome = try await client.submitVerificationCode(
            phone: "0901234567",
            password: "secret",
            code: "878931",
            challenge: reqRes.challenge
        )
        guard case let .rejected(ec, msg, _) = submitOutcome else {
            return XCTFail("Expected .rejected when neither session_key nor verificationToken was issued, got \(submitOutcome)")
        }
        XCTAssertEqual(ec, 2003)
        XCTAssertEqual(msg, ZolaLoginClient.expiredVerificationCodeMessage)
        XCTAssertFalse(transport.paths.contains("/api/register/verifyAccount"), "Must never fall through to verifyAccount without an explicit verificationToken")
        let cleared = await client.latestChallenge()
        XCTAssertNil(cleared?.activationToken, "Expired activationToken must be cleared on 2003")

        // Also verify 2036 / 2048 / 2052 are rejected with explicit guidance instead of entering generic OTP challenge
        let out2048 = await client.parseLoginResponse(
            obj: ["error_code": 2048, "error_message": "Security check"],
            text: "{}",
            sessionToken: nil
        )
        guard case let .rejected(ec2048, msg2048, _) = out2048 else {
            return XCTFail("Expected .rejected for 2048 security check, got \(out2048)")
        }
        XCTAssertEqual(ec2048, 2048)
        XCTAssertEqual(msg2048, ZolaLoginClient.securityWebCheckRequiredMessage)
    }

    private final class SecureVerificationTransport: ZolaNetworkTransport, @unchecked Sendable {
        var paths: [String] = []
        var verifyAccountInner: [String: Any]?
        var pathsReturning2048: Set<String> = ["/api/register/getActivationCode", "/api/register/activePasswordWithQuestion"]
        var activationResponse: [String: Any] = [
            "error_code": 2048,
            "error_message": "Security check",
            "data": [
                "secureUrl": "https://id.zaloapp.com/verify?session=abc",
                "sessionToken": "zk000.h5_session",
                "pwd_token": "pwd.h5",
            ] as [String: Any],
        ]

        func execute(_ request: URLRequest) async throws -> (Int, Data) {
            let path = request.url?.path ?? ""
            paths.append(path)
            let resp: [String: Any]
            switch path {
            case "/api/register/verifyClientInfo":
                resp = ["error_code": 0, "data": ["sessionToken": "zk000.req_tok"] as [String: Any]]
            case _ where pathsReturning2048.contains(path):
                resp = activationResponse
            case "/api/register/verifyAccount":
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let hex = body.split(separator: "&")
                    .first { $0.hasPrefix("data=") }
                    .map { String($0.dropFirst(5)) } ?? ""
                verifyAccountInner = try ZolaCrypto.decryptZCIDParams(hex, zcid: ZolaDeviceIdentity.defaultProfile.zcid)
                resp = ["error_code": 2002, "error_message": "stop here"]
            default:
                resp = ["error_code": 0, "data": [:] as [String: Any]]
            }
            return (200, try JSONSerialization.data(withJSONObject: resp))
        }
    }

    func testCode2048RoutesToH5VerificationEvenWithPwdToken() async throws {
        let transport = SecureVerificationTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        let outcome = try await client.login(phone: "0901234567", password: "secret")
        guard case let .secureVerification(secure) = outcome else {
            return XCTFail("2048 with secureUrl must open the H5 page, got \(outcome)")
        }
        XCTAssertEqual(secure.secureUrl, "https://id.zaloapp.com/verify?session=abc")
        XCTAssertEqual(secure.sessionToken, "zk000.h5_session")
        XCTAssertEqual(secure.pwdToken, "pwd.h5")
        let afterLogin = await client.latestChallenge()
        XCTAssertNil(afterLogin, "2048 must not create an OTP challenge")

        let request = try await client.requestVerificationCode(phone: "0901234567", method: .recentDevice)
        XCTAssertFalse(request.sent)
        XCTAssertEqual(request.errorCode, 2048)
        XCTAssertEqual(request.secureVerification?.secureUrl, secure.secureUrl)
    }

    func testSecureVerificationCookiesMatchNativeWebView() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secure = ZolaSecureVerification(
            secureUrl: "https://id.zaloapp.com/verify?session=abc",
            sessionToken: "zk000.h5_session"
        )
        let cookies = Dictionary(uniqueKeysWithValues: secure.webCookies(now: now).map { ($0.name, $0) })

        XCTAssertEqual(cookies["zacc_session"]?.value, "zk000.h5_session")
        XCTAssertEqual(cookies["zlink3rd"]?.value, "https://id.zaloapp.com/verify?session=abc")
        XCTAssertEqual(cookies["zacc_session"]?.domain, "id.zaloapp.com")
        XCTAssertEqual(cookies["zacc_session"]?.path, "/")
        XCTAssertEqual(cookies["zlink3rd"]?.expiresDate, now.addingTimeInterval(21 * 24 * 3600))
        XCTAssertTrue(ZolaSecureVerification(secureUrl: "https://id.zaloapp.com/v").webCookies().isEmpty)
    }

    func testPrecheck2048KeepsH5TokenAwayFromPasswordStep() async throws {
        final class Precheck2048Transport: ZolaNetworkTransport, @unchecked Sendable {
            var paths: [String] = []
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                paths.append(request.url?.path ?? "")
                let resp: [String: Any] = [
                    "error_code": 2048,
                    "data": ["secureUrl": "https://id.zaloapp.com/v", "sessionToken": "zk000.h5"] as [String: Any],
                ]
                return (200, try JSONSerialization.data(withJSONObject: resp))
            }
        }
        let transport = Precheck2048Transport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        let outcome = try await client.login(phone: "0901234567", password: "secret")
        guard case let .secureVerification(secure) = outcome else {
            return XCTFail("Expected the H5 page, got \(outcome)")
        }
        XCTAssertEqual(secure.sessionToken, "zk000.h5")
        XCTAssertFalse(transport.paths.contains("/api/register/activePasswordWithQuestion"))
    }

    func testSecureVerificationWithoutPasswordFollowsOtpPath() async throws {
        let transport = SecureVerificationTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        transport.pathsReturning2048.insert("/api/register/activeAccountByActivationCode")
        let challenge = ZolaLoginChallenge(
            fields: ["otp"],
            sessionToken: nil,
            activationToken: "zk000.act",
            activationType: 6,
            isForgotPassword: false
        )
        let outcome = try await client.submitVerificationCode(
            phone: "0901234567",
            password: "",
            code: "123456",
            challenge: challenge
        )
        guard case let .secureVerification(secure) = outcome else {
            return XCTFail("Expected the H5 page, got \(outcome)")
        }

        _ = try await client.completeSecureVerification(
            phone: "0901234567",
            password: "",
            verification: secure,
            result: ZolaSecureVerificationResult(verificationToken: "tok-otp", verificationType: 1)
        )
        let inner = try XCTUnwrap(transport.verifyAccountInner)
        XCTAssertNil(inner["password"], "Native omits password on the OTP path")
        XCTAssertEqual(inner["verificationToken"] as? String, "tok-otp")
        XCTAssertEqual(inner["pwd_token"] as? String, "pwd.h5")
        XCTAssertEqual(inner["activation_type"] as? String, "6")
        XCTAssertNil(inner["code"], "The accepted code is not part of this request")
    }

    func testLoginWithoutCryptKeyIsNotReportedAsSuccess() async throws {
        final class MissingKeysTransport: ZolaNetworkTransport, @unchecked Sendable {
            var doLoginCalls = 0
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let resp: [String: Any]
                switch request.url?.path ?? "" {
                case "/api/register/verifyClientInfo":
                    resp = ["error_code": 0, "data": ["sessionToken": "zk000.req"] as [String: Any]]
                case "/api/login/doLogin":
                    doLoginCalls += 1
                    throw URLError(.timedOut)
                default:
                    resp = ["error_code": 0, "data": ["user_id": 1234, "session_key": "sk", "token": "tok"] as [String: Any]]
                }
                return (200, try JSONSerialization.data(withJSONObject: resp))
            }
        }
        let transport = MissingKeysTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)

        let outcome = try await client.login(phone: "0901234567", password: "secret")
        guard case let .rejected(_, message, _) = outcome else {
            return XCTFail("A session without CrypKey cannot send messages, got \(outcome)")
        }
        XCTAssertEqual(message, ZolaLoginClient.sessionKeysMissingMessage)
        XCTAssertEqual(transport.doLoginCalls, 2, "Network failures get one retry")
    }

    func testCode2048DuringOtpSubmitStillOpensH5() async throws {
        let transport = SecureVerificationTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let challenge = ZolaLoginChallenge(
            fields: ["otp"],
            sessionToken: nil,
            activationToken: "zk000.act",
            isForgotPassword: false
        )
        transport.pathsReturning2048.insert("/api/register/activeAccountByActivationCode")

        let outcome = try await client.submitVerificationCode(
            phone: "0901234567",
            password: "secret",
            code: "123456",
            challenge: challenge
        )
        guard case .secureVerification = outcome else {
            return XCTFail("OTP step must keep the H5 outcome, got \(outcome)")
        }
        let afterSubmit = await client.latestChallenge()
        XCTAssertNil(afterSubmit?.activationToken, "An accepted code must not stay available for a second submit")
    }

    func testCode2048WithPwdTokenButNoUrlIsNotAnOtpChallenge() async throws {
        let client = ZolaLoginClient(identity: .defaultProfile, transport: SecureVerificationTransport())
        let outcome = await client.parseLoginResponse(
            obj: ["error_code": 2048, "data": ["pwd_token": "pwd.h5"] as [String: Any]],
            text: "{}",
            sessionToken: nil
        )
        guard case let .rejected(ec, _, _) = outcome else {
            return XCTFail("Expected .rejected, got \(outcome)")
        }
        XCTAssertEqual(ec, 2048)
    }

    func testCode2048IgnoresNonHttpsSecureUrl() async throws {
        let client = ZolaLoginClient(identity: .defaultProfile, transport: SecureVerificationTransport())
        let outcome = await client.parseLoginResponse(
            obj: ["error_code": 2048, "data": ["secureUrl": "http://example.com/x"] as [String: Any]],
            text: "{}",
            sessionToken: nil
        )
        guard case let .rejected(ec, _, _) = outcome else {
            return XCTFail("Non-https secureUrl must not be opened, got \(outcome)")
        }
        XCTAssertEqual(ec, 2048)
    }

    func testSecureVerificationBridgeMessageParsing() {
        let nested: [String: Any] = [
            "action": ZolaSecureVerificationResult.bridgeAction,
            "options": [
                "error_code": 0,
                "data": ["verificationToken": " tok-1 ", "verificationType": 1] as [String: Any],
            ] as [String: Any],
        ]
        XCTAssertEqual(
            ZolaSecureVerificationResult.parse(bridgeMessage: nested),
            ZolaSecureVerificationResult(verificationToken: "tok-1", verificationType: 1)
        )

        let jsonStrings: [String: Any] = [
            "options": "{\"error_code\":0,\"data\":{\"verificationToken\":\"tok-2\",\"verificationType\":\"2\",\"pwd_token\":\"p2\"}}",
        ]
        XCTAssertEqual(
            ZolaSecureVerificationResult.parse(bridgeMessage: jsonStrings),
            ZolaSecureVerificationResult(verificationToken: "tok-2", verificationType: 2, pwdToken: "p2")
        )

        XCTAssertEqual(
            ZolaSecureVerificationResult.parse(bridgeMessage: ["options": ["error_code": 2003] as [String: Any]])?.errorCode,
            2003
        )
        XCTAssertNil(ZolaSecureVerificationResult.parse(bridgeMessage: ["action": "action.show.toast"]))

        // Shape sent by `ZaloJavaScriptInterface.jsCall(jstoken, action, access_token, options, callback)`.
        let jsCall: [String: Any] = [
            "jstoken": "js",
            "action": ZolaSecureVerificationResult.bridgeAction,
            "access_token": "",
            "options": "{\"error_code\":0,\"data\":\"{\\\"verificationToken\\\":\\\"tok-3\\\",\\\"verificationType\\\":1}\"}",
        ]
        XCTAssertEqual(
            ZolaSecureVerificationResult.parse(bridgeMessage: jsCall),
            ZolaSecureVerificationResult(verificationToken: "tok-3", verificationType: 1)
        )
    }

    func testCompleteSecureVerificationFollowsVerificationType() async throws {
        let transport = SecureVerificationTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        let secure = ZolaSecureVerification(secureUrl: "https://id.zaloapp.com/verify", pwdToken: "pwd.h5")

        _ = try await client.completeSecureVerification(
            phone: "0901234567",
            password: "secret",
            verification: secure,
            result: ZolaSecureVerificationResult(verificationToken: "tok-1", verificationType: 1)
        )
        XCTAssertEqual(transport.verifyAccountInner?["verificationToken"] as? String, "tok-1")
        XCTAssertEqual(transport.verifyAccountInner?["pwd_token"] as? String, "pwd.h5", "Must keep pwd_token from the 2048 response")
        XCTAssertNil(transport.verifyAccountInner?["code"], "No activation code exists on this path")

        let reactivate = try await client.completeSecureVerification(
            phone: "0901234567",
            password: "secret",
            verification: secure,
            result: ZolaSecureVerificationResult(verificationToken: "", verificationType: 2)
        )
        guard case let .challenge(_, _, message) = reactivate else {
            return XCTFail("verificationType 2 must return to OTP methods, got \(reactivate)")
        }
        XCTAssertEqual(message, ZolaLoginClient.reactivationRequiredMessage)

        // Native reads `verificationType` first, so a usable result still counts with a non-zero `error_code`.
        transport.verifyAccountInner = nil
        _ = try await client.completeSecureVerification(
            phone: "0901234567",
            password: "secret",
            verification: secure,
            result: ZolaSecureVerificationResult(errorCode: 7, verificationToken: "tok-3", verificationType: 1)
        )
        XCTAssertEqual(transport.verifyAccountInner?["verificationToken"] as? String, "tok-3")

        transport.paths.removeAll()
        let failed = try await client.completeSecureVerification(
            phone: "0901234567",
            password: "secret",
            verification: secure,
            result: ZolaSecureVerificationResult(errorCode: 2003, verificationToken: "", verificationType: 0)
        )
        guard case let .rejected(ec, _, _) = failed else {
            return XCTFail("Page failure must be surfaced, got \(failed)")
        }
        XCTAssertEqual(ec, 2003)
        XCTAssertTrue(transport.paths.isEmpty, "A failed page result must not call the server")
    }

    func testDiagnosticsNeverContainValues() async throws {
        let transport = SecureVerificationTransport()
        let client = ZolaLoginClient(identity: .defaultProfile, transport: transport)
        _ = try await client.login(phone: "0901234567", password: "secret")

        let joined = await client.diagnostics().joined(separator: "\n")
        XCTAssertTrue(joined.contains("ec=2048"))
        XCTAssertTrue(joined.contains("pwd_token"), "Key names are needed to diagnose the next failure")
        XCTAssertTrue(joined.contains("host=id.zaloapp.com"))
        XCTAssertFalse(joined.contains("pwd.h5"))
        XCTAssertFalse(joined.contains("zk000"))
        XCTAssertFalse(joined.contains("session=abc"))
    }

    func testReviewerEdgeCases_DoLoginConsumedToken_ZDKRecovery_TwoXScale_AndMakeSession() async throws {
        // 1. @2x iPhone model (`iP11`) uses Scale/2.00 when scale is omitted
        let ip11Zcid = try ZolaCrypto.generateZCID(
            idfa: "11223344-5566-7788-99AA-BBCCDDEEFF00",
            platform: "iP11_@26.1_@NJ",
            timestampMs: 1_762_000_000_000
        )
        XCTAssertEqual(
            ZolaCrypto.userAgent(forZCID: ip11Zcid),
            "Zalo/261002 (iPhone; iOS 26.1; Scale/2.00)"
        )

        // 2. ZolaLoginResult.makeSession() preserves accessToken and loginPhone
        let loginRes = ZolaLoginResult(
            userId: 100_000_103,
            token: "access_tok_999",
            sessionKey: "sess_key_999",
            zcid: ip11Zcid,
            cryptKey: Data(repeating: 0x33, count: 16),
            loginPhone: "84901234567"
        )
        let builtSession = try loginRes.makeSession()
        XCTAssertEqual(builtSession.accessToken, "access_tok_999")
        XCTAssertEqual(builtSession.loginPhone, "84901234567")

        // 3. ZDK recovery: expired 2001.* clears immediately on error, and rejected cached sdkId triggers /sdk/mobile/ios re-registration
        final class ZDKRecoveryTransport: ZolaNetworkTransport, @unchecked Sendable {
            private let lock = NSLock()
            var failAll = true
            var sdkCalls = 0
            var idCalls = 0

            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                let bodyStr = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let shouldFail = lock.withLock { failAll }
                if shouldFail {
                    throw URLError(.notConnectedToInternet)
                }
                if path.hasSuffix("/sdk/mobile/ios") {
                    lock.withLock { sdkCalls += 1 }
                    return (200, try JSONSerialization.data(withJSONObject: ["data": ["sdkId": "fresh_sdk_777"]]))
                }
                if path.hasSuffix("/id/mobile/ios") {
                    lock.withLock { idCalls += 1 }
                    if bodyStr.contains("sdkId=stale_sdk_000") {
                        return (200, try JSONSerialization.data(withJSONObject: ["error_code": -1, "data": [:] as [String: Any]]))
                    }
                    return (200, try JSONSerialization.data(withJSONObject: [
                        "data": ["deviceId": "2001.recovered_dev_id", "expire": Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000]
                    ]))
                }
                return (404, Data())
            }
        }

        let store = ZolaDeviceIdentityStore(inMemory: true)
        store.save(ZolaStoredDeviceRecord(
            idfa: "11223344-5566-7788-99AA-BBCCDDEEFF00",
            vendorId: "AABBCCDD-1122-3344-5566-77889900AABB",
            zcid: ip11Zcid,
            zcidTimestampMs: 1_762_000_000_000,
            hardwareModel: "iPhone12,1",
            platformModel: "iP11_@26.1_@NJ",
            zdkSdkId: "stale_sdk_000",
            deviceIdentifier: "2001.expired_old_id",
            deviceIdentifierExpiresAtMs: 1_000 // already expired
        ))
        let zdkTransport = ZDKRecoveryTransport()
        var cfg = ZolaLoginConfig()
        cfg.enableZDKMintingOnCustomTransport = true
        let zdkIdentity = ZolaDeviceIdentity(
            idfa: "11223344-5566-7788-99AA-BBCCDDEEFF00",
            zcid: ip11Zcid,
            deviceIdentifier: "2001.expired_old_id",
            model: "iP11_@26.1_@NJ",
            deviceName: "iPhone 11",
            width: 414,
            height: 896,
            vendorId: "AABBCCDD-1122-3344-5566-77889900AABB",
            hardwareModel: "iPhone12,1",
            scale: "2.00"
        )
        let zdkClient = ZolaLoginClient(config: cfg, identity: zdkIdentity, identityStore: store, transport: zdkTransport)
        let offlineDevId = await zdkClient.ensureDeviceIdentifier()
        XCTAssertEqual(offlineDevId, "", "Must never return an expired 2001.* token when refresh fails")
        XCTAssertNil(store.load()?.deviceIdentifier)

        zdkTransport.failAll = false
        let recoveredDevId = await zdkClient.ensureDeviceIdentifier()
        XCTAssertEqual(recoveredDevId, "2001.recovered_dev_id")
        XCTAssertEqual(zdkTransport.sdkCalls, 1, "Rejected cached sdkId must trigger /sdk/mobile/ios re-registration")
        XCTAssertEqual(zdkTransport.idCalls, 2)

        // 4. passwordLogin must NOT send consumed session_token into /api/login/doLogin
        final class DoLoginInspectTransport: ZolaNetworkTransport, @unchecked Sendable {
            let zcid: String
            var doLoginInner: [String: Any]?
            init(zcid: String) { self.zcid = zcid }
            func execute(_ request: URLRequest) async throws -> (Int, Data) {
                let path = request.url?.path ?? ""
                let bodyStr = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
                var inner: [String: Any] = [:]
                for pair in bodyStr.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2, kv[0] == "data" {
                        let hexStr = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        if let dict = try? ZolaCrypto.decryptZCIDParams(hexStr, zcid: zcid) {
                            inner = dict
                        }
                    }
                }
                if path == "/api/register/verifyClientInfo" {
                    return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": ["session_token": "zk000.once_tok"]]))
                }
                if path == "/api/register/activePasswordWithQuestion" {
                    // Return partial login lacking cryptKey so enrichWithDoLoginIfNeeded fires
                    return (200, try JSONSerialization.data(withJSONObject: [
                        "error_code": 0,
                        "data": ["user_id": 100_000_103, "session_key": "partial_sess", "token": "acc_123"] as [String: Any]
                    ]))
                }
                if path == "/api/login/doLogin" {
                    doLoginInner = inner
                    return (200, try JSONSerialization.data(withJSONObject: [
                        "error_code": 0,
                        "data": [
                            "user_id": 100_000_103,
                            "session_key": "full_sess",
                            "token": "acc_123",
                            "CrypKey": Data(repeating: 0x77, count: 16).base64EncodedString()
                        ] as [String: Any]
                    ]))
                }
                return (404, Data())
            }
        }
        let doLoginTransport = DoLoginInspectTransport(zcid: ip11Zcid)
        let pwClient = ZolaLoginClient(identity: zdkIdentity, transport: doLoginTransport)
        let pwOutcome = try await pwClient.login(phone: "0901234567", password: "secret", existingSessionToken: "zk000.once_tok")
        guard case let .success(pwRes) = pwOutcome else {
            return XCTFail("Expected .success after doLogin enrichment")
        }
        XCTAssertEqual(pwRes.cryptKey, Data(repeating: 0x77, count: 16))
        XCTAssertNil(doLoginTransport.doLoginInner?["session_token"], "Consumed password session_token must not be sent to /api/login/doLogin")
    }
}

private final class PreloadSnapshotTransport: ZolaNetworkTransport, @unchecked Sendable {
    let session: ZolaSession
    let groups: Int
    let perGroup: Int

    init(session: ZolaSession, groups: Int, perGroup: Int) {
        self.session = session
        self.groups = groups
        self.perGroup = perGroup
    }

    func execute(_ request: URLRequest) async throws -> (Int, Data) {
        guard request.url?.path == "/api/preload" else {
            let enc = try ZolaCrypto.encryptZCIDParams(["hasMore": false, "msg": []], zcid: session.zcid)
            return (200, try JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc]))
        }
        var msgs: [[String: Any]] = []
        var infos: [[String: Any]] = []
        for g in 0..<groups {
            let gid = 800_000_000 + g
            infos.append(["gid": gid, "glbMsgId": 1, "tsJoinGroup": 1])
            for i in 0..<perGroup {
                let data: [String: Any] = [
                    "id": 7_000_000_000 + g * 1000 + i,
                    "cliMsgId": 9_000_000_000 + g * 1000 + i,
                    "fromU": 500_000 + i,
                    "fromD": "TV",
                    "to": gid,
                    "ts": 1_793_188_000_000 + i * 1000,
                    "msg": "tin \(i)",
                ]
                msgs.append(["text": ["type": "webchat", "data": data] as [String: Any]])
            }
        }
        let enc = try ZolaCrypto.encryptZCIDParams(["infoJoinGroup": infos, "lastMsgs": msgs], zcid: session.zcid)
        return (200, try JSONSerialization.data(withJSONObject: ["e": 0, "errMessage": "Success!!", "data": enc]))
    }
}

final class ZolaWatermarkReplayTests: XCTestCase {
    private func assertNoReplay(groups: Int, perGroup: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let sess = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "test_session_key_not_sent",
            cryptKey: Data(repeating: 0x11, count: 16),
            zcidIsNative: false,
            groupIds: (0..<groups).map { Int64(800_000_000 + $0) }
        )
        let client = ZolaClient(
            session: sess,
            transport: PreloadSnapshotTransport(session: sess, groups: groups, perGroup: perGroup),
            minPollIntervalSeconds: 0
        )
        let first = try await client.pollOnce(includePreload: true, includeOffline: true, emitInitialSnapshot: true)
        XCTAssertEqual(first.count, groups * perGroup, file: file, line: line)
        for cycle in 1...3 {
            let next = try await client.pollOnce(includePreload: true, includeOffline: true, emitInitialSnapshot: false)
            XCTAssertEqual(next.count, 0, "poll \(cycle) replayed an already delivered snapshot", file: file, line: line)
        }
    }

    func testSnapshotOf1020MessagesIsNotReplayed() async throws {
        try await assertNoReplay(groups: 51, perGroup: 20)
    }

    func testSnapshotOf4000MessagesIsNotReplayed() async throws {
        try await assertNoReplay(groups: 200, perGroup: 20)
    }

    func testKeysStillInSnapshotSurviveNewTrafficFromBusyThread() {
        var wm = ZolaWatermarkState()
        let quiet = (0..<900).map { "quiet:\($0)" }
        wm.reserveSeenCapacity(forMessages: quiet.count)
        for key in quiet {
            XCTAssertTrue(wm.markSeen(key))
        }
        for round in 0..<4 {
            for i in 0..<600 {
                _ = wm.markSeen("busy:\(round):\(i)")
            }
            for key in quiet {
                XCTAssertFalse(wm.markSeen(key), "\(key) was evicted while the server still returns it")
            }
        }
    }

    func testLargeSnapshotSurvivesRestartAndKeepsMostRecentOrder() throws {
        var wm = ZolaWatermarkState()
        wm.reserveSeenCapacity(forMessages: 2_000)
        for i in 0..<4_000 {
            XCTAssertTrue(wm.markSeen("k:\(i)"))
        }
        XCTAssertFalse(wm.markSeen("k:0"))
        XCTAssertEqual(wm.seenIds.last, "k:0")

        var restored = try JSONDecoder().decode(ZolaWatermarkState.self, from: JSONEncoder().encode(wm))
        XCTAssertEqual(restored, wm)
        XCTAssertEqual(restored.seenIds.count, 4_000)
        for i in 0..<4_000 {
            XCTAssertFalse(restored.markSeen("k:\(i)"))
        }
    }

    func testDefaultCapacityStaysBounded() {
        var wm = ZolaWatermarkState()
        for i in 0..<10_000 {
            _ = wm.markSeen("k:\(i)")
        }
        XCTAssertLessThanOrEqual(wm.seenIds.count, ZolaConstants.maxSeenIds + 256)
        XCTAssertFalse(wm.markSeen("k:9999"))
        XCTAssertTrue(wm.markSeen("k:0"))
    }
}

final class ZolaGroupSendReviewFixTests: XCTestCase {
    private func element(msgType: Int8, retCode: Int32, cmd: Int16 = 201) -> ZolaUnpackedChatElement {
        ZolaUnpackedChatElement(
            frameSize: 27,
            version: 2,
            checksum: 0,
            needAck: 0,
            msgType: msgType,
            seqId: 9,
            srcId: 1,
            srcType: 3,
            cmd: cmd,
            subCmd: 1,
            bodyData: Data(),
            retCode: retCode
        )
    }

    func testGroupTextAcceptsTheAppsFourConfirmationCommands() {
        XCTAssertEqual(ZolaClient.groupTextAckCmds, [201, 204, 205, 207])
    }

    #if canImport(Network)
    #endif

    func testGroupSendFailureSeparatesNotSentFromUnconfirmed() {
        let timeout = ZolaError.transport("Quá thời gian chờ phản hồi lệnh 201 từ máy chủ Zalo")
        XCTAssertEqual(
            ZolaClient.groupSendFailure(timeout, handedOff: true) as? ZolaGroupSendError,
            ZolaGroupSendError(delivery: .unconfirmed, underlying: timeout)
        )
        let closed = ZolaError.transport("Kết nối cuộc gọi không còn hoạt động")
        XCTAssertEqual(
            ZolaClient.groupSendFailure(closed, handedOff: false) as? ZolaGroupSendError,
            ZolaGroupSendError(delivery: .notSent, underlying: closed)
        )
        let keySet = URLError(.notConnectedToInternet)
        XCTAssertEqual((ZolaClient.groupSendFailure(keySet, handedOff: false) as? ZolaGroupSendError)?.delivery, .notSent)
        let expired = ZolaError.sessionExpired(code: -96, endpoint: "UXChatSocket", message: "")
        XCTAssertEqual(ZolaClient.groupSendFailure(expired, handedOff: true) as? ZolaError, expired)
    }

    func testMentionOffsetsBeyondInt16AreRejected() {
        let huge: [String: Any] = ["type": 0, "uid": 123, "pos": 4_611_686_018_427_387_904, "len": 4_611_686_018_427_387_904]
        XCTAssertNil(ZolaMention.fromRaw(huge))
        XCTAssertNil(ZolaMention.fromRaw(["type": 0, "uid": 123, "pos": 0, "len": 40_000]))
        XCTAssertNil(ZolaMention.fromRaw(["type": 1, "pos": 40_000, "len": 4]))
        XCTAssertEqual(ZolaMention.fromRaw(["type": 0, "uid": 123, "pos": 32_767, "len": 3]), ZolaMention(type: 0, uid: 123, pos: 32_767, len: 3))
    }

    // MARK: - Build 80 Video Call Stability: `sP2P=0`, Audio/Video Compound RTCP + REMB, PT Isolation & UDP Reorder Buffer

    #if canImport(AVFoundation) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)

    #if canImport(Network)
    #endif
    #endif
}

/// `chat.webcontent` (v1, `params` JSON) / `chat.webcontent.v2` (`zinstant_data` + `zinstant_msg`) OA bubbles,
/// shaped after `-[RichMessageContent _parseCommonAttachWithData:]` (`0x10010c0f4`) and `InstantChatInfo` (`0x100d7ede8`).
final class ZolaWebContentTests: XCTestCase {
    private func socketItem(msgType: String, content: Any) -> [String: Any] {
        [
            "msgId": 8_445_107_800_956,
            "cliMsgId": 1_793_664_608_959,
            "uidFrom": 100_000_107,
            "dName": "Thời Tiết",
            "idTo": 100_000_101,
            "ts": 1_793_664_608_959,
            "msgType": msgType,
            "content": content,
        ]
    }

    func testV1ParamsWithTitleBuildsCardAndKeepsSanitizedRaw() throws {
        let params: [String: Any] = [
            "item": [
                "zinstantdata_id": "templateId=1234&product=weather",
                "data_url": "https://zinstant.zadn.vn/static/ab/1234/layout.zins",
                "checksum": "c0ffee",
                "bundle_data": #"{"temp":"31°C"}"#,
            ],
            "customMsg": ["msg": ["vi": "Hà Nội 31°C, có mưa rào", "en": "Hanoi 31°C"]],
            "maxWidth": 280,
            "jsToken": "SHOULD_NOT_SURVIVE",
        ]
        let paramsString = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let content: [String: Any] = [
            "title": "Dự báo thời tiết hôm nay",
            "description": "",
            "href": "https://zalo.me/weather?src=oa&access_token=SECRET123",
            "thumb": "//photo-oa.zadn.vn/thumb.jpg",
            "action": "zinstant.weather",
            "params": paramsString,
            "type": "",
            "childnumber": 0,
        ]
        let msg = ZolaMessage.fromRawItem(socketItem(msgType: "chat.webcontent", content: content), selfUid: 100_000_101, defaultSource: "socket")

        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "")
        let wc = try XCTUnwrap(msg.webContent)
        XCTAssertEqual(wc.version, 1)
        XCTAssertEqual(wc.displayTitle, "Dự báo thời tiết hôm nay")
        XCTAssertEqual(wc.displayDescription, "Hà Nội 31°C, có mưa rào")
        XCTAssertEqual(wc.templateId, "templateId=1234&product=weather")
        XCTAssertEqual(wc.layoutDataUrl, "https://zinstant.zadn.vn/static/ab/1234/layout.zins")
        XCTAssertEqual(wc.safeThumbUrl, "https://photo-oa.zadn.vn/thumb.jpg")
        XCTAssertEqual(msg.attachments.first?.kind, "webcontent")
        XCTAssertEqual(msg.attachments.first?.title, "Dự báo thời tiết hôm nay")
        XCTAssertEqual(msg.previewText, "Dự báo thời tiết hôm nay")

        XCTAssertTrue(wc.hasRawJson)
        XCTAssertFalse(wc.rawJson.contains("SHOULD_NOT_SURVIVE"))
        XCTAssertFalse(wc.rawJson.contains("SECRET123"))
        XCTAssertFalse(wc.rawJson.contains("jsToken"))
        XCTAssertTrue(wc.rawJson.contains("src=oa"))
        XCTAssertTrue(wc.rawJson.contains("templateId=1234"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(wc.rawJson.utf8)) as? [String: Any])
    }

    func testV2ZInstantDataGzipBase64AndMessageInfo() throws {
        let payload: [String: Any] = [
            "item": ["zinstantdata_id": "templateId=99&product=bibi", "data_url": "https://zinstant.zadn.vn/static/x/99.zins", "zit": "t"],
            "bundle_data": ["sessionKey": "LEAK", "line": "Bibi gửi ưu đãi"],
        ]
        let packed = try XCTUnwrap(ZolaCrypto.gzipCompress(try JSONSerialization.data(withJSONObject: payload)))
        let zinstantMsg = #"{"customMsg":{"msg":{"vi":"Bibi: ưu đãi 20% hôm nay"}},"layoutType":1}"#
        let content: [String: Any] = [
            "title": "",
            "description": "",
            "href": "",
            "thumb": "",
            "action": "",
            "params": "",
            "zinstant_data": ["type": 0, "data": packed.base64EncodedString()],
            "zinstant_msg": zinstantMsg,
        ]
        let msg = ZolaMessage.fromRawItem(socketItem(msgType: "chat.webcontent.v2", content: content), selfUid: 100_000_101, defaultSource: "socket")

        let wc = try XCTUnwrap(msg.webContent)
        XCTAssertEqual(wc.version, 2)
        XCTAssertEqual(wc.templateId, "templateId=99&product=bibi")
        XCTAssertEqual(wc.noticeText, "Bibi: ưu đãi 20% hôm nay")
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.attachments.first?.kind, "webcontent")
        XCTAssertEqual(msg.previewText, "Bibi: ưu đãi 20% hôm nay")
        XCTAssertTrue(wc.rawJson.contains("data_decoded"))
        XCTAssertTrue(wc.rawJson.contains("Bibi gửi ưu đãi"))
        XCTAssertFalse(wc.rawJson.contains("LEAK"))
    }

    func testTemplateOnlyFallsBackToNoticeButKeepsRaw() throws {
        let content: [String: Any] = [
            "title": "",
            "description": "",
            "href": "javascript:alert(1)",
            "thumb": "http://evil.example.com/x.png",
            "params": #"{"item":{"zinstantdata_id":"templateId=7","data_base64":"AAAA"}}"#,
        ]
        let msg = ZolaMessage.fromRawItem(socketItem(msgType: "chat.webcontent", content: content), selfUid: 100_000_101, defaultSource: "socket")
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Thông báo hệ thống Zalo")
        XCTAssertTrue(msg.attachments.isEmpty)
        let wc = try XCTUnwrap(msg.webContent)
        XCTAssertFalse(wc.hasCardContent)
        XCTAssertEqual(wc.safeHref, "")
        XCTAssertEqual(wc.safeThumbUrl, "")
        XCTAssertTrue(wc.rawJson.contains("templateId=7"))
    }

    func testEmptyOrStringContentNeverCrashes() {
        for content in [[:] as [String: Any], ["params": "{not json"], ["zinstant_data": ["type": 0, "data": "@@@"]], ["zinstant_data": "x"]] as [Any] {
            let msg = ZolaMessage.fromRawItem(socketItem(msgType: "chat.webcontent.v2", content: content), selfUid: 100_000_101)
            XCTAssertFalse(msg.text.isEmpty)
            XCTAssertTrue(msg.attachments.isEmpty)
        }
        let bare = ZolaMessage.fromRawItem(socketItem(msgType: "chat.webcontent", content: ""), selfUid: 100_000_101)
        XCTAssertEqual(bare.kind, "system")
        XCTAssertNil(bare.webContent)
        XCTAssertNil(ZolaWebContent.parse(msgType: "webchat", attach: ["title": "x"]))
        XCTAssertNil(ZolaWebContent.parse(msgType: "chat.webcontent", attach: [:]))
    }

    func testCodableRoundTripAndLegacyCacheWithoutWebContent() throws {
        let legacy = #"{"attachments":[],"text":"Thông báo từ Thời Tiết","id":8445000000001,"toId":100000107,"isGroup":false,"reactions":[],"senderName":"Thời Tiết","threadId":100000107,"isSelf":false,"source":"socket","tsMs":1793664608959,"cliMsgId":1793664608959,"mcrypt":0,"msgType":"chat.webcontent","senderId":100000107,"isCloud":false,"kind":"system"}"#
        let old = try JSONDecoder().decode(ZolaMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(old.webContent)
        XCTAssertEqual(old.text, "Thông báo từ Thời Tiết")

        let wc = ZolaWebContent(version: 2, title: "Tiêu đề", rawJson: #"{"title":"Tiêu đề"}"#)
        let msg = old.withWebContent(wc)
        let decoded = try JSONDecoder().decode(ZolaMessage.self, from: try JSONEncoder().encode(msg))
        XCTAssertEqual(decoded.webContent, wc)
        XCTAssertEqual(decoded, msg)

        let partial = try JSONDecoder().decode(ZolaWebContent.self, from: Data(#"{"title":"Chỉ có tiêu đề"}"#.utf8))
        XCTAssertEqual(partial.version, 1)
        XCTAssertEqual(partial.displayTitle, "Chỉ có tiêu đề")
        XCTAssertFalse(partial.hasRawJson)
    }
}

/// `group.*` wire events (membership/admin/setting/name/avatar) and board objects
/// (poll / pinned note / reminder) parsed by `ZolaMessage.fromRawItem`. All fixtures are
/// synthetic — no network, no session keys — and every lookup tolerates missing keys,
/// string-typed numbers and string-wrapped JSON.
final class ZolaGroupWireMessageTests: XCTestCase {
    private let selfUid: Int64 = 100_000_103
    private let actorUid: Int64 = 100_000_102
    private let gid: Int64 = 900_111_222

    private func groupItem(
        msgType: String,
        attach: Any? = nil,
        msg: Any? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": 8_425_999_000_001,
            "cliMsgId": 1_730_999_000_001,
            "fromU": actorUid,
            "fromD": "Văn An",
            "to": gid,
            "ts": 1_730_999_000_001,
            "msgType": msgType,
        ]
        if let attach { item["attach"] = attach }
        if let msg { item["msg"] = msg }
        for (key, value) in extra { item[key] = value }
        return item
    }

    private func parse(_ item: [String: Any]) -> ZolaMessage {
        ZolaMessage.fromRawItem(item, selfUid: selfUid, knownGroupIds: [gid])
    }

    func testGroupJoinWithUpdateMemsComposesAddedText() {
        let msg = parse(groupItem(
            msgType: "group.join.v2",
            attach: [
                "updateMems": [
                    ["uid": 555_001, "dName": "Mai"],
                    ["uid": 555_002, "dName": "Lan"],
                ],
            ]
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Văn An đã thêm Mai, Lan vào nhóm")
        let ev = try? XCTUnwrap(msg.groupEvent)
        XCTAssertEqual(ev?.action, "group.join.v2")
        XCTAssertEqual(ev?.actorUid, actorUid)
        XCTAssertEqual(ev?.actorName, "Văn An")
        XCTAssertEqual(ev?.memberUids, [555_001, 555_002])
        XCTAssertEqual(ev?.memberNames, ["Mai", "Lan"])
        XCTAssertNil(msg.boardCard)
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupJoinViaLinkWhenActorIsTheOnlyMember() {
        let msg = parse(groupItem(
            msgType: "group.join",
            attach: ["updateMems": [["uid": actorUid, "dName": "Văn An"]]]
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Văn An đã tham gia nhóm")
        XCTAssertNotNil(msg.groupEvent)
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupJoinViaLinkFlag() {
        let msg = parse(groupItem(
            msgType: "group.join.v2",
            attach: ["members": [["uid": 555_003, "dName": "Mai"]], "joinByLink": 1]
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Mai đã tham gia nhóm")
    }

    func testGroupLeaveEvent() {
        let msg = parse(groupItem(
            msgType: "group.leave",
            attach: ["updateMems": [["uid": 555_004, "dName": "Mai"]]]
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Mai đã rời nhóm")
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupForceLeaveEvent() {
        let msg = parse(groupItem(
            msgType: "group.force.leave.v2",
            attach: ["updateMems": [["uid": 555_004, "dName": "Mai"]]]
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Văn An đã xoá Mai khỏi nhóm")
        let ev = try? XCTUnwrap(msg.groupEvent)
        XCTAssertEqual(ev?.memberNames, ["Mai"])
    }

    func testGroupUpdateRenameAndAvatar() {
        let rename = parse(groupItem(
            msgType: "group.update",
            attach: ["name": "Nhóm Mới"]
        ))
        XCTAssertEqual(rename.kind, "system")
        XCTAssertEqual(rename.text, "Văn An đã đổi tên nhóm thành Nhóm Mới")
        XCTAssertEqual(rename.groupEvent?.detail, "Nhóm Mới")

        let avatar = parse(groupItem(
            msgType: "group.update",
            attach: ["avt": "https://example.com/new-avatar.jpg"]
        ))
        XCTAssertEqual(avatar.kind, "system")
        XCTAssertEqual(avatar.text, "Văn An đã đổi ảnh đại diện nhóm")
    }

    func testGroupAdminGrantAndRevoke() {
        let grant = parse(groupItem(
            msgType: "group.add.admin",
            attach: ["adminIds": [["uid": 555_010, "dName": "Mai"]]]
        ))
        XCTAssertEqual(grant.kind, "system")
        XCTAssertEqual(grant.text, "Văn An đã bổ nhiệm Mai làm phó nhóm")

        let revoke = parse(groupItem(
            msgType: "group.remove.admin",
            attach: ["adminIds": [["uid": 555_010, "dName": "Mai"]]]
        ))
        XCTAssertEqual(revoke.kind, "system")
        XCTAssertEqual(revoke.text, "Văn An đã xoá vai trò phó nhóm của Mai")
    }

    func testGroupApproveAndSettingEvents() {
        let approve = parse(groupItem(
            msgType: "group.join.approve",
            attach: ["members": [["uid": 555_020, "dName": "Mai"]]]
        ))
        XCTAssertEqual(approve.kind, "system")
        XCTAssertEqual(approve.text, "Văn An đã duyệt Mai vào nhóm")

        let setting = parse(groupItem(msgType: "group.update.setting", attach: ["settings": ["lockSendMsg": 1]]))
        XCTAssertEqual(setting.kind, "system")
        XCTAssertEqual(setting.text, "Văn An đã thay đổi cài đặt nhóm")
    }

    func testGroupUnknownActionNeverFallsBackToPlaceholder() {
        let msg = parse(groupItem(msgType: "group.xyz", attach: ["foo": "bar"]))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Văn An đã cập nhật nhóm")
        XCTAssertEqual(msg.groupEvent?.action, "group.xyz")
        XCTAssertNotEqual(msg.text, "[Tin nhắn chưa hỗ trợ hiển thị]")
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupPollFullPayload() {
        let msg = parse(groupItem(
            msgType: "group.poll",
            attach: [
                "question": "Ăn trưa ở đâu?",
                "options": [
                    ["content": "Phở", "votes": 2],
                    ["content": "Cơm", "votes": "3"],
                ],
                "isAnonymous": 1,
                "allowMultiChoices": 0,
                "totalVotes": 5,
                "pollId": 77_889,
            ]
        ))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.text, "Bình chọn: Ăn trưa ở đâu?")
        let card = try? XCTUnwrap(msg.boardCard)
        XCTAssertEqual(card?.kind, .poll)
        XCTAssertEqual(card?.title, "Ăn trưa ở đâu?")
        XCTAssertEqual(card?.options.count, 2)
        XCTAssertEqual(card?.options.first?.label, "Phở")
        XCTAssertEqual(card?.options.first?.votes, 2)
        XCTAssertEqual(card?.options.last?.votes, 3)
        XCTAssertEqual(card?.totalVotes, 5)
        XCTAssertEqual(card?.isAnonymous, true)
        XCTAssertEqual(card?.allowMultiChoice, false)
        XCTAssertEqual(card?.actionText, "đã cập nhật bình chọn")
        XCTAssertEqual(msg.previewText, "[Bình chọn] Ăn trưa ở đâu?")
        XCTAssertNil(msg.groupEvent)
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupPollMissingOptionsStillRendersCard() {
        let msg = parse(groupItem(msgType: "group.poll", attach: ["question": "OK?"]))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.boardCard?.kind, .poll)
        XCTAssertEqual(msg.boardCard?.title, "OK?")
        XCTAssertEqual(msg.boardCard?.options.count ?? -1, 0)
        XCTAssertEqual(msg.text, "Bình chọn: OK?")
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testGroupPollNestedInsideJsonStrings() {
        // `attach` arrives as a string-wrapped JSON object.
        let attachString = #"{"action":"group.poll","question":"Q?","options":[{"content":"A","votes":"1"}]}"#
        let msg = parse(groupItem(msgType: "webchat", attach: attachString))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.boardCard?.kind, .poll)
        XCTAssertEqual(msg.boardCard?.options.first?.label, "A")
        XCTAssertEqual(msg.boardCard?.options.first?.votes, 1)
        XCTAssertEqual(msg.msgType, "group.poll")

        // `params` arrives as a string-wrapped JSON object holding the group action.
        let paramsString = #"{"action":"group.update","name":"Tên Từ Params"}"#
        let viaParams = parse(groupItem(msgType: "webchat", extra: ["params": paramsString]))
        XCTAssertEqual(viaParams.kind, "system")
        XCTAssertEqual(viaParams.text, "Văn An đã đổi tên nhóm thành Tên Từ Params")
    }

    func testGroupNoteCard() {
        let body = "Đầu ghi chú\nPhần thân chi tiết\nDòng ba"
        let msg = parse(groupItem(
            msgType: "group.update.topic",
            attach: ["boardType": "note", "content": body]
        ))
        XCTAssertEqual(msg.kind, "board")
        let card = try? XCTUnwrap(msg.boardCard)
        XCTAssertEqual(card?.kind, .note)
        XCTAssertEqual(card?.title, "Đầu ghi chú")
        XCTAssertEqual(card?.body, body)
        XCTAssertEqual(card?.actionText, "đã ghim ghi chú")
        XCTAssertEqual(msg.text, "Ghi chú: Đầu ghi chú")
        XCTAssertEqual(msg.previewText, "[Ghi chú] Đầu ghi chú")
    }

    func testGroupTopicWithoutBoardTypeIsNote() {
        let msg = parse(groupItem(
            msgType: "group.update.topic",
            attach: ["title": "Chỉ một dòng"]
        ))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.boardCard?.kind, .note)
        XCTAssertEqual(msg.boardCard?.title, "Chỉ một dòng")
    }

    func testGroupReminderSecondsAndMilliseconds() {
        let seconds = parse(groupItem(
            msgType: "group.topic.remind",
            attach: ["title": "Họp team", "startTime": 1_730_999_000]
        ))
        XCTAssertEqual(seconds.kind, "board")
        let cardSeconds = try? XCTUnwrap(seconds.boardCard)
        XCTAssertEqual(cardSeconds?.kind, .reminder)
        XCTAssertEqual(cardSeconds?.title, "Họp team")
        XCTAssertEqual(cardSeconds?.startMs, 1_730_999_000_000)
        XCTAssertEqual(cardSeconds?.actionText, "đã tạo nhắc hẹn")
        XCTAssertEqual(seconds.previewText, "[Nhắc hẹn] Họp team")

        let millis = parse(groupItem(
            msgType: "group.topic.remind",
            attach: ["title": "Họp lại", "remindTime": 1_730_999_000_001, "repeatStr": "RRULE:FREQ=WEEKLY", "locationStr": "Phòng 3"]
        ))
        let cardMillis = try? XCTUnwrap(millis.boardCard)
        XCTAssertEqual(cardMillis?.startMs, 1_730_999_000_001)
        XCTAssertEqual(cardMillis?.repeatText, "RRULE:FREQ=WEEKLY")
        XCTAssertEqual(cardMillis?.locationText, "Phòng 3")
    }

    func testGroupRemoveTopicIsSystemPill() {
        let msg = parse(groupItem(msgType: "group.remove.topic", attach: ["topicId": 42]))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Văn An đã gỡ ghi chú/nhắc hẹn")
        XCTAssertNotNil(msg.groupEvent)
        XCTAssertNil(msg.boardCard)
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
    }

    func testLegacyCacheDecodesWithoutGroupFields() throws {
        let legacy = #"{"attachments":[],"text":"Văn An đã thêm Mai vào nhóm","id":8445999000001,"toId":900111222,"isGroup":true,"reactions":[],"senderName":"Văn An","threadId":900111222,"isSelf":false,"source":"mfetch","tsMs":1730999000001,"cliMsgId":1730999000001,"mcrypt":0,"msgType":"group.join.v2","senderId":100000102,"isCloud":false,"kind":"system","rawDebugJson":"{}"}"#
        let old = try JSONDecoder().decode(ZolaMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(old.groupEvent)
        XCTAssertNil(old.boardCard)
        XCTAssertEqual(old.text, "Văn An đã thêm Mai vào nhóm")

        let event = ZolaGroupEventInfo(action: "group.join.v2", actorUid: actorUid, actorName: "Văn An", memberUids: [555_001], memberNames: ["Mai"])
        let card = ZolaBoardCard(kind: .poll, title: "Q?", options: [ZolaPollOption(label: "A", votes: 1)])
        let msg = ZolaMessage(
            id: 1, cliMsgId: 1, threadId: gid, isGroup: true, senderId: actorUid,
            senderName: "Văn An", toId: gid, tsMs: 1, msgType: "group.poll",
            kind: "board", text: "Bình chọn: Q?", isSelf: false,
            groupEvent: event, boardCard: card
        )
        let decoded = try JSONDecoder().decode(ZolaMessage.self, from: try JSONEncoder().encode(msg))
        XCTAssertEqual(decoded, msg)
        XCTAssertEqual(decoded.groupEvent, event)
        XCTAssertEqual(decoded.boardCard, card)
    }

    func testPlainTextAndPhotoUnchanged() {
        let text = parse(groupItem(msgType: "webchat", msg: "xin chào"))
        XCTAssertEqual(text.kind, "text")
        XCTAssertEqual(text.text, "xin chào")
        XCTAssertNil(text.groupEvent)
        XCTAssertNil(text.boardCard)
        XCTAssertTrue(text.rawDebugJson.isEmpty)

        let photo = parse(groupItem(
            msgType: "chat.photo",
            attach: ["href": "https://example.com/p.jpg", "thumb": "https://example.com/t.jpg"]
        ))
        XCTAssertEqual(photo.kind, "photo")
        XCTAssertEqual(photo.attachments.first?.kind, "photo")
        XCTAssertNil(photo.groupEvent)
        XCTAssertNil(photo.boardCard)
        XCTAssertTrue(photo.rawDebugJson.isEmpty)
    }

    func testGroupEventsNeverCrashOnMalformedPayloads() {
        let malformed: [[String: Any]] = [
            groupItem(msgType: "group.join.v2"),
            groupItem(msgType: "group.poll"),
            groupItem(msgType: "group.update.topic"),
            groupItem(msgType: "group.topic.remind"),
            groupItem(msgType: "group.update", attach: ["updateMems": "not-an-array", "name": 123]),
            groupItem(msgType: "group.poll", attach: ["options": "not-json", "votes": ["a": 1]]),
            groupItem(msgType: "group.join", attach: "{\"updateMems\": [{\"uid\": \"555777\", \"dName\": \"Số Chuỗi\"}]}"),
            groupItem(msgType: "group.xyz", msg: #"{"action":"group.join","updateMems":[{"uid":555888,"dName":"Trong Msg"}]}"#),
        ]
        for item in malformed {
            let msg = parse(item)
            XCTAssertFalse(msg.text.isEmpty, "group.* items must never produce an empty bubble")
            XCTAssertNotEqual(msg.text, "[Tin nhắn chưa hỗ trợ hiển thị]")
            XCTAssertFalse(msg.rawDebugJson.isEmpty)
        }
    }

    func testGroupEventInsideMsgJsonString() {
        // The whole payload can be a JSON object inside `msg` while `attach` is empty.
        let msg = parse(groupItem(
            msgType: "webchat",
            attach: [:] as [String: Any],
            msg: #"{"action":"group.join","updateMems":[{"uid":555999,"dName":"Lan"}],"fromD":"Chủ Nhóm"}"#
        ))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertEqual(msg.text, "Chủ Nhóm đã thêm Lan vào nhóm")
        XCTAssertEqual(msg.groupEvent?.memberNames, ["Lan"])
    }
}

/// QA edge coverage for the `group.*` wire parser: normal group traffic must bypass the new
/// branch, payload fields tolerate alternate shapes, and non-group 1-1 actions keep old behavior.
final class ZolaGroupWireEdgeCaseTests: XCTestCase {
    private let selfUid: Int64 = 100_000_103
    private let actorUid: Int64 = 100_000_102
    private let gid: Int64 = 900_111_222

    private func groupItem(
        msgType: String,
        attach: Any? = nil,
        msg: Any? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": 8_426_000_000_001,
            "cliMsgId": 1_731_000_000_001,
            "fromU": actorUid,
            "fromD": "Văn An",
            "to": gid,
            "ts": 1_731_000_000_001,
            "msgType": msgType,
        ]
        if let attach { item["attach"] = attach }
        if let msg { item["msg"] = msg }
        for (key, value) in extra { item[key] = value }
        return item
    }

    private func directItem(
        msgType: String,
        attach: Any? = nil,
        msg: Any? = nil,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var item = groupItem(msgType: msgType, attach: attach, msg: msg, extra: extra)
        item["to"] = selfUid
        return item
    }

    private func parse(_ item: [String: Any]) -> ZolaMessage {
        ZolaMessage.fromRawItem(item, selfUid: selfUid, knownGroupIds: [gid])
    }

    // MARK: - Fixes from the independent review (Gemini, 04/11/2026)

    func testPollVoteSumDoesNotOverflow() {
        let huge = "9223372036854775807"
        let msg = parse(groupItem(msgType: "group.poll", attach: [
            "question": "Tràn số?",
            "options": [["content": "A", "votes": huge], ["content": "B", "votes": huge]],
        ]))
        XCTAssertEqual(msg.boardCard?.kind, .poll)
        XCTAssertEqual(msg.boardCard?.totalVotes, 2_000_000_000)
    }

    func testNoteWithCreationTimeStaysNote() {
        let msg = parse(groupItem(msgType: "group.update.topic", attach: [
            "boardType": "note", "content": "Nội quy nhóm", "startTime": 1_731_000_000,
        ]))
        XCTAssertEqual(msg.boardCard?.kind, .note)
    }

    func testMembershipEventWithStartFieldIsNotReminder() {
        let msg = parse(groupItem(msgType: "group.join.v2", attach: [
            "start": 1, "updateMembers": [["id": "555004", "dName": "Mai"]],
        ]))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertNil(msg.boardCard)
    }

    func testDirectMessageWithPastedGroupJsonIsNotParsedAsGroupWire() {
        var item = directItem(msgType: "webchat", msg: "{\"type\":\"group.poll\",\"question\":\"x\"}")
        item["content"] = "{\"type\":\"group.poll\",\"question\":\"x\"}"
        let msg = parse(item)
        XCTAssertNil(msg.boardCard)
        XCTAssertNil(msg.groupEvent)
    }

    func testGroupInviteLinkCardKeepsItsLink() {
        let msg = parse(groupItem(msgType: "chat.recommended", attach: [
            "action": "group.invite", "href": "https://zalo.me/g/abcdef", "title": "Nhóm bán hàng",
        ]))
        XCTAssertNil(msg.groupEvent)
        XCTAssertNotEqual(msg.kind, "system")
    }

    func testUidOnlyLeaveUsesSenderName() {
        let msg = parse(groupItem(msgType: "group.leave", attach: ["uIds": [actorUid]], extra: ["fromD": "Mai"]))
        XCTAssertEqual(msg.kind, "system")
        XCTAssertFalse(msg.text.contains("Một thành viên"), msg.text)
        XCTAssertTrue(msg.text.contains("Mai"), msg.text)
    }

    func testRawDebugJsonStripsSensitiveKeys() {
        let msg = parse(groupItem(msgType: "group.update", attach: ["name": "Tên Mới"], extra: ["zpw_sek": "SECRET-SHOULD-NOT-LEAK", "token": "T0K3N"]))
        XCTAssertFalse(msg.rawDebugJson.isEmpty)
        XCTAssertFalse(msg.rawDebugJson.contains("SECRET-SHOULD-NOT-LEAK"))
        XCTAssertFalse(msg.rawDebugJson.contains("T0K3N"))
    }

    func testMergingKeepsBoardCardAndGroupEvent() {
        let poll = parse(groupItem(msgType: "group.poll", attach: ["question": "Đi đâu?"]))
        XCTAssertNotNil(poll.boardCard)
        let bare = ZolaMessage(id: poll.id, cliMsgId: poll.cliMsgId, threadId: poll.threadId, isGroup: true,
                               senderId: poll.senderId, toId: poll.toId, tsMs: poll.tsMs,
                               msgType: poll.msgType, kind: poll.kind, text: poll.text, isSelf: false)
        let merged = ZolaMessage.merging(existing: poll, incoming: bare)
        XCTAssertEqual(merged.boardCard, poll.boardCard)
        XCTAssertEqual(merged.withReactionSnapshot(["/-heart"]).boardCard, poll.boardCard)
        XCTAssertEqual(merged.withWebContent(nil).boardCard, poll.boardCard)
    }

    func testGroupUpdateWithAvatarAndEchoedNameIsNotReportedAsRename() {
        let both = parse(groupItem(msgType: "group.update", attach: ["avt": "https://example.invalid/a.jpg", "name": "Tên Cũ"]))
        XCTAssertEqual(both.kind, "system")
        XCTAssertFalse(both.text.contains("đổi tên"), both.text)
        XCTAssertTrue(both.text.contains("cập nhật thông tin nhóm"), both.text)

        let avatarHint = parse(groupItem(msgType: "group.update", attach: ["avt": "https://example.invalid/a.jpg", "name": "Tên Cũ", "updateType": "avatar"]))
        XCTAssertTrue(avatarHint.text.contains("đổi ảnh đại diện nhóm"), avatarHint.text)

        let nameHint = parse(groupItem(msgType: "group.update", attach: ["avt": "https://example.invalid/a.jpg", "name": "Tên Mới", "updateType": "name"]))
        XCTAssertTrue(nameHint.text.contains("đổi tên nhóm thành Tên Mới"), nameHint.text)

        let nameOnly = parse(groupItem(msgType: "group.update", attach: ["name": "Tên Mới"]))
        XCTAssertTrue(nameOnly.text.contains("đổi tên nhóm thành Tên Mới"), nameOnly.text)

        let avatarOnly = parse(groupItem(msgType: "group.update", attach: ["avt": "https://example.invalid/a.jpg"]))
        XCTAssertTrue(avatarOnly.text.contains("đổi ảnh đại diện nhóm"), avatarOnly.text)
    }

    func testGroupActionWrappedInsideAttachContentStringIsDetected() {
        let wrapped = "{\"action\":\"group.poll\",\"question\":\"Đi ăn ở đâu?\",\"options\":[{\"content\":\"Phở\",\"votes\":2}]}"
        let msg = parse(groupItem(msgType: "webchat", attach: ["content": wrapped]))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.boardCard?.kind, .poll)
        XCTAssertEqual(msg.boardCard?.title, "Đi ăn ở đâu?")
    }

    func testBareGroupDotStringInAttachContentIsNotTreatedAsGroupEvent() {
        let msg = parse(groupItem(msgType: "webchat", attach: ["content": "group.update hôm nay nhé"], msg: "group.update hôm nay nhé"))
        XCTAssertNil(msg.groupEvent)
        XCTAssertNil(msg.boardCard)
    }

    func testGroupStickerQuoteAndMentionNotCaughtByGroupBranch() {
        let sticker = parse(groupItem(
            msgType: "chat.sticker",
            attach: ["id": 46_163, "catId": 104]
        ))
        XCTAssertEqual(sticker.attachments.first?.kind, "sticker")
        XCTAssertNil(sticker.groupEvent)
        XCTAssertNil(sticker.boardCard)
        XCTAssertTrue(sticker.rawDebugJson.isEmpty)

        let quoted = parse(groupItem(
            msgType: "webchat",
            msg: "trả lời nè",
            extra: ["quote": ["ownerId": actorUid, "msg": "tin gốc", "cliMsgId": 5, "msgType": "webchat"]]
        ))
        XCTAssertEqual(quoted.kind, "text")
        XCTAssertEqual(quoted.text, "trả lời nè")
        XCTAssertEqual(quoted.quote?.text, "tin gốc")
        XCTAssertNil(quoted.groupEvent)
        XCTAssertNil(quoted.boardCard)

        let mentioned = parse(groupItem(
            msgType: "webchat",
            msg: "@Mai ơi",
            extra: ["mentions": [["type": 0, "uid": 555_001, "pos": 0, "len": 4]]]
        ))
        XCTAssertEqual(mentioned.kind, "text")
        XCTAssertEqual(mentioned.mentions.count, 1)
        XCTAssertEqual(mentioned.mentions.first?.uid, 555_001)
        XCTAssertNil(mentioned.groupEvent)
        XCTAssertNil(mentioned.boardCard)
    }

    func testGroupPollPayloadInsideContentJsonString() {
        // `attach.content` carries the whole poll payload as a JSON string (one nesting level
        // below `attach`): container keys are scanned for fields even though the action came
        // from `msgType` itself.
        let contentString = #"{"question":"Ăn gì trưa nay?","options":[{"content":"Phở","votes":1},{"content":"Bún"}]}"#
        let msg = parse(groupItem(
            msgType: "group.poll",
            attach: ["content": contentString]
        ))
        XCTAssertEqual(msg.kind, "board")
        let card = try? XCTUnwrap(msg.boardCard)
        XCTAssertEqual(card?.kind, .poll)
        XCTAssertEqual(card?.title, "Ăn gì trưa nay?")
        XCTAssertEqual(card?.options.count, 2)
        XCTAssertEqual(card?.options.first?.label, "Phở")

        // `attach.data` string-wrapped payload: dataSub covers the second nesting level.
        let dataString = #"{"question":"Chọn ngày họp?","options":["T2","T4"]}"#
        let viaData = parse(groupItem(msgType: "group.poll", attach: ["data": dataString]))
        XCTAssertEqual(viaData.kind, "board")
        XCTAssertEqual(viaData.boardCard?.title, "Chọn ngày họp?")
        XCTAssertEqual(viaData.boardCard?.options.map { $0.label }, ["T2", "T4"])
    }

    func testGroupReminderStartTimeNumericString() {
        let secondsString = parse(groupItem(
            msgType: "group.topic.remind",
            attach: ["title": "Họp", "startTime": "1730999000"]
        ))
        XCTAssertEqual(secondsString.boardCard?.kind, .reminder)
        XCTAssertEqual(secondsString.boardCard?.startMs, 1_730_999_000_000)

        let millisString = parse(groupItem(
            msgType: "group.topic.remind",
            attach: ["title": "Họp", "startTime": "1730999000001"]
        ))
        XCTAssertEqual(millisString.boardCard?.startMs, 1_730_999_000_001)
    }

    func testGroupJoinEmptyMemberLists() {
        for key in ["updateMems", "updateMembers", "members"] {
            let msg = parse(groupItem(
                msgType: "group.join.v2",
                attach: [key: [Any]()]
            ))
            XCTAssertEqual(msg.kind, "system")
            XCTAssertFalse(msg.text.isEmpty)
            XCTAssertNotEqual(msg.text, "[Tin nhắn chưa hỗ trợ hiển thị]")
            XCTAssertEqual(msg.groupEvent?.memberUids ?? [-1], [])
            XCTAssertEqual(msg.groupEvent?.memberNames ?? ["x"], [])
            XCTAssertFalse(msg.rawDebugJson.isEmpty)
        }
    }

    func testGroupNamesWithEmojiSurvive() {
        let msg = parse(groupItem(
            msgType: "group.join.v2",
            attach: ["updateMems": [["uid": 555_001, "dName": "Mai 🌸"], ["uid": 555_002, "dName": "Lan 🎉🎊"]]]
        ))
        XCTAssertEqual(msg.text, "Văn An đã thêm Mai 🌸, Lan 🎉🎊 vào nhóm")
        XCTAssertEqual(msg.groupEvent?.memberNames, ["Mai 🌸", "Lan 🎉🎊"])

        let rename = parse(groupItem(msgType: "group.update", attach: ["name": "Nhóm 🚀🌙"]))
        XCTAssertEqual(rename.text, "Văn An đã đổi tên nhóm thành Nhóm 🚀🌙")
        XCTAssertEqual(rename.groupEvent?.detail, "Nhóm 🚀🌙")
    }

    func testDirectNonGroupActionsKeepOldBehavior() {
        let pin = parse(directItem(
            msgType: "webchat",
            attach: ["action": "msginfo.pin", "notifyTxt": "Ghim tin"]
        ))
        XCTAssertEqual(pin.kind, "system")
        XCTAssertNil(pin.groupEvent)
        XCTAssertNil(pin.boardCard)
        XCTAssertTrue(pin.rawDebugJson.isEmpty)

        let weird = parse(directItem(
            msgType: "webchat",
            attach: ["action": "foo.unknown", "title": "xin chào"]
        ))
        XCTAssertNil(weird.groupEvent)
        XCTAssertNil(weird.boardCard)
        XCTAssertTrue(weird.rawDebugJson.isEmpty)

        // Plain text that merely mentions the word "group" is never a group event.
        let plain = parse(directItem(msgType: "webchat", msg: "vào group đi"))
        XCTAssertEqual(plain.kind, "text")
        XCTAssertEqual(plain.text, "vào group đi")
        XCTAssertNil(plain.groupEvent)
        XCTAssertNil(plain.boardCard)
        XCTAssertFalse(plain.isGroup)
    }

    func testActionKeysWithoutGroupDotPrefixBypassBranch() {
        // Strings that start with "group" but lack the "group." dot are not group wire actions.
        let noDot = parse(groupItem(
            msgType: "webchat",
            attach: ["action": "groupsync", "title": "đồng bộ"]
        ))
        XCTAssertNil(noDot.groupEvent)
        XCTAssertNil(noDot.boardCard)

        // Numeric `mt`/`type` fields never match the "group." prefix check.
        let numericMt = parse(groupItem(
            msgType: "webchat",
            msg: "hello",
            extra: ["mt": 2, "type": 5]
        ))
        XCTAssertEqual(numericMt.kind, "text")
        XCTAssertEqual(numericMt.text, "hello")
        XCTAssertNil(numericMt.groupEvent)
    }

    func testGroupPollLifecycleActions() {
        let vote = parse(groupItem(
            msgType: "group.poll.vote",
            attach: ["question": "Q?", "options": [["content": "A", "votes": 2]]]
        ))
        XCTAssertEqual(vote.kind, "board")
        XCTAssertEqual(vote.boardCard?.actionText, "đã bình chọn")

        let closed = parse(groupItem(
            msgType: "group.poll.close",
            attach: ["question": "Q?"]
        ))
        XCTAssertEqual(closed.kind, "board")
        XCTAssertEqual(closed.boardCard?.actionText, "đã kết thúc bình chọn")
    }

    func testGroupPollNestedInsideMsgAndDataStrings() {
        // `msg` is a JSON string whose `data` field is itself a JSON string (two levels).
        let innerData = #"{"question":"Sâu 2 lớp?","options":[{"label":"Ừ"},{"label":"Không"}]}"#
        let msgPayload = "{\"action\":\"group.poll\",\"data\":\(innerData.debugDescription)}"
        let msg = parse(groupItem(msgType: "webchat", msg: msgPayload))
        XCTAssertEqual(msg.kind, "board")
        XCTAssertEqual(msg.boardCard?.title, "Sâu 2 lớp?")
        XCTAssertEqual(msg.boardCard?.options.map { $0.label }, ["Ừ", "Không"])
    }
}
