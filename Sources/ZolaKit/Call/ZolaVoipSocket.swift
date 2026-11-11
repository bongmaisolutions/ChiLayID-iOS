import Foundation
#if canImport(Network)
import Network
#endif

/// Real-time signaling events emitted by `UXVoipSocket` (`ZolaVoipSocketSession`) during a native Zalo 1-1 call.
public enum ZolaVoipCallEvent: Sendable, Equatable {
    case connecting(callId: Int32, clientCallId: Int32, partnerUid: Int64, isVideo: Bool)
    case ringing(callId: Int32, partnerUid: Int64)
    case answered(callId: Int32, partnerUid: Int64)
    case busy(callId: Int32, partnerUid: Int64)
    case rejected(callId: Int32, partnerUid: Int64, status: Int, reason: String)
    case ended(callId: Int32, partnerUid: Int64, reason: String)
    case incomingInvite(
        callId: Int32,
        partnerUid: Int64,
        isVideo: Bool,
        callerName: String,
        avatarUrl: String,
        rtpAddress: String,
        rtcpAddress: String,
        sessionId: String
    )
    case partnerCameraChanged(callId: Int32, partnerUid: Int64, isCameraOn: Bool, reason: Int)
    case failed(callId: Int32, partnerUid: Int64, code: Int, message: String)
}

/// Parsed fields from server `cmd = 401` (`CallEntity updateCallEntity:` at `0x102e96ba0`).
public struct ZolaVoipParsedCallEntity: Sendable, Equatable {
    public let errorCode: Int
    public let errorMessage: String
    public let status: Int
    public let serverCallId: Int32
    public let sessionId: String
    public let rtpAddress: String
    public let rtcpAddress: String
    public let relayHost: String
    public let relayPort: UInt16
    public let relayToken: String
    public let extendDataString: String

    public var isAllowed: Bool {
        errorCode == 0 && (status == 0 || status == 3)
    }
}

/// Endpoint descriptor for `UXChatSocket` / `UXVoipSocket` (`0x7d0`), optionally carrying the server's 32-byte X25519 public key (`SocketEntity.pubKey`).
public struct ZolaVoipEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let serverPubKeyBase64: String?

    public init(host: String, port: UInt16, serverPubKeyBase64: String? = nil) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port > 0 ? port : 443
        let trimmedPub = serverPubKeyBase64?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverPubKeyBase64 = (trimmedPub?.isEmpty == false) ? trimmedPub : nil
    }

    public var hasValidServerPubKey32: Bool {
        guard let b64 = serverPubKeyBase64, let data = Data(base64Encoded: b64) else {
            return false
        }
        return data.count == 32
    }
}

/// Pure, deterministic protocol helpers for `UXVoipSocket` / `VoipChatModule` (`0x102f9029c`) and `CallEntity` (`0x102e96ba0`).
public enum ZolaVoipProtocol {
    public static let defaultEndpoints: [(host: String, port: UInt16)] = [
        ("49.213.95.89", 443),
        ("49.213.95.88", 443),
        ("49.213.95.80", 443),
        ("49.213.95.96", 443),
        ("120.138.69.142", 443),
        ("49.213.95.89", 8080),
    ]

    /// Verified live `UXChatSocket` (`0x7d0`) endpoints captured from production Zalo iOS `261002`
    /// (`mac35`/`mac36`/`mac37`). Each carries its real X25519 `SocketEntity.pubKey` (32 raw bytes),
    /// so sessions persisted *before* `socketServers` existed can still satisfy the live encryption
    /// gate without forcing a re-login.
    public static let defaultVerifiedEncryptedEndpoints: [ZolaVoipEndpoint] = [
        ZolaVoipEndpoint(
            host: "49.213.95.89", port: 443,
            serverPubKeyBase64: "BR0HdKuunrwPLa0LE3hZo1JuticL3JhpuC8p+mNdLjE="
        ),
        ZolaVoipEndpoint(
            host: "49.213.95.90", port: 443,
            serverPubKeyBase64: "odUMIaXRIZ3lPeWVFh1PV2A3eOhhthwbExmPapxKegg="
        ),
    ]

    public static let httpUpgradeHeaderBytes = Data(
        "GET/HTTP/1.1\r\nHost: Zalo\r\nUser-Agent: Mozilla/5.0\r\n\r\n".utf8
    )
    public static let httpHeaderEndMarker = Data("\r\n\r\n".utf8)
    private static let httpResponsePrefix = Data("HTTP".utf8)

    /// Builds the `UXAsyncSocket` pseudo-HTTP preamble (`GET/HTTP/1.1\r\nHost: <ip>\r\nUser-Agent: Mozilla/5.0\r\n\r\n`).
    public static func makeHttpUpgradeHeader(host: String) -> Data {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = cleanHost.isEmpty ? "Zalo" : cleanHost
        return Data("GET/HTTP/1.1\r\nHost: \(resolvedHost)\r\nUser-Agent: Mozilla/5.0\r\n\r\n".utf8)
    }

    static func startsWithHttpPrefix(_ data: Data) -> Bool {
        data.starts(with: httpResponsePrefix)
    }

    /// Returns `true` only for explicit local loopback endpoints (`127.0.0.1`, `::1`, `localhost`).
    /// Raw `AUTHEN` without `EncryptProtocolVer2` (`0x08` X25519 + `keySetValue` AES-256-GCM) must never
    /// be sent to production Zalo socket servers (`49.213.95.*`), or Zalo will reject/revoke `session_key`.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean == "127.0.0.1" || clean == "::1" || clean == "localhost"
    }

    public static func splitHostPort(_ address: String, defaultHost: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let colonIdx = trimmed.lastIndex(of: ":") else {
            return (trimmed.isEmpty ? defaultHost : trimmed, defaultPort)
        }
        let hostPart = String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let portPart = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = hostPart.isEmpty ? defaultHost : hostPart
        let resolvedPort = UInt16(portPart) ?? defaultPort
        return (resolvedHost, resolvedPort)
    }

    static func extractFirstServerAddress(from rawServers: Any?, key: String = "rtp") -> String {
        if let strArr = rawServers as? [String], let first = strArr.first(where: { !$0.isEmpty }) {
            return first
        }
        if let dictArr = rawServers as? [[String: Any]], let first = dictArr.first {
            let direct = ZolaJSON.string(first[key])
            if !direct.isEmpty { return direct }
            let ip = ZolaJSON.string(first["ip"] ?? first["host"] ?? first["rtpIP"] ?? first["rtp"])
            let port = ZolaJSON.int(first["port"] ?? first["rtpPort"], default: 0)
            if !ip.isEmpty {
                return (port > 0 && !ip.contains(":")) ? "\(ip):\(port)" : ip
            }
        }
        if let nestedJsonStr = rawServers as? String,
           let bytes = nestedJsonStr.data(using: .utf8),
           let nestedDict = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        {
            let nestedDirect = ZolaJSON.string(nestedDict[key == "rtcp" ? "rtcpServerAddr" : "rtpServerAddr"])
            if !nestedDirect.isEmpty { return nestedDirect }
            return extractFirstServerAddress(from: nestedDict["serverAddr"] ?? nestedDict["servers"], key: key)
        }
        if let nestedDict = rawServers as? [String: Any] {
            let nestedDirect = ZolaJSON.string(nestedDict[key == "rtcp" ? "rtcpServerAddr" : "rtpServerAddr"])
            if !nestedDirect.isEmpty { return nestedDirect }
            return extractFirstServerAddress(from: nestedDict["serverAddr"] ?? nestedDict["servers"], key: key)
        }
        return ""
    }

    /// Parses the server's `cmd = 401` JSON response matching `CallEntity updateCallEntity:` (`0x102e96ba0`).
    public static func parseCallResponse(
        from element: ZolaUnpackedChatElement,
        fallbackCallId: Int32,
        fallbackRtpAddress: String = "49.213.95.89:10000",
        fallbackRtcpAddress: String = "49.213.95.89:10001"
    ) -> ZolaVoipParsedCallEntity {
        guard element.retCode == 0 else {
            return ZolaVoipParsedCallEntity(
                errorCode: Int(element.retCode),
                errorMessage: "Máy chủ cuộc gọi trả mã lỗi \(element.retCode)",
                status: Int(element.retCode),
                serverCallId: fallbackCallId,
                sessionId: String(fallbackCallId),
                rtpAddress: fallbackRtpAddress,
                rtcpAddress: fallbackRtcpAddress,
                relayHost: "49.213.95.89",
                relayPort: 10000,
                relayToken: "",
                extendDataString: #"{"ver":4,"net":1,"rel":1}"#
            )
        }

        let json = element.parseJSONDictionary() ?? [:]
        let errCode = ZolaJSON.int(json["error_code"] ?? json["err"] ?? json["e"], default: 0)
        let data = (json["data"] as? [String: Any]) ?? json
        let errMsg = [
            json["error_message"],
            data["error_message"],
            data["msg"],
            json["message"],
        ]
            .map { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        let status = ZolaJSON.int(data["status"], default: 0)
        let rawId = Int32(truncatingIfNeeded: ZolaJSON.int64(data["id"] ?? data["callId"], default: 0))
        let serverCallId = rawId != 0 ? rawId : fallbackCallId

        let rawSess = ZolaJSON.string(data["sessId"] ?? data["sessionId"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = rawSess.isEmpty ? String(serverCallId) : rawSess

        let serverRtp = [
            ZolaJSON.string(data["rtpIP"]),
            ZolaJSON.string(data["rtpAddress"]),
            ZolaJSON.string(data["rtpAddr"]),
            extractFirstServerAddress(from: data["servers"] ?? data["zrtpServers"] ?? data["serverAddr"], key: "rtp"),
            extractFirstServerAddress(from: data["zrtcConfig"], key: "rtp"),
            extractFirstServerAddress(from: data["extendData"], key: "rtp"),
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        let rtpAddress = serverRtp.isEmpty ? fallbackRtpAddress : serverRtp
        let (relayHost, relayPort) = splitHostPort(rtpAddress, defaultHost: "49.213.95.89", defaultPort: 10000)

        let serverRtcp = [
            ZolaJSON.string(data["rtcpIP"]),
            ZolaJSON.string(data["rtcpAddress"]),
            ZolaJSON.string(data["rtcpAddr"]),
            extractFirstServerAddress(from: data["serverAddr"], key: "rtcp"),
            extractFirstServerAddress(from: data["zrtcConfig"], key: "rtcp"),
            extractFirstServerAddress(from: data["extendData"], key: "rtcp"),
        ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        let rtcpAddress: String
        if !serverRtcp.isEmpty {
            rtcpAddress = serverRtcp
        } else if !serverRtp.isEmpty {
            // `rtcpMux = 1` (`mac35`): Zalo media relays multiplex RTP and RTCP on the same port (`rtpIP`).
            rtcpAddress = rtpAddress
        } else {
            rtcpAddress = fallbackRtcpAddress
        }

        let relayToken = ZolaJSON.string(data["token"] ?? data["relayToken"] ?? data["zrtpToken"])

        let extendDataString: String
        if let s = data["extendData"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            extendDataString = s
        } else if let extObj = data["extendData"] as? [String: Any],
                  let extBytes = try? JSONSerialization.data(withJSONObject: extObj),
                  let extStr = String(data: extBytes, encoding: .utf8), !extStr.isEmpty {
            extendDataString = extStr
        } else {
            extendDataString = #"{"ver":4,"net":1,"rel":1}"#
        }

        return ZolaVoipParsedCallEntity(
            errorCode: errCode,
            errorMessage: errMsg,
            status: status,
            serverCallId: serverCallId,
            sessionId: sessionId,
            rtpAddress: rtpAddress,
            rtcpAddress: rtcpAddress,
            relayHost: relayHost,
            relayPort: relayPort,
            relayToken: relayToken,
            extendDataString: extendDataString
        )
    }

    /// Human-readable Vietnamese message for non-allowed `cmd=401` status / error codes.
    public static func describeCallError(errorCode: Int, status: Int, serverMessage: String) -> String {
        if !serverMessage.isEmpty {
            return serverMessage
        }
        if status == 6 {
            return "Người nhận đang bận cuộc gọi khác"
        }
        if status == 1 || status == 2 {
            return "Người nhận hiện không thể nhận cuộc gọi"
        }
        if errorCode != 0 {
            return "Không thể khởi tạo cuộc gọi Zalo (mã \(errorCode))"
        }
        return "Không thể đổ chuông tới người nhận (trạng thái \(status))"
    }

    /// Interprets incoming `UXVoipSocket` push frames (`cmd = 402, 403, 405, 407, 409, 415, 424`) per `VoipChatModule` (`0x102f9029c`).
    public static func interpretIncomingElement(
        _ element: ZolaUnpackedChatElement,
        activeCallId: Int32,
        clientCallId: Int32,
        activePartnerUid: Int64,
        selfUid: Int64
    ) -> (event: ZolaVoipCallEvent?, autoAckCmd: Int32?, resolvedCallId: Int32, resolvedPartnerUid: Int64) {
        let json = element.parseJSONDictionary()
        let errorCode = ZolaJSON.int(json?["error_code"] ?? json?["err"], default: Int(element.retCode))
        let data = (json?["data"] as? [String: Any]) ?? json ?? [:]

        // Live captures (`mac35`) show server pushes for `402`/`405`/`409`/`415` carrying a raw
        // `[partnerId:i32LE][callId:i32LE]…` binary prefix instead of a JSON body. Pulling the two
        // leading words keeps `resolvedPartnerUid`/`resolvedCallId` exact when the caller hangs up.
        var binPartnerId: Int64 = 0
        var binCallId: Int32 = 0
        if json == nil, element.bodyData.count >= 8,
           let p = try? element.bodyData.readInt32LE(at: 0),
           let c = try? element.bodyData.readInt32LE(at: 4) {
            binPartnerId = Int64(UInt32(bitPattern: p))
            binCallId = c
        }

        let rawPktCallId = Int32(truncatingIfNeeded: ZolaJSON.int64(data["id"] ?? data["callId"], default: Int64(binCallId)))
        let resolvedCallId = rawPktCallId != 0 ? rawPktCallId : activeCallId

        // Ignore frames belonging to a different call when an active call ID is bound (except new incoming 402 when idle).
        if element.cmd != 402,
           activeCallId != 0,
           rawPktCallId != 0,
           rawPktCallId != activeCallId,
           rawPktCallId != clientCallId {
            return (nil, nil, resolvedCallId, activePartnerUid)
        }

        let unsignedSrcId = Int64(UInt32(bitPattern: element.srcId))
        func validPartner(_ candidate: Int64) -> Int64? {
            (candidate > 0 && candidate != selfUid) ? candidate : nil
        }

        // CRITICAL (`0x102fa3a10` & `mac35`): in incoming `cmd = 402`, `data["userId"]` is the
        // CALLEE'S OWN UID (`selfUid`), whereas `element.srcId` is the caller's UID!
        // Never treat `userId` (or any value equal to `selfUid`) as `partnerUid`.
        let resolvedPartnerUid: Int64 = [
            validPartner(ZolaJSON.int64(data["partnerId"], default: 0)),
            validPartner(ZolaJSON.int64(data["callerId"], default: 0)),
            validPartner(ZolaJSON.int64(data["fromId"], default: 0)),
            validPartner(ZolaJSON.int64(data["uidFrom"], default: 0)),
            validPartner(ZolaJSON.int64(data["calleeId"], default: 0)),
            validPartner(ZolaJSON.int64(data["toId"], default: 0)),
            validPartner(binPartnerId),
            // A fresh invite can arrive while a previous call is still bound. Its caller
            // must come from the invite itself, never the previous call's partner.
            element.cmd == 402 ? nil : validPartner(activePartnerUid),
            validPartner(unsignedSrcId),
        ].compactMap { $0 }.first ?? 0

        let needsAck = ZolaJSON.int(data["neekACK"] ?? data["needACK"] ?? data["needAck"], default: 0) == 1
        let autoAckCmd: Int32? = (needsAck && resolvedCallId != 0 && resolvedPartnerUid != 0)
            ? Int32(element.cmd)
            : nil

        switch element.cmd {
        case 407: // `voipModule:didReceiveCallRinging:` (`0x102f909a8`)
            guard errorCode == 0 else {
                return (
                    .failed(
                        callId: resolvedCallId,
                        partnerUid: resolvedPartnerUid,
                        code: errorCode,
                        message: ZolaJSON.string(json?["error_message"]).isEmpty
                            ? "Không thể đổ chuông (mã \(errorCode))"
                            : ZolaJSON.string(json?["error_message"])
                    ),
                    autoAckCmd,
                    resolvedCallId,
                    resolvedPartnerUid
                )
            }
            if data["status"] != nil {
                let ringStatus = ZolaJSON.int(data["status"], default: 0)
                if ringStatus == 6 {
                    return (.busy(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)
                } else if ringStatus != 0 {
                    return (
                        .rejected(
                            callId: resolvedCallId,
                            partnerUid: resolvedPartnerUid,
                            status: ringStatus,
                            reason: "Không thể đổ chuông tới thiết bị nhận (mã \(ringStatus))"
                        ),
                        autoAckCmd,
                        resolvedCallId,
                        resolvedPartnerUid
                    )
                }
            }
            return (.ringing(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)

        case 408: // `voipModule:didReceiveCallRequestAnswerACK:` (`0x102f90a20` — server confirms callee answer)
            guard errorCode == 0 else {
                return (
                    .failed(
                        callId: resolvedCallId,
                        partnerUid: resolvedPartnerUid,
                        code: errorCode,
                        message: ZolaJSON.string(json?["error_message"]).isEmpty
                            ? "Không thể kết nối cuộc gọi (mã \(errorCode))"
                            : ZolaJSON.string(json?["error_message"])
                    ),
                    autoAckCmd,
                    resolvedCallId,
                    resolvedPartnerUid
                )
            }
            return (.answered(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)

        case 403, 424: // `voipModule:didReceiveCallAnswer:` (`0x102f90c48`) & `didReceiveCallAnswerCompact:` (`0x102f90704`)
            if element.cmd == 424, activeCallId == 0 {
                return (nil, autoAckCmd, resolvedCallId, resolvedPartnerUid)
            }
            let status = ZolaJSON.int(data["status"], default: errorCode == 0 ? 0 : errorCode)
            if errorCode == 0 && status == 0 {
                return (.answered(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)
            } else if status == 6 {
                return (.busy(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)
            } else {
                let defaultReason: String = {
                    if status == 5 {
                        return "Không thể thiết lập cuộc gọi với thiết bị nhận (mã 5)"
                    } else if status == 1 || status == 2 || status == 3 {
                        return "Người nhận từ chối cuộc gọi"
                    } else {
                        return "Cuộc gọi kết thúc từ phía nhận (mã \(status))"
                    }
                }()
                let reason = [
                    ZolaJSON.string(data["reason"]),
                    ZolaJSON.string(data["msg"]),
                    ZolaJSON.string(json?["error_message"]),
                ].first { !$0.isEmpty } ?? defaultReason
                return (
                    .rejected(callId: resolvedCallId, partnerUid: resolvedPartnerUid, status: status, reason: reason),
                    autoAckCmd,
                    resolvedCallId,
                    resolvedPartnerUid
                )
            }

        case 405: // `voipModule:didReceiveCallRequestCancel:` (`0x102f90bd8`)
            return (
                .ended(callId: resolvedCallId, partnerUid: resolvedPartnerUid, reason: "Đối phương đã huỷ cuộc gọi"),
                autoAckCmd,
                resolvedCallId,
                resolvedPartnerUid
            )

        case 409: // `voipModule:didReceiveCallRequestEndCall:` (`0x102f90b68`)
            let status = ZolaJSON.int(data["status"], default: 0)
            if status == 6 {
                return (.busy(callId: resolvedCallId, partnerUid: resolvedPartnerUid), autoAckCmd, resolvedCallId, resolvedPartnerUid)
            } else if status == 1 || status == 2 {
                return (
                    .rejected(
                        callId: resolvedCallId,
                        partnerUid: resolvedPartnerUid,
                        status: status,
                        reason: "Người nhận từ chối cuộc gọi"
                    ),
                    autoAckCmd,
                    resolvedCallId,
                    resolvedPartnerUid
                )
            }
            return (
                .ended(callId: resolvedCallId, partnerUid: resolvedPartnerUid, reason: "Cuộc gọi đã kết thúc"),
                autoAckCmd,
                resolvedCallId,
                resolvedPartnerUid
            )

        case 412: // `voipModule:didReceiveSwitchToVideoCall:` (`0x102f90cb8`)
            return (
                .partnerCameraChanged(
                    callId: resolvedCallId,
                    partnerUid: resolvedPartnerUid,
                    isCameraOn: true,
                    reason: 0
                ),
                autoAckCmd,
                resolvedCallId,
                resolvedPartnerUid
            )

        case 421: // `voipModule:didReceiveVideoCallCameraState:` (`0x102f905a8` / `0x102fa1bf8`)
            let status: Int
            let reason: Int
            if json == nil, element.bodyData.count >= 12 {
                status = Int((try? element.bodyData.readInt32LE(at: 8)) ?? 0)
                reason = element.bodyData.count >= 18
                    ? Int((try? element.bodyData.readInt32LE(at: 14)) ?? 0)
                    : 0
            } else {
                status = ZolaJSON.int(data["type"] ?? data["status"] ?? data["cameraState"], default: 0)
                reason = ZolaJSON.int(data["reason"], default: 0)
            }
            return (
                .partnerCameraChanged(
                    callId: resolvedCallId,
                    partnerUid: resolvedPartnerUid,
                    isCameraOn: status != 0,
                    reason: reason
                ),
                autoAckCmd,
                resolvedCallId,
                resolvedPartnerUid
            )

        case 402: // `voipModule:didReceiveCallRequestAnswer:` (`0x102f902e0` — incoming call invite)
            guard element.msgType != 3, element.subCmd != 3, errorCode == 0,
                  rawPktCallId != 0, resolvedPartnerUid != 0 else {
                return (nil, autoAckCmd, resolvedCallId, resolvedPartnerUid)
            }
            let isVideo = isIncomingInviteVideo(element: element, data: data)
            // Zalo iOS `cmd = 402` sends `"Dname"` (capital D, lower n — `0x102f8ff64` & `mac35`).
            let callerName = [
                ZolaJSON.string(data["Dname"]),
                ZolaJSON.string(data["dName"]),
                ZolaJSON.string(data["callerName"]),
                ZolaJSON.string(data["displayName"]),
            ].first { !$0.isEmpty } ?? ""
            let avatarUrl = ZolaJSON.string(data["avatar"] ?? data["avt"])
            let rtp = [
                ZolaJSON.string(data["rtpIP"]),
                ZolaJSON.string(data["rtpAddress"]),
                ZolaJSON.string(data["rtpAddr"]),
                extractFirstServerAddress(from: data["zrtcConfig"], key: "rtp"),
                extractFirstServerAddress(from: data["extendData"], key: "rtp"),
                extractFirstServerAddress(from: data["servers"], key: "rtp"),
                extractFirstServerAddress(from: data["zrtpServers"], key: "rtp"),
                extractFirstServerAddress(from: data["serverAddr"], key: "rtp"),
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let rawRtcp = [
                ZolaJSON.string(data["rtcpIP"]),
                ZolaJSON.string(data["rtcpAddress"]),
                ZolaJSON.string(data["rtcpAddr"]),
                extractFirstServerAddress(from: data["zrtcConfig"], key: "rtcp"),
                extractFirstServerAddress(from: data["extendData"], key: "rtcp"),
                extractFirstServerAddress(from: data["servers"], key: "rtcp"),
                extractFirstServerAddress(from: data["zrtpServers"], key: "rtcp"),
                extractFirstServerAddress(from: data["serverAddr"], key: "rtcp"),
            ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            let rtcp = rawRtcp.isEmpty ? rtp : rawRtcp
            let sess = ZolaJSON.string(data["sessId"] ?? data["sessionId"])
            return (
                .incomingInvite(
                    callId: resolvedCallId,
                    partnerUid: resolvedPartnerUid,
                    isVideo: isVideo,
                    callerName: callerName,
                    avatarUrl: avatarUrl,
                    rtpAddress: rtp,
                    rtcpAddress: rtcp,
                    sessionId: sess
                ),
                autoAckCmd,
                resolvedCallId,
                resolvedPartnerUid
            )

        default:
            return (nil, autoAckCmd, resolvedCallId, resolvedPartnerUid)
        }
    }

    /// Schema flags only; never log invite payloads, identities, addresses or credentials.
    static func incomingInviteModeDiagnostic(_ element: ZolaUnpackedChatElement) -> String {
        let json = element.parseJSONDictionary() ?? [:]
        let data = (json["data"] as? [String: Any]) ?? json
        func dictionary(_ raw: Any?) -> [String: Any]? {
            if let value = raw as? [String: Any] { return value }
            guard let value = raw as? String, let bytes = value.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        func shape(_ raw: Any?) -> String {
            guard let raw else { return "none" }
            if raw is NSNull { return "null" }
            if raw is [String: Any] { return "object" }
            if raw is [Any] { return "array" }
            if let value = raw as? NSNumber { return value.doubleValue == 0 ? "zero" : "nonzero" }
            if let value = raw as? String { return value.isEmpty ? "empty-string" : "string" }
            return "other"
        }
        let ext = dictionary(data["extendData"]) ?? dictionary(dictionary(data["extraData"])?["extendData"]) ?? [:]
        return "sub=\(element.subCmd) outer=\(ZolaJSON.int(data["callType"], default: -1)) type=\(ZolaJSON.int(data["type"], default: -1)) explicit=\(ZolaJSON.int(data["isVideo"], default: -1)) ext=\(ZolaJSON.int(ext["callType"], default: -1)) video=\(shape(data["video"])) codec=\(shape(data["videoCodec"])) extvideo=\(shape(ext["video"])) extcodec=\(shape(ext["videoCodec"])) selected=\(isIncomingInviteVideo(element: element, data: data) ? 1 : 0)"
    }

    /// Detects whether an incoming `cmd = 402` invite is a Video Call (`VoipChatModule` `0x102f8ffc4..0x102f9000c`).
    /// On live Zalo `cmd = 402` frames (`mac35`), outer `data["callType"]` is `3` (`protocolVersion == 3`) for BOTH voice and video,
    /// whereas `extendData["callType"]` is `1` for video and `0` for voice; video capabilities may appear in both.
    public static func isIncomingInviteVideo(element: ZolaUnpackedChatElement, data: [String: Any]) -> Bool {
        func parseDict(_ raw: Any?) -> [String: Any]? {
            if let dict = raw as? [String: Any] { return dict }
            let str = ZolaJSON.string(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !str.isEmpty, let bytes = str.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        }
        let extDict = parseDict(data["extendData"]) ?? parseDict(parseDict(data["extraData"])?["extendData"])
        if let mode = extDict?["callType"] {
            // Live native voice AND video invites advertise video codec capabilities at both
            // levels. The explicit mode is authoritative: 0=voice, 1=video (2026-11-04 sandbox).
            let callType = ZolaJSON.int(mode, default: -1)
            if callType == 0 || callType == 1 { return callType == 1 }
        }
        // Preserve legacy invites that do not carry an explicit native extendData mode.
        if ZolaJSON.int(data["isVideo"], default: 0) == 1 || element.subCmd == 4 {
            return true
        }
        let outerCallType = ZolaJSON.int(data["callType"] ?? data["type"], default: 0)
        if outerCallType == 4 { return true }
        if data["video"] != nil || data["videoCodec"] != nil { return true }
        if let extDict, extDict["video"] != nil || extDict["videoCodec"] != nil { return true }
        return false
    }

}

#if canImport(Network)
/// Call-scoped persistent `UXVoipSocket` / `UXChatSocket` (`0x7d0`) TCP session
/// (`NWConnection` + `GET/HTTP/1.1` preamble + `EncryptProtocolVer2` `0x08` `AUTHEN subCmd=5` + `0x04` AES-256-GCM stream loop).
final class ZolaVoipSocketSession: @unchecked Sendable {
    private struct CommandWaiter {
        let id: UUID
        let expectedCmd: Int16
        /// When set, only a `msgType = 3/4` reply carrying this `seqId` and one of `ackCmds` resolves the waiter.
        let ackSeqId: Int32?
        let ackCmds: Set<Int16>
        let requiresResponseBody: Bool
        let continuation: CheckedContinuation<ZolaUnpackedChatElement, Error>
    }

    private let selfUid: Int64
    private let srcId: Int32
    private let authenPayload: Data
    private let endpoints: [ZolaVoipEndpoint]
    private var socketCrypto: ZolaSocketCrypto?
    private let heartbeatIntervalSeconds: Double
    /// `true` for the persistent background listener: after a call terminates, only the call binding
    /// is cleared — the authenticated `0x7d0` TCP link + heartbeat stay alive for the next call.
    private var keepAliveAfterCallEnd: Bool
    private var onEvent: (@Sendable (ZolaVoipCallEvent) -> Void)?
    private var onChatElement: (@Sendable (ZolaUnpackedChatElement) -> Void)?
    private let queue = DispatchQueue(label: "com.zolakit.voip.session")

    private var connection: NWConnection?
    private var connectedHost: String = ""
    private var connectedPort: UInt16 = 443
    private var receiveBuffer = Data()
    private var httpHeaderChecked = false
    private var isClosed = false
    private var ownershipRevoked = false
    private var seqCounter: Int32 = 1
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastInboundActivityAt: Date = Date()
    private var incomingModeDiagnosticCount = 0

    struct VoipCallContext: Sendable {
        var sessionId: String
        var rtpAddress: String
        var rtcpAddress: String
        var extendData: String
    }

    private let incomingPartnerAllowlist: Set<Int64>?
    private var activeCallId: Int32 = 0
    private var clientCallId: Int32 = 0
    private var activePartnerUid: Int64 = 0
    private var activeIsVideo: Bool = false
    private var activeCallIsIncoming = false
    private var activeCallReceived408 = false
    private final class OutgoingAnswerAcknowledgement {
        var accepted = false
        var sent = false
        var pending: [CheckedContinuation<Void, Error>] = []
    }
    private var outgoingAnswerAcknowledgement = OutgoingAnswerAcknowledgement()

    struct FinishLogIdentity: Sendable {
        let sendType: Int32
        let receivedIncomingAnswerAcknowledgement: Bool
    }

    /// Exact call/peer ownership only: a delayed end must never borrow a newer call's ACK.
    func finishLogIdentity(callId: Int32, partnerUid: Int64) async -> FinishLogIdentity? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard callId != 0, callId == self.activeCallId,
                      partnerUid == self.activePartnerUid else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: FinishLogIdentity(
                    sendType: self.activeCallIsIncoming ? 1 : 0,
                    receivedIncomingAnswerAcknowledgement: self.activeCallIsIncoming && self.activeCallReceived408
                ))
            }
        }
    }

    struct ClaimedFinishLog: Sendable {
        let identity: FinishLogIdentity
        let remotelyEnded: Bool
        let context: VoipCallContext?
    }
    private struct FinishKey: Hashable { let callId: Int32; let peer: Int64 }
    private struct RetainedFinish {
        let value: ClaimedFinishLog
        let deadline: TimeInterval
        var claimed: Bool
    }
    // A terminal callback may remove SwiftUI's call view before its finalizer runs.
    // Keep only a bounded, short-lived exact identity; never reuse the next call's ACK.
    private var retainedFinishes: [FinishKey: RetainedFinish] = [:]

    private func pruneFinishesOnQueue() {
        let now = ProcessInfo.processInfo.systemUptime
        retainedFinishes = retainedFinishes.filter { $0.value.deadline > now }
        while retainedFinishes.count > 8,
              let oldest = retainedFinishes.min(by: { $0.value.deadline < $1.value.deadline })?.key {
            retainedFinishes.removeValue(forKey: oldest)
        }
    }

    private func retainRemoteFinishOnQueue(callId: Int32, peer: Int64) {
        guard callId != 0, callId == activeCallId, peer == activePartnerUid else { return }
        pruneFinishesOnQueue()
        let key = FinishKey(callId: callId, peer: peer)
        guard retainedFinishes[key] == nil else { return }
        retainedFinishes[key] = RetainedFinish(value: ClaimedFinishLog(
            identity: FinishLogIdentity(sendType: activeCallIsIncoming ? 1 : 0,
                receivedIncomingAnswerAcknowledgement: activeCallIsIncoming && activeCallReceived408),
            remotelyEnded: true, context: voipCallContextByCallId[callId]),
            deadline: ProcessInfo.processInfo.systemUptime + 60, claimed: false)
        pruneFinishesOnQueue()
    }

    /// Atomic one-shot claim serializes competing onChange/onDisappear finalizers.
    func claimFinishLog(callId: Int32, partnerUid: Int64) async -> ClaimedFinishLog? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.pruneFinishesOnQueue()
                let key = FinishKey(callId: callId, peer: partnerUid)
                if var retained = self.retainedFinishes[key] {
                    guard !retained.claimed else { continuation.resume(returning: nil); return }
                    retained.claimed = true
                    self.retainedFinishes[key] = retained
                    continuation.resume(returning: retained.value)
                    return
                }
                guard callId != 0, partnerUid == self.activePartnerUid,
                      callId == self.activeCallId || callId == self.clientCallId else {
                    continuation.resume(returning: nil); return
                }
                let value = ClaimedFinishLog(identity: FinishLogIdentity(
                    sendType: self.activeCallIsIncoming ? 1 : 0,
                    receivedIncomingAnswerAcknowledgement: self.activeCallIsIncoming && self.activeCallReceived408),
                    remotelyEnded: false, context: self.voipCallContextByCallId[callId])
                let record = RetainedFinish(value: value,
                    deadline: ProcessInfo.processInfo.systemUptime + 60, claimed: true)
                self.retainedFinishes[key] = record
                // Client/server aliases refer to the same outgoing call, not two finish logs.
                if self.activeCallId != 0 {
                    self.retainedFinishes[FinishKey(callId: self.activeCallId, peer: partnerUid)] = record
                }
                if self.clientCallId != 0 {
                    self.retainedFinishes[FinishKey(callId: self.clientCallId, peer: partnerUid)] = record
                }
                self.pruneFinishesOnQueue()
                continuation.resume(returning: value)
            }
        }
    }

    /// A delayed old-call finalizer must never unbind or close a newly accepted call.
    func completeClaimedFinish(callId: Int32, partnerUid: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if partnerUid == self.activePartnerUid,
                   callId != 0, callId == self.activeCallId || callId == self.clientCallId {
                    if self.keepAliveAfterCallEnd { self.unbindCallOnQueue() }
                    else { self.closeOnQueue() }
                }
                continuation.resume()
            }
        }
    }

    private var receivedServerCommands: [Int16] = []
    /// Raw `extendData` JSON string per incoming/active `callId` (P2P endpoints, `sP2P`, `tpType`, …) —
    /// queried via `voipExtendData(forCallId:)` so the `incomingInvite` enum case stays unchanged.
    private var voipExtendDataByCallId: [Int32: String] = [:]
    private var voipCallContextByCallId: [Int32: VoipCallContext] = [:]

    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectWaiterId: UUID?
    private var commandWaiters: [UUID: CommandWaiter] = [:]

    convenience init(
        selfUid: Int64,
        authenPayload: Data,
        endpoints: [(host: String, port: UInt16)] = ZolaVoipProtocol.defaultEndpoints,
        keepAliveAfterCallEnd: Bool = false,
        onEvent: (@Sendable (ZolaVoipCallEvent) -> Void)?,
        onChatElement: (@Sendable (ZolaUnpackedChatElement) -> Void)? = nil,
        incomingPartnerAllowlist: Set<Int64>? = nil
    ) {
        self.init(
            selfUid: selfUid,
            authenPayload: authenPayload,
            encryptedEndpoints: endpoints.map { ZolaVoipEndpoint(host: $0.host, port: $0.port, serverPubKeyBase64: nil) },
            socketCrypto: nil,
            heartbeatIntervalSeconds: 0,
            keepAliveAfterCallEnd: keepAliveAfterCallEnd,
            onEvent: onEvent,
            onChatElement: onChatElement,
            incomingPartnerAllowlist: incomingPartnerAllowlist
        )
    }

    init(
        selfUid: Int64,
        authenPayload: Data,
        encryptedEndpoints: [ZolaVoipEndpoint],
        socketCrypto: ZolaSocketCrypto?,
        heartbeatIntervalSeconds: Double = 18.0,
        keepAliveAfterCallEnd: Bool = false,
        onEvent: (@Sendable (ZolaVoipCallEvent) -> Void)?,
        onChatElement: (@Sendable (ZolaUnpackedChatElement) -> Void)? = nil,
        incomingPartnerAllowlist: Set<Int64>? = nil
    ) {
        self.selfUid = selfUid
        self.srcId = Int32(truncatingIfNeeded: selfUid)
        self.authenPayload = authenPayload
        self.endpoints = encryptedEndpoints
        self.socketCrypto = socketCrypto
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.keepAliveAfterCallEnd = keepAliveAfterCallEnd
        self.onEvent = onEvent
        self.onChatElement = onChatElement
        self.incomingPartnerAllowlist = incomingPartnerAllowlist
    }

    func setEventHandler(_ handler: (@Sendable (ZolaVoipCallEvent) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.onEvent = handler
                cont.resume()
            }
        }
    }

    func setChatElementHandler(_ handler: (@Sendable (ZolaUnpackedChatElement) -> Void)?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.onChatElement = handler
                cont.resume()
            }
        }
    }

    func enableKeepAliveAfterCallEnd() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.keepAliveAfterCallEnd = true
                cont.resume()
            }
        }
    }

    func isKeepAliveEnabled() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.keepAliveAfterCallEnd)
            }
        }
    }

    func nextSeqId() async -> Int32 {
        await withCheckedContinuation { cont in
            queue.async {
                self.seqCounter &+= 1
                if self.seqCounter <= 0 { self.seqCounter = 2 }
                cont.resume(returning: self.seqCounter)
            }
        }
    }

    func bindCall(serverCallId: Int32, clientCallId: Int32, partnerUid: Int64, isVideo: Bool) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.activeCallId = serverCallId
                self.clientCallId = clientCallId
                self.activePartnerUid = partnerUid
                self.activeIsVideo = isVideo
                self.activeCallIsIncoming = false
                self.activeCallReceived408 = false
                self.outgoingAnswerAcknowledgement = OutgoingAnswerAcknowledgement()
                cont.resume()
            }
        }
    }

    /// Caller confirmation after its relay is ready. Native `voipStream:withResult:withType:`
    /// (type 5, 0x102fbaa48) sends `requestVoiceCallAnswerWithACK:` (408), separately from 423.
    /// Never opens a socket, changes ownership, or acknowledges an incoming/callee 408.
    func acknowledgeOutgoingAnswer(partnerUid: Int64, callId: Int32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !ownershipRevoked, !isClosed, let connection,
                      activeCallId != 0, callId != 0,
                      callId == activeCallId || callId == clientCallId,
                      partnerUid > 0, partnerUid == activePartnerUid,
                      !activeCallIsIncoming, outgoingAnswerAcknowledgement.accepted else {
                    continuation.resume(throwing: ZolaError.safetyGate("Cuộc gọi đi chưa nhận xác nhận trả lời phù hợp"))
                    return
                }
                let state = outgoingAnswerAcknowledgement
                if state.sent { continuation.resume(); return }
                state.pending.append(continuation)
                guard state.pending.count == 1 else { return }
                seqCounter &+= 1
                if seqCounter <= 0 { seqCounter = 2 }
                let frame = ZolaCrypto.packVoipRingingAckFrame(
                    srcId: srcId, partnerId: Int32(truncatingIfNeeded: activePartnerUid),
                    callId: activeCallId, status: 0, seqId: seqCounter)
                func finish(_ error: Error?) {
                    let callbacks = state.pending
                    state.pending.removeAll()
                    state.sent = error == nil
                    for callback in callbacks {
                        if let error { callback.resume(throwing: error) }
                        else { callback.resume() }
                    }
                }
                do {
                    let wire = try sealOutboundOnQueue(frame.payload)
                    connection.send(content: wire, completion: .contentProcessed { error in
                        self.queue.async {
                            if let error { finish(ZolaError.transport("Gửi xác nhận trả lời thất bại: \(error.localizedDescription)")) }
                            else if self.outgoingAnswerAcknowledgement !== state || self.isClosed || self.ownershipRevoked {
                                finish(ZolaError.safetyGate("Cuộc gọi đã kết thúc trong khi xác nhận"))
                            } else { finish(nil) }
                        }
                    })
                } catch { finish(error) }
            }
        }
    }

    func snapshotCommands() async -> (host: String, port: UInt16, commands: [Int16]) {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: (self.connectedHost, self.connectedPort, self.receivedServerCommands))
            }
        }
    }

    func matchesCall(callId: Int32, partnerUid: Int64) async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                guard !self.isClosed else {
                    cont.resume(returning: false)
                    return
                }
                let idMatch = (callId == 0) || (self.activeCallId == callId) || (self.clientCallId == callId)
                let partnerMatch = (partnerUid == 0) || (self.activePartnerUid == 0) || (self.activePartnerUid == partnerUid)
                cont.resume(returning: idMatch && partnerMatch)
            }
        }
    }

    /// Marks the currently-bound call as a video call (`activeIsVideo = true`) after a mid-call
    /// voice→video upgrade (`cmd = 416, subCmd = 3`) is sent, or when the peer switches to video
    /// (`cmd = 412`). Keeps the socket's view of the call in sync so any `isVideo`-gated inbound
    /// handling treats subsequent frames as video.
    func markCallVideo() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.activeIsVideo = true
                cont.resume()
            }
        }
    }

    func isCallVideo() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.activeIsVideo)
            }
        }
    }

    /// Clears the bound call (`activeCallId`/`clientCallId`/`activePartnerUid`/`activeIsVideo`) while
    /// keeping the authenticated TCP link + heartbeat alive — used by the background listener after
    /// `reject`/`cancel`/call end so the socket can serve the next call immediately.
    func unbindCall() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.unbindCallOnQueue()
                cont.resume()
            }
        }
    }

    /// Cleanup after a suspended outgoing setup fails. Identity and teardown share one queue turn,
    /// so an intervening redial cannot be closed/unbound by the older request.
    func finishFailedOutgoingSetup(callId: Int32, partnerUid: Int64, closeSocket: Bool) async {
        await withCheckedContinuation { continuation in
            queue.async {
                guard callId != 0, self.activeCallId == callId,
                      self.activePartnerUid == partnerUid, !self.activeCallIsIncoming else {
                    continuation.resume(); return
                }
                if closeSocket && !self.keepAliveAfterCallEnd { self.closeOnQueue() }
                else { self.unbindCallOnQueue() }
                continuation.resume()
            }
        }
    }

    private func unbindCallOnQueue() {
        if activeCallId != 0 {
            voipExtendDataByCallId.removeValue(forKey: activeCallId)
            voipCallContextByCallId.removeValue(forKey: activeCallId)
        }
        if clientCallId != 0 {
            voipExtendDataByCallId.removeValue(forKey: clientCallId)
            voipCallContextByCallId.removeValue(forKey: clientCallId)
        }
        activeCallId = 0
        clientCallId = 0
        activePartnerUid = 0
        activeIsVideo = false
        activeCallIsIncoming = false
        activeCallReceived408 = false
        outgoingAnswerAcknowledgement = OutgoingAnswerAcknowledgement()
    }

    /// `true` when the TCP connection is still open — lets `ZolaClient` reuse `activeVoipSocket`
    /// for outgoing calls instead of re-authenticating a fresh `0x7d0` session.
    func isSocketAlive() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: !self.isClosed && self.connection != nil)
            }
        }
    }

    /// Raw `extendData` JSON captured from the `cmd=402`/`407`/`403` frame for `callId` (P2P endpoints,
    /// codec hints). Kept outside `ZolaVoipCallEvent.incomingInvite` so the enum signature stays stable.
    func voipExtendData(forCallId callId: Int32) async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.voipExtendDataByCallId[callId])
            }
        }
    }

    func storeCallContext(
        callId: Int32,
        sessionId: String,
        rtpAddress: String,
        rtcpAddress: String,
        extendData: String = ""
    ) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard callId != 0 else {
                    cont.resume()
                    return
                }
                var existing = self.voipCallContextByCallId[callId]
                    ?? VoipCallContext(sessionId: "", rtpAddress: "", rtcpAddress: "", extendData: "")
                if !sessionId.isEmpty { existing.sessionId = sessionId }
                if !rtpAddress.isEmpty { existing.rtpAddress = rtpAddress }
                if !rtcpAddress.isEmpty { existing.rtcpAddress = rtcpAddress }
                if !extendData.isEmpty {
                    existing.extendData = extendData
                    self.voipExtendDataByCallId[callId] = extendData
                }
                self.voipCallContextByCallId[callId] = existing
                cont.resume()
            }
        }
    }

    func callContext(forCallId callId: Int32) async -> VoipCallContext? {
        await withCheckedContinuation { cont in
            queue.async {
                if let ctx = self.voipCallContextByCallId[callId] {
                    cont.resume(returning: ctx)
                } else if self.activeCallId != 0, let ctx = self.voipCallContextByCallId[self.activeCallId] {
                    cont.resume(returning: ctx)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// A revoked socket must not retry another endpoint after ownership transfers to the service.
    func revokeLocalOwnership() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.ownershipRevoked = true
                self.closeOnQueue()
                continuation.resume()
            }
        }
    }

    /// The queue owns invite dispatch and call identity; check+close must be atomic with both.
    func revokeLocalOwnershipIfIdle() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.activeCallId == 0 else { continuation.resume(returning: false); return }
                self.ownershipRevoked = true
                self.closeOnQueue()
                continuation.resume(returning: true)
            }
        }
    }

    private func checkLocalOwnership() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.ownershipRevoked { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume() }
            }
        }
    }

    /// Connects TCP, sends `GET/HTTP/1.1` preamble + `AUTHEN` (`0x08` encrypted or loopback plaintext), and verifies `retCode == 0`.
    func connectAndAuthenticate(perHostTimeout: Double = 3.5) async throws {
        if socketCrypto != nil {
            guard !endpoints.isEmpty, endpoints.allSatisfy(\.hasValidServerPubKey32) else {
                throw ZolaError.safetyGate(
                    "Đã chặn kết nối UXVoipSocket tới máy chủ Zalo vì thiếu khoá công khai X25519 32B (SocketEntity.pubKey) để bảo vệ phiên đăng nhập."
                )
            }
        } else {
            guard !endpoints.isEmpty, endpoints.allSatisfy({ ZolaVoipProtocol.isLoopbackHost($0.host) }) else {
                throw ZolaError.safetyGate(
                    "Đã chặn kết nối UXVoipSocket thô tới máy chủ Zalo (thiếu lớp mã hoá ProtocolVer2/AuthenV3Aes) để bảo vệ phiên đăng nhập không bị thu hồi."
                )
            }
        }

        var lastError: Error = ZolaError.transport("Không thể kết nối máy chủ thoại Zalo")
        // Endpoints that accepted TCP but closed cleanly before answering the authen frame. That is how
        // the server rejects an authen it cannot decrypt (stale socket keySet); a network outage never
        // reaches TCP `.ready`, so it stays a transport error.
        var closedBeforeAuthAck = 0
        for endpoint in endpoints {
            try await checkLocalOwnership()
            var tcpReady = false
            do {
                try await connectSingleEndpoint(host: endpoint.host, port: endpoint.port, timeoutSeconds: perHostTimeout)
                tcpReady = true
                try await checkLocalOwnership()
                let wireAuthen = try await makeWireAuthenPayload(serverPubKeyBase64: endpoint.serverPubKeyBase64)
                let authAck = try await sendWireAndWait(
                    wirePayload: wireAuthen,
                    expectedCmd: 1,
                    timeoutSeconds: perHostTimeout
                )
                if authAck.retCode == 0 {
                    try await checkLocalOwnership()
                    await startHeartbeatIfNeeded()
                    return
                }
                await close()
                if authAck.retCode == 102 || authAck.retCode == -96 {
                    throw ZolaError.sessionExpired(
                        code: Int(authAck.retCode),
                        endpoint: "UXChatSocket:1",
                        message: "Phiên Zalo đã hết hạn trên UXChatSocket (retCode=\(authAck.retCode))"
                    )
                }
                // Auth rejected by server (`-1` / `-67`) — stop retrying identical credentials across hosts.
                throw ZolaError.server(
                    code: Int(authAck.retCode),
                    message: "Phiên gọi Zalo bị từ chối xác thực (retCode=\(authAck.retCode))"
                )
            } catch let err as ZolaError {
                if case .sessionExpired = err {
                    throw err
                }
                if case .server = err {
                    throw err
                }
                if case .safetyGate = err {
                    throw err
                }
                if tcpReady, case .transport = err, await remoteClosedCleanlyDuringAttempt() {
                    closedBeforeAuthAck += 1
                }
                lastError = err
                await resetForRetry()
            } catch {
                lastError = error
                await resetForRetry()
            }
        }
        if closedBeforeAuthAck > 0 {
            throw ZolaError.server(
                code: ZolaConstants.errorInvalidSessionKey,
                message: "Máy chủ Zalo đóng kết nối ngay sau bước xác thực socket (khoá socket có thể đã hết hạn)"
            )
        }
        throw lastError
    }

    private func remoteClosedCleanlyDuringAttempt() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async { cont.resume(returning: self.remoteClosedCleanly) }
        }
    }

    private func makeWireAuthenPayload(serverPubKeyBase64: String?) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    if let crypto = self.socketCrypto {
                        guard let pubB64 = serverPubKeyBase64 else {
                            throw ZolaError.safetyGate("Thiếu SocketEntity.pubKey trên endpoint VoIP")
                        }
                        let sealed = try crypto.sealAuthenFrame(self.authenPayload, serverPubKeyBase64: pubB64)
                        cont.resume(returning: sealed)
                    } else {
                        cont.resume(returning: self.authenPayload)
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func startHeartbeatIfNeeded() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.startHeartbeatOnQueue()
                cont.resume()
            }
        }
    }

    /// Set on `queue` when the server ends the stream cleanly (FIN) during the current attempt.
    private var remoteClosedCleanly = false

    private func resetForRetry() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopHeartbeatOnQueue()
                self.connection?.stateUpdateHandler = nil
                self.connection?.cancel()
                self.connection = nil
                self.receiveBuffer.removeAll(keepingCapacity: false)
                self.httpHeaderChecked = false
                self.isClosed = false
                self.failAllWaitersOnQueue(with: ZolaError.transport("Đặt lại kết nối VoIP socket"))
                cont.resume()
            }
        }
    }

    private func connectSingleEndpoint(host: String, port: UInt16, timeoutSeconds: Double) async throws {
        // 1. Wait for TCP `.ready`
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let nwHost = NWEndpoint.Host(host)
                let nwPort = NWEndpoint.Port(rawValue: port) ?? .https
                let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
                self.remoteClosedCleanly = false
                self.connection = conn
                self.connectedHost = host
                self.connectedPort = port
                self.receiveBuffer.removeAll(keepingCapacity: true)
                self.httpHeaderChecked = false
                self.isClosed = false

                let waiterId = UUID()
                self.connectWaiterId = waiterId
                self.connectContinuation = cont

                conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if self.connectWaiterId == waiterId, let c = self.connectContinuation {
                            self.connectWaiterId = nil
                            self.connectContinuation = nil
                            c.resume()
                        }
                    case let .failed(nwErr):
                        let err = ZolaError.transport("Lỗi kết nối VoIP socket \(host):\(port): \(nwErr.localizedDescription)")
                        self.handleRemoteDisconnectOnQueue(error: err)
                    case .cancelled:
                        let err = ZolaError.transport("Kết nối VoIP socket \(host):\(port) đã đóng")
                        self.handleRemoteDisconnectOnQueue(error: err)
                    default:
                        break
                    }
                }
                conn.start(queue: self.queue)

                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self, self.connectWaiterId == waiterId, let c = self.connectContinuation else { return }
                    self.connectWaiterId = nil
                    self.connectContinuation = nil
                    conn.cancel()
                    c.resume(throwing: ZolaError.transport("Quá thời gian kết nối máy chủ cuộc gọi \(host):\(port)"))
                }
            }
        }

        // 2. Start continuous receive loop & send UXAsyncSocket HTTP preamble without blocking on an optional HTTP 200 response
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let conn = self.connection, !self.isClosed else {
                    cont.resume(throwing: ZolaError.transport("VoIP socket chưa sẵn sàng"))
                    return
                }
                self.pumpReceiveLoopOnQueue()
                let upgradeBytes = ZolaVoipProtocol.makeHttpUpgradeHeader(host: host)
                conn.send(content: upgradeBytes, completion: .contentProcessed { sendErr in
                    if let sendErr {
                        cont.resume(throwing: ZolaError.transport("Gửi HTTP Upgrade thất bại: \(sendErr.localizedDescription)"))
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }

    private func sealOutboundOnQueue(_ chatElementPayload: Data) throws -> Data {
        if let crypto = socketCrypto {
            return try crypto.sealFrame(chatElementPayload)
        }
        return chatElementPayload
    }

    func sendFrame(_ frame: ZolaChatElementFrame) async throws {
        try await sendRaw(frame.payload)
    }

    func sendRaw(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let conn = self.connection, !self.isClosed else {
                    cont.resume(throwing: ZolaError.transport("Kết nối cuộc gọi đã đóng"))
                    return
                }
                let wirePayload: Data
                do {
                    wirePayload = try self.sealOutboundOnQueue(payload)
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                conn.send(content: wirePayload, completion: .contentProcessed { sendErr in
                    if let sendErr {
                        cont.resume(throwing: ZolaError.transport("Gửi gói tín hiệu cuộc gọi thất bại: \(sendErr.localizedDescription)"))
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }

    /// Pass `ackSeqId` + `ackCmds` for commands whose `cmd` is shared with server pushes (`201`): the app
    /// correlates those purely by `seqId` (`MessageSendHandleModule socketStream:didReceiveElement:` `0x100b74bd0`).
    func sendAndWait(
        rawPayload: Data,
        expectedCmd: Int16,
        timeoutSeconds: Double = 5.0,
        ackSeqId: Int32? = nil,
        ackCmds: Set<Int16> = [],
        requiresResponseBody: Bool = false,
        onHandedToNetwork: (@Sendable () -> Void)? = nil
    ) async throws -> ZolaUnpackedChatElement {
        let wirePayload = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try self.sealOutboundOnQueue(rawPayload))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return try await sendWireAndWait(
            wirePayload: wirePayload,
            expectedCmd: expectedCmd,
            timeoutSeconds: timeoutSeconds,
            ackSeqId: ackSeqId,
            ackCmds: ackCmds,
            requiresResponseBody: requiresResponseBody,
            onHandedToNetwork: onHandedToNetwork
        )
    }

    private func sendWireAndWait(
        wirePayload: Data,
        expectedCmd: Int16,
        timeoutSeconds: Double,
        ackSeqId: Int32? = nil,
        ackCmds: Set<Int16> = [],
        requiresResponseBody: Bool = false,
        onHandedToNetwork: (@Sendable () -> Void)? = nil
    ) async throws -> ZolaUnpackedChatElement {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ZolaUnpackedChatElement, Error>) in
            queue.async { [self] in
                guard let conn = self.connection, !self.isClosed else {
                    cont.resume(throwing: ZolaError.transport("Kết nối cuộc gọi không còn hoạt động"))
                    return
                }
                let waiterId = UUID()
                self.commandWaiters[waiterId] = CommandWaiter(
                    id: waiterId,
                    expectedCmd: expectedCmd,
                    ackSeqId: ackSeqId,
                    ackCmds: ackCmds,
                    requiresResponseBody: requiresResponseBody,
                    continuation: cont
                )

                onHandedToNetwork?()
                conn.send(content: wirePayload, completion: .contentProcessed { [weak self] sendErr in
                    guard let self, let sendErr else { return }
                    if let waiter = self.commandWaiters.removeValue(forKey: waiterId) {
                        waiter.continuation.resume(
                            throwing: ZolaError.transport("Lỗi gửi lệnh \(expectedCmd): \(sendErr.localizedDescription)")
                        )
                    }
                })

                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self, let waiter = self.commandWaiters.removeValue(forKey: waiterId) else { return }
                    waiter.continuation.resume(
                        throwing: ZolaError.transport("Quá thời gian chờ phản hồi lệnh \(expectedCmd) từ máy chủ Zalo")
                    )
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.closeOnQueue()
                cont.resume()
            }
        }
    }

    // MARK: - Internal Serial-Queue Stream Processing

    private func startHeartbeatOnQueue() {
        stopHeartbeatOnQueue()
        guard heartbeatIntervalSeconds > 0, !isClosed else { return }
        lastInboundActivityAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + heartbeatIntervalSeconds,
            repeating: heartbeatIntervalSeconds,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            guard let self, let conn = self.connection, !self.isClosed else { return }
            let idleTimeout = max(45.0, self.heartbeatIntervalSeconds * 2.5)
            if Date().timeIntervalSince(self.lastInboundActivityAt) > idleTimeout {
                self.handleRemoteDisconnectOnQueue(
                    error: ZolaError.transport("Quá hạn phản hồi heartbeat trên VoIP socket")
                )
                return
            }
            self.seqCounter &+= 1
            if self.seqCounter <= 0 { self.seqCounter = 2 }
            let ping = ZolaCrypto.packSocketHeartbeatFrame(srcId: self.srcId, seqId: self.seqCounter)
            guard let wire = try? self.sealOutboundOnQueue(ping.payload) else { return }
            conn.send(content: wire, completion: .contentProcessed { _ in })
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeatOnQueue() {
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        stopHeartbeatOnQueue()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        failAllWaitersOnQueue(with: ZolaError.transport("Phiên VoIP socket đã đóng"))
    }

    private func failAllWaitersOnQueue(with error: Error) {
        if let c = connectContinuation {
            connectWaiterId = nil
            connectContinuation = nil
            c.resume(throwing: error)
        }
        let waiters = Array(commandWaiters.values)
        commandWaiters.removeAll()
        for w in waiters {
            w.continuation.resume(throwing: error)
        }
    }

    private func handleRemoteDisconnectOnQueue(error: Error) {
        let hadActiveCall = !isClosed && activeCallId != 0
        let callId = activeCallId
        let partnerUid = activePartnerUid
        closeOnQueue()
        if hadActiveCall {
            onEvent?(.ended(callId: callId, partnerUid: partnerUid, reason: "Mất kết nối tín hiệu cuộc gọi"))
        }
    }

    private func pumpReceiveLoopOnQueue() {
        guard let conn = connection, !isClosed else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, recvErr in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.lastInboundActivityAt = Date()
                self.receiveBuffer.append(data)
                self.drainReceiveBufferOnQueue()
            }
            if let recvErr {
                self.handleRemoteDisconnectOnQueue(
                    error: ZolaError.transport("Lỗi đọc VoIP socket: \(recvErr.localizedDescription)")
                )
                return
            }
            if isComplete {
                self.remoteClosedCleanly = true
                self.handleRemoteDisconnectOnQueue(
                    error: ZolaError.transport("Máy chủ Zalo đã đóng kết nối cuộc gọi")
                )
                return
            }
            self.pumpReceiveLoopOnQueue()
        }
    }

    private func drainReceiveBufferOnQueue() {
        if !httpHeaderChecked {
            guard receiveBuffer.count >= 4 else { return }
            if ZolaVoipProtocol.startsWithHttpPrefix(receiveBuffer) {
                guard let markerRange = receiveBuffer.range(of: ZolaVoipProtocol.httpHeaderEndMarker) else {
                    if receiveBuffer.count > 16384 {
                        handleRemoteDisconnectOnQueue(error: ZolaError.transport("Phản hồi HTTP Upgrade không hợp lệ"))
                    }
                    return
                }
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<markerRange.upperBound)
            }
            httpHeaderChecked = true
        }

        if let crypto = socketCrypto {
            while receiveBuffer.count >= 51 {
                let snapshot = Data(receiveBuffer.prefix(4))
                guard let totalWireLen = try? snapshot.readUInt32LE(at: 0) else { break }
                if totalWireLen < 51 || totalWireLen > 1_048_576 {
                    handleRemoteDisconnectOnQueue(
                        error: ZolaError.crypto("Khung tín hiệu mã hoá 0x7d0 không hợp lệ (size=\(totalWireLen))")
                    )
                    return
                }
                guard receiveBuffer.count >= Int(totalWireLen) else {
                    break
                }
                let wireFrame = Data(receiveBuffer.prefix(Int(totalWireLen)))
                receiveBuffer.removeFirst(Int(totalWireLen))

                let reconstructed: Data
                do {
                    reconstructed = try crypto.openFrame(wireFrame)
                } catch {
                    handleRemoteDisconnectOnQueue(error: error)
                    return
                }
                guard let element = try? ZolaCrypto.unpackChatElementFrame(reconstructed) else {
                    continue
                }
                handleUnpackedElementOnQueue(element)
            }
            return
        }

        while receiveBuffer.count >= 23 {
            let snapshot = Data(receiveBuffer.prefix(4))
            guard let frameSize = try? snapshot.readUInt32LE(at: 0) else { break }
            if frameSize < 23 || frameSize > 1_048_576 {
                handleRemoteDisconnectOnQueue(
                    error: ZolaError.crypto("Khung tín hiệu VoIP không hợp lệ (size=\(frameSize))")
                )
                return
            }
            guard receiveBuffer.count >= Int(frameSize) else {
                break
            }
            let rawFrame = Data(receiveBuffer.prefix(Int(frameSize)))
            receiveBuffer.removeFirst(Int(frameSize))

            guard let element = try? ZolaCrypto.unpackChatElementFrame(rawFrame) else {
                continue
            }
            handleUnpackedElementOnQueue(element)
        }
    }

    /// Ordinary sends end on msgType4 or a msgType3 error. Recall requires a nonempty command result;
    /// empty transport receipts must leave that waiter pending for the JSON response.
    static func resolvesSeqWaiter(_ element: ZolaUnpackedChatElement, requiresResponseBody: Bool = false) -> Bool {
        if requiresResponseBody {
            return (element.msgType == 3 || element.msgType == 4)
                && (element.retCode != 0 || !element.bodyData.isEmpty)
        }
        return element.msgType == 4 || (element.msgType == 3 && element.retCode != 0)
    }

    private func handleUnpackedElementOnQueue(_ element: ZolaUnpackedChatElement) {
        if element.cmd != 2 {
            if receivedServerCommands.count >= 256 {
                receivedServerCommands.removeFirst(receivedServerCommands.count - 255)
            }
            receivedServerCommands.append(element.cmd)
        }

        // Seq-bound waiters run first: chat sends are confirmed by a possibly empty `msgType = 4` frame, which
        // the drop below would discard, and `cmd = 201` also carries pushes the cmd-only match would swallow.
        // Ordinary sends keep waiting after msgType3/retCode0; response-body commands (recall) accept the result.
        if let matchedKey = commandWaiters.first(where: {
               $0.value.ackSeqId == element.seqId && $0.value.ackCmds.contains(element.cmd)
                   && Self.resolvesSeqWaiter(element, requiresResponseBody: $0.value.requiresResponseBody)
           })?.key,
           let waiter = commandWaiters.removeValue(forKey: matchedKey) {
            waiter.continuation.resume(returning: element)
            return
        }

        // Ignore pure transport-level empty receipt ACKs (`msgType = 4`, `retCode = 0`, `bodyLen = 0`)
        // for request/response commands (`373..398`, `1582`, `1584`, `401`, etc.) so `sendAndWait` receives
        // the actual `msgType = 3` server payload frame that follows immediately after the ACK, and so active
        // VoIP sessions never misinterpret an empty receipt ACK as a call teardown/signal event.
        if element.msgType == 4 && element.retCode == 0 && element.bodyData.isEmpty && element.cmd != 2 {
            return
        }

        // 1. Fulfill any explicit command waiter (`cmd=1` AUTHEN, `cmd=2` Heartbeat, `cmd=401` CallRequest, `cmd=425` Preselect, `FriendRequestManager` `373..398`/`1582`/`1584`, etc.)
        if let matchedKey = commandWaiters.first(where: { $0.value.ackSeqId == nil && $0.value.expectedCmd == element.cmd })?.key,
           let waiter = commandWaiters.removeValue(forKey: matchedKey) {
            waiter.continuation.resume(returning: element)
            let isAsyncVoipPushCmd: Bool = {
                switch element.cmd {
                case 402, 403, 405, 406, 407, 408, 409, 412, 415, 421, 423, 424:
                    return true
                default:
                    return false
                }
            }()
            if !isAsyncVoipPushCmd {
                return
            }
        }
        if element.cmd == 2 {
            return
        }

        // 1b. Dispatch `ChatProcessor` (`0x100a84174` / `0x100a84d48`) push & offline-batch frames on `0x7d0`
        // BEFORE dropping `msgType = 3` (since `121`/`224` GetOffline responses arrive as `msgType = 3`).
        // Status pushes have their own parser/ACK commands; pure msgType4 receipts were dropped above.
        let isAsyncChatCmd: Bool = {
            if ZolaNativeChatSignals.handles(element.cmd) { return true }
            switch element.cmd {
            case 600:
                return true // Native NotifyStreamModule input.601 is its outgoing ACK.
            case 101, 113, 121, 201, 224, 1991, 1992, 1780, 1782, 1785, 1787, 10109, 10207, 10209:
                return true
            default:
                return false
            }
        }()
        if isAsyncChatCmd {
            if (element.msgType != 4 || element.retCode != 0) && (!element.bodyData.isEmpty || element.cmd == 106 || element.cmd == 1991 || element.retCode != 0) {
                onChatElement?(element)
            }
            return
        }

        // Ignore unclaimed `msgType = 3` server ACKs to client-originated fire-and-forget requests
        // (`cmd = 425` preselect, `416` ZRTP req, `415` confirm ack, `423` cmd ack, `406` finish log,
        // `402/subCmd = 3` answer ack, `405`/`409` cancel/end ack, or empty-body `407` callee-ringing ack).
        // NEVER drop `cmd = 408` (`didReceiveCallRequestAnswerACK:`), `403`, `424`, or non-empty `407`!
        if element.msgType == 3 {
            switch element.cmd {
            case 408, 403, 424:
                break
            case 407 where !element.bodyData.isEmpty:
                break
            default:
                return
            }
        }

        if element.cmd == 402, incomingModeDiagnosticCount < 8 {
            incomingModeDiagnosticCount += 1
            NSLog("zolakit incoming-mode %@", ZolaVoipProtocol.incomingInviteModeDiagnostic(element))
        }

        // 2. Interpret asynchronous server push frames (`407` ringing, `408`/`403`/`424` answer, `405`/`409` end, `402` invite)
        let interpreted = ZolaVoipProtocol.interpretIncomingElement(
            element,
            activeCallId: activeCallId,
            clientCallId: clientCallId,
            activePartnerUid: activePartnerUid,
            selfUid: selfUid
        )

        // When the peer switches the call to video (`cmd = 412` `didReceiveSwitchToVideoCall`), mark the
        // bound session as video so any `isVideo`-gated inbound routing treats the incoming `0x0d` video
        // flow as video from here on. (Runs on the socket's serial queue, so direct assignment is safe.)
        if element.cmd == 412 {
            activeIsVideo = true
        }

        if let ackCmd = interpreted.autoAckCmd, let conn = connection, !isClosed {
            seqCounter &+= 1
            if seqCounter <= 0 { seqCounter = 2 }
            let ackFrame = ZolaCrypto.packVoipCommandAckFrame(
                srcId: srcId,
                partnerId: Int32(truncatingIfNeeded: interpreted.resolvedPartnerUid),
                callId: interpreted.resolvedCallId,
                ackedCommand: ackCmd,
                seqId: seqCounter
            )
            if let wireAck = try? sealOutboundOnQueue(ackFrame.payload) {
                conn.send(content: wireAck, completion: .contentProcessed { _ in })
            }
        }

        // Preserve `extendData`, `rtpIP`, and `sessId` on `402` invite, `407` peer ringing, and `403`/`424`/`408` answer.
        if interpreted.resolvedCallId != 0,
           (element.cmd != 402 || activeCallId == 0),
           (element.cmd == 402 || element.cmd == 407 || element.cmd == 403 || element.cmd == 424 || element.cmd == 408)
        {
            let parsedJson: [String: Any]? = {
                if let direct = element.parseJSONDictionary() { return direct }
                if (element.cmd == 407 || element.cmd == 403),
                   element.bodyData.count > 18,
                   let tailObj = try? JSONSerialization.jsonObject(with: Data(element.bodyData.dropFirst(18))) as? [String: Any]
                {
                    return tailObj
                }
                return nil
            }()
            if let json = parsedJson {
                let data = (json["data"] as? [String: Any]) ?? json
                var ext = ZolaJSON.string(data["extendData"])
                if ext.isEmpty, let extDict = data["extendData"] as? [String: Any],
                   let extBytes = try? JSONSerialization.data(withJSONObject: extDict, options: [.sortedKeys]) {
                    ext = String(decoding: extBytes, as: UTF8.self)
                }
                if ext.isEmpty {
                    let extraDict: [String: Any]? = {
                        if let dict = data["extraData"] as? [String: Any] { return dict }
                        let rawExtra = ZolaJSON.string(data["extraData"]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !rawExtra.isEmpty, let bytes = rawExtra.data(using: .utf8) else { return nil }
                        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                    }()
                    if let extraDict {
                        if let nestedStr = extraDict["extendData"] as? String, !nestedStr.isEmpty {
                            ext = nestedStr
                        } else if let nestedDict = extraDict["extendData"] as? [String: Any],
                                  let nestedBytes = try? JSONSerialization.data(withJSONObject: nestedDict, options: [.sortedKeys])
                        {
                            ext = String(decoding: nestedBytes, as: UTF8.self)
                        } else if extraDict["p2p"] != nil,
                                  let extraBytes = try? JSONSerialization.data(withJSONObject: extraDict, options: [.sortedKeys])
                        {
                            ext = String(decoding: extraBytes, as: UTF8.self)
                        }
                    }
                }
                let updatedRtp = [
                    ZolaJSON.string(data["rtpIP"]),
                    ZolaJSON.string(data["rtpAddress"]),
                    ZolaJSON.string(data["rtpAddr"]),
                    ZolaVoipProtocol.extractFirstServerAddress(from: data["zrtcConfig"], key: "rtp"),
                    ZolaVoipProtocol.extractFirstServerAddress(from: data["extendData"], key: "rtp"),
                    ZolaVoipProtocol.extractFirstServerAddress(from: data["servers"], key: "rtp"),
                    ZolaVoipProtocol.extractFirstServerAddress(from: data["zrtpServers"], key: "rtp"),
                    ZolaVoipProtocol.extractFirstServerAddress(from: data["serverAddr"], key: "rtp"),
                ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
                let updatedSess = ZolaJSON.string(data["sessId"] ?? data["sessionId"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ext.isEmpty || !updatedRtp.isEmpty || !updatedSess.isEmpty {
                    var ctx = voipCallContextByCallId[interpreted.resolvedCallId]
                        ?? VoipCallContext(sessionId: "", rtpAddress: "", rtcpAddress: "", extendData: "")
                    if !ext.isEmpty {
                        voipExtendDataByCallId[interpreted.resolvedCallId] = ext
                        ctx.extendData = ext
                    }
                    // Never clobber an already-registered caller relay on `407`/`403`; allow `402` invite or `408` authoritative update.
                    if !updatedRtp.isEmpty, (ctx.rtpAddress.isEmpty || element.cmd == 402 || element.cmd == 408) {
                        ctx.rtpAddress = updatedRtp
                        if ctx.rtcpAddress.isEmpty { ctx.rtcpAddress = updatedRtp }
                    }
                    if !updatedSess.isEmpty {
                        ctx.sessionId = updatedSess
                    }
                    voipCallContextByCallId[interpreted.resolvedCallId] = ctx
                }
            }
        }

        guard let event = interpreted.event else { return }

        if case let .incomingInvite(invCallId, invPartnerUid, invIsVideo, _, _, invRtp, invRtcp, invSess) = event {
            // Test-service policy is checked before ACK/ringing/busy writes or call binding.
            if let incomingPartnerAllowlist, !incomingPartnerAllowlist.contains(invPartnerUid) { return }
            if activeCallId != 0 {
                if let conn = connection, !isClosed {
                    seqCounter &+= 1
                    if seqCounter <= 0 { seqCounter = 2 }
                    let ack415 = ZolaCrypto.packVoipConfirmIncomingAckFrame(
                        srcId: srcId,
                        partnerId: Int32(truncatingIfNeeded: invPartnerUid),
                        callId: invCallId,
                        seqId: seqCounter
                    )
                    if let wire = try? sealOutboundOnQueue(ack415.payload) {
                        conn.send(content: wire, completion: .contentProcessed { _ in })
                    }
                    if invCallId != activeCallId {
                        // Already busy on another call (`activeCallId`): reject concurrent invite cleanly without clobbering active call.
                        seqCounter &+= 1
                        if seqCounter <= 0 { seqCounter = 2 }
                        let busyAns = ZolaCrypto.packVoipAnswerCallFrame(
                            srcId: srcId,
                            partnerId: Int32(truncatingIfNeeded: invPartnerUid),
                            callId: invCallId,
                            status: 1,
                            sessionId: invSess,
                            rtpAddress: invRtp,
                            rtpServer: "",
                            codec: "",
                            paramsJson: "",
                            seqId: seqCounter
                        )
                        if let wire = try? sealOutboundOnQueue(busyAns.payload) {
                            conn.send(content: wire, completion: .contentProcessed { _ in })
                        }
                    }
                }
                return
            }
            activeCallId = invCallId
            clientCallId = invCallId
            activePartnerUid = invPartnerUid
            activeIsVideo = invIsVideo
            activeCallIsIncoming = true
            activeCallReceived408 = false
            voipCallContextByCallId[invCallId] = VoipCallContext(
                sessionId: invSess,
                rtpAddress: invRtp,
                rtcpAddress: invRtcp,
                extendData: voipExtendDataByCallId[invCallId] ?? ""
            )
        }

        let explicitAnswerCallId: Int32 = {
            if let json = element.parseJSONDictionary() {
                let data = (json["data"] as? [String: Any]) ?? json
                return Int32(truncatingIfNeeded: ZolaJSON.int64(data["id"] ?? data["callId"]))
            }
            return (try? element.bodyData.readInt32LE(at: 4)) ?? 0
        }()
        if (element.cmd == 403 || element.cmd == 424),
           explicitAnswerCallId != 0,
           (explicitAnswerCallId == activeCallId || explicitAnswerCallId == clientCallId),
           case let .answered(answeredCallId, answeredPartnerUid) = event,
           !activeCallIsIncoming, activeCallId != 0,
           (answeredCallId == activeCallId || answeredCallId == clientCallId),
           answeredPartnerUid == activePartnerUid {
            outgoingAnswerAcknowledgement.accepted = true
        }

        // Native `didReceiveCallRequestAnswerACK:` sets callStatus=163. Only a
        // successful interpreted 408 for this bound callee call is proof of that state.
        if element.cmd == 408,
           case let .answered(answeredCallId, answeredPartnerUid) = event,
           activeCallIsIncoming, answeredCallId == activeCallId,
           answeredPartnerUid == activePartnerUid,
           let answerJSON = element.parseJSONDictionary() {
            let answerData = (answerJSON["data"] as? [String: Any]) ?? answerJSON
            let explicitCallId = ZolaJSON.int64(answerData["id"] ?? answerData["callId"])
            if explicitCallId == Int64(activeCallId) {
                activeCallReceived408 = true
            }
        }

        if case let .ended(endedCallId, endedPeer, _) = event {
            retainRemoteFinishOnQueue(callId: endedCallId, peer: endedPeer)
        }
        onEvent?(event)

        // `mac35` live capture: the instant a `cmd=402` invite lands, the callee fires
        // `cmd=415` (confirm ACK, 12B `[partnerId][callId][1]`) then `cmd=407 status=0` (callee
        // ringing JSON) so the caller's UI flips to "Đang đổ chuông...".
        if case let .incomingInvite(_, _, invIsVideo, _, _, inviteRtpAddr, _, _) = event, let conn = connection, !isClosed {
            seqCounter &+= 1
            if seqCounter <= 0 { seqCounter = 2 }
            let ack415 = ZolaCrypto.packVoipConfirmIncomingAckFrame(
                srcId: srcId,
                partnerId: Int32(truncatingIfNeeded: interpreted.resolvedPartnerUid),
                callId: interpreted.resolvedCallId,
                seqId: seqCounter
            )
            if let wire = try? sealOutboundOnQueue(ack415.payload) {
                conn.send(content: wire, completion: .contentProcessed { _ in })
            }
            seqCounter &+= 1
            if seqCounter <= 0 { seqCounter = 2 }
            let ring407 = ZolaCrypto.packVoipCalleeRingingFrame(
                srcId: srcId,
                partnerId: Int32(truncatingIfNeeded: interpreted.resolvedPartnerUid),
                callId: interpreted.resolvedCallId,
                status: 0,
                isVideo: invIsVideo,
                rtpServerAddr: inviteRtpAddr,
                seqId: seqCounter
            )
            if let wire = try? sealOutboundOnQueue(ring407.payload) {
                conn.send(content: wire, completion: .contentProcessed { _ in })
            }
        }

        switch event {
        case .busy, .rejected, .ended, .failed:
            if keepAliveAfterCallEnd {
                // Persistent listener: unbind the finished call, keep `0x7d0` + heartbeat alive.
                unbindCallOnQueue()
            } else {
                activeCallId = 0
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.closeOnQueue()
                }
            }
        default:
            break
        }
    }
}
#endif
