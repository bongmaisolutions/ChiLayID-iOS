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

// CALL REGRESSION TESTS — bộ test bảo vệ cuộc gọi thoại/video (target ZolaKitCallTests).
// Chuyển nguyên văn từ Tests/ZolaKitTests/ZolaKitTests.swift; helper được chép lại vì khác target.
// Chạy riêng: swift test --filter ZolaKitCallTests  (xem docs/CALL-MODULE.md)

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

final class ZolaCallSignalingTests: XCTestCase {
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

    func testVoipStage1ServerFrameCodecCallEntityAndEventMapping() throws {
        // 1. 27-byte `msgType=3` empty-body AUTHEN ACK (`retCode = 0` & `retCode = -67`)
        let authAckOk = ZolaCrypto.packServerChatElementFrame(
            bodyData: Data(),
            srcId: 100_000_101,
            msgType: 3,
            cmd: 1,
            subCmd: 2,
            seqId: 1,
            retCode: 0
        )
        XCTAssertEqual(authAckOk.payload.count, 27)
        let unpackedOk = try ZolaCrypto.unpackChatElementFrame(authAckOk.payload)
        XCTAssertEqual(unpackedOk.msgType, 3)
        XCTAssertEqual(unpackedOk.cmd, 1)
        XCTAssertEqual(unpackedOk.subCmd, 2)
        XCTAssertEqual(unpackedOk.retCode, 0)
        XCTAssertTrue(unpackedOk.bodyData.isEmpty)

        let authAckDenied = ZolaCrypto.packServerChatElementFrame(
            bodyData: Data(),
            srcId: 100_000_101,
            msgType: 3,
            cmd: 1,
            subCmd: 2,
            seqId: 1,
            retCode: -67
        )
        let unpackedDenied = try ZolaCrypto.unpackChatElementFrame(authAckDenied.payload)
        XCTAssertEqual(unpackedDenied.retCode, -67)

        // 2. Gzip-compressed `msgType=3, cmd=401` JSON `CallEntity` response
        let callJson = #"{"error_code":0,"data":{"id":88776655,"status":0,"rtpIP":"49.213.95.89:15000","rtcpIP":"49.213.95.89:15001","sessId":"sess_8877","extendData":{"ver":4,"net":1,"rel":1}}}"#
        let gzCallBody = try XCTUnwrap(ZolaCrypto.gzipCompress(Data(callJson.utf8)))
        XCTAssertEqual(gzCallBody[0], 0x1F)
        XCTAssertEqual(gzCallBody[1], 0x8B)

        let resp401Frame = ZolaCrypto.packServerChatElementFrame(
            bodyData: gzCallBody,
            srcId: 100_000_101,
            msgType: 3,
            cmd: 401,
            subCmd: 4,
            seqId: 3,
            retCode: 0
        )
        let unpacked401 = try ZolaCrypto.unpackChatElementFrame(resp401Frame.payload)
        XCTAssertEqual(unpacked401.cmd, 401)
        let parsed = ZolaVoipProtocol.parseCallResponse(from: unpacked401, fallbackCallId: 12345)
        XCTAssertTrue(parsed.isAllowed)
        XCTAssertEqual(parsed.serverCallId, 88_776_655)
        XCTAssertEqual(parsed.rtpAddress, "49.213.95.89:15000")
        XCTAssertEqual(parsed.rtcpAddress, "49.213.95.89:15001")
        XCTAssertEqual(parsed.relayHost, "49.213.95.89")
        XCTAssertEqual(parsed.relayPort, 15000)
        XCTAssertEqual(parsed.sessionId, "sess_8877")

        // Busy response (`status = 6`)
        let busyJson = #"{"error_code":0,"data":{"id":88776655,"status":6}}"#
        let respBusy = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(busyJson.utf8),
                srcId: 100_000_101,
                msgType: 3,
                cmd: 401,
                subCmd: 4,
                retCode: 0
            ).payload
        )
        let parsedBusy = ZolaVoipProtocol.parseCallResponse(from: respBusy, fallbackCallId: 12345)
        XCTAssertFalse(parsedBusy.isAllowed)
        XCTAssertEqual(parsedBusy.status, 6)

        // 3. `cmd=407` ringing push with `"neekACK": 1` -> `.ringing` + `autoAckCmd = 407`
        let ringingJson = #"{"error_code":0,"data":{"id":88776655,"partnerId":100000106,"neekACK":1}}"#
        let push407 = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: try XCTUnwrap(ZolaCrypto.gzipCompress(Data(ringingJson.utf8))),
                srcId: 100_000_106,
                msgType: 1,
                cmd: 407,
                subCmd: 0,
                needAck: 1
            ).payload
        )
        let ringingResult = ZolaVoipProtocol.interpretIncomingElement(
            push407,
            activeCallId: 88_776_655,
            clientCallId: 12345,
            activePartnerUid: 100_000_106,
            selfUid: 100_000_101
        )
        XCTAssertEqual(ringingResult.event, ZolaVoipCallEvent.ringing(callId: 88_776_655, partnerUid: 100_000_106))
        XCTAssertEqual(ringingResult.autoAckCmd, 407)

        // 4. `cmd=423` Command ACK binary layout (`[partnerId][callId][ackedCommand]`)
        let ack423 = ZolaCrypto.packVoipCommandAckFrame(
            srcId: 100_000_101,
            partnerId: 100_000_106,
            callId: 88_776_655,
            ackedCommand: 407
        )
        let unpacked423 = try ZolaCrypto.unpackChatElementFrame(ack423.payload)
        XCTAssertEqual(unpacked423.cmd, 423)
        XCTAssertEqual(unpacked423.subCmd, 0)
        XCTAssertEqual(unpacked423.bodyData.count, 12)
        XCTAssertEqual(try unpacked423.bodyData.readInt32LE(at: 0), 100_000_106)
        XCTAssertEqual(try unpacked423.bodyData.readInt32LE(at: 4), 88_776_655)
        XCTAssertEqual(try unpacked423.bodyData.readInt32LE(at: 8), 407)

        // 5. `cmd=403` / `424` answered & rejected, `cmd=405` / `409` ended, `cmd=402` incoming invite
        let ansElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":88776655,"status":0}}"#.utf8),
                srcId: 100_000_106,
                msgType: 1,
                cmd: 424,
                subCmd: 0
            ).payload
        )
        XCTAssertEqual(
            ZolaVoipProtocol.interpretIncomingElement(
                ansElem,
                activeCallId: 88_776_655,
                clientCallId: 12345,
                activePartnerUid: 100_000_106,
                selfUid: 100_000_101
            ).event,
            ZolaVoipCallEvent.answered(callId: 88_776_655, partnerUid: 100_000_106)
        )

        let invElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":998877,"callerId":100000106,"callType":3,"dName":"Anh Bình"}}"#.utf8),
                srcId: 100_000_106,
                msgType: 1,
                cmd: 402,
                subCmd: 0
            ).payload
        )
        if case let .incomingInvite(callId, partnerUid, isVideo, callerName, _, _, _, _) = ZolaVoipProtocol.interpretIncomingElement(
            invElem,
            activeCallId: 0,
            clientCallId: 0,
            activePartnerUid: 0,
            selfUid: 100_000_101
        ).event {
            XCTAssertEqual(callId, 998_877)
            XCTAssertEqual(partnerUid, 100_000_106)
            XCTAssertFalse(isVideo)
            XCTAssertEqual(callerName, "Anh Bình")
        } else {
            XCTFail("Expected .incomingInvite from cmd=402")
        }
    }

    func testVoiceToVideoUpgradeFrameAndInboundSwitchToVideo() throws {
        // (a) Promoting a VOICE call to video must emit `cmd = 416, subCmd = 3` advertising the h264
        // codec + `callType = 1`, preserving the P2P/relay candidates negotiated during the voice
        // phase. A plain camera-state packet (`cmd = 421`) alone is NOT enough — this is the fix.
        let voiceExtend = ZolaCrypto.makeVoipExtendDataJson(
            localEndpoint: "192.168.1.5:24680",
            isVideo: false
        )
        // Baseline: the voice-phase extendData has no video codec and `callType = 0`.
        XCTAssertFalse(voiceExtend.contains("\"h264\""))
        XCTAssertTrue(voiceExtend.contains("\"callType\":0"))
        XCTAssertTrue(voiceExtend.contains("192.168.1.5"))

        let upgradeFrame = ZolaClient.buildVoipVideoUpgradeFrame(
            srcId: 100_000_101,
            partnerId: 100_000_106,
            callId: 88_776_655,
            baseExtendData: voiceExtend,
            rtpAddress: "49.213.95.89:15000",
            rtcpAddress: "49.213.95.89:15001",
            sessionId: "sess_8877",
            seqId: 7
        )
        let unpackedUpgrade = try ZolaCrypto.unpackChatElementFrame(upgradeFrame.payload)
        XCTAssertEqual(unpackedUpgrade.cmd, 416)
        XCTAssertEqual(unpackedUpgrade.subCmd, 3, "Voice→video upgrade must use ZRTP video subCmd = 3, not stay on voice subCmd = 2")
        let upgradeBodyText = String(decoding: unpackedUpgrade.bodyData, as: UTF8.self)
        XCTAssertTrue(upgradeBodyText.contains("\"name\":\"h264\""), "upgrade frame must advertise the h264 video codec")
        XCTAssertTrue(upgradeBodyText.contains("\"callType\":1"), "upgrade frame must flip callType to video (1)")
        XCTAssertTrue(upgradeBodyText.contains("192.168.1.5"), "upgrade must preserve the already-negotiated P2P candidate")

        // The extendData rebuilder in isolation: preserves video + falls back safely on bad input.
        let videoExtend = ZolaClient.makeVoipVideoUpgradeExtendData(from: voiceExtend)
        XCTAssertTrue(videoExtend.contains("\"name\":\"h264\""))
        XCTAssertTrue(videoExtend.contains("\"callType\":1"))
        XCTAssertTrue(ZolaClient.makeVoipVideoUpgradeExtendData(from: nil).contains("\"h264\""))
        XCTAssertTrue(ZolaClient.makeVoipVideoUpgradeExtendData(from: "not-json").contains("\"h264\""))

        // (b) An inbound `cmd = 412` (peer switched to video) must map to `.partnerCameraChanged`
        // with the camera ON so the app opens the inbound video stream (does not stay on voice).
        let switch412 = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":88776655,"partnerId":100000106}}"#.utf8),
                srcId: 100_000_106,
                msgType: 1,
                cmd: 412,
                subCmd: 0,
                needAck: 1
            ).payload
        )
        let switchResult = ZolaVoipProtocol.interpretIncomingElement(
            switch412,
            activeCallId: 88_776_655,
            clientCallId: 12345,
            activePartnerUid: 100_000_106,
            selfUid: 100_000_101
        )
        XCTAssertEqual(
            switchResult.event,
            ZolaVoipCallEvent.partnerCameraChanged(
                callId: 88_776_655,
                partnerUid: 100_000_106,
                isCameraOn: true,
                reason: 0
            ),
            "cmd = 412 must signal the partner turned video/camera on"
        )

        // (c) Regression: a call that is VIDEO from the start still emits `cmd = 416, subCmd = 3`,
        // and a voice ZRTP request still uses `subCmd = 2` (behaviour unchanged by the upgrade path).
        let videoFromStart = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipRequestZRTPFrame(
                srcId: 100_000_101,
                partnerId: 100_000_106,
                callId: 88_776_655,
                isVideo: true,
                codec: ZolaCrypto.defaultVoipCodecJson,
                seqId: 3
            ).payload
        )
        XCTAssertEqual(videoFromStart.cmd, 416)
        XCTAssertEqual(videoFromStart.subCmd, 3)

        let voiceFromStart = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipRequestZRTPFrame(
                srcId: 100_000_101,
                partnerId: 100_000_106,
                callId: 88_776_655,
                isVideo: false,
                codec: ZolaCrypto.defaultVoipCodecJson,
                seqId: 3
            ).payload
        )
        XCTAssertEqual(voiceFromStart.cmd, 416)
        XCTAssertEqual(voiceFromStart.subCmd, 2)
    }

    #if canImport(Network)
    func testVoipStage1LoopbackSocketHandshakeRingingAutoAckAndDryRunGate() async throws {
        // 1. Verify dryRun == true never opens network or spams chat
        let session = try ZolaSession(
            uid: 100_000_101,
            sessionKey: "sk_test_voip_stage1",
            cryptKey: Data(repeating: 0x11, count: 16),
            zcid: "0102030405060708"
        )
        let mockHttp = MockZolaTransport(session: session)
        let client = ZolaClient(session: session, transport: mockHttp, minPollIntervalSeconds: 0)
        let dryReceipt = try await client.startVoipCall(partnerUid: 100_000_106, callId: 123_456, dryRun: true)
        XCTAssertTrue(dryReceipt.ok)
        XCTAssertEqual(dryReceipt.callId, 123_456)
        XCTAssertTrue(dryReceipt.serverCommands.isEmpty, "dryRun must not fabricate fake serverCmds=[408]")
        XCTAssertTrue(mockHttp.requests.isEmpty, "startVoipCall must never send fake text messages over HTTP")

        // 2. Local loopback `NWListener` simulating `UXVoipSocket` server
        let serverQueue = DispatchQueue(label: "test.uxvoipsocket.server")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let expRinging = expectation(description: "Client receives real cmd=407 ringing")
        let expAutoAck423 = expectation(description: "Server receives automatic cmd=423 ACK for cmd=407")
        let expAnswered = expectation(description: "Client receives cmd=403 answered")
        let expStep2Zrtp = expectation(description: "Server receives Step-2 cmd=416 ZRTP frame")

        listener.newConnectionHandler = { serverConn in
            var rxBuf = Data()
            var upgraded = false

            func pumpServer() {
                serverConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, err in
                    if let chunk, !chunk.isEmpty {
                        rxBuf.append(chunk)
                        if !upgraded, let marker = rxBuf.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            rxBuf.removeSubrange(rxBuf.startIndex..<marker.upperBound)
                            upgraded = true
                            serverConn.send(content: Data("HTTP/1.1 200 OK\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        while upgraded, rxBuf.count >= 23 {
                            guard let fSize = try? Data(rxBuf.prefix(4)).readUInt32LE(at: 0),
                                  rxBuf.count >= Int(fSize)
                            else { break }
                            let raw = Data(rxBuf.prefix(Int(fSize)))
                            rxBuf.removeFirst(Int(fSize))
                            guard let elem = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }

                            if elem.cmd == 1 {
                                let ack = ZolaCrypto.packServerChatElementFrame(
                                    bodyData: Data(),
                                    srcId: 100_000_101,
                                    msgType: 3,
                                    cmd: 1,
                                    subCmd: 2,
                                    seqId: elem.seqId,
                                    retCode: 0
                                )
                                serverConn.send(content: ack.payload, completion: .contentProcessed { _ in })
                            } else if elem.cmd == 401 {
                                let json = #"{"error_code":0,"data":{"id":77665544,"status":0,"rtpIP":"49.213.95.89:16000","rtcpIP":"49.213.95.89:16001","sessId":"sess_77665544","extendData":{"ver":4,"net":1,"rel":1}}}"#
                                let gz = ZolaCrypto.gzipCompress(Data(json.utf8)) ?? Data(json.utf8)
                                let resp = ZolaCrypto.packServerChatElementFrame(
                                    bodyData: gz,
                                    srcId: 100_000_101,
                                    msgType: 3,
                                    cmd: 401,
                                    subCmd: 4,
                                    seqId: elem.seqId,
                                    retCode: 0
                                )
                                serverConn.send(content: resp.payload, completion: .contentProcessed { _ in })
                            } else if elem.cmd == 416 {
                                let bodyStr = String(decoding: elem.bodyData, as: UTF8.self)
                                if bodyStr.contains("49.213.95.89:16000") && bodyStr.contains("sess_77665544") {
                                    expStep2Zrtp.fulfill()
                                }
                                let ringJson = #"{"error_code":0,"data":{"id":77665544,"partnerId":100000106,"neekACK":1}}"#
                                let ringGz = ZolaCrypto.gzipCompress(Data(ringJson.utf8)) ?? Data(ringJson.utf8)
                                let push407 = ZolaCrypto.packServerChatElementFrame(
                                    bodyData: ringGz,
                                    srcId: 100_000_106,
                                    msgType: 1,
                                    cmd: 407,
                                    subCmd: 0,
                                    needAck: 1
                                )
                                serverConn.send(content: push407.payload, completion: .contentProcessed { _ in })
                            } else if elem.cmd == 423 {
                                if elem.bodyData.count == 12,
                                   (try? elem.bodyData.readInt32LE(at: 4)) == 77_665_544,
                                   (try? elem.bodyData.readInt32LE(at: 8)) == 407 {
                                    expAutoAck423.fulfill()
                                    let ansJson = #"{"error_code":0,"data":{"id":77665544,"partnerId":100000106,"status":0}}"#
                                    let push403 = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: Data(ansJson.utf8),
                                        srcId: 100_000_106,
                                        msgType: 1,
                                        cmd: 403,
                                        subCmd: 0
                                    )
                                    serverConn.send(content: push403.payload, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    if err == nil && !isComplete {
                        pumpServer()
                    }
                }
            }
            serverConn.start(queue: serverQueue)
            pumpServer()
        }

        let readyExp = expectation(description: "Loopback listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readyExp.fulfill()
            }
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let authen = ZolaCrypto.packSocketAuthenFrame(
            srcId: 100_000_101,
            sessionKey: "sk_test_voip_stage1",
            deviceModel: "iP16Pro",
            imei: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
            seqId: 1
        ).payload

        let sock = ZolaVoipSocketSession(
            selfUid: 100_000_101,
            authenPayload: authen,
            endpoints: [("127.0.0.1", port)],
            onEvent: { ev in
                switch ev {
                case .ringing(callId: 77_665_544, partnerUid: 100_000_106):
                    expRinging.fulfill()
                case .answered(callId: 77_665_544, partnerUid: 100_000_106):
                    expAnswered.fulfill()
                default:
                    break
                }
            }
        )

        try await sock.connectAndAuthenticate()
        await sock.bindCall(serverCallId: 111_222, clientCallId: 111_222, partnerUid: 100_000_106, isVideo: false)

        let callReq = ZolaCrypto.packVoipCallRequestFrame(
            srcId: 100_000_101,
            partnerId: 100_000_106,
            callId: 111_222,
            isVideo: false,
            seqId: await sock.nextSeqId()
        )
        let resp401 = try await sock.sendAndWait(rawPayload: callReq.payload, expectedCmd: 401, timeoutSeconds: 3.0)
        let parsed = ZolaVoipProtocol.parseCallResponse(from: resp401, fallbackCallId: 111_222)
        XCTAssertEqual(parsed.serverCallId, 77_665_544)
        await sock.bindCall(serverCallId: parsed.serverCallId, clientCallId: 111_222, partnerUid: 100_000_106, isVideo: false)

        let zrtp = ZolaCrypto.packVoipRequestZRTPFrame(
            srcId: 100_000_101,
            partnerId: 100_000_106,
            callId: parsed.serverCallId,
            isVideo: false,
            rtpAddress: parsed.rtpAddress,
            rtcpAddress: parsed.rtcpAddress,
            sessionId: parsed.sessionId,
            externData: parsed.extendDataString,
            seqId: await sock.nextSeqId()
        )
        try await sock.sendFrame(zrtp)

        await fulfillment(of: [expStep2Zrtp, expRinging, expAutoAck423, expAnswered], timeout: 4.0)
        await sock.close()
    }
    #endif

    func testVoipProductionSocketSafetyGateNeverRevokesSessionKey() async throws {
        XCTAssertTrue(ZolaVoipProtocol.isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(ZolaVoipProtocol.isLoopbackHost("localhost"))
        XCTAssertTrue(ZolaVoipProtocol.isLoopbackHost("::1"))
        XCTAssertFalse(ZolaVoipProtocol.isLoopbackHost("49.213.95.89"))
        XCTAssertFalse(ZolaVoipProtocol.isLoopbackHost("120.138.69.125"))

        #if canImport(Network)
        let prodSocket = ZolaVoipSocketSession(
            selfUid: 100_000_101,
            authenPayload: Data([0x01, 0x02]),
            endpoints: [("49.213.95.89", 443)],
            onEvent: nil
        )
        do {
            try await prodSocket.connectAndAuthenticate()
            XCTFail("Expected safetyGate error when attempting raw AUTHEN against production Zalo socket")
        } catch let ZolaError.safetyGate(msg) {
            XCTAssertTrue(msg.contains("UXVoipSocket") || msg.contains("phiên đăng nhập"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        #endif

        // Mock transport keeps `fetchKeySet` off the real network: sessions saved before
        // `socketServers` now fall back to `defaultVerifiedEncryptedEndpoints`, so the gate that
        // must trip is the missing `EncryptProtocolVer2` keySet — still a hard safetyGate.
        let (client, mock) = try makeClient()

        do {
            _ = try await client.startVoipCall(
                partnerUid: 100_000_108,
                callId: 99_887,
                isVideo: false,
                dryRun: false
            )
            XCTFail("Expected startVoipCall(dryRun: false) without keySet to throw safetyGate")
        } catch let ZolaError.safetyGate(msg) {
            XCTAssertTrue(msg.contains("keySet") || msg.contains("session_key") || msg.contains("Zalo"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(
            mock.requests.contains { $0.url?.host?.hasPrefix("49.213.") == true },
            "no plaintext AUTHEN may reach production VoIP hosts"
        )

        let afterStart = await client.session
        XCTAssertFalse(afterStart.isExpired, "Blocked live VoIP call must never mark session expired")

        // cancelVoipCall(dryRun: false) with no open socket must be a safe no-op (never opens a fresh TCP socket)
        try await client.cancelVoipCall(
            partnerUid: 100_000_108,
            callId: 99_887,
            isVideo: false,
            durationSeconds: 0,
            dryRun: false
        )
        let afterCancel = await client.session
        XCTAssertFalse(afterCancel.isExpired)
    }

    func testSocketCryptoProV21AuthenSubCmd5KeyRotationAndEncryptedLoopbackCall() async throws {
        // 1. Legacy numeric `keySetId` JSON backward compatibility + String `keySetId` round-trip
        let legacyJson = Data(#"{"uid":100000101,"sessionKey":"sk_legacy","cryptKey":"MTIzNDU2Nzg5MDEyMzQ1Ng==","zcid":"0102030405060708","keySetId":901,"keySetValue":"\#(Data(repeating: 0x22, count: 32).base64EncodedString())"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(ZolaSession.self, from: legacyJson)
        XCTAssertEqual(decodedLegacy.keySetId, "901")
        XCTAssertTrue(decodedLegacy.hasValidKeySet)

        // 2. Exact byte-size & round-trip verification of `0x08` (`AUTHEN subCmd=5`) against `mac37` (295B) & `aead1` (300B)
        let sk61 = "p-5E.100000101.a1." + String(repeating: "K", count: 43)
        XCTAssertEqual(sk61.utf8.count, 61)
        let serverPriv = Curve25519.KeyAgreement.PrivateKey()
        let serverPubB64 = serverPriv.publicKey.rawRepresentation.base64EncodedString()
        let staleKey32 = Data((0..<32).map { UInt8($0 &+ 0x10) })
        let freshKey32 = Data((0..<32).map { UInt8($0 &+ 0x50) })
        let ksId16 = "m8Qp2Vx9Lz4Rn7Tw"
        XCTAssertEqual(ksId16.utf8.count, 16)

        var crypto = try ZolaSocketCrypto(
            keySetId: ksId16,
            keySetValueBase64: freshKey32.base64EncodedString()
        )

        let authenMac37 = ZolaCrypto.packSocketAuthenFrame(
            srcId: 100_000_101,
            sessionKey: sk61,
            deviceModel: "iP14_@18.7_@NJ",
            imei: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
            subCmd: 5,
            seqId: 1
        )
        XCTAssertEqual(authenMac37.frameSize, 158)
        let wireAuthen295 = try crypto.sealAuthenFrame(authenMac37.payload, serverPubKeyBase64: serverPubB64)
        XCTAssertEqual(wireAuthen295.count, 295)
        XCTAssertEqual(try wireAuthen295.readUInt32LE(at: 0), 295)
        XCTAssertEqual(wireAuthen295[4], 0x08)

        let authenAead1 = ZolaCrypto.packSocketAuthenFrame(
            srcId: 100_000_101,
            sessionKey: sk61,
            deviceModel: "iP16Pro_@26.3.1_@NJ",
            imei: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
            subCmd: 5,
            seqId: 1
        )
        XCTAssertEqual(authenAead1.frameSize, 163)
        let wireAuthen300 = try crypto.sealAuthenFrame(authenAead1.payload, serverPubKeyBase64: serverPubB64)
        XCTAssertEqual(wireAuthen300.count, 300)
        XCTAssertEqual(try wireAuthen300.readUInt32LE(at: 0), 300)
        XCTAssertEqual(wireAuthen300[4], 0x08)

        let openedAuthen = try ZolaSocketCrypto.openAuthenFrame(
            wireAuthen300,
            serverPrivateKeyRaw32: serverPriv.rawRepresentation,
            resolveKeySetValue: { id in id == ksId16 ? freshKey32 : nil }
        )
        XCTAssertEqual(openedAuthen.keySetId, ksId16)
        XCTAssertEqual(openedAuthen.clientPublicKey, crypto.clientPublicKeyData)
        let unpackedAuthen = try ZolaCrypto.unpackChatElementFrame(openedAuthen.chatElementPayload)
        XCTAssertEqual(unpackedAuthen.cmd, 1)
        XCTAssertEqual(unpackedAuthen.subCmd, 5)
        XCTAssertTrue(String(decoding: unpackedAuthen.bodyData, as: UTF8.self).hasSuffix(sk61))

        // 3. `AuthenV3Aes` (`subCmd = 4` & `subCmd = 3`) round-trip key derivation & AES-256-CBC decryption
        let tsSec: UInt32 = 1_793_500_123
        let aesPub: Int64 = 9_876_543_210
        let aesPriv: Int64 = 1_234_567_890
        let v3Frame = try ZolaCrypto.packSocketAuthenV3AesFrame(
            srcId: 100_000_101,
            sessionKey: sk61,
            aesPublicId: aesPub,
            aesPrivateId: aesPriv,
            timestampSec: tsSec,
            subCmd: 4,
            deviceModel: "iP16Pro_@26.3.1_@NJ",
            imei: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB"
        )
        let unpackedV3 = try ZolaCrypto.unpackChatElementFrame(v3Frame.payload)
        XCTAssertEqual(unpackedV3.cmd, 1)
        XCTAssertEqual(unpackedV3.subCmd, 4)
        let v3HeaderSkip = 12 + 2 + "iP16Pro_@26.3.1_@NJ".utf8.count + 2 + 36 + 1 + 4 + 8
        let b64Tail = String(decoding: unpackedV3.bodyData.subdata(in: v3HeaderSkip..<unpackedV3.bodyData.count), as: UTF8.self)
        let cipherSk = try XCTUnwrap(Data(base64Encoded: b64Tail))
        let derivedKey = ZolaCrypto.deriveAuthenV3AesKey(timestampSec: tsSec, aesPrivateId: aesPriv)
        let decryptedSk = try ZolaCrypto.aesCBC(cipherSk, key: derivedKey, iv: Data(repeating: 0, count: 16), decrypt: true)
        XCTAssertEqual(String(decoding: decryptedSk, as: UTF8.self), sk61)

        // 4. `0x04` Heartbeat (57B wire) + `rotateKeySet` old-key fallback + tampered-tag rejection
        let pingFrame = ZolaCrypto.packSocketHeartbeatFrame(srcId: 100_000_101, counter: 77, seqId: 2)
        XCTAssertEqual(pingFrame.frameSize, 29)
        let wirePing = try crypto.sealFrame(pingFrame.payload)
        XCTAssertEqual(wirePing.count, 57)
        XCTAssertEqual(wirePing[4], 0x04)

        let nextKey32 = Data((0..<32).map { UInt8($0 &+ 0x90) })
        try crypto.rotateKeySet(keySetId: "r9Wz3Kp7Qm2Vx8Ln", keySetValueBase64: nextKey32.base64EncodedString())
        // Frame sealed with previous key (`freshKey32`) must still open via `previousKey` fallback!
        let openedFromPrev = try crypto.openFrame(wirePing)
        XCTAssertEqual(try ZolaCrypto.unpackChatElementFrame(openedFromPrev).cmd, 2)

        var tampered = wirePing
        tampered[20] ^= 0xFF
        XCTAssertThrowsError(try crypto.openFrame(tampered))

        #if canImport(Network)
        // 5. End-to-end encrypted `0x7d0` `ZolaClient.startVoipCall(dryRun: false)` with:
        //    - NO HTTP 200 OK response before `AUTHEN-RESP` (matching `aead1` production `49.213.95.89:443`)
        //    - First connection rejected with `retCode = -67` on stale `keySetId`
        //    - Automatic 1-time `/api/helper/getKeySet` refresh + reconnect with rotated 16-char `keySetId`
        //    - Full encrypted `401` -> `416` -> `407` -> auto-ACK `423` -> `403` -> `cancelVoipCall` (`405` + `406`)
        let serverQueue = DispatchQueue(label: "test.proV21.encrypted.server")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let staleId = "staleKeySetId001"
        let freshId = "freshKeySetId002"
        let keyMap: [String: Data] = [
            staleId: staleKey32,
            freshId: freshKey32,
        ]

        let expRejectedStale = expectation(description: "Server rejects first AUTHEN with retCode=-67")
        let expAuthSuccess = expectation(description: "Server accepts rotated AUTHEN subCmd=5")
        let expRinging = expectation(description: "Client receives encrypted cmd=407 ringing")
        let expAutoAck423 = expectation(description: "Server decrypts automatic cmd=423 ACK")
        let expAnswered = expectation(description: "Client receives encrypted cmd=403 answered")
        let expCancel405 = expectation(description: "Server decrypts cmd=405 cancel call")
        let expCallerFinish406 = expectation(description: "Caller finish report has native caller identity")

        listener.newConnectionHandler = { serverConn in
            var rxBuf = Data()
            var strippedPreamble = false
            var sessionCrypto: ZolaSocketCrypto?

            func pumpEncryptedServer() {
                serverConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, err in
                    if let chunk, !chunk.isEmpty {
                        rxBuf.append(chunk)
                        if !strippedPreamble, let marker = rxBuf.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            let headerText = String(decoding: rxBuf[rxBuf.startIndex..<marker.upperBound], as: UTF8.self)
                            XCTAssertTrue(headerText.contains("GET/HTTP/1.1\r\nHost: 127.0.0.1"))
                            rxBuf.removeSubrange(rxBuf.startIndex..<marker.upperBound)
                            strippedPreamble = true
                            // Intentionally omit `HTTP/1.1 200 OK\r\n\r\n` to verify non-blocking `aead1` compatibility!
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
                                    resolveKeySetValue: { keyMap[$0] }
                                ),
                                let authElem = try? ZolaCrypto.unpackChatElementFrame(opened.chatElementPayload),
                                let matchedKey = keyMap[opened.keySetId],
                                let srvCrypto = try? ZolaSocketCrypto(
                                    keySetId: opened.keySetId,
                                    keySetValueBase64: matchedKey.base64EncodedString()
                                ) else { continue }

                                XCTAssertEqual(authElem.cmd, 1)
                                XCTAssertEqual(authElem.subCmd, 5)

                                if opened.keySetId == staleId {
                                    expRejectedStale.fulfill()
                                    let rejectCE = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: Data(),
                                        srcId: 100_000_101,
                                        msgType: 3,
                                        cmd: 1,
                                        subCmd: 5,
                                        seqId: authElem.seqId,
                                        retCode: -67
                                    )
                                    if let sealedReject = try? srvCrypto.sealFrame(rejectCE.payload) {
                                        serverConn.send(content: sealedReject, completion: .contentProcessed { _ in })
                                    }
                                } else if opened.keySetId == freshId {
                                    sessionCrypto = srvCrypto
                                    expAuthSuccess.fulfill()
                                    let okBody = ZolaCrypto.gzipCompress(Data(#"{"data":{"type":1}}"#.utf8)) ?? Data()
                                    let okCE = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: okBody,
                                        srcId: 100_000_101,
                                        msgType: 3,
                                        cmd: 1,
                                        subCmd: 5,
                                        seqId: authElem.seqId,
                                        retCode: 0
                                    )
                                    if let sealedOk = try? srvCrypto.sealFrame(okCE.payload) {
                                        serverConn.send(content: sealedOk, completion: .contentProcessed { _ in })
                                    }
                                }
                            } else if wType == 0x04, let srvCrypto = sessionCrypto {
                                guard let rawCE = try? srvCrypto.openFrame(wire),
                                      let elem = try? ZolaCrypto.unpackChatElementFrame(rawCE)
                                else { continue }

                                if elem.cmd == 401 {
                                    let json = #"{"error_code":0,"data":{"id":88776655,"status":0,"rtpIP":"49.213.95.89:17000","rtcpIP":"49.213.95.89:17001","sessId":"sess_88776655","extendData":{"ver":4,"net":1,"rel":1}}}"#
                                    let gz = ZolaCrypto.gzipCompress(Data(json.utf8)) ?? Data(json.utf8)
                                    let resp401 = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: gz,
                                        srcId: 100_000_101,
                                        msgType: 3,
                                        cmd: 401,
                                        subCmd: 4,
                                        seqId: elem.seqId,
                                        retCode: 0
                                    )
                                    if let sealed = try? srvCrypto.sealFrame(resp401.payload) {
                                        serverConn.send(content: sealed, completion: .contentProcessed { _ in })
                                    }
                                } else if elem.cmd == 416 {
                                    let ringJson = #"{"error_code":0,"data":{"id":88776655,"partnerId":100000106,"neekACK":1}}"#
                                    let ringGz = ZolaCrypto.gzipCompress(Data(ringJson.utf8)) ?? Data(ringJson.utf8)
                                    let push407 = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: ringGz,
                                        srcId: 100_000_106,
                                        msgType: 1,
                                        cmd: 407,
                                        subCmd: 0,
                                        needAck: 1
                                    )
                                    if let sealed = try? srvCrypto.sealFrame(push407.payload) {
                                        serverConn.send(content: sealed, completion: .contentProcessed { _ in })
                                    }
                                } else if elem.cmd == 423 {
                                    if elem.bodyData.count == 12,
                                       (try? elem.bodyData.readInt32LE(at: 4)) == 88_776_655,
                                       (try? elem.bodyData.readInt32LE(at: 8)) == 407 {
                                        expAutoAck423.fulfill()
                                        let ansJson = #"{"error_code":0,"data":{"id":88776655,"partnerId":100000106,"status":0}}"#
                                        let push403 = ZolaCrypto.packServerChatElementFrame(
                                            bodyData: Data(ansJson.utf8),
                                            srcId: 100_000_106,
                                            msgType: 1,
                                            cmd: 403,
                                            subCmd: 0
                                        )
                                        if let sealed = try? srvCrypto.sealFrame(push403.payload) {
                                            serverConn.send(content: sealed, completion: .contentProcessed { _ in })
                                        }
                                    }
                                } else if elem.cmd == 406 {
                                    XCTAssertEqual(try? elem.bodyData.readInt32LE(at: 12), 88_776_655)
                                    XCTAssertEqual(try? elem.bodyData.readInt32LE(at: 8), 7)
                                    XCTAssertEqual(try? elem.bodyData.readInt32LE(at: 20), 0, "Native caller whoIdentity/sendType is0")
                                    expCallerFinish406.fulfill()
                                } else if elem.cmd == 409 || elem.cmd == 405 {
                                    expCancel405.fulfill()
                                }
                            }
                        }
                    }
                    if err == nil && !isComplete {
                        pumpEncryptedServer()
                    }
                }
            }
            serverConn.start(queue: serverQueue)
            pumpEncryptedServer()
        }

        let readyExp = expectation(description: "Encrypted listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { readyExp.fulfill() }
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let encryptedSession = try ZolaSession(
            uid: 100_000_101,
            sessionKey: sk61,
            cryptKey: Data(repeating: 0x33, count: 16),
            zcid: try ZolaCrypto.generateZCID(
                idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
                platform: "iP16Pro_@26.3.1_@NJ",
                timestampMs: 1_793_500_000_000
            ),
            zcidIsNative: true,
            socketServers: [
                ZolaSocketServer(
                    hostName: "127.0.0.1",
                    hostPort: Int(port),
                    key: 5,
                    pubKey: serverPubB64,
                    tagName: "chat"
                ),
            ],
            keySetId: staleId,
            keySetValue: staleKey32.base64EncodedString(),
            accessToken: "zk_rotate_access_token_secret",
            loginPhone: "+84909888777"
        )

        let mockHttp = MockZolaTransport(session: encryptedSession)
        mockHttp.mockKeySetId = freshId
        mockHttp.mockKeySetValue = freshKey32.base64EncodedString()
        let liveClient = ZolaClient(session: encryptedSession, transport: mockHttp, minPollIntervalSeconds: 0)
        await liveClient.setVoipEventHandler { ev in
            switch ev {
            case .ringing(callId: 88_776_655, partnerUid: 100_000_106):
                expRinging.fulfill()
            case .answered(callId: 88_776_655, partnerUid: 100_000_106):
                expAnswered.fulfill()
            default:
                break
            }
        }

        let liveReceipt = try await liveClient.startVoipCall(
            partnerUid: 100_000_106,
            callId: 444_555,
            isVideo: false,
            dryRun: false
        )
        XCTAssertTrue(liveReceipt.ok)
        XCTAssertEqual(liveReceipt.callId, 88_776_655)
        XCTAssertEqual(mockHttp.keySetAttempts, 1, "Must refresh getKeySet exactly once after -67")
        let rotatedSession = await liveClient.session
        XCTAssertEqual(rotatedSession.keySetId, freshId)

        await fulfillment(of: [expRejectedStale, expAuthSuccess, expRinging, expAutoAck423, expAnswered], timeout: 4.0)

        try await liveClient.cancelVoipCall(
            partnerUid: 100_000_106,
            callId: liveReceipt.callId,
            isVideo: false,
            durationSeconds: 7,
            dryRun: false
        )
        await fulfillment(of: [expCancel405, expCallerFinish406], timeout: 2.0)
        #endif
    }

    func testVoipVerifiedEndpointsCarryRealX25519PubKeys() throws {
        let eps = ZolaVoipProtocol.defaultVerifiedEncryptedEndpoints
        XCTAssertEqual(eps.count, 2)
        XCTAssertEqual(Set(eps.map { "\($0.host):\($0.port)" }), ["49.213.95.89:443", "49.213.95.90:443"])
        for ep in eps {
            XCTAssertTrue(ep.hasValidServerPubKey32, "\(ep.host) must carry a 32-byte X25519 pubKey")
            XCTAssertEqual(try XCTUnwrap(ep.serverPubKeyBase64.flatMap { Data(base64Encoded: $0) }).count, 32)
        }
    }

    func testVoipBinaryPrefixInterpretationForPushFrames() throws {
        // Binary `[partnerId:i32LE][callId:i32LE]` push frames (no JSON) must still resolve
        // partner + call id so cancel/end pushes are never dropped.
        var bin = Data()
        bin.append(contentsOf: [0x6A, 0xE1, 0xF5, 0x05]) // partnerId = 100_000_106
        bin.append(contentsOf: [0x08, 0x15, 0xA1, 0x04]) // callId = 77_665_544

        func unpack(_ cmd: Int16) throws -> ZolaUnpackedChatElement {
            try ZolaCrypto.unpackChatElementFrame(
                ZolaCrypto.packServerChatElementFrame(
                    bodyData: bin, srcId: 100_000_106, msgType: 1, cmd: cmd, subCmd: 0
                ).payload
            )
        }

        // `405` cancel → `.ended` resolved purely from the binary prefix.
        let cancel = ZolaVoipProtocol.interpretIncomingElement(
            try unpack(405),
            activeCallId: 77_665_544,
            clientCallId: 77_665_544,
            activePartnerUid: 0,
            selfUid: 100_000_101
        )
        XCTAssertEqual(cancel.resolvedCallId, 77_665_544)
        XCTAssertEqual(cancel.resolvedPartnerUid, 100_000_106)
        guard case .ended = try XCTUnwrap(cancel.event) else {
            return XCTFail("binary cmd=405 must produce .ended")
        }

        // `409` end → `.ended` with the same binary resolution.
        let end = ZolaVoipProtocol.interpretIncomingElement(
            try unpack(409),
            activeCallId: 77_665_544,
            clientCallId: 77_665_544,
            activePartnerUid: 0,
            selfUid: 100_000_101
        )
        XCTAssertEqual(end.resolvedPartnerUid, 100_000_106)
        guard case .ended = try XCTUnwrap(end.event) else {
            return XCTFail("binary cmd=409 must produce .ended")
        }

        // `415` confirm-incoming-ack push → no call event, but ids still resolve.
        let confirm = ZolaVoipProtocol.interpretIncomingElement(
            try unpack(415),
            activeCallId: 77_665_544,
            clientCallId: 77_665_544,
            activePartnerUid: 0,
            selfUid: 100_000_101
        )
        XCTAssertEqual(confirm.resolvedCallId, 77_665_544)
        XCTAssertEqual(confirm.resolvedPartnerUid, 100_000_106)

        // `402` invite in binary form → `.incomingInvite` with binary-resolved ids.
        let invite = ZolaVoipProtocol.interpretIncomingElement(
            try unpack(402),
            activeCallId: 0,
            clientCallId: 0,
            activePartnerUid: 0,
            selfUid: 100_000_101
        )
        guard case let .incomingInvite(callId, partnerUid, _, _, _, _, _, _) = try XCTUnwrap(invite.event) else {
            return XCTFail("binary cmd=402 must produce .incomingInvite")
        }
        XCTAssertEqual(callId, 77_665_544)
        XCTAssertEqual(partnerUid, 100_000_106)

        // The JSON variant stays intact (`415` JSON push is ignored as a call event).
        let json415 = try unpack(415)
        _ = json415
        let jsonElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":77665544,"partnerId":100000106,"neekACK":1}}"#.utf8),
                srcId: 100_000_106, msgType: 1, cmd: 415, subCmd: 0
            ).payload
        )
        let j = ZolaVoipProtocol.interpretIncomingElement(
            jsonElem,
            activeCallId: 77_665_544,
            clientCallId: 77_665_544,
            activePartnerUid: 100_000_106,
            selfUid: 100_000_101
        )
        XCTAssertEqual(j.resolvedCallId, 77_665_544)
        XCTAssertEqual(j.autoAckCmd, 415)
    }

    #if canImport(Network)
    func testVoipIncomingInviteAutoConfirms415AndRings407ThenAnswersAndStaysAlive() async throws {
        // Loopback `UXChatSocket` server: pushes `cmd=402` invite and records what the callee
        // sends back — expect `cmd=415` + `cmd=407(status=0)`, then answer `cmd=408` +
        // `cmd=402/subCmd=3`, and after `cancelVoipCall` the socket stays alive for call #2.
        let serverQueue = DispatchQueue(label: "test.voip.callee.server")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let expInvite = expectation(description: "client emits .incomingInvite")
        let exp415 = expectation(description: "server receives cmd=415 confirm ACK")
        let exp407 = expectation(description: "server receives cmd=407 status=0 ringing")
        let exp408 = expectation(description: "server receives cmd=408 answer")
        let exp402Answer = expectation(description: "server receives cmd=402/subCmd=3 answer")
        let expSecondInvite = expectation(description: "second cmd=402 handled on same socket")

        var pushedSecond = false

        listener.newConnectionHandler = { serverConn in
            var rxBuf = Data()
            var upgraded = false

            func pushInvite(_ callId: Int32) {
                let json = """
                {"error_code":0,"data":{"id":\(callId),"callerId":100000106,"callType":3,"dName":"Caller","extendData":{"sP2P":1,"p2p":"10.0.0.2:5000"}}}
                """
                let frame = ZolaCrypto.packServerChatElementFrame(
                    bodyData: Data(json.utf8),
                    srcId: 100_000_106,
                    msgType: 1,
                    cmd: 402,
                    subCmd: 0
                )
                serverConn.send(content: frame.payload, completion: .contentProcessed { _ in })
            }

            func pumpServer() {
                serverConn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, err in
                    if let chunk, !chunk.isEmpty {
                        rxBuf.append(chunk)
                        if !upgraded, let marker = rxBuf.range(of: ZolaVoipProtocol.httpHeaderEndMarker) {
                            rxBuf.removeSubrange(rxBuf.startIndex..<marker.upperBound)
                            upgraded = true
                            serverConn.send(content: Data("HTTP/1.1 200 OK\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                        }
                        while upgraded, rxBuf.count >= 23 {
                            guard let fSize = try? Data(rxBuf.prefix(4)).readUInt32LE(at: 0),
                                  rxBuf.count >= Int(fSize)
                            else { break }
                            let raw = Data(rxBuf.prefix(Int(fSize)))
                            rxBuf.removeFirst(Int(fSize))
                            guard let elem = try? ZolaCrypto.unpackChatElementFrame(raw) else { continue }

                            if elem.cmd == 1 {
                                // AUTHEN → ACK retCode=0, then push the first invite.
                                let ack = ZolaCrypto.packServerChatElementFrame(
                                    bodyData: Data(),
                                    srcId: 100_000_101,
                                    msgType: 3,
                                    cmd: 1,
                                    subCmd: 2,
                                    seqId: elem.seqId,
                                    retCode: 0
                                )
                                serverConn.send(content: ack.payload, completion: .contentProcessed { _ in })
                                pushInvite(66_777_888)
                            } else if elem.cmd == 415 {
                                // The second invite also triggers 415/407 — only the first call's
                                // frames fulfill the expectations (double-fulfill crashes XCTest).
                                if (try? elem.bodyData.readInt32LE(at: 4)) == 66_777_888 {
                                    exp415.fulfill()
                                    XCTAssertEqual(elem.bodyData.count, 12)
                                    XCTAssertEqual(try? elem.bodyData.readInt32LE(at: 0), 100_000_106)
                                }
                            } else if elem.cmd == 407 {
                                if (try? elem.bodyData.readInt32LE(at: 4)) == 66_777_888 {
                                    exp407.fulfill()
                                    XCTAssertEqual(try? elem.bodyData.readInt32LE(at: 8), 0)
                                }
                            } else if elem.cmd == 408 {
                                exp408.fulfill()
                                // After the answer completes, simulate the caller cancelling:
                                // push binary `cmd=405` end — the listener socket must stay alive,
                                // then a second `cmd=402` invite must still arrive on the same link.
                                if !pushedSecond {
                                    pushedSecond = true
                                    var endBin = Data()
                                    endBin.append(contentsOf: [0x6A, 0xE1, 0xF5, 0x05]) // 100_000_106
                                    endBin.append(contentsOf: [0x20, 0xF3, 0xFA, 0x03]) // 66_777_888
                                    let endFrame = ZolaCrypto.packServerChatElementFrame(
                                        bodyData: endBin,
                                        srcId: 100_000_106,
                                        msgType: 1,
                                        cmd: 405,
                                        subCmd: 0
                                    )
                                    serverConn.send(content: endFrame.payload, completion: .contentProcessed { _ in
                                        pushInvite(88_999_000)
                                    })
                                }
                            } else if elem.cmd == 402, elem.subCmd == 3 {
                                exp402Answer.fulfill()
                            }
                        }
                    }
                    if err == nil && !isComplete {
                        pumpServer()
                    }
                }
            }
            serverConn.start(queue: serverQueue)
            pumpServer()
        }

        let readyExp = expectation(description: "callee listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { readyExp.fulfill() }
        }
        listener.start(queue: serverQueue)
        await fulfillment(of: [readyExp], timeout: 3.0)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let authen = ZolaCrypto.packSocketAuthenFrame(
            srcId: 100_000_101,
            sessionKey: "sk_test_voip_callee",
            deviceModel: "iP16Pro",
            imei: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
            seqId: 1
        ).payload

        let sock = ZolaVoipSocketSession(
            selfUid: 100_000_101,
            authenPayload: authen,
            endpoints: [("127.0.0.1", port)],
            keepAliveAfterCallEnd: true,
            onEvent: { ev in
                if case let .incomingInvite(callId, partnerUid, _, _, _, _, _, _) = ev {
                    if callId == 66_777_888, partnerUid == 100_000_106 { expInvite.fulfill() }
                    if callId == 88_999_000 { expSecondInvite.fulfill() }
                }
            }
        )
        try await sock.connectAndAuthenticate()

        await fulfillment(of: [expInvite, exp415, exp407], timeout: 5.0)
        let extOpt = await sock.voipExtendData(forCallId: 66_777_888)
        let storedExt = try XCTUnwrap(extOpt)
        XCTAssertTrue(storedExt.contains("sP2P"))

        // Callee answers → `cmd=408` then `cmd=402/subCmd=3`.
        let seq408 = await sock.nextSeqId()
        try await sock.sendFrame(
            ZolaCrypto.packVoipRingingAckFrame(
                srcId: 100_000_101, partnerId: 100_000_106, callId: 66_777_888, status: 0, seqId: seq408
            )
        )
        let seqAnswer = await sock.nextSeqId()
        try await sock.sendFrame(
            ZolaCrypto.packVoipAnswerCallFrame(
                srcId: 100_000_101, partnerId: 100_000_106, callId: 66_777_888, seqId: seqAnswer
            )
        )
        await fulfillment(of: [exp408, exp402Answer], timeout: 5.0)

        // Server pushes binary `cmd=405` end + a second invite — keepAlive keeps the socket usable.
        await fulfillment(of: [expSecondInvite], timeout: 5.0)
        let aliveAfterFirstCall = await sock.isSocketAlive()
        XCTAssertTrue(aliveAfterFirstCall)

        await sock.close()
        let aliveAfterClose = await sock.isSocketAlive()
        XCTAssertFalse(aliveAfterClose)
    }
    #endif

    func testNativeVoipUserIdSelfUidGuardAnswer402SubCmd3End409AndZrtcPacketFraming() throws {
        // 1. Live `mac35` regression: `cmd = 402` has `data["userId"] == selfUid` (callee `100_000_103`),
        // `element.srcId == 100_000_102` (caller), and `"Dname": "Minh Anh -demo"`.
        let liveInviteJson = #"""
        {"error_code":0,"data":{"id":9051234,"userId":100000103,"Dname":"Minh Anh -demo","avatar":"https://ava.zalo.me/ma.jpg","callType":3,"rtpIP":"42.1.81.69:4200","sessId":"5xnTdsco6n0Q_live_token"}}
        """#
        let invElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(liveInviteJson.utf8),
                srcId: 100_000_102,
                msgType: 1,
                cmd: 402,
                subCmd: 0
            ).payload
        )
        let interpreted = ZolaVoipProtocol.interpretIncomingElement(
            invElem,
            activeCallId: 0,
            clientCallId: 0,
            activePartnerUid: 0,
            selfUid: 100_000_103
        )
        XCTAssertEqual(interpreted.resolvedPartnerUid, 100_000_102, "Must never resolve callee's own userId as partnerUid")
        guard case let .incomingInvite(callId, partnerUid, isVideo, callerName, _, rtp, rtcp, sess) = interpreted.event else {
            return XCTFail("Expected .incomingInvite")
        }
        XCTAssertEqual(callId, 9_051_234)
        XCTAssertEqual(partnerUid, 100_000_102)
        XCTAssertFalse(isVideo)
        XCTAssertEqual(callerName, "Minh Anh -demo")
        XCTAssertEqual(rtp, "42.1.81.69:4200")
        XCTAssertEqual(rtcp, "42.1.81.69:4200")
        XCTAssertEqual(sess, "5xnTdsco6n0Q_live_token")

        // Server `msgType = 3` ACK for `cmd = 402, subCmd = 3` must NEVER emit `.incomingInvite`.
        let answerAckElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0}"#.utf8),
                srcId: 100_000_103,
                msgType: 3,
                cmd: 402,
                subCmd: 3
            ).payload
        )
        let ackInterp = ZolaVoipProtocol.interpretIncomingElement(
            answerAckElem,
            activeCallId: 9_051_234,
            clientCallId: 9_051_234,
            activePartnerUid: 100_000_102,
            selfUid: 100_000_103
        )
        XCTAssertNil(ackInterp.event)

        // 2. `cmd = 402, subCmd = 3` exact 8-field `VoipRequestOperation` (`0x102f93234`) layout
        let ansFrame = ZolaCrypto.packVoipAnswerCallFrame(
            srcId: 100_000_103,
            partnerId: 100_000_102,
            callId: 9_051_234,
            status: 0,
            sessionId: "sess_tok",
            rtpAddress: "42.1.81.69:4200",
            rtpServer: "",
            codec: ZolaCrypto.defaultVoipCodecJson,
            paramsJson: #"{"ver":1}"#
        )
        let unpackedAns = try ZolaCrypto.unpackChatElementFrame(ansFrame.payload)
        XCTAssertEqual(unpackedAns.cmd, 402)
        XCTAssertEqual(unpackedAns.subCmd, 3)
        XCTAssertEqual(unpackedAns.needAck, 1)
        XCTAssertEqual(try unpackedAns.bodyData.readInt32LE(at: 0), 100_000_102)
        XCTAssertEqual(unpackedAns.bodyData[4], 0)
        XCTAssertEqual(try unpackedAns.bodyData.readInt32LE(at: 5), 9_051_234)
        XCTAssertEqual(try unpackedAns.bodyData.readUInt16LE(at: 9), 8) // "sess_tok"
        XCTAssertEqual(String(decoding: unpackedAns.bodyData[11..<19], as: UTF8.self), "sess_tok")
        XCTAssertEqual(try unpackedAns.bodyData.readUInt16LE(at: 19), 15) // "42.1.81.69:4200"
        XCTAssertEqual(String(decoding: unpackedAns.bodyData[21..<36], as: UTF8.self), "42.1.81.69:4200")
        XCTAssertEqual(try unpackedAns.bodyData.readUInt16LE(at: 36), 0) // rtpServer == ""

        // 3. `cmd = 409, subCmd = 0` active hangup layout (`0x102f94264`)
        let endFrame = ZolaCrypto.packVoipEndCallFrame(
            srcId: 100_000_103,
            partnerId: 100_000_102,
            callId: 9_051_234,
            sessionId: "sess_tok",
            rtpAddress: "42.1.81.69:4200"
        )
        let unpackedEnd = try ZolaCrypto.unpackChatElementFrame(endFrame.payload)
        XCTAssertEqual(unpackedEnd.cmd, 409)
        XCTAssertEqual(unpackedEnd.subCmd, 0)
        XCTAssertEqual(unpackedEnd.needAck, 1)
        XCTAssertEqual(try unpackedEnd.bodyData.readInt32LE(at: 0), 100_000_102)
        XCTAssertEqual(unpackedEnd.bodyData[4], 0)
        XCTAssertEqual(try unpackedEnd.bodyData.readInt32LE(at: 5), 9_051_234)

        for (reason, expectedStatus) in [(Int32(1), UInt8(0)), (2, 2), (12, 3)] {
            let mapped = ZolaCrypto.packVoipEndCallFrame(srcId: 100_000_103,
                partnerId: 100_000_102, callId: 9_051_234, reasonCode: reason)
            let decoded = try ZolaCrypto.unpackChatElementFrame(mapped.payload)
            XCTAssertEqual(decoded.bodyData[4], expectedStatus)
            XCTAssertEqual(try decoded.bodyData.readInt32LE(at: decoded.bodyData.count - 4), reason)
        }

        // 4. `libzrtc` UDP `ZRTCPacket` (`initZRTPToServer`, `ping`/`pong`, `0x7f` relay audio)
        let initCaller = ZolaCrypto.packZrtcInitServerPacket(
            isCaller: true,
            selfUid: 100_000_103,
            partnerUid: 100_000_102,
            callId: 9_051_234,
            sessionId: "sess_tok",
            seq: 1
        )
        XCTAssertEqual(initCaller.count, 31 + 8)
        XCTAssertEqual(initCaller[0], 0x01)
        XCTAssertEqual(initCaller[1], 0x00)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 2), 0)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 6), 1)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 10), 100_000_103)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 14), 0)
        XCTAssertEqual(try initCaller.readUInt16LE(at: 18), 11)
        XCTAssertEqual(initCaller[20], 2)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 21), 9_051_234)
        XCTAssertEqual(try initCaller.readUInt32LE(at: 25), 100_000_102)

        let initCallee = ZolaCrypto.packZrtcInitServerPacket(
            isCaller: false,
            selfUid: 100_000_103,
            partnerUid: 100_000_102,
            callId: 9_051_234,
            sessionId: "sess_tok",
            seq: 2
        )
        XCTAssertEqual(initCallee[1], 0x00)
        XCTAssertEqual(try initCallee.readUInt32LE(at: 6), 2)
        XCTAssertEqual(try initCallee.readUInt16LE(at: 18), 12)
        XCTAssertEqual(initCallee[20], 2)

        let ping = ZolaCrypto.packZrtcPingPacket(selfUid: 100_000_103, partnerUid: 100_000_102, callId: 9_051_234, seq: 7)
        XCTAssertEqual(ping.count, 25)
        XCTAssertEqual(ping[0], 0x01)
        XCTAssertEqual(ping[1], 0x00)
        XCTAssertEqual(try ping.readUInt32LE(at: 6), 7)
        XCTAssertEqual(try ping.readUInt32LE(at: 10), 100_000_103)
        XCTAssertEqual(try ping.readUInt32LE(at: 14), 100_000_102)
        XCTAssertEqual(try ping.readUInt16LE(at: 18), 3)
        XCTAssertEqual(ping[20], 3)
        XCTAssertEqual(try ping.readUInt32LE(at: 21), 9_051_234)
        let pong = try XCTUnwrap(ZolaCrypto.packZrtcPongPacket(fromPing: ping, selfUid: 100_000_102))
        XCTAssertEqual(pong.count, 25)
        XCTAssertEqual(pong[0], 0x02)
        XCTAssertEqual(try pong.readUInt32LE(at: 6), 7)
        XCTAssertEqual(try pong.readUInt32LE(at: 21), 9_051_234)

        let fakeRtp = Data([0x80, 113, 0x00, 0x01, 0x00, 0x00, 0x03, 0xC0, 0x00, 0x8A, 0x1C, 0x42, 0xAA, 0xBB])
        let relayAudio = ZolaCrypto.packZrtcRelayAudioPacket(isCaller: false, callId: 9_051_234, payload: fakeRtp)
        XCTAssertEqual(relayAudio[0], 0x7f)
        XCTAssertEqual(relayAudio[2], 0x01)
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioPayload(relayAudio), fakeRtp)
    }

    #if canImport(Network)
    func testSharedChatSocketMultiplexesFriendQueriesWithoutKickingVoipCall() async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.zolakit.test.shared0x7d0")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let readyExp = expectation(description: "Mock 0x7d0 listener ready")
        let answeredExp = expectation(description: "Call answered over shared 0x7d0")
        final class CounterBox: @unchecked Sendable {
            var acceptedCount = 0
            var activeServerConn: NWConnection?
            var unexpectedEndedEvents = 0
        }
        let box = CounterBox()

        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            box.acceptedCount += 1
            // Enforce Zalo's single-0x7d0-socket-per-UID behavior: any 2nd connection kicks the 1st!
            if let old = box.activeServerConn {
                old.cancel()
            }
            box.activeServerConn = conn
            conn.start(queue: serverQueue)

            var buf = Data()
            var upgraded = false
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, _ in
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
                                } else if el.cmd == 401 {
                                    let body = Data(#"{"error_code":0,"data":{"status":0,"id":880011,"sessId":"s_mux","serverAddr":[{"rtp":"42.1.81.69:4200","rtcp":"42.1.81.69:4200"}]}}"#.utf8)
                                    let resp = ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 100_000_102, msgType: 3, cmd: 401, subCmd: 1, seqId: el.seqId)
                                    conn.send(content: resp.payload, completion: .contentProcessed { _ in })
                                } else if el.cmd == ZolaConstants.cmdFriendRequestStatus {
                                    let body = Data(#"{"error_code":0,"data":{"isFriend":1,"status":1}}"#.utf8)
                                    let resp = ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 0, msgType: 3, cmd: ZolaConstants.cmdFriendRequestStatus, subCmd: 1, seqId: el.seqId)
                                    conn.send(content: resp.payload, completion: .contentProcessed { _ in })
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
            uid: 100_000_103,
            sessionKey: "sk_shared_mux_test",
            zcid: "native_zcid_shared_mux",
            zcidIsNative: true
        )
        let client = ZolaClient(
            session: session,
            voipLoopbackEndpoints: [("127.0.0.1", port)]
        )
        await client.setVoipEventHandler { ev in
            switch ev {
            case .answered(callId: 880_011, partnerUid: 100_000_102):
                answeredExp.fulfill()
            case .ended:
                box.unexpectedEndedEvents += 1
            default:
                break
            }
        }

        try await client.startVoipIncomingListener()
        let receipt = try await client.startVoipCall(partnerUid: 100_000_102, callId: 123_456)
        XCTAssertTrue(receipt.ok)
        XCTAssertEqual(receipt.callId, 880_011)

        // Simulate `ChatScreen` polling `getPeerFriendStatus` mid-call: must multiplex onto the same socket!
        let st1 = try await client.getPeerFriendStatus(100_000_102)
        let st2 = try await client.getPeerFriendStatus(100_000_102)
        XCTAssertTrue(st1.isFriend)
        XCTAssertTrue(st2.isFriend)
        XCTAssertEqual(box.acceptedCount, 1, "Must reuse single 0x7d0 socket instead of opening a 2nd connection that kicks active VoIP call")
        XCTAssertEqual(box.unexpectedEndedEvents, 0)

        // Push `cmd = 403` answer from server on the still-alive shared socket
        serverQueue.async {
            let ansBody = Data(#"{"error_code":0,"data":{"id":880011,"partnerId":100000102,"status":0}}"#.utf8)
            let push403 = ZolaCrypto.packServerChatElementFrame(bodyData: ansBody, srcId: 100_000_102, msgType: 1, cmd: 403, subCmd: 1, seqId: 99)
            box.activeServerConn?.send(content: push403.payload, completion: .contentProcessed { _ in })
        }
        await fulfillment(of: [answeredExp], timeout: 3.0)
        XCTAssertEqual(box.unexpectedEndedEvents, 0)

        await client.stopVoipIncomingListener()
    }
    #endif

    #if canImport(Network)
    func testIncomingCallAnswerAckCmd408MsgType3AndBidirectionalZrtcRelay() async throws {
        let serverQueue = DispatchQueue(label: "com.zolakit.zolakit.test.cmd408")
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }

        let readyExp = expectation(description: "0x7d0 server ready")
        let inviteExp = expectation(description: "Callee received 402 invite")
        let autoRingExp = expectation(description: "Server received callee 415 + 407")
        let answered408Exp = expectation(description: "Callee received cmd=408 msgType=3 answer confirmation")
        let hangup409Exp = expectation(description: "Server received cmd=409 connected hangup")
        let secondInviteExp = expectation(description: "Second incoming call")
        let secondFinishExp = expectation(description: "Unacknowledged second call finish")

        final class ServerState: @unchecked Sendable {
            var activeConn: NWConnection?
            var saw415 = false
            var saw407 = false
            var saw402Answer = false
            var saw409 = false
            var count406 = 0
            var subCmd406: Int8 = 0
            var finishReports: [Int32: (status: Int32, duration: Int32, role: Int32)] = [:]
            var unexpectedEvents = 0
        }
        let state = ServerState()

        listener.stateUpdateHandler = { st in
            if case .ready = st { readyExp.fulfill() }
        }
        listener.newConnectionHandler = { conn in
            state.activeConn = conn
            conn.start(queue: serverQueue)
            var buf = Data()
            var upgraded = false
            func pump() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, _ in
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
                                case 415:
                                    state.saw415 = true
                                    if state.saw407 && state.count406 == 0 { autoRingExp.fulfill() }
                                case 407:
                                    if !state.saw407 {
                                        state.saw407 = true
                                        if state.saw415 { autoRingExp.fulfill() }
                                    }
                                case 402 where el.subCmd == 3:
                                    state.saw402Answer = true
                                    // 1. Server sends raw request ACK (`cmd = 402, subCmd = 3, msgType = 3`) — MUST be ignored!
                                    let ack402 = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 402, subCmd: 3, seqId: el.seqId)
                                    conn.send(content: ack402.payload, completion: .contentProcessed { _ in })
                                    // 2. Server sends `cmd = 408, msgType = 3` (`didReceiveCallRequestAnswerACK:`) with updated relay endpoint — MUST NOT be dropped!
                                    let body408 = Data(#"{"error_code":0,"data":{"id":991122,"partnerId":100000102,"rtpIP":"42.1.81.70:4202","sessId":"sess_408_live"}}"#.utf8)
                                    let ack408 = ZolaCrypto.packServerChatElementFrame(bodyData: body408, srcId: 100_000_102, msgType: 3, cmd: 408, subCmd: 0, seqId: el.seqId)
                                    conn.send(content: ack408.payload, completion: .contentProcessed { _ in })
                                case 409:
                                    XCTAssertEqual(el.bodyData[4], 0, "Ordinary native hangup reason1 uses status byte0")
                                    XCTAssertEqual(try? el.bodyData.readInt32LE(at: el.bodyData.count - 4), 1)
                                    if !state.saw409 {
                                        state.saw409 = true
                                        // Server sends `cmd = 409, msgType = 3` ACK — MUST be ignored without duplicate `.ended`!
                                        let ack409 = ZolaCrypto.packServerChatElementFrame(bodyData: Data(), srcId: el.srcId, msgType: 3, cmd: 409, subCmd: 0, seqId: el.seqId)
                                        conn.send(content: ack409.payload, completion: .contentProcessed { _ in })
                                    }
                                case 406:
                                    state.count406 += 1
                                    state.subCmd406 = el.subCmd
                                    if let cid = try? el.bodyData.readInt32LE(at: 12),
                                       let status = try? el.bodyData.readInt32LE(at: 4),
                                       let duration = try? el.bodyData.readInt32LE(at: 8),
                                       let role = try? el.bodyData.readInt32LE(at: 20) {
                                        state.finishReports[cid] = (status, duration, role)
                                        if cid == 991_123 { secondFinishExp.fulfill() }
                                    }
                                    if state.saw409 && state.count406 == 1 {
                                        hangup409Exp.fulfill()
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

        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_cmd408_test",
            zcid: "native_zcid_cmd408",
            zcidIsNative: true
        )
        let client = ZolaClient(
            session: session,
            voipLoopbackEndpoints: [("127.0.0.1", port)]
        )
        await client.setVoipEventHandler { ev in
            switch ev {
            case .incomingInvite(let cid, let pid, _, _, _, _, _, _):
                if cid == 991_122 && pid == 100_000_102 {
                    inviteExp.fulfill()
                } else if cid == 991_123 && pid == 100_000_102 {
                    secondInviteExp.fulfill()
                }
            case .answered(let cid, let pid):
                if cid == 991_122 && pid == 100_000_102 {
                    answered408Exp.fulfill()
                } else {
                    state.unexpectedEvents += 1
                }
            case .ended, .failed, .rejected:
                state.unexpectedEvents += 1
            default:
                break
            }
        }

        try await client.startVoipIncomingListener()

        // Push `cmd = 402` incoming invite from caller `100000102`
        serverQueue.async {
            let invJson = Data(#"{"error_code":0,"data":{"id":991122,"userId":100000103,"callType":3,"Dname":"Minh Anh -demo","rtpIP":"42.1.81.69:4200","sessId":"sess_init"}}"#.utf8)
            let invFrame = ZolaCrypto.packServerChatElementFrame(bodyData: invJson, srcId: 100_000_102, msgType: 1, cmd: 402, subCmd: 0, seqId: 10)
            state.activeConn?.send(content: invFrame.payload, completion: .contentProcessed { _ in })
        }

        await fulfillment(of: [inviteExp, autoRingExp], timeout: 3.0)

        // Callee answers (`cmd = 402, subCmd = 3`) -> server replies `402/3 msgType=3` + `408 msgType=3`
        try await client.answerVoipCall(
            partnerUid: 100_000_102,
            callId: 991_122,
            localEndpoint: "192.168.1.50:32000",
            rtpAddress: "42.1.81.69:4200",
            sessionId: "sess_init"
        )
        await fulfillment(of: [answered408Exp], timeout: 3.0)
        XCTAssertTrue(state.saw402Answer)

        let endpoints = await client.voipCallEndpoints(forCallId: 991_122)
        XCTAssertEqual(endpoints?.rtpAddress, "42.1.81.70:4202")
        XCTAssertEqual(endpoints?.sessionId, "sess_408_live")
        XCTAssertEqual(state.unexpectedEvents, 0)

        // Hang up connected call (`isConnected: true` -> sends `cmd = 409` + single `406/subCmd=3`)
        try await client.cancelVoipCall(
            partnerUid: 100_000_102,
            callId: 991_122,
            durationSeconds: 7,
            isConnected: true
        )
        await fulfillment(of: [hangup409Exp], timeout: 3.0)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.count406, 1, "cancelVoipCall must send exactly ONE cmd=406 frame (subCmd=3) so server never inserts duplicate call bubbles")
        XCTAssertEqual(state.subCmd406, 3)
        XCTAssertEqual(state.unexpectedEvents, 0)
        XCTAssertEqual(state.finishReports[991_122]?.status, 0, "Exact408-confirmed callee uses empirically verified neutral finish status; ACK163 is not a successful media outcome")
        XCTAssertEqual(state.finishReports[991_122]?.duration, 7)
        XCTAssertEqual(state.finishReports[991_122]?.role, 1)

        // Redial on the same peer: an old408 must not mark this new incoming call answered.
        serverQueue.async {
            let invite = ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":991123,"userId":100000103,"callType":3}}"#.utf8),
                srcId: 100_000_102, msgType: 1, cmd: 402, subCmd: 0, seqId: 20)
            let staleAck = ZolaCrypto.packServerChatElementFrame(
                bodyData: Data(#"{"error_code":0,"data":{"id":991122,"partnerId":100000102}}"#.utf8),
                srcId: 100_000_102, msgType: 3, cmd: 408, subCmd: 0, seqId: 21)
            state.activeConn?.send(content: invite.payload + staleAck.payload, completion: .contentProcessed { _ in })
        }
        await fulfillment(of: [secondInviteExp], timeout: 3)
        try await client.cancelVoipCall(partnerUid: 100_000_102, callId: 991_123,
                                        durationSeconds: 7, isConnected: true)
        await fulfillment(of: [secondFinishExp], timeout: 3)
        XCTAssertEqual(state.finishReports[991_123]?.status, 160, "No408 for this call: preserve old unconfirmed behavior")
        XCTAssertEqual(state.finishReports[991_123]?.role, 1)
        XCTAssertEqual(state.unexpectedEvents, 0)

        await client.stopVoipIncomingListener()
    }
    #endif

    #if canImport(Network)
    #if canImport(AVFoundation) && canImport(AudioToolbox)
    func testMediaEnginePostAnswerRelayUpdateSinglePathAndRtpDeduplication() async throws {
        let udpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.zrtc.udp")
        let relayListener = try NWListener(using: .udp, on: .any)
        let candidateListener = try NWListener(using: .udp, on: .any)
        defer {
            relayListener.cancel()
            candidateListener.cancel()
        }

        let relayReady = expectation(description: "Relay UDP ready")
        let candidateReady = expectation(description: "P2P candidate UDP ready")
        let sawInit12 = expectation(description: "Relay received ZRTC init pktCmd=12 after updateRelaySession")
        let sawRelayAudio0x03 = expectation(description: "Relay received 0x03 + CallToken 1-1 audio packet")

        final class RelayCapture: @unchecked Sendable {
            var candidatePacketCount = 0
            var relayAudioCount = 0
            var lastOutboundToken: UInt32 = 0
            var lastOutboundInnerRtp = Data()
            var didFulfillInit = false
            var didFulfillAudio = false
        }
        let capture = RelayCapture()
        let expectedRelayToken: UInt32 = 0x6A10_AD79

        relayListener.stateUpdateHandler = { st in if case .ready = st { relayReady.fulfill() } }
        candidateListener.stateUpdateHandler = { st in if case .ready = st { candidateReady.fulfill() } }

        relayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pump() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, !data.isEmpty {
                        if data.first == 0x01, data.count >= 20, (try? data.readUInt16LE(at: 18)) == 12 {
                            if !capture.didFulfillInit {
                                capture.didFulfillInit = true
                                sawInit12.fulfill()
                            }
                            if let ack = ZolaCrypto.packZrtcPongPacket(
                                fromPing: data,
                                selfUid: 0,
                                relayToken: expectedRelayToken
                            ) {
                                conn.send(content: ack, completion: .contentProcessed { _ in })
                            }
                            // Send identical RTP packet TWICE wrapped in `0x04` (real 1-1 `:4200` relay->client header)
                            // + a 2nd distinct seq packet to verify continuous UDP pumping & deduplication!
                            let rtp1 = ZolaVoipMediaEngine.buildRtpPacket(
                                payloadType: 0, // PCMU
                                sequenceNumber: 4242,
                                timestamp: 960,
                                ssrc: 0x11223344,
                                payload: Data(repeating: 0x7F, count: 160)
                            )
                            let rtp2 = ZolaVoipMediaEngine.buildRtpPacket(
                                payloadType: 0, // PCMU
                                sequenceNumber: 4243,
                                timestamp: 1920,
                                ssrc: 0x11223344,
                                payload: Data(repeating: 0x7F, count: 160)
                            )
                            let wrapped1 = ZolaCrypto.packZrtcOneToOneRelayInboundPacket(rtpPayload: rtp1)
                            let wrapped2 = ZolaCrypto.packZrtcOneToOneRelayInboundPacket(rtpPayload: rtp2)
                            conn.send(content: wrapped1, completion: .contentProcessed { _ in })
                            conn.send(content: wrapped1, completion: .contentProcessed { _ in })
                            conn.send(content: wrapped2, completion: .contentProcessed { _ in })
                        } else if data.first == 0x03, data.count > 5 {
                            capture.relayAudioCount += 1
                            capture.lastOutboundToken = (try? data.readUInt32LE(at: 1)) ?? 0
                            capture.lastOutboundInnerRtp = data.subdata(in: 5..<data.count)
                            if !capture.didFulfillAudio {
                                capture.didFulfillAudio = true
                                sawRelayAudio0x03.fulfill()
                            }
                        }
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pump()
                }
            }
            pump()
        }

        candidateListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pump() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, !data.isEmpty {
                        capture.candidatePacketCount += 1
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pump()
                }
            }
            pump()
        }

        relayListener.start(queue: udpQueue)
        candidateListener.start(queue: udpQueue)
        await fulfillment(of: [relayReady, candidateReady], timeout: 3.0)
        let relayPort = try XCTUnwrap(relayListener.port?.rawValue)
        let candidatePort = try XCTUnwrap(candidateListener.port?.rawValue)

        // Start transport BEFORE `cmd = 408` arrives (`sessionId` initially empty, initial dummy port = candidatePort)
        let media = ZolaVoipMediaEngine(callId: 991_122)
        media.forceZrtcFramingOnLoopback = true
        defer { media.stop() }

        let candEp = ZolaVoipMediaEngine.MediaEndpoint(host: "127.0.0.1", port: candidatePort)
        try media.prepareTransport(relay: candEp, p2pEndpoints: [candEp])

        // Verify `parseP2PEndpoints` excludes `rtpServerAddr`/`rtpIP` so relay is never duplicated as a P2P candidate
        let parsedP2P = ZolaVoipMediaEngine.parseP2PEndpoints(
            fromExtendData: #"{"rtpServerAddr":"42.1.81.70:4202","rtpIP":"42.1.81.70:4202","p2pAddr":"192.168.1.20:35000"}"#
        )
        XCTAssertEqual(parsedP2P, [ZolaVoipMediaEngine.MediaEndpoint(host: "192.168.1.20", port: 35_000)])

        // Now `cmd = 408` arrives post-answer -> `updateRelaySession` switches primary relay + `sess_408_live`
        let realRelayEp = ZolaVoipMediaEngine.MediaEndpoint(host: "127.0.0.1", port: relayPort)
        media.updateRelaySession(
            relay: realRelayEp,
            isCaller: false,
            selfUid: 100_000_103,
            partnerUid: 100_000_102,
            sessionId: "sess_408_live"
        )

        await fulfillment(of: [sawInit12], timeout: 3.0)

        // Inject outbound RTP packet: must go ONLY to `realRelayEp` as `0x03 + CallToken` (zero packets to `candidatePort`!)
        let outRtp = ZolaVoipMediaEngine.buildRtpPacket(
            payloadType: 0,
            sequenceNumber: 1,
            timestamp: 960,
            ssrc: UInt32(bitPattern: 991_122),
            payload: Data(repeating: 0xFF, count: 160)
        )
        media.sendTestRtpPacket(outRtp)
        await fulfillment(of: [sawRelayAudio0x03], timeout: 3.0)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(media.relayToken, expectedRelayToken)
        XCTAssertEqual(capture.relayAudioCount, 1)
        XCTAssertEqual(capture.lastOutboundToken, expectedRelayToken, "Outbound 1-1 ZRTC relay RTP must carry the 4-byte CallToken from 0x02 ACK")
        XCTAssertEqual(capture.lastOutboundInnerRtp, outRtp)
        XCTAssertEqual(capture.candidatePacketCount, 0, "Single-path ZRTC relay must NOT blast duplicate P2P copies to unverified P2P candidates")
        XCTAssertEqual(media.decodedFrameCount, 2, "3 inbound 0x04 ZRTC packets (seq 4242 x2 + seq 4243 x1) after 0x02 ACK must continuously pump UDP and decode exactly 2 deduplicated frames")
    }
    #endif
    #endif

    #if canImport(Network)
    #if canImport(AVFoundation) && canImport(AudioToolbox)
    func testStartVoipCallCompletesZrtcUdpRelayHandshakeBeforeSendingCmd416() async throws {
        let tcpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.pre416.tcp")
        let udpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.pre416.udp")
        let tcpListener = try NWListener(using: .tcp, on: .any)
        let udpRelayListener = try NWListener(using: .udp, on: .any)
        defer {
            tcpListener.cancel()
            udpRelayListener.cancel()
        }

        let tcpReady = expectation(description: "Mock 0x7d0 TCP ready")
        let udpReady = expectation(description: "Mock :4200 UDP relay ready")
        let ringingExp = expectation(description: "Received cmd=407 continuous ringing")

        final class OrderingBox: @unchecked Sendable {
            private let lock = NSLock()
            var timeline: [String] = []
            var cmd416PayloadUtf8: String = ""
            func record(_ event: String) {
                lock.lock()
                timeline.append(event)
                lock.unlock()
            }
            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return timeline
            }
        }
        let box = OrderingBox()

        tcpListener.stateUpdateHandler = { st in if case .ready = st { tcpReady.fulfill() } }
        udpRelayListener.stateUpdateHandler = { st in if case .ready = st { udpReady.fulfill() } }

        udpRelayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pumpUdp() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, data.count >= 31, data[0] == 0x01, (try? data.readUInt16LE(at: 18)) == 11 {
                        box.record("udp:init11")
                        // Build exact 54-byte live-shaped `0x02` `InitZRTP` response (`retCode=0 @ 21`, `callId @ 25`, `addrLen=19 @ 33`, ASCII `"58.187.162.19:51515" @ 35`).
                        let seq = (try? data.readUInt32LE(at: 6)) ?? 1
                        let selfUidWord = (try? data.readUInt32LE(at: 10)) ?? 0
                        let callIdWord = (try? data.readUInt32LE(at: 21)) ?? 0
                        let reflectedAscii = Data("58.187.162.19:51515".utf8)
                        var ack = Data(capacity: 35 + reflectedAscii.count)
                        ack.append(0x02)
                        ack.append(0x00)
                        ack.appendUInt32LE(0)
                        ack.appendUInt32LE(seq)
                        ack.appendUInt32LE(selfUidWord)
                        ack.appendUInt32LE(0)
                        ack.appendUInt16LE(11)
                        ack.append(0x02)
                        ack.appendUInt32LE(0) // `retCode = 0`
                        ack.appendUInt32LE(callIdWord)
                        ack.appendUInt32LE(0xFA95_CA05)
                        ack.appendUInt16LE(UInt16(reflectedAscii.count))
                        ack.append(reflectedAscii)
                        conn.send(content: ack, completion: .contentProcessed { _ in
                            box.record("udp:ack02")
                        })
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pumpUdp()
                }
            }
            pumpUdp()
        }

        udpRelayListener.start(queue: udpQueue)
        await fulfillment(of: [udpReady], timeout: 3.0)
        let udpPort = try XCTUnwrap(udpRelayListener.port?.rawValue)

        tcpListener.newConnectionHandler = { conn in
            conn.start(queue: tcpQueue)
            var buf = Data()
            var upgraded = false
            func pumpTcp() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { chunk, _, isComplete, _ in
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
                                } else if el.cmd == 401 {
                                    box.record("tcp:401")
                                    let rtpStr = "127.0.0.1:\(udpPort)"
                                    let body = Data(#"{"error_code":0,"data":{"status":0,"id":770055,"sessId":"sess_pre416_live","serverAddr":[{"rtp":"\#(rtpStr)","rtcp":"\#(rtpStr)"}]}}"#.utf8)
                                    let resp = ZolaCrypto.packServerChatElementFrame(bodyData: body, srcId: 100_000_102, msgType: 3, cmd: 401, subCmd: 1, seqId: el.seqId)
                                    conn.send(content: resp.payload, completion: .contentProcessed { _ in })
                                } else if el.cmd == 416 {
                                    box.record("tcp:416")
                                    box.cmd416PayloadUtf8 = String(decoding: el.bodyData, as: UTF8.self)
                                    // Push live-shaped `cmd=407` with nested `extraData` JSON string carrying callee's P2P candidates (`status: 0`).
                                    let ringJson = #"{"error_code":0,"data":{"id":770055,"status":0,"neekACK":1,"extraData":"{\"audioCodec\":{},\"extendData\":{\"callType\":0,\"p2p\":[{\"ip\":\"192.168.1.9\",\"port\":53827,\"type\":0},{\"ip\":\"58.187.162.19\",\"port\":53827,\"type\":1}]}}"}}"#
                                    let ringPush = ZolaCrypto.packServerChatElementFrame(bodyData: Data(ringJson.utf8), srcId: 100_000_102, msgType: 1, cmd: 407, subCmd: 0, seqId: 99)
                                    conn.send(content: ringPush.payload, completion: .contentProcessed { _ in })
                                }
                            }
                        }
                    }
                    if !isComplete { pumpTcp() }
                }
            }
            pumpTcp()
        }

        tcpListener.start(queue: tcpQueue)
        await fulfillment(of: [tcpReady], timeout: 3.0)
        let tcpPort = try XCTUnwrap(tcpListener.port?.rawValue)

        let session = try ZolaSession(
            uid: 100_000_103,
            sessionKey: "sk_pre416_test",
            zcid: "native_zcid_pre416",
            zcidIsNative: true
        )
        let client = ZolaClient(
            session: session,
            voipLoopbackEndpoints: [("127.0.0.1", tcpPort)]
        )
        await client.setVoipEventHandler { ev in
            if case .ringing(callId: 770_055, partnerUid: 100_000_102) = ev {
                ringingExp.fulfill()
            }
        }

        let receipt = try await client.startVoipCall(
            partnerUid: 100_000_102,
            callId: 111_222,
            localEndpoint: "192.168.1.35:49000"
        )
        XCTAssertTrue(receipt.ok)
        XCTAssertEqual(receipt.callId, 770_055)

        let prepared = await client.takePreparedVoipMediaEngine(forCallId: 770_055)
        let engine = try XCTUnwrap(prepared, "ZolaClient.startVoipCall must retain the pre-416 registered ZolaVoipMediaEngine for single-socket continuity")
        defer { engine.stop() }
        XCTAssertTrue(engine.isRelayHandshakeConfirmed)
        XCTAssertEqual(engine.reflectedPublicEndpoint, "58.187.162.19:51515")

        await fulfillment(of: [ringingExp], timeout: 3.0)

        let events = box.snapshot()
        guard let idx401 = events.firstIndex(of: "tcp:401"),
              let idxInit11 = events.firstIndex(of: "udp:init11"),
              let idx416 = events.firstIndex(of: "tcp:416")
        else {
            return XCTFail("Missing expected protocol sequence in \(events)")
        }
        XCTAssertLessThan(idx401, idxInit11, "InitZRTP (pktCmd=11) must follow cmd=401")
        XCTAssertLessThan(idxInit11, idx416, "InitZRTP (pktCmd=11) MUST be sent and ACKed BEFORE cmd=416 so callee never drops with status=5")
        XCTAssertTrue(box.cmd416PayloadUtf8.contains("58.187.162.19"), "cmd=416 externData must advertise STUN-reflected type=1 P2P candidate")
        XCTAssertTrue(box.cmd416PayloadUtf8.contains("51515"))

        let rawCtx = await client.voipCallEndpoints(forCallId: 770_055)
        let ctx = try XCTUnwrap(rawCtx)
        XCTAssertEqual(ctx.rtpAddress, "127.0.0.1:\(udpPort)", "cmd=407 must not clobber registered caller relay rtpAddress")
        let peerCandidates = ZolaVoipMediaEngine.parseP2PEndpoints(fromExtendData: ctx.extendData)
        XCTAssertTrue(peerCandidates.contains(ZolaVoipMediaEngine.MediaEndpoint(host: "192.168.1.9", port: 53_827)))
        XCTAssertTrue(peerCandidates.contains(ZolaVoipMediaEngine.MediaEndpoint(host: "58.187.162.19", port: 53_827)))

        try await client.cancelVoipCall(partnerUid: 100_000_102, callId: 770_055)
    }
    #endif
    #endif

    func testZrtcOneToOneFramingCallTokenAndRtcpRejection() throws {
        let reflectedAscii = Data("58.187.162.19:51515".utf8)
        var ack = Data()
        ack.append(0x02)
        ack.append(0x00)
        ack.appendUInt32LE(0)
        ack.appendUInt32LE(9) // seq @ 6..9
        ack.appendUInt32LE(100_000_103) // selfUid @ 10..13
        ack.appendUInt32LE(0)
        ack.appendUInt16LE(11) // pktCmd @ 18..19
        ack.append(0x02)
        ack.appendUInt32LE(0) // retCode = 0 @ 21..24
        ack.appendUInt32LE(770_055) // callId @ 25..28
        ack.appendUInt32LE(0xFA95_CA05) // CallToken @ 29..32
        ack.appendUInt16LE(UInt16(reflectedAscii.count)) // addrLen @ 33..34
        ack.append(reflectedAscii) // @ 35..53

        let parsedAck = try XCTUnwrap(ZolaCrypto.parseZrtcInitServerAck(ack))
        XCTAssertEqual(parsedAck.seq, 9)
        XCTAssertEqual(parsedAck.pktCmd, 11)
        XCTAssertEqual(parsedAck.retCode, 0)
        XCTAssertEqual(parsedAck.callId, 770_055)
        XCTAssertEqual(parsedAck.token, 0xFA95_CA05)
        XCTAssertEqual(parsedAck.reflectedAddress, "58.187.162.19:51515")
        XCTAssertNil(ZolaCrypto.parseZrtcInitServerAck(Data(ack.prefix(32))), "Truncated retCode=0 ACK without 4-byte CallToken must be rejected")

        let fakeRtp = Data([0x80, 113, 0x00, 0x10, 0x00, 0x00, 0x03, 0xC0, 0x00, 0x0B, 0xBF, 0xC7, 0x78, 0x01, 0x02])
        let outRelay = ZolaCrypto.packZrtcOneToOneRtpPacket(isP2P: false, token: 0xFA95_CA05, rtpPayload: fakeRtp)
        XCTAssertEqual(outRelay[0], 0x03)
        XCTAssertEqual(try outRelay.readUInt32LE(at: 1), 0xFA95_CA05)
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioPayload(outRelay), fakeRtp)

        let outP2P = ZolaCrypto.packZrtcOneToOneRtpPacket(isP2P: true, token: 0xFA95_CA05, rtpPayload: fakeRtp)
        XCTAssertEqual(outP2P[0], 0x05)
        XCTAssertEqual(try outP2P.readUInt32LE(at: 1), 0xFA95_CA05)
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioPayload(outP2P), fakeRtp)

        let inRelay = ZolaCrypto.packZrtcOneToOneRelayInboundPacket(rtpPayload: fakeRtp)
        XCTAssertEqual(inRelay[0], 0x04)
        XCTAssertEqual(inRelay.count, 1 + fakeRtp.count)
        XCTAssertEqual(ZolaCrypto.unpackZrtcAudioPayload(inRelay), fakeRtp)

        // RTCP / video wrappers must NEVER unwrap as audio RTP!
        for rejectedHeader: UInt8 in [0x07, 0x0d, 0x0e, 0x0f, 0x01, 0x02] {
            var pkt = Data([rejectedHeader, 0x01, 0x02, 0x03, 0x04])
            pkt.append(fakeRtp)
            XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(pkt), "Header 0x\(String(rejectedHeader, radix: 16)) must be rejected")
        }
        let groupRtcp = ZolaCrypto.packZrtcRelayAudioPacket(isCaller: true, callId: 770_055, payload: fakeRtp, pktCmd: 7)
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(groupRtcp))
    }

    #if canImport(AVFoundation) && canImport(AudioToolbox)
    func testOpusVariableDuration20ms40ms60msCoreAudioDecode() throws {
        let media = ZolaVoipMediaEngine(callId: 770_055)
        defer { media.stop() }

        func makeSine20msFrame(frameIndex: Int) -> Data {
            var pcm = Data(capacity: 960 * 2)
            let baseSample = frameIndex * 960
            for i in 0..<960 {
                let phase = 2.0 * Double.pi * 440.0 * Double(baseSample + i) / 48_000.0
                let v = Int16((sin(phase) * 14_000.0).rounded())
                pcm.append(UInt8(truncatingIfNeeded: v))
                pcm.append(UInt8(truncatingIfNeeded: v >> 8))
            }
            return pcm
        }

        func rmsOfPcm16(_ data: Data) -> Double {
            let count = data.count / 2
            guard count > 0 else { return 0 }
            var sumSq = 0.0
            data.withUnsafeBytes { raw in
                guard let ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<count {
                    let s = Double(ptr[i])
                    sumSq += s * s
                }
            }
            return (sumSq / Double(count)).squareRoot()
        }

        // Prime encoder across 4 continuous 20ms 440Hz frames
        _ = try XCTUnwrap(media.encodeOpusFrameForTesting(makeSine20msFrame(frameIndex: 0)))
        let f1 = try XCTUnwrap(media.encodeOpusFrameForTesting(makeSine20msFrame(frameIndex: 1)))
        let f2 = try XCTUnwrap(media.encodeOpusFrameForTesting(makeSine20msFrame(frameIndex: 2)))
        let f3 = try XCTUnwrap(media.encodeOpusFrameForTesting(makeSine20msFrame(frameIndex: 3)))

        // 1. 20ms single-frame Opus packet (`code = 0`, 960 samples)
        XCTAssertEqual(ZolaVoipMediaEngine.opusPacketSampleCount(f1), 960)
        let dec20 = try XCTUnwrap(media.decodeOpusPacketForTesting(f1))
        XCTAssertGreaterThanOrEqual(dec20.count, 800 * 2)
        XCTAssertLessThanOrEqual(dec20.count, 960 * 2)
        let dec20Second = try XCTUnwrap(media.decodeOpusPacketForTesting(f2))
        XCTAssertGreaterThan(rmsOfPcm16(dec20Second), 1_500, "Decoded 20ms Opus sine wave must carry strong audible energy")

        // 2. 40ms RFC 6716 `code = 1` equal-length 2-frame Opus packet (1_920 samples)
        let tocBase = f2[f2.startIndex] & 0xFC
        let body2 = f2.dropFirst()
        var pkt40 = Data([tocBase | 0x01])
        pkt40.append(body2)
        pkt40.append(body2)
        XCTAssertEqual(ZolaVoipMediaEngine.opusPacketSampleCount(pkt40), 1_920)
        let dec40 = try XCTUnwrap(media.decodeOpusPacketForTesting(pkt40))
        XCTAssertEqual(dec40.count, 1_920 * 2)
        XCTAssertGreaterThan(rmsOfPcm16(dec40), 1_500, "Decoded 40ms Opus packet must carry strong audible energy")

        // 3. 60ms RFC 6716 `code = 3` VBR 3-frame Opus packet (`maxFT: 60` = 2_880 samples!)
        let b1 = f1.dropFirst()
        let b2 = f2.dropFirst()
        let b3 = f3.dropFirst()
        XCTAssertLessThan(b1.count, 252)
        XCTAssertLessThan(b2.count, 252)
        var pkt60Vbr = Data([tocBase | 0x03, 0x83, UInt8(b1.count), UInt8(b2.count)])
        pkt60Vbr.append(b1)
        pkt60Vbr.append(b2)
        pkt60Vbr.append(b3)
        XCTAssertEqual(ZolaVoipMediaEngine.opusPacketSampleCount(pkt60Vbr), 2_880)
        let dec60 = try XCTUnwrap(media.decodeOpusPacketForTesting(pkt60Vbr))
        XCTAssertEqual(dec60.count, 2_880 * 2, "60ms Opus packet (maxFT=60) must decode all 2880 samples instead of returning 0 frames")
        XCTAssertGreaterThan(rmsOfPcm16(dec60), 1_500, "Decoded 60ms Opus packet must carry strong audible energy")
    }
    #endif

    #if canImport(AVFoundation) && canImport(AudioToolbox)
    func testPrewarmedRelayPreservedAcrossPlaceholderEndpoint() async throws {
        let udpQueue = DispatchQueue(label: "com.zolakit.zolakit.test.prewarm.preserve")
        let relayListener = try NWListener(using: .udp, on: .any)
        defer { relayListener.cancel() }

        let relayReady = expectation(description: "Mock relay ready")
        relayListener.stateUpdateHandler = { st in if case .ready = st { relayReady.fulfill() } }
        relayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pump() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, data.first == 0x01, data.count >= 20, (try? data.readUInt16LE(at: 18)) == 11 {
                        if let ack = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0, relayToken: 0xCAFE_BABE) {
                            conn.send(content: ack, completion: .contentProcessed { _ in })
                        }
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pump()
                }
            }
            pump()
        }
        relayListener.start(queue: udpQueue)
        await fulfillment(of: [relayReady], timeout: 3.0)
        let relayPort = try XCTUnwrap(relayListener.port?.rawValue)
        let realRelay = ZolaVoipMediaEngine.MediaEndpoint(host: "127.0.0.1", port: relayPort)

        let media = ZolaVoipMediaEngine(callId: 551_122)
        media.forceZrtcFramingOnLoopback = true
        defer { media.stop() }

        media.configureZrtcSession(isCaller: true, selfUid: 100_000_103, partnerUid: 100_000_102, sessionId: "sess_keep")
        try media.prepareTransport(relay: realRelay)
        let confirmed = await media.waitForRelayHandshake(timeoutMs: 1_500)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(media.relayToken, 0xCAFE_BABE)
        XCTAssertEqual(media.currentRelayEndpoint, realRelay)

        // Calling prepareTransport again with placeholder 49.213.95.89:443 must NOT clobber the confirmed relay or token!
        try media.prepareTransport(relay: ZolaVoipMediaEngine.MediaEndpoint(host: "49.213.95.89", port: 443))
        XCTAssertTrue(media.isRelayHandshakeConfirmed)
        XCTAssertEqual(media.relayToken, 0xCAFE_BABE)
        XCTAssertEqual(media.currentRelayEndpoint, realRelay)
    }
    #endif

    func testVoipVideoSignalingFrames401416402407421AndZrtcVideoWireFormat() throws {
        // 1. cmd=401 MUST emit callType=3 (ZRTP v3) for BOTH voice and video — callType=4 caused server error 11100 ("Invalid Data")!
        let callVoice = ZolaCrypto.packVoipCallRequestFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_001, isVideo: false)
        let callVideo = ZolaCrypto.packVoipCallRequestFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_002, isVideo: true)
        let unpackedVoice401 = try ZolaCrypto.unpackChatElementFrame(callVoice.payload)
        let unpackedVideo401 = try ZolaCrypto.unpackChatElementFrame(callVideo.payload)
        XCTAssertEqual(unpackedVoice401.cmd, 401)
        XCTAssertEqual(unpackedVideo401.cmd, 401)
        XCTAssertEqual(unpackedVoice401.subCmd, 4)
        XCTAssertEqual(unpackedVideo401.subCmd, 4)
        XCTAssertEqual(unpackedVoice401.bodyData.first, 3)
        XCTAssertEqual(unpackedVideo401.bodyData.first, 3, "cmd=401 video callType must be 3 (ZRTP), never 4 (11100 Invalid Data)")

        // 2. cmd=405 (cancel) & cmd=407 (reject) use 2 for voice and 3 for video
        let cancelVoice = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipCancelCallFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_001, status: 1, isVideo: false).payload
        )
        let cancelVideo = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipCancelCallFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_002, status: 1, isVideo: true).payload
        )
        XCTAssertEqual(cancelVoice.bodyData[12], 2)
        XCTAssertEqual(cancelVideo.bodyData[12], 3)

        let rejectVoice = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipRejectCallFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_001, status: 506, isVideo: false).payload
        )
        let rejectVideo = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipRejectCallFrame(srcId: 100_000_103, partnerId: 100_000_102, callId: 901_002, status: 506, isVideo: true).payload
        )
        XCTAssertEqual(rejectVoice.bodyData[12], 2)
        XCTAssertEqual(rejectVideo.bodyData[12], 3)

        // 3. cmd=416 subCmd=3 extendData advertises H.264 payload 97 + supportHevcDecode=0 while keeping voice extendData untouched
        let extVoice = ZolaCrypto.makeVoipExtendDataJson(localEndpoint: "192.168.1.9:35000", isVideo: false)
        let extVideo = ZolaCrypto.makeVoipExtendDataJson(localEndpoint: "192.168.1.9:35000", isVideo: true)
        let voiceObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(extVoice.utf8)) as? [String: Any])
        let videoObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(extVideo.utf8)) as? [String: Any])
        XCTAssertEqual(voiceObj["callType"] as? Int, 0)
        XCTAssertNil(voiceObj["video"], "Voice call extendData must stay untouched without video codec block")
        XCTAssertEqual(videoObj["callType"] as? Int, 1)
        XCTAssertEqual(videoObj["supportHevcDecode"] as? Int, 0)
        XCTAssertEqual(ZolaCrypto.extractNegotiatedH264PayloadType(fromExtendData: extVideo), 97)

        // 4. cmd=407 callee ringing frame advertises video capability when isVideo == true
        let ringVideo = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packVoipCalleeRingingFrame(srcId: 100_000_102, partnerId: 100_000_103, callId: 901_002, isVideo: true).payload
        )
        let ringText = String(decoding: ringVideo.decodedBodyData, as: UTF8.self)
        XCTAssertTrue(ringText.contains("\"h264\""), "Callee video ringing must advertise h264 codec")

        // 5. Incoming cmd=402 invite distinguishes video vs voice via extendData.callType even when outer callType == 3
        let incomingVoiceJson: [String: Any] = [
            "error_code": 0,
            "data": [
                "callId": 778_801,
                "callerId": 100_000_103,
                "callType": 3,
                "rtpIP": "120.138.74.166:4200",
                "sessId": "sess_voice",
                "extendData": extVoice,
            ] as [String: Any],
        ]
        let incomingVideoJson: [String: Any] = [
            "error_code": 0,
            "data": [
                "callId": 778_802,
                "callerId": 100_000_103,
                "callType": 3,
                "rtpIP": "120.138.74.166:4200",
                "sessId": "sess_video",
                "extendData": extVideo,
            ] as [String: Any],
        ]
        let voiceElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packChatElementFrame(
                bodyData: try JSONSerialization.data(withJSONObject: incomingVoiceJson),
                srcId: 100_000_102,
                srcType: 0,
                msgType: 0,
                cmd: 402,
                subCmd: 0,
                seqId: 1
            ).payload
        )
        let videoElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packChatElementFrame(
                bodyData: try JSONSerialization.data(withJSONObject: incomingVideoJson),
                srcId: 100_000_102,
                srcType: 0,
                msgType: 0,
                cmd: 402,
                subCmd: 0,
                seqId: 2
            ).payload
        )
        let voiceInterp = ZolaVoipProtocol.interpretIncomingElement(
            voiceElem,
            activeCallId: 0,
            clientCallId: 0,
            activePartnerUid: 0,
            selfUid: 100_000_102
        )
        if case let .incomingInvite(_, _, isVidVoice, _, _, _, _, _) = voiceInterp.event {
            XCTAssertFalse(isVidVoice, "Outer callType=3 with extendData.callType=0 must remain a Voice Call")
        } else {
            XCTFail("Expected incomingInvite for voice 402")
        }
        let videoInterp = ZolaVoipProtocol.interpretIncomingElement(
            videoElem,
            activeCallId: 0,
            clientCallId: 0,
            activePartnerUid: 0,
            selfUid: 100_000_102
        )
        if case let .incomingInvite(_, _, isVidVideo, _, _, _, _, _) = videoInterp.event {
            XCTAssertTrue(isVidVideo, "Outer callType=3 with extendData.callType=1 must be recognized as a Video Call")
        } else {
            XCTFail("Expected incomingInvite for video 402")
        }

        // 6. cmd=421 camera on/off binary pack & inbound interpretation (18B binary + JSON) + cmd=412
        let camOffFrame = ZolaCrypto.packVoipVideoCameraStateFrame(
            srcId: 100_000_103,
            partnerId: 100_000_102,
            callId: 778_802,
            isCameraOn: false,
            reason: 0
        )
        let unpackedCamOff = try ZolaCrypto.unpackChatElementFrame(camOffFrame.payload)
        XCTAssertEqual(unpackedCamOff.cmd, 421)
        XCTAssertEqual(unpackedCamOff.subCmd, 0)
        XCTAssertEqual(unpackedCamOff.bodyData.count, 18)
        let camOffInterp = ZolaVoipProtocol.interpretIncomingElement(
            unpackedCamOff,
            activeCallId: 778_802,
            clientCallId: 778_802,
            activePartnerUid: 100_000_102,
            selfUid: 100_000_103
        )
        if case let .partnerCameraChanged(cid, pid, camOn, _) = camOffInterp.event {
            XCTAssertEqual(cid, 778_802)
            XCTAssertEqual(pid, 100_000_102)
            XCTAssertFalse(camOn)
        } else {
            XCTFail("Expected partnerCameraChanged from binary cmd=421")
        }

        let camOnJsonElem = try ZolaCrypto.unpackChatElementFrame(
            ZolaCrypto.packChatElementFrame(
                bodyData: try JSONSerialization.data(withJSONObject: [
                    "error_code": 0,
                    "data": ["callId": 778_802, "partnerId": 100_000_103, "status": 1],
                ]),
                srcId: 100_000_102,
                srcType: 0,
                msgType: 0,
                cmd: 412,
                subCmd: 0,
                seqId: 3
            ).payload
        )
        let camOnInterp = ZolaVoipProtocol.interpretIncomingElement(
            camOnJsonElem,
            activeCallId: 778_802,
            clientCallId: 778_802,
            activePartnerUid: 100_000_103,
            selfUid: 100_000_102
        )
        if case let .partnerCameraChanged(cid2, pid2, camOn2, _) = camOnInterp.event {
            XCTAssertEqual(cid2, 778_802)
            XCTAssertEqual(pid2, 100_000_103)
            XCTAssertTrue(camOn2)
        } else {
            XCTFail("Expected partnerCameraChanged from JSON cmd=412")
        }

        // 7. ZRTCPacket 1-1 video framing (0x0d/0x0e RTP, 0x0f/0x11 RTCP, 0x7f pktCmd=8/9) & strict audio isolation
        let sampleVideoRtp = Data([0x80, 0xE1, 0x00, 0x05, 0x00, 0x01, 0x5F, 0x90, 0x12, 0x34, 0x56, 0x78, 0x65, 0x88, 0x84])
        let outVid0d = ZolaCrypto.packZrtcOneToOneVideoPacket(isRtcp: false, token: 0xAABB_CCDD, payload: sampleVideoRtp)
        XCTAssertEqual(outVid0d.first, 0x0d)
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(outVid0d), "Audio unpacker must reject 0x0d video RTP")
        let unpacked0d = try XCTUnwrap(ZolaCrypto.unpackZrtcVideoPayload(outVid0d))
        XCTAssertFalse(unpacked0d.isRtcp)
        XCTAssertEqual(unpacked0d.payload, sampleVideoRtp)

        let inVid0e = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(isRtcp: false, payload: sampleVideoRtp)
        XCTAssertEqual(inVid0e.first, 0x0e)
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(inVid0e))
        let unpacked0e = try XCTUnwrap(ZolaCrypto.unpackZrtcVideoPayload(inVid0e))
        XCTAssertFalse(unpacked0e.isRtcp)
        XCTAssertEqual(unpacked0e.payload, sampleVideoRtp)

        let pli = ZolaH264RtpPacketizer.buildRtcpPliPacket(senderSsrc: 0x1122_3344, mediaSsrc: 0x5566_7788)
        let outRtcp0f = ZolaCrypto.packZrtcOneToOneVideoPacket(isRtcp: true, token: 0xAABB_CCDD, payload: pli)
        let inRtcp11 = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(isRtcp: true, payload: pli)
        XCTAssertEqual(outRtcp0f.first, 0x0f)
        XCTAssertEqual(inRtcp11.first, 0x11)
        XCTAssertNil(ZolaCrypto.unpackZrtcAudioPayload(inRtcp11))
        let unpacked11 = try XCTUnwrap(ZolaCrypto.unpackZrtcVideoPayload(inRtcp11))
        XCTAssertTrue(unpacked11.isRtcp)
        XCTAssertEqual(unpacked11.payload, pli)
        XCTAssertTrue(ZolaH264RtpDepacketizer.isInboundKeyframeRequestRtcp(unpacked11.payload))

        let groupVid = ZolaCrypto.packZrtcRelayVideoPacket(isCaller: true, callId: 778_802, payload: sampleVideoRtp, isRtcp: false)
        XCTAssertEqual(groupVid.first, 0x7f)
        XCTAssertEqual(try XCTUnwrap(ZolaCrypto.unpackZrtcVideoPayload(groupVid)).payload, sampleVideoRtp)
    }

    func testVideoRtcpWrappersRejectInvalidHeaders() throws {
        let pli = ZolaH264RtpPacketizer.buildRtcpPliPacket(senderSsrc: 1, mediaSsrc: 2)
        for prefix in [Data([0x11]), Data([0x0F, 0, 0, 0, 0])] {
            XCTAssertEqual(ZolaCrypto.unpackZrtcVideoPayload(prefix + pli)?.payload, pli)
            for invalid in [Data(), Data([0x80, 206]), Data([0x40, 206, 0, 2]), Data([0x80, 98, 0, 2])] {
                XCTAssertNil(ZolaCrypto.unpackZrtcVideoPayload(prefix + invalid))
            }
        }
    }

    #if canImport(Network) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testDirectRtpKeyframeRoutesToVideoBeforeAnyDelta() async throws {
        let receiver = ZolaVoipMediaEngine(callId: 880_105)
        defer { receiver.stop() }
        receiver.setVideoMode(enabled: true, cameraEnabled: false)
        let keyType = expectation(description: "PT 98 reported as video")
        receiver.onRemotePayloadType = { pt in
            XCTAssertEqual(pt, 98)
            keyType.fulfill()
        }
        // Parameter sets alone exercise routing and SSRC discovery without requiring VideoToolbox.
        let packet = ZolaVoipMediaEngine.buildRtpPacket(
            payloadType: 98, sequenceNumber: 500, timestamp: 90_000, ssrc: 0x55AA_7788,
            payload: Data([0x78, 0, 4, 0x67, 0x42, 0xC0, 0x1E, 0, 4, 0x68, 0xCE, 0x3C, 0x80])
        )
        try receiver.ingestDatagramForTesting(packet)
        // Queue barrier through the existing synchronized getter ensures RTP has reached video.
        XCTAssertEqual(receiver.decodedVideoFrameCount, 0)
        XCTAssertEqual(receiver.decodedFrameCount, 0)
        let routed = expectation(description: "Video engine received keyframe PT with no premature PLI")
        receiver.diagnosticsSnapshot { line in
            XCTAssertTrue(line.contains("pt=[98:1]"), line)
            XCTAssertTrue(line.contains("pli=0/0"), line)
            routed.fulfill()
        }
        await fulfillment(of: [keyType, routed], timeout: 2)
    }
    #endif

    #if canImport(Network) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testHardwareDualPtDirectRtpProducesImagesAndIOSurfacePixelBuffers() async throws {
        final class FrameState: @unchecked Sendable {
            let lock = NSLock()
            var packets: [Data] = []
            var timestamps: [Int64] = []
            var payloadTypes: Set<UInt8> = []
        }
        let state = FrameState()
        let encoded = expectation(description: "Hardware encoder emitted keyframe and two deltas")
        encoded.expectedFulfillmentCount = 3
        let sender = ZolaVoipVideoEngine(callId: 880_103)
        let receiver = ZolaVoipMediaEngine(callId: 880_104)
        defer { sender.stop(); receiver.stop() }
        sender.onOutboundVideoPacket = { packet, isRtcp in
            guard !isRtcp, let parsed = ZolaH264RtpDepacketizer.parseRtpPacket(packet) else { return }
            state.lock.withLock { state.packets.append(packet) }
            if parsed.marker { encoded.fulfill() }
        }
        sender.ensureDecoderRunning()
        for index in 0..<3 {
            XCTAssertTrue(sender.encodeSyntheticFrame(width: 640, height: 480, r: UInt8(30 + index), forceKeyframe: index == 0))
        }
        await fulfillment(of: [encoded], timeout: 5)
        let packets = state.lock.withLock { state.packets }
        XCTAssertEqual(Set(packets.map { $0[1] & 0x7F }), [97, 98])

        var assembler = ZolaH264RtpDepacketizer()
        let units = packets.flatMap { assembler.ingestRtpPacket($0) }
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units.map(\.containsIdr), [true, false, false])
        let images = expectation(description: "Direct RTP emits CGImage for keyframe and deltas")
        images.expectedFulfillmentCount = 3
        let pixels = expectation(description: "Direct RTP emits IOSurface pixel buffers")
        pixels.expectedFulfillmentCount = 3
        // Register the pixel callback before creating the engine; CGImage callback after creation.
        receiver.onRemoteVideoPixelBuffer = { buffer, pts in
            XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), 480)
            XCTAssertEqual(pts.timescale, 90_000)
            state.lock.withLock { state.timestamps.append(pts.value) }
            pixels.fulfill()
        }
        receiver.setVideoMode(enabled: true, cameraEnabled: false)
        receiver.onRemoteVideoFrame = { image in
            XCTAssertEqual(image.width, 640)
            XCTAssertEqual(image.height, 480)
            images.fulfill()
        }
        receiver.onRemotePayloadType = { pt in
            state.lock.withLock { _ = state.payloadTypes.insert(pt) }
        }
        var wire = ZolaH264RtpPacketizer(ssrc: 0x55AA_7788, maxPayloadSize: 256, initialSequenceNumber: 500)
        for unit in units {
            let frame = wire.packetizeAccessUnit(
                nalUnits: unit.vclNalUnits, sps: unit.sps, pps: unit.pps,
                isKeyframe: unit.containsIdr, rtpTimestamp: unit.rtpTimestamp
            )
            if unit.containsIdr {
                XCTAssertGreaterThan(frame.count, 2, "Keyframe uses STAP-A plus FU-A fragments")
            }
            // First PT 98 STAP-A locks SSRC. Swap subsequent pairs and inject foreign RTX/FEC.
            try receiver.ingestDatagramForTesting(try XCTUnwrap(frame.first))
            var remaining = Array(frame.dropFirst())
            if remaining.count >= 2 { remaining.swapAt(0, 1) }
            for (index, packet) in remaining.enumerated() {
                let noise = ZolaVoipMediaEngine.buildRtpPacket(
                    payloadType: [100, 116, 117][index % 3], sequenceNumber: UInt16(9_000 + index),
                    timestamp: unit.rtpTimestamp, ssrc: 0xDEAD_BEEF, payload: Data([0x65, 0xAA])
                )
                try receiver.ingestDatagramForTesting(ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(payload: noise))
                try receiver.ingestDatagramForTesting(packet)
            }
        }
        await fulfillment(of: [images, pixels], timeout: 5)
        XCTAssertEqual(receiver.decodedFrameCount, 0, "PT 98 must never reach the audio decoder")
        XCTAssertEqual(receiver.decodedVideoFrameCount, 3)
        XCTAssertEqual(state.lock.withLock { state.payloadTypes }, [97, 98])
        XCTAssertEqual(state.lock.withLock { state.timestamps }, units.map { Int64($0.rtpTimestamp) })
        let diagnostics = expectation(description: "No false PLI or decode errors")
        receiver.diagnosticsSnapshot { line in
            XCTAssertTrue(line.contains("pli=0/0"), line)
            XCTAssertTrue(line.contains("loi-giaima=0"), line)
            XCTAssertTrue(line.contains("idr=0/1"), line)
            diagnostics.fulfill()
        }
        await fulfillment(of: [diagnostics], timeout: 2)
    }
    #endif

    #if canImport(Network) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testVideoPreviewConvertsFullRangeBiPlanarPixelBuffer() throws {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes, &buffer
        ), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane))
            memset(base, plane == 0 ? 80 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let image = try XCTUnwrap(ZolaVoipVideoEngine.makeVideoImage(from: pixelBuffer))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }
    #endif

    #if canImport(Network) && canImport(VideoToolbox) && canImport(CoreMedia) && canImport(CoreVideo) && canImport(CoreGraphics)
    func testTwoWayHardwareH264VideoOverZrtcRelayLoopback() async throws {
        final class RelayPeerBox: @unchecked Sendable {
            let lock = NSLock()
            var callerConn: NWConnection?
            var calleeConn: NWConnection?
            var calleeImageSize: (Int, Int)?
            var callerImageSize: (Int, Int)?
        }

        let udpQueue = DispatchQueue(label: "test.zrtc.video.relay")
        let relayListener = try NWListener(using: .udp, on: .any)
        defer { relayListener.cancel() }

        let box = RelayPeerBox()
        let callerToken: UInt32 = 0x1122_3344
        let calleeToken: UInt32 = 0x5566_7788

        let relayReady = expectation(description: "Mock ZRTC video relay ready")
        relayListener.stateUpdateHandler = { st in
            if case .ready = st { relayReady.fulfill() }
        }
        relayListener.newConnectionHandler = { conn in
            conn.start(queue: udpQueue)
            func pump() {
                conn.receiveMessage { data, _, isComplete, err in
                    if err != nil { return }
                    if let data, !data.isEmpty {
                        if data.first == 0x01, data.count >= 20, let cmd = try? data.readUInt16LE(at: 18) {
                            if cmd == 11 {
                                box.lock.withLock { box.callerConn = conn }
                                if let ack = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0, relayToken: callerToken) {
                                    conn.send(content: ack, completion: .contentProcessed { _ in })
                                }
                            } else if cmd == 12 {
                                box.lock.withLock { box.calleeConn = conn }
                                if let ack = ZolaCrypto.packZrtcPongPacket(fromPing: data, selfUid: 0, relayToken: calleeToken) {
                                    conn.send(content: ack, completion: .contentProcessed { _ in })
                                }
                            }
                        } else if let vid = ZolaCrypto.unpackZrtcVideoPayload(data) {
                            // Forward 0x0d/0x0f outbound video as 0x0e/0x11 inbound relay video to the opposite peer!
                            let (cCaller, cCallee) = box.lock.withLock { (box.callerConn, box.calleeConn) }
                            if let cCaller, conn === cCaller, let cCallee {
                                let forwarded = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(
                                    isRtcp: vid.isRtcp,
                                    payload: vid.payload
                                )
                                cCallee.send(content: forwarded, completion: .contentProcessed { _ in })
                            } else if let cCallee, conn === cCallee, let cCaller {
                                let forwarded = ZolaCrypto.packZrtcOneToOneVideoRelayInboundPacket(
                                    isRtcp: vid.isRtcp,
                                    payload: vid.payload
                                )
                                cCaller.send(content: forwarded, completion: .contentProcessed { _ in })
                            }
                        }
                    } else if isComplete {
                        return
                    }
                    if case .cancelled = conn.state { return }
                    pump()
                }
            }
            pump()
        }
        relayListener.start(queue: udpQueue)
        await fulfillment(of: [relayReady], timeout: 3.0)
        let relayPort = try XCTUnwrap(relayListener.port?.rawValue)
        let relayEp = ZolaVoipMediaEngine.MediaEndpoint(host: "127.0.0.1", port: relayPort)

        let caller = ZolaVoipMediaEngine(callId: 880_100)
        let callee = ZolaVoipMediaEngine(callId: 880_100)
        caller.forceZrtcFramingOnLoopback = true
        callee.forceZrtcFramingOnLoopback = true
        defer {
            caller.stop()
            callee.stop()
        }

        let calleeDecodedExp = expectation(description: "Callee decoded H.264 CGImage from Caller over ZRTC 0x0d->0x0e")
        calleeDecodedExp.assertForOverFulfill = false
        let callerDecodedExp = expectation(description: "Caller decoded H.264 CGImage from Callee over ZRTC 0x0d->0x0e")
        callerDecodedExp.assertForOverFulfill = false

        callee.onRemoteVideoFrame = { img in
            box.lock.withLock { box.calleeImageSize = (img.width, img.height) }
            calleeDecodedExp.fulfill()
        }
        caller.onRemoteVideoFrame = { img in
            box.lock.withLock { box.callerImageSize = (img.width, img.height) }
            callerDecodedExp.fulfill()
        }

        caller.setVideoMode(enabled: true, h264PayloadType: 97, cameraEnabled: false)
        callee.setVideoMode(enabled: true, h264PayloadType: 97, cameraEnabled: false)
        let callerPixelExp = expectation(description: "Caller receives PiP-compatible IOSurface")
        callerPixelExp.assertForOverFulfill = false
        let calleePixelExp = expectation(description: "Callee receives PiP-compatible IOSurface")
        calleePixelExp.assertForOverFulfill = false
        caller.onRemoteVideoPixelBuffer = { buffer, pts in
            XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
            XCTAssertEqual(pts.timescale, 90_000)
            callerPixelExp.fulfill()
        }
        callee.onRemoteVideoPixelBuffer = { buffer, pts in
            XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
            XCTAssertEqual(pts.timescale, 90_000)
            calleePixelExp.fulfill()
        }
        caller.configureZrtcSession(isCaller: true, selfUid: 100_000_103, partnerUid: 100_000_102, sessionId: "sess_vid_loop")
        callee.configureZrtcSession(isCaller: false, selfUid: 100_000_102, partnerUid: 100_000_103, sessionId: "sess_vid_loop")

        try caller.prepareTransport(relay: relayEp)
        try callee.prepareTransport(relay: relayEp)

        let callerAck = await caller.waitForRelayHandshake(timeoutMs: 2_000)
        let calleeAck = await callee.waitForRelayHandshake(timeoutMs: 2_000)
        XCTAssertTrue(callerAck)
        XCTAssertTrue(calleeAck)

        // Pump 3 synthetic frames in both directions (VideoToolbox hardware H.264 encode -> UDP 0x0d -> 0x0e -> VTDecompressionSession)
        for idx in 0..<3 {
            let shade = UInt8(truncatingIfNeeded: 40 + idx * 50)
            caller.sendSyntheticVideoFrameForTesting(width: 320, height: 240, r: shade, g: 0x88, b: 0xEE)
            callee.sendSyntheticVideoFrameForTesting(width: 320, height: 240, r: 0xEE, g: shade, b: 0x44)
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        await fulfillment(of: [calleeDecodedExp, callerDecodedExp, callerPixelExp, calleePixelExp], timeout: 4.0)
        let (cSize, rSize) = box.lock.withLock { (box.calleeImageSize, box.callerImageSize) }
        XCTAssertEqual(cSize?.0, 320)
        XCTAssertEqual(cSize?.1, 240)
        XCTAssertEqual(rSize?.0, 320)
        XCTAssertEqual(rSize?.1, 240)
        XCTAssertGreaterThanOrEqual(callee.decodedVideoFrameCount, 1)
        XCTAssertGreaterThanOrEqual(caller.decodedVideoFrameCount, 1)
    }
    #endif
}
