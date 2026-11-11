import Foundation

// Timeline post writes, decoded from Zalo iOS 261002 (UXChatSocket 0x7d0, sourceType 3, messageType 1):
//   - TEXT POST  cmd 1233 subCmd 4  (`+[IMRequestController postStatusFeed:complete:]` 0x101263dd8)
//     Body (108 bytes for a 19-char "Only me" post, matched byte for byte against a live capture):
//       Int16 0, UInt8 clientType(2), Int32 clientVersion, Int16 0, Int32 0, Int32 deviceType,
//       Int64 feedts (client ms), Int32 textLen + UTF8 text, UInt8 tagCount (+ Int32 uid each),
//       Double longitude(-1), Double latitude(-1), Int16 locationNameLen (+ UTF8),
//       Int16 privacy (0 = friends, 1 = only me — confirmed from the client's FeedEntity cache),
//       Int16 privacyFriendIdCount (+ Int32 each), UInt8 addMutualTimeline, Int32 typofeed,
//       Int32 textColor(-1), Int32 backgroundColor(-1), Double backgroundRatio(-1), Int32 align(-1),
//       Int32 backgroundRenderType(-1), UInt8 checkin, Int16 trackingSource(1), Int32 paramsLen + params.
//   - DELETE     cmd 296  subCmd 0  (`+[SingleRequestManager removeFeed:success:failure:]` 0x1011d9a1c)
//     Body: Int64 feedId.
//   - PHOTO POST cmd 1796 subCmd 1  (`+[IMRequestController postSinglePhotoFeed:photoId:dimension:success:failure:]` 0x10126a2e0)
//     Body (142 bytes for a 14-char "Only me" caption, matched byte for byte against a live Zalo 2 capture):
//       Int16 0, UInt8 clientType(2), Int32 clientVersion, Int16 0, Int64 photoId, Int64 feedts (ms),
//       Int32 captionLen + UTF8 caption, Int32 tagCount (+ Int32 uid each), Int32 deviceType,
//       Double longitude(-1), Double latitude(-1), Int32 locationNameLen (+ UTF8), Int32 privacy,
//       Int32 privacyFriendIdCount (+ Int32 each), Int32 width, Int32 height, UInt8 0, Int32 0, Int32 typofeed(0),
//       Int16 trackingSource(40), Int32 paramsLen + params, Int64 0, Int16 0, UInt8 0, Int16 0.
//   - PHOTO UPLOAD before the post: `FeedMediaUploader` cmd 166 subCmd 3. `SocialMediaUploader performSocket:uploadFile:`
//     (0x101315b64) passes destId 0 and destType 0; the HTTP helper 0x103b45c50 maps cmd 166 to uploadFeature 1.
//     `FeedMediaUploader didCompleteUploadFile:processUploadData:` (0x10131b698) reads `data.sFileId`, else `data.photo_id`.
// Writes go to Zalo for real; callers must keep `dryRun: true` except on an explicit user action.

extension ZolaConstants {
    public static let cmdFeedPostText: Int16 = 1233
    public static let subCmdFeedPostText: Int8 = 4
    public static let cmdFeedDelete: Int16 = 296
    public static let cmdFeedPostPhoto: Int16 = 1796
    public static let subCmdFeedPostPhoto: Int8 = 1
    /// Pre-upload `uploadFeature` of a timeline photo (native upload command 166).
    public static let feedPhotoUploadFeature = 1
}

public enum ZolaFeedPrivacy: Int16, Codable, Sendable, CaseIterable {
    case friends = 0
    case onlyMe = 1

    public var title: String {
        switch self {
        case .friends: return "Bạn bè"
        case .onlyMe: return "Chỉ mình tôi"
        }
    }
}

public enum ZolaFeedComposer {
    public static let maxTextBytes = 10_000

    public static func textPostBody(text: String, privacy: ZolaFeedPrivacy, clientTimestampMs: Int64,
                                    deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZolaError.invalidArgument("Bài viết đang trống.") }
        let textData = Data(text.utf8)
        guard textData.count <= maxTextBytes else { throw ZolaError.invalidArgument("Bài viết quá dài.") }
        guard clientTimestampMs > 0 else { throw ZolaError.invalidArgument("Thời điểm đăng bài không hợp lệ.") }
        var body = Data()
        body.appendInt16LE(0)
        body.appendUInt8(UInt8(ZolaConstants.clientTypeIOS))
        body.appendInt32LE(Int32(ZolaConstants.clientVersionIOS))
        body.appendInt16LE(0)
        body.appendInt32LE(0)
        body.appendInt32LE(deviceType)
        body.appendInt64LE(clientTimestampMs)
        body.appendInt32LE(Int32(textData.count))
        body.append(textData)
        body.appendUInt8(0)                       // no tagged friends
        body.appendDoubleLE(-1)                   // longitude: none
        body.appendDoubleLE(-1)                   // latitude: none
        body.appendInt16LE(0)                     // empty location name
        body.appendInt16LE(privacy.rawValue)
        body.appendInt16LE(0)                     // no custom friend list
        body.appendUInt8(0)                       // addMutualTimeline
        body.appendInt32LE(0)                     // typofeed: plain text
        body.appendInt32LE(-1)                    // textColor
        body.appendInt32LE(-1)                    // backgroundColor
        body.appendDoubleLE(-1)                   // backgroundRatio
        body.appendInt32LE(-1)                    // align
        body.appendInt32LE(-1)                    // backgroundRenderType
        body.appendUInt8(0)                       // checkin
        body.appendInt16LE(1)                     // tracking source, as the live client sent
        body.appendInt32LE(1)                     // tracking params: empty C string
        body.appendUInt8(0)
        return body
    }

    public static func textPostFrame(text: String, privacy: ZolaFeedPrivacy, clientTimestampMs: Int64,
                                     srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(
            bodyData: try textPostBody(text: text, privacy: privacy, clientTimestampMs: clientTimestampMs),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdFeedPostText,
            subCmd: ZolaConstants.subCmdFeedPostText, seqId: seqId, needAck: 1)
    }

    public static func deleteBody(feedId: Int64) throws -> Data {
        guard feedId > 0 else { throw ZolaError.invalidArgument("Mã bài viết không hợp lệ.") }
        var body = Data()
        body.appendInt64LE(feedId)
        return body
    }

    public static func deleteFrame(feedId: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(bodyData: try deleteBody(feedId: feedId), srcId: srcId, srcType: 3,
            msgType: 1, cmd: ZolaConstants.cmdFeedDelete, subCmd: 0, seqId: seqId, needAck: 1)
    }

    /// Upper bound of one timeline photo upload: the raw (non-chunked) native upload route only.
    public static let maxPhotoBytes = 2 * 1024 * 1024 - 1
    /// Tracking values the live client sent when posting from the photo composer.
    public static let photoPostTrackingSource: Int16 = 40
    public static let photoPostTrackingParams = #"{"btnType":1,"eventType":0}"#

    public static func photoPostBody(photoId: Int64, caption: String, privacy: ZolaFeedPrivacy, width: Int32, height: Int32,
                                     clientTimestampMs: Int64,
                                     deviceType: Int32 = ZolaTimelineFeed.defaultDeviceType) throws -> Data {
        guard photoId > 0 else { throw ZolaError.invalidArgument("Ảnh chưa tải lên được.") }
        guard width > 0, height > 0 else { throw ZolaError.invalidArgument("Kích thước ảnh không hợp lệ.") }
        guard clientTimestampMs > 0 else { throw ZolaError.invalidArgument("Thời điểm đăng bài không hợp lệ.") }
        let captionData = Data(caption.utf8)
        guard captionData.count <= maxTextBytes else { throw ZolaError.invalidArgument("Bài viết quá dài.") }
        let params = Data(photoPostTrackingParams.utf8)
        var body = Data()
        body.appendInt16LE(0)
        body.appendUInt8(UInt8(ZolaConstants.clientTypeIOS))
        body.appendInt32LE(Int32(ZolaConstants.clientVersionIOS))
        body.appendInt16LE(0)
        body.appendInt64LE(photoId)
        body.appendInt64LE(clientTimestampMs)
        body.appendInt32LE(Int32(captionData.count))
        body.append(captionData)
        body.appendInt32LE(0)                     // no tagged friends
        body.appendInt32LE(deviceType)
        body.appendDoubleLE(-1)                   // longitude: none
        body.appendDoubleLE(-1)                   // latitude: none
        body.appendInt32LE(0)                     // empty location name
        body.appendInt32LE(Int32(privacy.rawValue))
        body.appendInt32LE(0)                     // no custom friend list
        body.appendInt32LE(width)
        body.appendInt32LE(height)
        body.appendUInt8(0)
        body.appendInt32LE(0)
        body.appendInt32LE(0)                     // typofeed: plain
        body.appendInt16LE(photoPostTrackingSource)
        body.appendInt32LE(Int32(params.count))
        body.append(params)
        body.appendInt64LE(0)
        body.appendInt16LE(0)                     // empty string
        body.appendUInt8(0)
        body.appendInt16LE(0)
        return body
    }

    public static func photoPostFrame(photoId: Int64, caption: String, privacy: ZolaFeedPrivacy, width: Int32, height: Int32,
                                      clientTimestampMs: Int64, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard srcId != 0 else { throw ZolaError.invalidArgument("Tài khoản không hợp lệ.") }
        return ZolaCrypto.packChatElementFrame(
            bodyData: try photoPostBody(photoId: photoId, caption: caption, privacy: privacy, width: width, height: height,
                                        clientTimestampMs: clientTimestampMs),
            srcId: srcId, srcType: 3, msgType: 1, cmd: ZolaConstants.cmdFeedPostPhoto,
            subCmd: ZolaConstants.subCmdFeedPostPhoto, seqId: seqId, needAck: 1)
    }

    /// The photo id from a completed timeline photo upload, read like the native client: `sFileId`, then `photo_id`.
    public static func uploadedPhotoId(_ envelope: [String: Any]) -> Int64? {
        let data = (envelope["data"] as? [String: Any]) ?? envelope
        for source in [data, (data["data"] as? [String: Any]) ?? [:]] {
            for key in ["sFileId", "photo_id"] {
                let value = ZolaJSON.int64(source[key])
                if value > 0 { return value }
            }
        }
        return nil
    }

    /// The new feed id, when the reply carries one (key names seen in the client: `fid`, `feedId`, `feedid`).
    /// The live 1796 reply wraps the new post as `{holder_title, holder_type, item: {fid, …}}`.
    static func postedFeedId(_ data: [String: Any]) -> Int64? {
        for source in [data, (data["item"] as? [String: Any]) ?? [:]] {
            for key in ["fid", "feedId", "feedid", "feed_id", "id"] {
                let value = ZolaJSON.int64(source[key])
                if value > 0 { return value }
            }
        }
        return nil
    }
}

extension Data {
    mutating func appendDoubleLE(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &bits) { append(contentsOf: $0) }
    }
}

extension ZolaClient {
    nonisolated(unsafe) private static var composerShapeNotes = 0

    /// Publishes a text post on the account's timeline. Returns the new feed id when the server reports it.
    /// A real write to Zalo: only call with `dryRun: false` from an explicit user action.
    @discardableResult
    public func postTimelineText(_ text: String, privacy: ZolaFeedPrivacy, dryRun: Bool = true) async throws -> Int64? {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try ZolaFeedComposer.textPostFrame(text: text, privacy: privacy, clientTimestampMs: ts, srcId: srcId, seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaFeedComposer.textPostFrame(text: text, privacy: privacy, clientTimestampMs: ts, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedPostText,
                timeoutSeconds: 12, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedPostText], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response) // includes the 102/-96 session breaker
            if let handler = Self.diagnosticHandler, Self.composerShapeNotes < 3 {
                Self.composerShapeNotes += 1
                handler("dang-bai code=\(parsed.code) keys=\(parsed.data.keys.sorted().joined(separator: ","))")
            }
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa nhận bài viết." : parsed.message)
            }
            return ZolaFeedComposer.postedFeedId(parsed.data)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ đăng bài native.")
        #endif
    }

    /// Publishes a single-photo post (JPEG under `ZolaFeedComposer.maxPhotoBytes`). Uploads the photo first, then sends
    /// cmd 1796. Returns the new feed id when the server reports it. A real write: `dryRun: false` only from a user tap.
    @discardableResult
    public func postTimelinePhoto(jpegData: Data, width: Int, height: Int, caption: String, privacy: ZolaFeedPrivacy,
                                  dryRun: Bool = true) async throws -> Int64? {
        try assertSessionAlive()
        guard !jpegData.isEmpty else { throw ZolaError.invalidArgument("Chưa chọn ảnh.") }
        guard jpegData.count <= ZolaFeedComposer.maxPhotoBytes else { throw ZolaError.invalidArgument("Ảnh quá lớn.") }
        let srcId = Int32(truncatingIfNeeded: session.uid)
        let w = Int32(clamping: width), h = Int32(clamping: height)
        // Validate every field offline before anything leaves the device (the photo id is not known yet).
        _ = try ZolaFeedComposer.photoPostFrame(photoId: 1, caption: caption, privacy: privacy, width: w, height: h,
                                                clientTimestampMs: 1, srcId: srcId, seqId: 1)
        guard !dryRun else { return nil }
        #if canImport(Network)
        let photoId = try await uploadTimelinePhoto(jpegData: jpegData, width: width, height: height)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaFeedComposer.photoPostFrame(photoId: photoId, caption: caption, privacy: privacy, width: w, height: h,
                                                            clientTimestampMs: ts, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedPostPhoto,
                timeoutSeconds: 12, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedPostPhoto], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response) // includes the 102/-96 session breaker
            if let handler = Self.diagnosticHandler, Self.composerShapeNotes < 3 {
                Self.composerShapeNotes += 1
                handler("dang-anh code=\(parsed.code) keys=\(parsed.data.keys.sorted().joined(separator: ","))")
            }
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa nhận bài viết." : parsed.message)
            }
            return ZolaFeedComposer.postedFeedId(parsed.data)
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ đăng bài native.")
        #endif
    }

    /// Uploads one timeline photo with the native feed values (uploadFeature 1, destId 0, destType 0) over the same
    /// pure-HTTP pre-upload + raw POST as chat media, and returns its photo id. Never opens an upload socket.
    /// Ordinary upload errors keep the session; 102/-96 latch the breaker inside `executeNativeUploadRequest`.
    func uploadTimelinePhoto(jpegData: Data, width: Int, height: Int) async throws -> Int64 {
        try assertSessionAlive()
        let rawId = Int32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000) & 0x7FFF_FFFF)
        let cliFileId = rawId > 0 ? rawId : 1_000_001
        let fileName = "\(ZolaCrypto.md5Hex(jpegData)).jpg"
        let configBase: String = {
            if let overrideUrl = session.serviceHosts?["upload_config"], !overrideUrl.isEmpty,
               !Self.isForbiddenWebWpaURL(overrideUrl) {
                return overrideUrl
            }
            if let cached = cachedUploadConfigURL, !cached.isEmpty { return cached }
            return ZolaConstants.defaultUploadConfigURL
        }()
        let sep = configBase.contains("?") ? "&" : "?"
        let configURLString = "\(configBase)\(sep)clientType=\(ZolaConstants.clientTypeIOS)&clientVersion=\(ZolaConstants.clientVersionIOS)&uploadFeature=\(ZolaConstants.feedPhotoUploadFeature)&numOfFiles=0&subCmd=10&key=\(cliFileId)&httpVer=1&destId=0&destType=0&fileSize=\(Int64(jpegData.count))&cliFileId=\(cliFileId)&fileName=\(ZolaRequestBuilder.urlEncode(fileName))&width=\(width)&height=\(height)"
        guard let configURL = URL(string: configURLString) else { throw ZolaError.invalidArgument("Invalid native pre-upload URL") }
        var configRequest = URLRequest(url: configURL)
        configRequest.httpMethod = "GET"
        configRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        configRequest.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        configRequest.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
        ZolaRequestBuilder.applySessionBoxHeaders(&configRequest, session: session, urlString: configURLString)

        let (configStatus, configRaw) = try await executeNativeUploadRequest(configRequest, stage: "feed-photo/config")
        let config = Self.unwrapUploadEnvelope(configRaw, zcid: session.zcid)
        let configCode = config["error_code"] != nil ? ZolaJSON.int(config["error_code"]) : (configStatus == 200 ? 0 : configStatus)
        guard configCode == 0 else {
            let message = ZolaJSON.string(config["error_message"] ?? config["errMessage"])
            throw ZolaError.server(code: configCode, message: message.isEmpty ? "Zalo chưa cho tải ảnh lên (HTTP \(configStatus))." : message)
        }
        let hosts = Self.extractPreUploadUrls(from: config).filter { !$0.isEmpty && !Self.isForbiddenWebWpaURL($0) }
        guard !hosts.isEmpty else { throw ZolaError.transport("Máy chủ Zalo không trả về đường dẫn tải ảnh lên.") }

        let crc = ZolaCrypto.crc32(jpegData)
        let strippedZcid = session.zcid.hasPrefix("1_") ? String(session.zcid.dropFirst(2)) : session.zcid
        var lastError: Error?
        for host in hosts {
            guard let hostURL = URL(string: host) else { continue }
            var request = URLRequest(url: hostURL)
            request.httpMethod = "POST"
            request.httpBody = jpegData
            request.setValue("raw", forHTTPHeaderField: "Content-Type")
            request.setValue(String(jpegData.count), forHTTPHeaderField: "Content-Length")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
            if !strippedZcid.isEmpty { request.setValue(strippedZcid, forHTTPHeaderField: "zcid") }
            request.setValue("v2", forHTTPHeaderField: "v")
            request.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
            request.setValue("f=1; v=\(crc)", forHTTPHeaderField: "x-md-hv")
            ZolaRequestBuilder.applySessionBoxHeaders(&request, session: session, urlString: host)
            do {
                let (status, raw) = try await executeNativeUploadRequest(request, stage: "feed-photo/raw")
                let envelope = Self.unwrapUploadEnvelope(raw, zcid: session.zcid)
                let data = envelope["data"] as? [String: Any]
                let code = ZolaJSON.int(envelope["error_code"] ?? data?["error_code"], default: (200..<300).contains(status) ? 0 : status)
                if let handler = Self.diagnosticHandler, Self.composerShapeNotes < 3 {
                    Self.composerShapeNotes += 1
                    handler("tai-anh http=\(status) code=\(code) keys=\(((data ?? envelope).keys).sorted().joined(separator: ","))")
                }
                if code == 0, let photoId = ZolaFeedComposer.uploadedPhotoId(envelope) { return photoId }
                let message = ZolaJSON.string(envelope["error_message"] ?? envelope["errMessage"])
                lastError = ZolaError.server(code: code == 0 ? -1 : code,
                                             message: message.isEmpty ? "Zalo chưa trả mã ảnh sau khi tải lên." : message)
            } catch {
                if case ZolaError.sessionExpired = error { throw error }
                lastError = error
            }
        }
        throw lastError ?? ZolaError.transport("Không tải được ảnh lên máy chủ Zalo.")
    }

    /// Deletes one of the account's own timeline posts. A real write; explicit user action only.
    @discardableResult
    public func deleteTimelinePost(feedId: Int64, dryRun: Bool = true) async throws -> Bool {
        try assertSessionAlive()
        let srcId = Int32(truncatingIfNeeded: session.uid)
        _ = try ZolaFeedComposer.deleteFrame(feedId: feedId, srcId: srcId, seqId: 1)
        guard !dryRun else { return false }
        #if canImport(Network)
        return try await withAuthenticatedChatSocket { socket in
            let seq = await socket.nextSeqId()
            let frame = try ZolaFeedComposer.deleteFrame(feedId: feedId, srcId: srcId, seqId: seq)
            let response = try await socket.sendAndWait(rawPayload: frame.payload, expectedCmd: ZolaConstants.cmdFeedDelete,
                timeoutSeconds: 10, ackSeqId: seq, ackCmds: [ZolaConstants.cmdFeedDelete], requiresResponseBody: true)
            let parsed = try parseChatSocketResponse(response)
            guard parsed.code == 0 else {
                throw ZolaError.server(code: parsed.code, message: parsed.message.isEmpty ? "Zalo chưa xoá bài viết." : parsed.message)
            }
            return true
        }
        #else
        throw ZolaError.transport("Nền tảng không hỗ trợ xoá bài native.")
        #endif
    }
}
