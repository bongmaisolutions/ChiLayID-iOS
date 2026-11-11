import Foundation

/// Native261002 `ZAChatSendModel` / `ChatSocketCmdHelper` group envelopes.
/// No HTTP failover: group media is 201/207, while ReactionEntity uses 1785.
internal struct ZolaGroupMediaWire: Sendable {
    let data: Data
    let command: Int16
    let subCommand: Int8

    static func media(
        subCmd: Int8, href: String = "", thumb: String = "", title: String = "",
        description: String = "", action: String = "", param: String = "",
        quote: ZolaQuote? = nil, includeIOSProps: Bool = false,
        clientIdMs: Int64 = 0, trackingIdHex: String? = nil, extraDataJSON: String? = nil
    ) throws -> Self {
        guard [31, 32, 44, 46].contains(subCmd) else {
            throw ZolaError.safetyGate("Định dạng media nhóm này chưa có khung native được kiểm chứng")
        }
        let built = ZolaCrypto.buildMediaMsgBodyData(subCmd: subCmd, title: title,
            description: description, href: href, thumb: thumb, action: action, param: param,
            quote: quote, includeIOSProps: includeIOSProps, trackingIdHex: trackingIdHex, clientIdMs: clientIdMs,
            extraDataJSON: extraDataJSON)
        return groupEnvelope(built.bodyData, subCmd: subCmd)
    }

    static func sticker(stickerId: Int32, cateId: Int32, stickerType: Int8 = 7,
                        quote: ZolaQuote? = nil, includeIOSProps: Bool = false,
                        clientIdMs: Int64 = 0, trackingIdHex: String? = nil) throws -> Self {
        guard stickerId > 0, cateId > 0 || (cateId == 0 && stickerType == 2 && (1...30).contains(stickerId)) else {
            throw ZolaError.invalidArgument("Invalid native sticker metadata")
        }
        let built = ZolaCrypto.buildStickerMsgBodyData(stickerId: stickerId, cateId: cateId,
            stickerType: stickerType, quote: quote, includeIOSProps: includeIOSProps,
            trackingIdHex: trackingIdHex, clientIdMs: clientIdMs)
        return groupEnvelope(built.bodyData, subCmd: built.subCmd)
    }

    /// `getPropertiesData:` 0x100c871ac–0x100c875b4: no properties -> original body;
    /// properties -> cmd207, Int16 subCmd + UInt8 count + TLV + body.
    private static func groupEnvelope(_ oneToOneBody: Data, subCmd: Int8) -> Self {
        let hasProperties = oneToOneBody[oneToOneBody.startIndex + 2] != 0
        return Self(data: hasProperties ? oneToOneBody : Data(oneToOneBody.dropFirst(3)),
                    command: hasProperties ? 207 : 201, subCommand: subCmd)
    }

    /// `ReactionEntity createReactionChatElement` 0x100e06a38 writes the 55/0
    /// prefix unconditionally, then uses group1785 (one-to-one1780).
    static func reaction(parameterJSON: String) throws -> Self {
        guard let json = parameterJSON.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: json)) is [String: Any] else {
            throw ZolaError.invalidArgument("Reaction params must be a JSON object")
        }
        let built = ZolaCrypto.buildMediaMsgBodyData(subCmd: 55, param: parameterJSON)
        return Self(data: built.bodyData, command: 1785, subCommand: 55)
    }

    static func reactionParameters(messageSenderUid: Int64, cliMsgId: Int64, globalMsgId: Int64,
                                   icon: String, removing: Bool, msgType: Int) throws -> String {
        guard cliMsgId > 0 || globalMsgId > 0, messageSenderUid > 0, msgType > 0 else {
            throw ZolaError.invalidArgument("Reaction requires a message ID, sender and native message type")
        }
        guard let mapped = ZolaReactionCatalog.wireReaction(for: icon) else {
            throw ZolaError.invalidArgument("Unsupported native reaction icon")
        }
        let object: [String: Any] = [
            "msgSender": String(messageSenderUid), "rIcon": mapped.rIcon,
            "rType": removing ? -1 : mapped.rType,
            "rMsg": [["cMsgID": cliMsgId, "gMsgID": globalMsgId, "msgType": msgType]], "source": 6,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func frame(uid: Int64, gid: Int64, seqId: Int32, clientIdMs: Int64) throws -> ZolaChatElementFrame {
        guard uid > 0, uid <= Int64(UInt32.max), gid > 0, gid <= Int64(UInt32.max), clientIdMs > 0 else {
            throw ZolaError.invalidArgument("Native group IDs must fit UInt32 and clientIdMs must be positive")
        }
        return ZolaCrypto.packChatElementFrame(bodyData: data, srcId: Int32(truncatingIfNeeded: uid),
            srcType: 3, msgType: 2, cmd: command, subCmd: subCommand, seqId: seqId,
            needAck: 1, desId: Int32(truncatingIfNeeded: gid), desType: 4, globalMsgId: clientIdMs)
    }

    static func checkPolicy(enabled: Bool, dryRun: Bool, group: ZolaGroup?, senderUid: Int64 = 0) throws {
        guard dryRun || enabled else { throw ZolaError.safetyGate("Gửi media vào nhóm chưa được cho phép trong phiên này") }
        guard dryRun || group != nil else { throw ZolaError.safetyGate("Tải thông tin nhóm trước khi gửi media") }
        guard group?.isE2ee != true else { throw ZolaError.safetyGate("Chưa hỗ trợ gửi media vào nhóm mã hoá đầu cuối") }
        if let group, group.lockSendMsg == true,
           !(senderUid > 0 && (group.creatorId == senderUid || group.adminIds.contains(senderUid))) {
            throw ZolaError.safetyGate("Nhóm đang khoá gửi tin")
        }
    }
}

extension ZolaClient {
    /// URL fields must refer to already uploaded native assets. This method never uploads.
    /// Live sending requires explicit opt-in; app callers must also recheck group permissions.
    public func sendMediaGroup(
        gid: Int64, subCmd: Int8, href: String = "", thumb: String = "", title: String = "",
        description: String = "", action: String = "", param: String = "", caption: String = "",
        quote: ZolaQuote? = nil, dryRun: Bool = true, groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil, trackingIdHex: String? = nil, extraDataJSON: String? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let wire = try ZolaGroupMediaWire.media(subCmd: subCmd, href: href, thumb: thumb, title: title,
            description: description.isEmpty ? caption : description, action: action, param: param,
            quote: quote, includeIOSProps: !session.cryptKey.isEmpty, clientIdMs: cid, trackingIdHex: trackingIdHex,
            extraDataJSON: extraDataJSON)
        return try await executeNativeGroupMedia(wire, gid: gid, clientIdMs: cid, dryRun: dryRun, groupSendEnabled: groupSendEnabled)
    }

    public func sendStickerGroup(
        gid: Int64, stickerId: Int32, cateId: Int32 = 10425, stickerType: Int8 = 7,
        quote: ZolaQuote? = nil, dryRun: Bool = true, groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil, trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let wire = try ZolaGroupMediaWire.sticker(stickerId: stickerId, cateId: cateId,
            stickerType: stickerType, quote: quote, includeIOSProps: !session.cryptKey.isEmpty,
            clientIdMs: cid, trackingIdHex: trackingIdHex)
        return try await executeNativeGroupMedia(wire, gid: gid, clientIdMs: cid, dryRun: dryRun, groupSendEnabled: groupSendEnabled)
    }

    /// Server ACK is required; socket handoff without confirmation stays `.unconfirmed`.
    internal func executeNativeGroupMedia(_ wire: ZolaGroupMediaWire, gid: Int64, clientIdMs: Int64,
                                          dryRun: Bool, groupSendEnabled: Bool) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        try ZolaGroupMediaWire.checkPolicy(enabled: groupSendEnabled, dryRun: dryRun, group: groupsCache[gid], senderUid: session.uid)
        let uid = session.uid
        let preview = try wire.frame(uid: uid, gid: gid, seqId: 1, clientIdMs: clientIdMs)
        if dryRun {
            return ZolaSendReceipt(ok: true, dryRun: true, sent: false, endpoint: "UXChatSocket:\(wire.command)",
                uid: uid, desId: gid, cmd: wire.command, innerSocketCmd: wire.command,
                subCmd: wire.subCommand, clientIdMs: clientIdMs, frameSize: preview.frameSize, cryptKeySha256_8: session.cryptKeySha256_8)
        }
        #if canImport(Network)
        let handedOff = ZolaHandOffFlag()
        let ack: ZolaUnpackedChatElement
        do {
            ack = try await withAuthenticatedChatSocket { sock in
                let seq = await sock.nextSeqId()
                let frame = try wire.frame(uid: uid, gid: gid, seqId: seq, clientIdMs: clientIdMs)
                return try await sock.sendAndWait(rawPayload: frame.payload, expectedCmd: wire.command,
                    timeoutSeconds: 8, ackSeqId: seq, ackCmds: wire.command == 1785 ? [1785] : Self.groupTextAckCmds,
                    onHandedToNetwork: { handedOff.set() })
            }
        } catch { throw Self.groupSendFailure(error, handedOff: handedOff.isSet) }
        let result = try evaluateGroupTextAck(ack)
        return ZolaSendReceipt(ok: result.ok, dryRun: false, sent: true, endpoint: "UXChatSocket:\(wire.command)",
            uid: uid, desId: gid, cmd: wire.command, innerSocketCmd: wire.command,
            subCmd: wire.subCommand, clientIdMs: clientIdMs, frameSize: preview.frameSize,
            cryptKeySha256_8: session.cryptKeySha256_8, serverErrorCode: result.serverErrorCode)
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ UXChatSocket")
        #endif
    }
}

// Typed rich-field builders share the already verified native 1-1 media schemas.
extension ZolaClient {
    public func sendPhotoGroup(
        gid: Int64,
        photoUrl: String,
        thumbUrl: String = "",
        width: Int = 0,
        height: Int = 0,
        fileExt: String = "jpg",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil,
        mediaGroup: ZolaMediaGroupLayout? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = ZolaAttachment.normalizeMediaUrl(photoUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanUrl.isEmpty, cleanUrl.lowercased().hasPrefix("http") else {
            throw ZolaError.invalidArgument("photoUrl must be a valid HTTP(S) URL")
        }
        let rawThumb = thumbUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanThumb = rawThumb.isEmpty ? cleanUrl : ZolaAttachment.normalizeMediaUrl(rawThumb)
        let cleanExt: String = {
            let trimmed = fileExt.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased()
            return trimmed.isEmpty ? "jpg" : trimmed
        }()
        let safeW = width > 0 ? width : 720
        let safeH = height > 0 ? height : 720
        let paramJson = ZolaMediaGroupLayout.photoParamJSON(url: cleanUrl, thumb: cleanThumb,
            width: safeW, height: safeH, fileExt: cleanExt, mediaGroup: mediaGroup)
        return try await sendMediaGroup(
            gid: gid,
            subCmd: ZolaConstants.subCmdSendPhoto,
            href: cleanUrl,
            thumb: cleanThumb,
            title: "",
            description: caption,
            action: "chat.photo",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            groupSendEnabled: groupSendEnabled,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex,
            extraDataJSON: mediaGroup?.extraDataJSON
        )
    }

    public func sendFileGroup(
        gid: Int64,
        fileUrl: String,
        fileName: String,
        fileSize: Int,
        fileExt: String = "",
        checksumMd5: String = "",
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = fileUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUrl.isEmpty else {
            throw ZolaError.invalidArgument("fileUrl must not be empty")
        }
        guard !cleanName.isEmpty && cleanName != "sendBubbleMessage" else {
            throw ZolaError.invalidArgument("fileName must not be empty")
        }
        let cleanExt: String = {
            let trimmed = fileExt.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\r\n")).lowercased()
            if !trimmed.isEmpty { return trimmed }
            let pathExt = (cleanName as NSString).pathExtension.lowercased()
            return pathExt.isEmpty ? "dat" : pathExt
        }()
        var paramObj: [String: Any] = [
            "fType": 1,
            "fileExt": cleanExt,
            "fileName": cleanName,
            "fileSize": max(0, fileSize),
        ]
        if !checksumMd5.isEmpty {
            paramObj["checksum"] = checksumMd5.lowercased()
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMediaGroup(
            gid: gid,
            subCmd: ZolaConstants.subCmdSendFile,
            href: cleanUrl,
            thumb: "",
            title: cleanName,
            description: caption,
            action: "share.file",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            groupSendEnabled: groupSendEnabled,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    public func sendVideoGroup(
        gid: Int64,
        videoUrl: String,
        thumbUrl: String = "",
        durationMs: Int,
        width: Int = 720,
        height: Int = 1280,
        rotation: Int = 0,
        fileSize: Int = 0,
        clientFileId: Int32? = nil,
        caption: String = "",
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let cleanUrl = ZolaAttachment.normalizeMediaUrl(videoUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanUrl.isEmpty, cleanUrl.lowercased().hasPrefix("http") else {
            throw ZolaError.invalidArgument("videoUrl must be a valid HTTP(S) URL")
        }
        let rawThumb = thumbUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedThumb = rawThumb.isEmpty ? "" : ZolaAttachment.normalizeMediaUrl(rawThumb)
        let lowerThumb = normalizedThumb.lowercased()
        let cleanThumb = (lowerThumb.hasSuffix(".mp4") || lowerThumb.hasSuffix(".mov") || lowerThumb.hasSuffix(".m4v"))
            ? ""
            : normalizedThumb

        let safeW = width > 0 ? width : 720
        let safeH = height > 0 ? height : 1280
        let resolvedCliFileId: Int = {
            if let clientFileId, clientFileId > 0 { return Int(clientFileId) }
            let seed = (clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)) & 0x7FFF_FFFF
            return max(1_000_001, Int(seed))
        }()
        let paramObj: [String: Any] = [
            "clientFileId": resolvedCliFileId,
            "duration": max(0, durationMs),
            "fileSize": max(0, fileSize),
            "video_height": safeH,
            "video_rotation": rotation,
            "video_width": safeW,
        ]
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMediaGroup(
            gid: gid,
            subCmd: ZolaConstants.subCmdSendVideo,
            href: cleanUrl,
            thumb: cleanThumb,
            title: "",
            description: caption,
            action: "chat.video.msg",
            param: paramJson,
            caption: caption,
            quote: quote,
            dryRun: dryRun,
            groupSendEnabled: groupSendEnabled,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }

    public func sendGroupVoice(
        gid: Int64,
        voiceUrl: String,
        durationMs: Int,
        fileSize: Int = 0,
        fileExt: String = "aac",
        m4aUrl: String = "",
        waveformSamples: [Int]? = nil,
        quote: ZolaQuote? = nil,
        dryRun: Bool = true,
        groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil,
        trackingIdHex: String? = nil
    ) async throws -> ZolaSendReceipt {
        let rawTrimmedUrl = voiceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTrimmedUrl.isEmpty else {
            throw ZolaError.invalidArgument("voiceUrl must not be empty")
        }
        let cleanExt = fileExt.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let fallbackLeaf = "voice.\(cleanExt.isEmpty ? "aac" : cleanExt)"
        let trimmedUrl = Self.ensureAudioPathExtension(rawTrimmedUrl, fileName: fallbackLeaf)
        let safeDuration = max(1_000, durationMs)
        let rawM4a = m4aUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedM4a = rawM4a.isEmpty
            ? trimmedUrl
            : Self.ensureAudioPathExtension(rawM4a, fileName: fallbackLeaf)
        var paramObj: [String: Any] = [
            "duration": safeDuration,
            "m4a": resolvedM4a,
        ]
        if fileSize > 0 {
            paramObj["fileSize"] = fileSize
        }
        if let waveformSamples, !waveformSamples.isEmpty {
            paramObj["waveformSamples"] = waveformSamples
        }
        let paramData = (try? JSONSerialization.data(withJSONObject: paramObj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let paramJson = String(decoding: paramData, as: UTF8.self)
        return try await sendMediaGroup(
            gid: gid,
            subCmd: ZolaConstants.subCmdSendVoice,
            href: trimmedUrl,
            thumb: "",
            title: "",
            description: "",
            action: "chat.voice",
            param: paramJson,
            caption: "",
            quote: quote,
            dryRun: dryRun,
            groupSendEnabled: groupSendEnabled,
            clientIdMs: clientIdMs,
            trackingIdHex: trackingIdHex
        )
    }
}

extension ZolaClient {
    /// Native ReactionEntity group1785. The target's server message type is required for rich messages.
    public func sendReactionGroup(
        gid: Int64, messageSenderUid: Int64, cliMsgId: Int64, globalMsgId: Int64,
        icon: String, removing: Bool = false, msgType: Int = 1, dryRun: Bool = true, groupSendEnabled: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> ZolaSendReceipt {
        try assertSessionAlive()
        let json = try ZolaGroupMediaWire.reactionParameters(messageSenderUid: messageSenderUid,
            cliMsgId: cliMsgId, globalMsgId: globalMsgId, icon: icon, removing: removing, msgType: msgType)
        let wire = try ZolaGroupMediaWire.reaction(parameterJSON: json)
        let cid = clientIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        return try await executeNativeGroupMedia(wire, gid: gid, clientIdMs: cid, dryRun: dryRun, groupSendEnabled: groupSendEnabled)
    }
}
