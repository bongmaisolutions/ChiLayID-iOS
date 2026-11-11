import CommonCrypto
import CryptoKit
import Foundation
import zlib

// ─────────────────────────────────────────────────────────────────────────────
// CALL MODULE (Sources/ZolaKit/Call) — native voice/video calling.
// Verified with two-way voice and video calls on real iPhones. Incoming calls share the
// UXChatSocket (0x7d0) with realtime chat, so change socket/keySet/session code with care.
// ─────────────────────────────────────────────────────────────────────────────

extension ZolaCrypto {
    // MARK: - `VoipRequestOperation` (`cmd=425`, `cmd=401/subCmd=4`, `cmd=416/subCmd=2|3`, `cmd=402/subCmd=3`, `cmd=405/subCmd=0`, `cmd=406/subCmd=1|3`, `cmd=407/subCmd=0`, `cmd=408/subCmd=0`, `cmd=409/subCmd=0`) & `ZRTCPacket` Codec

    /// Canonical Zalo iOS Native Opus 48 kHz mono/stereo codec descriptor (`mac35` & `ZrtpVoipService`).
    public static let defaultVoipCodecJson = #"[{"dynamicFptime":0,"frmPtime":20,"name":"opus/48000/2","payload":113}]"#

    /// Builds Zalo's `extendData` JSON (`_parseExtendData` in `libzrtc`) advertising `newZrtc = 1`,
    /// `packetMode = 2`, `srtpMode = 0` (plain RTP v2 inside ZRTC frames), optional `p2p` LAN + STUN-reflected
    /// public candidates (`type = 0|1`), and optional `serverAddr` relay descriptor.
    public static func makeVoipExtendDataJson(
        localEndpoint: String = "",
        reflectedPublicEndpoint: String = "",
        rtpServerAddr: String = "",
        rtcpServerAddr: String = "",
        isVideo: Bool = false
    ) -> String {
        var dict: [String: Any] = [
            "callType": isVideo ? 1 : 0,
            "fromNoti": 0,
            "gccAudio": 1,
            "gccMode": 1,
            "gccSVLR": 1,
            "maxFT": 60,
            "negoVidQual": 1,
            "newZrtc": 1,
            "packetMode": 2,
            "platform": 1,
            "rtcpMux": 1,
            "sP2P": 0,
            "select2side": 1,
            "spTcp": 1,
            "srtcp": 0,
            "srtpMode": 0,
            "supportCallBusy": 1,
            "tpType": 0,
            "useRelay": 1,
            "ver": 1,
        ]
        if isVideo {
            dict["supportHevcDecode"] = 0
            dict["video"] = [
                "codec": [[
                    "name": "h264",
                    "payload": 97,
                ]],
            ]
        }
        var p2pCandidates: [[String: Any]] = []
        var localIpVal = ""
        var localPortVal = 0
        let trimmedLocal = localEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocal.isEmpty {
            let parts = trimmedLocal.split(separator: ":")
            if parts.count == 2, let port = Int(parts[1]), port > 0, port <= Int(UInt16.max) {
                let ip = String(parts[0])
                if !ip.isEmpty {
                    localIpVal = ip
                    localPortVal = port
                    dict["localP2PIp"] = ip
                    dict["localP2PPort"] = port
                    p2pCandidates.append(["ip": ip, "port": port, "type": 0])
                }
            }
        }
        let trimmedPublic = reflectedPublicEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPublic.isEmpty {
            let parts = trimmedPublic.split(separator: ":")
            if parts.count == 2, let port = Int(parts[1]), port > 0, port <= Int(UInt16.max) {
                let ip = String(parts[0])
                if !ip.isEmpty, (ip != localIpVal || port != localPortVal) {
                    p2pCandidates.append(["ip": ip, "port": port, "type": 1])
                }
            }
        }
        if !p2pCandidates.isEmpty {
            dict["p2p"] = p2pCandidates
        }
        let trimmedRelay = rtpServerAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRelay.isEmpty {
            let trimmedRtcp = rtcpServerAddr.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedRtcp = trimmedRtcp.isEmpty ? trimmedRelay : trimmedRtcp
            dict["rtpServerAddr"] = trimmedRelay
            dict["serverAddr"] = [[
                "bonus": 0,
                "rtcp": resolvedRtcp,
                "rtp": trimmedRelay,
                "tpType": 0,
            ]]
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: bytes, encoding: .utf8),
              !str.isEmpty
        else {
            return #"{"callType":0,"fromNoti":0,"newZrtc":1,"packetMode":2,"platform":1,"rtcpMux":1,"sP2P":0,"select2side":1,"spTcp":1,"srtcp":0,"srtpMode":0,"supportCallBusy":1,"tpType":0,"useRelay":1,"ver":1}"#
        }
        return str
    }

    /// Extracts the negotiated H.264 dynamic RTP payload type (`96...127`, defaulting to `97` per `CallController.cpp` `0x1005237e8`)
    /// from Zalo `extendData` JSON (`{"video":{"codec":[{"name":"h264","payload":97}]}}`).
    public static func extractNegotiatedH264PayloadType(fromExtendData extendDataJson: String?) -> UInt8 {
        guard let raw = extendDataJson?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return 97
        }
        let codecEntries: [[String: Any]]
        if let videoDict = dict["video"] as? [String: Any],
           let list = videoDict["codec"] as? [[String: Any]] {
            codecEntries = list
        } else if let list = dict["video"] as? [[String: Any]] {
            codecEntries = list
        } else if let list = dict["videoCodec"] as? [[String: Any]] {
            codecEntries = list
        } else {
            return 97
        }
        for entry in codecEntries {
            let name = ((entry["name"] as? String) ?? "").lowercased()
            guard name.contains("h264") || name.contains("avc") else { continue }
            let pt = (entry["payload"] as? Int) ?? (entry["payload"] as? NSNumber)?.intValue ?? 0
            if (96...127).contains(pt) {
                return UInt8(pt)
            }
        }
        return 97
    }

    /// Builds `VoipRequestOperation` `createPacketRequestDataForPreSelectServerWithPartnerId:requestId:` (`cmd = 425, subCmd = 0|3`).
    public static func packVoipPreselectFrame(
        srcId: Int32,
        partnerId: Int32,
        requestId: Int32,
        subCmd: Int8 = 0,
        seqId: Int32 = 1
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 8)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(requestId)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 425,
            subCmd: subCmd,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `createPacketRequestData` (`cmd = 401, subCmd = 4`).
    public static func packVoipCallRequestFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        isVideo: Bool = false,
        codec: String = "opus",
        source: Int32 = 1,
        paramsJson: String = #"{"ver":4,"net":1,"rel":1}"#,
        cachingInfo: String = "",
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        // `VoipRequestOperation` `0x102f92d04`: `CallEntity.callType` for ZRTP video is `3` (`mov w8, #3`).
        // Sending `4` does not exist on Zalo's server and immediately fails with `error_code = 11100 ("Invalid Data")`;
        // `3` is accepted by Zalo's server for both ZRTP voice (`cmd = 416/2`) and ZRTP video (`cmd = 416/3`).
        let callType: Int8 = 3
        let version: Int8 = 4
        let codecBytes = Data(codec.utf8)
        let paramsBytes = Data(paramsJson.utf8)
        let cachingBytes = Data(cachingInfo.utf8)

        var body = Data(capacity: 20 + codecBytes.count + paramsBytes.count + cachingBytes.count)
        body.appendInt8(callType)
        body.appendInt8(version)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: codecBytes.count))
        body.append(codecBytes)
        body.appendInt32LE(source)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: paramsBytes.count))
        body.append(paramsBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: cachingBytes.count))
        if !cachingBytes.isEmpty {
            body.append(cachingBytes)
        }

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 401,
            subCmd: 4,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `requestVoiceCallRequestZRTP:withCallId:withCodec:withRTP:withRTCP:withSessionId:withExternData:withSource:` (`cmd = 416, subCmd = 2|3` at `0x102f94b38`).
    /// This is Step 2 of Zalo's 2-step P2P/ZRTP call initiation (`ZrtpVoipService::requestVoiceToZrtpByClientCallId:` at `0x102fa92a0`),
    /// which transmits the caller's RTP/RTCP endpoints and triggers `cmd = 415` (`recv415`) on the partner.
    public static func packVoipRequestZRTPFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        isVideo: Bool = false,
        codec: String = "opus",
        rtpAddress: String = "49.213.95.89:10000",
        rtcpAddress: String = "49.213.95.89:10001",
        sessionId: String = "",
        externData: String = #"{"ver":4,"net":1,"rel":1}"#,
        source: Int32 = 1,
        seqId: Int32 = 3
    ) -> ZolaChatElementFrame {
        let resolvedSessionId = sessionId.isEmpty ? String(callId) : sessionId
        let codecBytes = Data(codec.utf8)
        let rtpBytes = Data(rtpAddress.utf8)
        let rtcpBytes = Data(rtcpAddress.utf8)
        let sessionBytes = Data(resolvedSessionId.utf8)
        let externBytes = Data(externData.utf8)

        var body = Data(
            capacity: 26 + codecBytes.count + rtpBytes.count + rtcpBytes.count + sessionBytes.count + externBytes.count
        )
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: codecBytes.count))
        body.append(codecBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: rtpBytes.count))
        body.append(rtpBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: rtcpBytes.count))
        body.append(rtcpBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: sessionBytes.count))
        body.append(sessionBytes)
        body.appendUInt16LE(0) // extraShort1 (`0x102f94c60`)
        body.appendUInt16LE(0) // extraShort2 (`0x102f94c68`)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: externBytes.count))
        body.append(externBytes)
        body.appendInt32LE(source)

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 416,
            subCmd: isVideo ? 3 : 2,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `createPacketReceiveAnswerData` (`cmd = 402, subCmd = 3`, `0x102f93234`).
    ///
    /// Exact 8-field binary body verified from `VoipRequestOperation` (`0x102f93234`) & `ZrtpVoipService` (`0x102f9fad8` / `0x102f9f11c`):
    /// 1. `partnerId` (`Int32 LE`)
    /// 2. `status` / `voiceCallState` (`Int8`: `0` = accept, `1` = busy, `3` = reject, `6` = timeout)
    /// 3. `callId` (`Int32 LE`)
    /// 4. `u16LE + sessionId` (`sessId` from `cmd = 402` invite)
    /// 5. `u16LE + rtpAddress` (`rtpIP` from `cmd = 402` invite)
    /// 6. `u16LE + rtpServer` (`""` across all call sites)
    /// 7. `u16LE + codec` (`defaultVoipCodecJson` when `status == 0`, `""` when rejecting/busy)
    /// 8. `u16LE + paramsJson` (`extendData` JSON when `status == 0`, `""` when rejecting/busy)
    public static func packVoipAnswerCallFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int8 = 0,
        sessionId: String = "",
        rtpAddress: String = "",
        rtpServer: String = "",
        codec: String = defaultVoipCodecJson,
        paramsJson: String = #"{"callType":0,"fromNoti":0,"newZrtc":1,"packetMode":2,"platform":1,"rtcpMux":1,"sP2P":0,"srtcp":0,"srtpMode":0,"supportCallBusy":1,"tpType":0,"ver":1}"#,
        cachingInfo: String = "",
        seqId: Int32 = 3
    ) -> ZolaChatElementFrame {
        let effectiveCodec = status == 0 ? codec : ""
        let effectiveExtend = status == 0 ? paramsJson : ""
        let sessionBytes = Data(sessionId.utf8)
        let rtpBytes = Data(rtpAddress.utf8)
        let rtpServerBytes = Data((rtpServer.isEmpty ? cachingInfo : rtpServer).utf8)
        let codecBytes = Data(effectiveCodec.utf8)
        let extendBytes = Data(effectiveExtend.utf8)

        var body = Data(
            capacity: 20 + sessionBytes.count + rtpBytes.count + rtpServerBytes.count + codecBytes.count + extendBytes.count
        )
        body.appendInt32LE(partnerId)
        body.appendInt8(status)
        body.appendInt32LE(callId)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: sessionBytes.count))
        if !sessionBytes.isEmpty { body.append(sessionBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: rtpBytes.count))
        if !rtpBytes.isEmpty { body.append(rtpBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: rtpServerBytes.count))
        if !rtpServerBytes.isEmpty { body.append(rtpServerBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: codecBytes.count))
        if !codecBytes.isEmpty { body.append(codecBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: extendBytes.count))
        if !extendBytes.isEmpty { body.append(extendBytes) }

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 402,
            subCmd: 3,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `createPacketEndCallData` (`cmd = 409, subCmd = 0`, `0x102f94264` / `Zalo2` `0x102fc7fb8`).
    /// Sent to tear down an already-connected call (`sendEndcallWithReason:`), whereas `cmd = 405` cancels a still-ringing call.
    public static func packVoipEndCallFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        reasonByte: Int8? = nil,
        sessionId: String = "",
        rtpAddress: String = "",
        extendData: String = "",
        reasonCode: Int32 = 1,
        seqId: Int32 = 4
    ) -> ZolaChatElementFrame {
        let sessionBytes = Data(sessionId.utf8)
        let rtpBytes = Data(rtpAddress.utf8)
        let extendBytes = Data(extendData.utf8)

        var body = Data(capacity: 20 + sessionBytes.count + rtpBytes.count + extendBytes.count)
        body.appendInt32LE(partnerId)
        // Native sendEndcallWithReason: (IPA261002 0x102fc7fe4..8010):
        // reason2 => status2, reason12 => status3, ordinary local end1 => status0.
        // Keep an explicit override for callers constructing other proven variants.
        let statusByte: Int8 = reasonByte ?? (reasonCode == 2 ? 2 : (reasonCode == 12 ? 3 : 0))
        body.appendInt8(statusByte)
        body.appendInt32LE(callId)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: sessionBytes.count))
        if !sessionBytes.isEmpty { body.append(sessionBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: rtpBytes.count))
        if !rtpBytes.isEmpty { body.append(rtpBytes) }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: extendBytes.count))
        if !extendBytes.isEmpty { body.append(extendBytes) }
        body.appendInt32LE(reasonCode)

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 409,
            subCmd: 0,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation.requestVoiceCallAnswerWithACK:withCallId:withStatus:`
    /// (`0x102f9415c`, cmd 408/sub0). Historical API name retained for compatibility.
    public static func packVoipRingingAckFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int32 = 0,
        seqId: Int32 = 4
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 12)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(status)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 408,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `requestSendACKCommand:withPartnerID:withCallID:` (`cmd = 423, subCmd = 0` at `0x102f95acc`).
    /// Sent automatically when server push frames (such as `cmd = 407` ringing) contain `"neekACK": 1` or `"needACK": 1`.
    public static func packVoipCommandAckFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        ackedCommand: Int32,
        seqId: Int32 = 5
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 12)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(ackedCommand)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 423,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `createPacketCancelCallData` (`cmd = 405, subCmd = 0`).
    public static func packVoipCancelCallFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int32 = 1,
        isVideo: Bool = false,
        seqId: Int32 = 3
    ) -> ZolaChatElementFrame {
        // `CallEntity.callType` (`0x102e9752c` / `0x102f9d3ec`): `2` = ZRTP Voice, `3` = ZRTP Video.
        let callType: Int32 = isVideo ? 3 : 2
        var body = Data(capacity: 16)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(status)
        body.appendInt32LE(callType)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 405,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `createPacketRejectCallData` (`cmd = 407, subCmd = 0`).
    public static func packVoipRejectCallFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int32 = 1,
        isVideo: Bool = false,
        reason: String = "",
        seqId: Int32 = 5
    ) -> ZolaChatElementFrame {
        let callType: Int32 = isVideo ? 3 : 2
        let reasonBytes = Data(reason.utf8)
        var body = Data(capacity: 18 + reasonBytes.count)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(status)
        body.appendInt32LE(callType)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: reasonBytes.count))
        if !reasonBytes.isEmpty {
            body.append(reasonBytes)
        }
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 407,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `requestVideoCallCameraStateWithPartnerID:withCallId:status:reason:` (`cmd = 421, subCmd = 0` at `0x102f94f0c`).
    /// 18-byte LE body: `[partnerId:i32LE][callId:i32LE][status:i32LE (1=on, 0=off)][u16LE(0)][reason:i32LE (0=user)]`.
    public static func packVoipVideoCameraStateFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        isCameraOn: Bool,
        reason: Int32 = 0,
        seqId: Int32 = 6
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 18)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(isCameraOn ? 1 : 0)
        body.appendUInt16LE(0)
        body.appendInt32LE(reason)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 421,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipChatModule confirmVoiceCallACKWithRequest:` (`cmd = 415, subCmd = 0`) — the 12-byte
    /// binary receipt the callee fires the instant a `cmd = 402` invite arrives, so the server marks
    /// the invite delivered on this device (`mac35` live capture `idx=1071..1354`).
    public static func packVoipConfirmIncomingAckFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        seqId: Int32 = 4
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 12)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(1)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 415,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds the callee `cmd = 407, subCmd = 0` ringing-status frame with `status = 0`
    /// (`mac35` `idx=1241`): `[partnerId:i32LE][callId:i32LE][status:i32LE][extra:i32LE][u16LE jsonLen][jsonBytes]`.
    /// Sending it right after the invite is what flips the caller's UI to "Đang đổ chuông...".
    /// `localP2PIp`/`localP2PPort`/`rtpServerAddr` are folded into `extendData` when provided.
    public static func packVoipCalleeRingingFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int32 = 0,
        isVideo: Bool = false,
        localP2PIp: String = "",
        localP2PPort: UInt16 = 0,
        rtpServerAddr: String = "",
        seqId: Int32 = 5
    ) -> ZolaChatElementFrame {
        var extendData: [String: Any] = [
            "callType": isVideo ? 1 : 0,
            "fromNoti": 0,
            "newZrtc": 1,
            "packetMode": 2,
            "platform": 1,
            "rtcpMux": 1,
            "sP2P": 0,
            "srtcp": 0,
            "srtpMode": 0,
            "supportCallBusy": 1,
            "tpType": 0,
            "ver": 1,
        ]
        if isVideo {
            extendData["supportHevcDecode"] = 0
            extendData["video"] = [
                "codec": [[
                    "name": "h264",
                    "payload": 97,
                ]],
            ]
        }
        if !localP2PIp.isEmpty { extendData["localP2PIp"] = localP2PIp }
        if localP2PPort > 0 {
            extendData["localP2PPort"] = Int(localP2PPort)
            if !localP2PIp.isEmpty {
                extendData["p2p"] = [["ip": localP2PIp, "port": Int(localP2PPort), "type": 0]]
            }
        }
        if !rtpServerAddr.isEmpty {
            extendData["rtpServerAddr"] = rtpServerAddr
            extendData["serverAddr"] = [["rtcp": rtpServerAddr, "rtp": rtpServerAddr]]
        }
        let jsonObj: [String: Any] = [
            "audioCodec": [[
                "dynamicFptime": 0,
                "frmPtime": 20,
                "name": "opus/48000/2",
                "payload": 113,
            ]],
            "extendData": extendData,
        ]
        let jsonBytes = (try? JSONSerialization.data(withJSONObject: jsonObj, options: [.sortedKeys])) ?? Data()

        var body = Data(capacity: 18 + jsonBytes.count)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(callId)
        body.appendInt32LE(status)
        body.appendInt32LE(0) // extra
        body.appendUInt16LE(UInt16(truncatingIfNeeded: jsonBytes.count))
        body.append(jsonBytes)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 407,
            subCmd: 0,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `VoipRequestOperation` `_requestSendLogFinishCallWithPartnerID:withCallId:withStatus:withDuration:withProtocol:withSendType:withParams:atTime:` (`cmd = 406, subCmd = 1|2|3`).
    public static func packVoipFinishCallLogFrame(
        srcId: Int32,
        partnerId: Int32,
        callId: Int32,
        status: Int32 = 162,
        durationSeconds: Int32 = 0,
        protocolVersion: Int32 = 3,
        sendType: Int32 = 1,
        paramsJson: String? = #"{"ver":4,"net":1,"rel":1}"#,
        timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        seqId: Int32 = 6
    ) -> ZolaChatElementFrame {
        let resolvedSubCmd: Int8
        switch protocolVersion {
        case 3: resolvedSubCmd = 3
        case 2: resolvedSubCmd = 2
        default: resolvedSubCmd = 1
        }
        var body = Data(capacity: 64)
        body.appendInt32LE(partnerId)
        body.appendInt32LE(status)
        body.appendInt32LE(durationSeconds)
        body.appendInt32LE(callId)
        body.appendInt32LE(protocolVersion)
        if protocolVersion == 3 {
            body.appendInt32LE(sendType)
            if let paramsJson, !paramsJson.isEmpty {
                let pBytes = Data(paramsJson.utf8)
                body.appendInt32LE(Int32(pBytes.count))
                body.append(pBytes)
            }
        }
        body.appendInt64LE(timestampMs)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 406,
            subCmd: resolvedSubCmd,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    // MARK: - `libzrtc` UDP `ZRTCPacket` Wire Framing (`0x100530854`, `0x100613774..0x100614c34`)

    /// Builds `zrtc::initZRTPToServer` (`pktCmd = 11` for caller, `pktCmd = 12` for callee; `0x100613774` & `0x100614150..0x100614490`)
    /// sent over UDP to the Zalo media relay (`rtpIP`, e.g. `42.1.81.69:4200`) to register the call's UDP socket and `sessId`.
    /// Server responds with `[0x02, 0x00, u32(0), seq:u32LE @ 6, selfUid:u32LE @ 10, u32(0), pktCmd:u16LE @ 18, 0x02, retCode:u32LE @ 21, callId:u32LE @ 25, token:u32LE @ 29, addrLen:u16LE @ 33, asciiIpPort @ 35..]`.
    public static func packZrtcInitServerPacket(
        isCaller: Bool,
        selfUid: Int64,
        partnerUid: Int64,
        callId: Int32,
        sessionId: String,
        seq: UInt32 = 1
    ) -> Data {
        let sessionBytes = Data(sessionId.utf8)
        let resolvedSeq: UInt32 = seq == 0 ? 1 : seq
        var pkt = Data(capacity: 31 + sessionBytes.count)
        pkt.append(0x01) // request packet type (`x19[0x08] = 1`)
        pkt.append(0x00) // flags (`x19[0x09] = 0`)
        pkt.appendUInt32LE(0) // reserved (`x19[0x0c] = 0`)
        pkt.appendUInt32LE(resolvedSeq) // `seq` (`x19[0x10]` -> wire 6..9)
        pkt.appendUInt32LE(UInt32(truncatingIfNeeded: selfUid)) // `x19[0x14]` -> wire 10..13
        pkt.appendUInt32LE(0) // `x19[0x18] = 0` -> wire 14..17
        pkt.appendUInt16LE(isCaller ? 11 : 12) // `pktCmd` (`x19[0x1c]` -> wire 18..19)
        pkt.append(0x02) // `subType = 2` (`x19[0x1e]` -> wire 20, both caller & callee for protocol 3)
        pkt.appendUInt32LE(UInt32(bitPattern: callId)) // `x19[0x38]` -> wire 21..24
        pkt.appendUInt32LE(UInt32(truncatingIfNeeded: partnerUid)) // `x19[0x3c]` -> wire 25..28
        pkt.appendUInt16LE(UInt16(truncatingIfNeeded: sessionBytes.count)) // wire 29..30
        if !sessionBytes.isEmpty {
            pkt.append(sessionBytes)
        }
        return pkt
    }

    /// Builds `ZRTCPacket` relay/P2P keepalive ping (`pktCmd = 3`, 25 bytes, `0x100613934` & `0x1006144f4`).
    public static func packZrtcPingPacket(
        selfUid: Int64,
        partnerUid: Int64 = 0,
        callId: Int32,
        seq: UInt32,
        pktCmd: UInt16 = 3
    ) -> Data {
        let resolvedSeq: UInt32 = seq == 0 ? 1 : seq
        var pkt = Data(capacity: 25)
        pkt.append(0x01) // request (`x19[0x08] = 1`)
        pkt.append(0x00) // flags (`x19[0x09] = 0`)
        pkt.appendUInt32LE(0) // `x19[0x0c] = 0` -> wire 2..5
        pkt.appendUInt32LE(resolvedSeq) // `x19[0x10] = seq` -> wire 6..9
        pkt.appendUInt32LE(UInt32(truncatingIfNeeded: selfUid)) // `x19[0x14]` -> wire 10..13
        pkt.appendUInt32LE(UInt32(truncatingIfNeeded: partnerUid)) // `x19[0x18]` -> wire 14..17
        pkt.appendUInt16LE(pktCmd) // `x19[0x1c]` -> wire 18..19
        pkt.append(0x03) // `subType = 3` (`x19[0x1e]` -> wire 20, carries `callId` at 21..24)
        pkt.appendUInt32LE(UInt32(bitPattern: callId)) // `x19[0x38]` -> wire 21..24
        return pkt
    }

    /// Parsed `0x02` `InitZRTP` response (`pktCmd == 11` caller / `12` callee) from `:4200` media relay (`0x1006147e8..0x100614860`).
    public struct ZrtcInitServerAck: Sendable, Equatable {
        public let seq: UInt32
        public let pktCmd: UInt16
        public let retCode: UInt32
        public let callId: UInt32
        /// 4-byte `CallToken` (`u32LE` at wire offset `29..32`) required in outbound `0x03`/`0x05` 1-1 RTP headers (`0x100613b84`).
        public let token: UInt32
        /// Optional STUN-reflected `<ip>:<port>` (`u16LE @ 33`, ASCII `@ 35..`).
        public let reflectedAddress: String

        public init(
            seq: UInt32,
            pktCmd: UInt16,
            retCode: UInt32,
            callId: UInt32,
            token: UInt32,
            reflectedAddress: String
        ) {
            self.seq = seq
            self.pktCmd = pktCmd
            self.retCode = retCode
            self.callId = callId
            self.token = token
            self.reflectedAddress = reflectedAddress
        }
    }

    /// Parses a `0x02` `InitZRTP` server ACK (`pktCmd == 11|12`), extracting `retCode` (`21..24`), `callId` (`25..28`),
    /// `token` (`29..32`, mandatory when `retCode == 0`), and optional `reflectedAddress` (`u16LE @ 33`, ASCII `@ 35..`).
    public static func parseZrtcInitServerAck(_ data: Data) -> ZrtcInitServerAck? {
        guard data.count >= 29, data[data.startIndex] == 0x02 else { return nil }
        guard let pktCmd = try? data.readUInt16LE(at: 18), (pktCmd == 11 || pktCmd == 12),
              let seq = try? data.readUInt32LE(at: 6),
              let retCode = try? data.readUInt32LE(at: 21),
              let callId = try? data.readUInt32LE(at: 25)
        else { return nil }
        if retCode == 0 {
            guard data.count >= 33 else { return nil }
        }
        let token: UInt32 = data.count >= 33 ? ((try? data.readUInt32LE(at: 29)) ?? 0) : 0
        var reflected = ""
        if data.count >= 35,
           let addrLen = try? data.readUInt16LE(at: 33),
           addrLen > 0,
           data.count >= 35 + Int(addrLen)
        {
            let slice = data.subdata(in: (data.startIndex + 35)..<(data.startIndex + 35 + Int(addrLen)))
            reflected = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ZrtcInitServerAck(
            seq: seq,
            pktCmd: pktCmd,
            retCode: retCode,
            callId: callId,
            token: token,
            reflectedAddress: reflected
        )
    }

    /// Builds a `0x02` ZRTC pong/ACK in response to an inbound `0x01` ping (`pktCmd == 3|5`, 25 bytes).
    /// When `relayToken` is explicitly supplied (mock `:4200` relay servers in loopback tests), also builds
    /// a 35-byte `InitZRTP` server ACK (`pktCmd == 11|12`). Production client callers omit `relayToken` (`nil`)
    /// so a client never fabricates server `InitZRTP` ACKs.
    public static func packZrtcPongPacket(
        fromPing data: Data,
        selfUid: Int64,
        relayToken: UInt32? = nil
    ) -> Data? {
        guard data.count >= 25, data[data.startIndex] == 0x01 else { return nil }
        guard let pktCmd = try? data.readUInt16LE(at: 18),
              (pktCmd == 3 || pktCmd == 5 || pktCmd == 11 || pktCmd == 12)
        else { return nil }
        let seq = (try? data.readUInt32LE(at: 6)) ?? 0
        let senderUid = (try? data.readUInt32LE(at: 10)) ?? 0
        let callIdWord = (try? data.readUInt32LE(at: 21)) ?? 0
        if pktCmd == 11 || pktCmd == 12 {
            guard let relayToken else { return nil }
            var ack = Data(capacity: 35)
            ack.append(0x02)
            ack.append(0x00)
            ack.appendUInt32LE(0)
            ack.appendUInt32LE(seq)
            ack.appendUInt32LE(selfUid != 0 ? UInt32(truncatingIfNeeded: selfUid) : senderUid)
            ack.appendUInt32LE(0)
            ack.appendUInt16LE(pktCmd)
            ack.append(0x02)
            ack.appendUInt32LE(0) // `retCode = 0` (`OK`)
            ack.appendUInt32LE(callIdWord)
            ack.appendUInt32LE(relayToken) // `CallToken` @ 29..32
            ack.appendUInt16LE(0) // `addrLen = 0` @ 33..34
            return ack
        }
        var pong = Data(capacity: 25)
        pong.append(0x02)
        pong.append(data[data.startIndex + 1])
        pong.appendUInt32LE(0)
        pong.appendUInt32LE(seq)
        pong.appendUInt32LE(UInt32(truncatingIfNeeded: selfUid))
        pong.appendUInt32LE(senderUid)
        pong.appendUInt16LE(pktCmd)
        pong.append(data[data.startIndex + 20])
        pong.appendUInt32LE(callIdWord)
        return pong
    }

    /// Wraps an RTP v2 audio packet in the 5-byte 1-1 `ZRTCPacket` header (`0x100613b84`, `isGroup == 0`):
    /// - Relay (`isP2P == false`): `[0x03][token: u32LE][rtpPayload]`
    /// - P2P (`isP2P == true`): `[0x05][token: u32LE][rtpPayload]`
    public static func packZrtcOneToOneRtpPacket(
        isP2P: Bool = false,
        token: UInt32,
        rtpPayload: Data
    ) -> Data {
        var pkt = Data(capacity: 5 + rtpPayload.count)
        pkt.append(isP2P ? 0x05 : 0x03)
        pkt.appendUInt32LE(token)
        pkt.append(rtpPayload)
        return pkt
    }

    /// Wraps an RTP v2 audio packet in the 1-byte `:4200` 1-1 relay->client inbound header (`0x04`, `0x100614718`):
    /// `[0x04][rtpPayload]`.
    public static func packZrtcOneToOneRelayInboundPacket(rtpPayload: Data) -> Data {
        var pkt = Data(capacity: 1 + rtpPayload.count)
        pkt.append(0x04)
        pkt.append(rtpPayload)
        return pkt
    }

    /// Wraps an RTP/audio frame in the 9-byte Group Call `ZRTCPacket` `0x7f` relay media header (`0x100614274..0x1006142f4`):
    /// `[0x7f, 0x00, isCaller ? 0x00 : 0x01, callId:u32LE, pktCmd(6):u16LE] + payload`.
    public static func packZrtcRelayAudioPacket(
        isCaller: Bool,
        callId: Int32,
        payload: Data,
        pktCmd: UInt16 = 6
    ) -> Data {
        var pkt = Data(capacity: 9 + payload.count)
        pkt.append(0x7f)
        pkt.append(0x00)
        pkt.append(isCaller ? 0x00 : 0x01)
        pkt.appendUInt32LE(UInt32(bitPattern: callId))
        pkt.appendUInt16LE(pktCmd)
        pkt.append(payload)
        return pkt
    }

    /// Wraps an RTCP v2 audio packet in the 5-byte 1-1 `ZRTCPacket` outbound header (`0x100613b84` & `0x1005a3fac`, `type = 0x05`):
    /// `[0x05][token: u32LE][rtcpPayload]`.
    public static func packZrtcOneToOneAudioRtcpPacket(
        token: UInt32,
        rtcpPayload: Data
    ) -> Data {
        var pkt = Data(capacity: 5 + rtcpPayload.count)
        pkt.append(0x05)
        pkt.appendUInt32LE(token)
        pkt.append(rtcpPayload)
        return pkt
    }

    /// Wraps an RTCP v2 audio packet in the 1-byte `:4200` 1-1 relay->client inbound header (`0x07`, `0x1006146c8`):
    /// `[0x07][rtcpPayload]`.
    public static func packZrtcOneToOneAudioRtcpRelayInboundPacket(rtcpPayload: Data) -> Data {
        var pkt = Data(capacity: 1 + rtcpPayload.count)
        pkt.append(0x07)
        pkt.append(rtcpPayload)
        return pkt
    }

    /// Unwraps an inbound `ZRTCPacket` audio RTCP datagram (`0x07` 1B relay inbound, `0x05` 5B loopback/P2P audio RTCP,
    /// or `0x7f` `pktCmd == 7` Group Call audio RTCP).
    public static func unpackZrtcAudioRtcpPayload(_ data: Data) -> Data? {
        guard let b0 = data.first else { return nil }
        switch b0 {
        case 0x07:
            guard data.count >= 5 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            guard (inner[inner.startIndex] >> 6) == 2, (192...223).contains(inner[inner.startIndex + 1]) else {
                return nil
            }
            return inner
        case 0x05:
            guard data.count >= 9 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            guard (inner[inner.startIndex] >> 6) == 2, (192...223).contains(inner[inner.startIndex + 1]) else {
                return nil
            }
            return inner
        case 0x7F:
            guard data.count > 9, let pktCmd = try? data.readUInt16LE(at: 7), pktCmd == 7 else {
                return nil
            }
            return data.subdata(in: (data.startIndex + 9)..<data.endIndex)
        default:
            return nil
        }
    }

    /// Unwraps an inbound `ZRTCPacket` audio datagram (`0x1006146c8..0x10061472c`), returning the inner RTP payload:
    /// - `0x04`: 1-1 inbound relay audio RTP (1-byte header; `:4200` strips sender's `CallToken` and rewrites `0x03 -> 0x04`)
    /// - `0x03`: 1-1 outbound/P2P audio RTP (5-byte header `[0x03][token:u32LE]`)
    /// - `0x05`: accepted only for non-RTCP RTP payloads (backward-compatible with legacy P2P RTP tests; `0x05` RTCP `192...223` routes to `unpackZrtcAudioRtcpPayload`)
    /// - `0x7f`: Group Call 9-byte relay media header (`pktCmd == 6` audio; rejects `pktCmd == 7` RTCP)
    /// Rejects RTCP/video wrappers (`0x07` relay audio RTCP, `0x0e` 1-1 relay inbound video RTP, `0x0d`/`0x0f`/`0x11` video).
    public static func unpackZrtcAudioPayload(_ data: Data) -> Data? {
        guard let b0 = data.first else { return nil }
        switch b0 {
        case 0x04:
            guard data.count > 1 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            if inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1]) {
                return nil
            }
            return inner
        case 0x03:
            guard data.count > 5 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            if inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1]) {
                return nil
            }
            return inner
        case 0x05:
            guard data.count > 5 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            if inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1]) {
                return nil
            }
            return inner
        case 0x7f:
            guard data.count > 9, let pktCmd = try? data.readUInt16LE(at: 7), pktCmd == 6 else { return nil }
            return data.subdata(in: (data.startIndex + 9)..<data.endIndex)
        default:
            return nil
        }
    }

    /// Wraps an RTP v2 or RTCP video packet in the 5-byte 1-1 `ZRTCPacket` header (`0x100613bd8` & `Transport::SendRtp`/`SendRtcp` `0x10058585c..0x100586014`, `w4 == 0`):
    /// - Video RTP (`isRtcp == false`): `[0x0d][token: u32LE][payload]`
    /// - Video RTCP (`isRtcp == true`): `[0x0f][token: u32LE][payload]`
    public static func packZrtcOneToOneVideoPacket(
        isRtcp: Bool = false,
        token: UInt32,
        payload: Data
    ) -> Data {
        var pkt = Data(capacity: 5 + payload.count)
        pkt.append(isRtcp ? 0x0F : 0x0D)
        pkt.appendUInt32LE(token)
        pkt.append(payload)
        return pkt
    }

    /// Wraps an RTP v2 or RTCP video packet in the 1-byte `:4200` 1-1 relay->client inbound header (`0x1006146c8` masks `0x4090` / `0x30000`):
    /// - Video RTP (`isRtcp == false`): `[0x0e][payload]`
    /// - Video RTCP (`isRtcp == true`): `[0x11][payload]`
    public static func packZrtcOneToOneVideoRelayInboundPacket(
        isRtcp: Bool = false,
        payload: Data
    ) -> Data {
        var pkt = Data(capacity: 1 + payload.count)
        pkt.append(isRtcp ? 0x11 : 0x0E)
        pkt.append(payload)
        return pkt
    }

    /// Wraps an RTP/RTCP video packet in the 9-byte Group Call `ZRTCPacket` `0x7f` relay media header (`0x100613bd8`, `w4 != 0`):
    /// `[0x7f, 0x00, isCaller ? 0x00 : 0x01, callId:u32LE, pktCmd(8=RTP | 9=RTCP):u16LE] + payload`.
    public static func packZrtcRelayVideoPacket(
        isCaller: Bool,
        callId: Int32,
        payload: Data,
        isRtcp: Bool = false
    ) -> Data {
        var pkt = Data(capacity: 9 + payload.count)
        pkt.append(0x7F)
        pkt.append(0x00)
        pkt.append(isCaller ? 0x00 : 0x01)
        pkt.appendUInt32LE(UInt32(bitPattern: callId))
        pkt.appendUInt16LE(isRtcp ? 9 : 8)
        pkt.append(payload)
        return pkt
    }

    /// Unwraps an inbound `ZRTCPacket` video RTP or RTCP datagram (`0x1006146c8`), returning `(payload, isRtcp)`:
    /// - `0x0e`: 1-1 inbound relay video RTP (1-byte header; `:4200` strips sender's `CallToken` and rewrites `0x0d -> 0x0e`)
    /// - `0x0d`: 1-1 P2P / direct loopback video RTP (5-byte header `[0x0d][token:u32LE]`)
    /// - `0x11`: 1-1 inbound relay video RTCP (1-byte header; `:4200` rewrites `0x0f -> 0x11`)
    /// - `0x0f`: 1-1 P2P / direct loopback video RTCP (5-byte header `[0x0f][token:u32LE]`)
    /// - `0x10`: 1-byte inbound RTCP/FEC wrapper (accepted as RTCP only if RFC 5761 PT byte is in `192...223`)
    /// - `0x7f`: Group Call 9-byte relay media header (`pktCmd == 8` video RTP, `pktCmd == 9` video RTCP)
    public static func unpackZrtcVideoPayload(_ data: Data) -> (payload: Data, isRtcp: Bool)? {
        guard let b0 = data.first else { return nil }
        switch b0 {
        case 0x0E:
            guard data.count > 1 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            let isMuxedRtcp = inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1])
            return (inner, isMuxedRtcp)
        case 0x0D:
            guard data.count > 5 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            let isMuxedRtcp = inner.count >= 2 && (inner[inner.startIndex] >> 6) == 2 && (192...223).contains(inner[inner.startIndex + 1])
            return (inner, isMuxedRtcp)
        case 0x11:
            guard data.count >= 5 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            guard (inner[inner.startIndex] >> 6) == 2, (192...223).contains(inner[inner.startIndex + 1]) else {
                return nil
            }
            return (inner, true)
        case 0x0F:
            guard data.count >= 9 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 5)..<data.endIndex)
            guard (inner[inner.startIndex] >> 6) == 2, (192...223).contains(inner[inner.startIndex + 1]) else {
                return nil
            }
            return (inner, true)
        case 0x10:
            guard data.count >= 9 else { return nil }
            let inner = data.subdata(in: (data.startIndex + 1)..<data.endIndex)
            guard (inner[inner.startIndex] >> 6) == 2, (192...223).contains(inner[inner.startIndex + 1]) else {
                return nil
            }
            return (inner, true)
        case 0x7F:
            guard data.count > 9, let pktCmd = try? data.readUInt16LE(at: 7), (pktCmd == 8 || pktCmd == 9) else {
                return nil
            }
            return (data.subdata(in: (data.startIndex + 9)..<data.endIndex), pktCmd == 9)
        default:
            return nil
        }
    }

    /// Wraps a `VoipRequestOperation` binary body into an authenticated HTTP failover frame (`session_key` + `cmd`/`subCmd`).
    public static func packHttpFailoverVoipFrame(
        srcId: Int32,
        cmd: Int16,
        subCmd: Int8,
        voipBodyData: Data,
        sessionKey: String,
        httpKey: Data = ZolaConstants.httpKeyData
    ) -> ZolaFailoverFrame {
        let skBytes = Data(sessionKey.utf8)
        let sessionSize = UInt16(truncatingIfNeeded: skBytes.count)
        let dataLen = 2 + skBytes.count + 1 + voipBodyData.count
        let frameSize = UInt32(16 + dataLen)
        let sum = UInt32(truncatingIfNeeded: Int64(srcId) + Int64(cmd) + Int64(subCmd))
        let checksum = sum ^ ZolaConstants.checksumMagic

        var header = Data(capacity: 16)
        header.appendUInt32LE(frameSize)
        header.appendInt8(ZolaConstants.httpFailoverVersion)
        header.appendUInt32LE(checksum)
        header.appendInt32LE(srcId)
        header.appendInt16LE(cmd)
        header.appendInt8(subCmd)

        var plainFrame = Data(capacity: dataLen)
        plainFrame.appendUInt16LE(sessionSize)
        plainFrame.append(skBytes)
        plainFrame.appendInt8(0)
        plainFrame.append(voipBodyData)

        let encFrame = encryptHTTPData(plainFrame, srcId: srcId, frameSize: frameSize, keyData: httpKey)
        return ZolaFailoverFrame(
            frameBytes: header + encFrame,
            cmd: cmd,
            subCmd: subCmd,
            frameSize: frameSize,
            dataLength: dataLen,
            checksum: checksum
        )
    }
}
