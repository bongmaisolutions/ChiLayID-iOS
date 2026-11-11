import Foundation

extension ZolaClient {
    /// Picks the first usable HTTPS URL out of an `uploadAttachment` response.
    internal static func extractUploadedFileURL(_ data: [String: Any]) -> String? {
        for key in ["aac", "m4a", "m4aUrl", "voiceUrl", "org", "hd", "fileUrl", "url", "normalUrl", "hdUrl"] {
            if let value = data[key] as? String {
                let normalized = ZolaAttachment.normalizeMediaUrl(value)
                if normalized.hasPrefix("https://") { return normalized }
            }
        }
        if let nested = data["data"] as? [String: Any] { return extractUploadedFileURL(nested) }
        return nil
    }

    /// Uploads recorded audio (`.m4a` or ADTS `.aac`) via Zalo iOS Native Pure-HTTP upload (`uploadFeature = 2`)
    /// and sends `subCmd = 31` (`action = "chat.voice"`, millisecond `duration`) with optional `TLV tag = 2` reply quote,
    /// returning both the uploaded Zalo CDN URL and `ZolaSendReceipt`.
    public func uploadAndSendVoiceFile(
        audioData: Data,
        threadId: Int64,
        type: ZolaThreadType = .user,
        durationMs: Int = 0,
        quote: ZolaQuote? = nil,
        dryRun: Bool = false,
        clientIdMs: Int64? = nil
    ) async throws -> (voiceUrl: String, m4aUrl: String, receipt: ZolaSendReceipt) {
        try assertSessionAlive()
        guard !audioData.isEmpty else { throw ZolaError.invalidArgument("audioData must not be empty") }
        let isGroupSend = type == .group || knownGroupIds().contains(threadId)
        // This compatibility wrapper has no group opt-in. Reject before uploading;
        // callers opting into group media use the guarded native group API instead.
        guard dryRun || !isGroupSend else {
            throw ZolaError.safetyGate("Gửi thoại nhóm cần API native nhóm có bật gửi tin nhóm")
        }
        // Normalize ANY decodable input to ADTS `.aac`: fast `m4aToAdtsAac` demux first, then the
        // `ExtAudioFile` transcode for `.caf`/`.wav`/`.mp3` so raw LPCM never reaches the CDN.
        guard let aacData = await ZolaADTS.convertToAdtsData(audioData) else {
            throw ZolaError.invalidArgument("Không chuyển đổi được bản ghi sang AAC/ADTS (định dạng nguồn không hợp lệ)")
        }
        let safeDurationMs = max(1_000, durationMs)
        let waveform = ZolaADTS.extractWaveformSamples(aacData)
        if dryRun {
            let dryUrl = "https://voice.talk.zing.vn/dryrun-\(clientIdMs ?? 0).aac"
            let receipt: ZolaSendReceipt
            if isGroupSend {
                receipt = try await sendVoiceGroup(
                    gid: threadId,
                    voiceUrl: dryUrl,
                    durationMs: safeDurationMs,
                    fileSize: aacData.count,
                    m4aUrl: dryUrl,
                    waveformSamples: waveform,
                    quote: quote,
                    dryRun: true,
                    clientIdMs: clientIdMs
                )
            } else {
                receipt = try await sendVoice1To1(
                    to: threadId,
                    voiceUrl: dryUrl,
                    durationMs: safeDurationMs,
                    fileSize: aacData.count,
                    fileExt: "aac",
                    m4aUrl: dryUrl,
                    waveformSamples: waveform,
                    quote: quote,
                    dryRun: true,
                    clientIdMs: clientIdMs
                )
            }
            return (dryUrl, dryUrl, receipt)
        }
        let fileName = "\(ZolaCrypto.md5Hex(aacData)).aac"
        // ADTS chat audio uses the completed-URL upload route, never Feed feature 3.
        let uploaded = try await uploadMediaNativeHTTP(
            fileData: aacData,
            fileName: fileName,
            toId: threadId,
            isGroup: isGroupSend,
            uploadFeature: 2
        )
        func isusableAudioURL(_ candidate: String) -> Bool {
            guard candidate.hasPrefix("https://") else { return false }
            let pathPart = candidate.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? candidate
            let ext = (pathPart as NSString).pathExtension.lowercased()
            return !["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext)
        }
        let normalUrl = ZolaAttachment.normalizeMediaUrl(
            ZolaJSON.string(uploaded["normalUrl"] ?? uploaded["aac"] ?? uploaded["org"] ?? uploaded["fileUrl"] ?? uploaded["url"])
        )
        let rawM4aUrl = ZolaAttachment.normalizeMediaUrl(
            ZolaJSON.string(uploaded["m4aUrl"] ?? uploaded["m4a"] ?? uploaded["aac"])
        )
        let baseVoiceUrl: String = {
            if isusableAudioURL(normalUrl) { return normalUrl }
            if isusableAudioURL(rawM4aUrl) { return rawM4aUrl }
            if let fallback = Self.extractUploadedFileURL(uploaded), isusableAudioURL(fallback) {
                return fallback
            }
            return ""
        }()
        guard baseVoiceUrl.hasPrefix("https://") else {
            throw ZolaError.transport(
                "Đã tải voice lên Zalo (fileId=\(ZolaJSON.string(uploaded["fileId"]))) nhưng phản hồi không chứa URL audio hợp lệ"
            )
        }
        let resolvedVoiceUrl = Self.ensureAudioPathExtension(baseVoiceUrl, fileName: fileName)
        let resolvedM4aUrl = isusableAudioURL(rawM4aUrl)
            ? Self.ensureAudioPathExtension(rawM4aUrl, fileName: fileName)
            : resolvedVoiceUrl
        let resolvedFileSize = max(aacData.count, ZolaJSON.int(uploaded["fileSize"]))
        let receipt: ZolaSendReceipt
        if isGroupSend {
            receipt = try await sendVoiceGroup(
                gid: threadId,
                voiceUrl: resolvedVoiceUrl,
                durationMs: safeDurationMs,
                fileSize: resolvedFileSize,
                m4aUrl: resolvedM4aUrl,
                waveformSamples: waveform,
                quote: quote,
                dryRun: false,
                clientIdMs: clientIdMs
            )
        } else {
            receipt = try await sendVoice1To1(
                to: threadId,
                voiceUrl: resolvedVoiceUrl,
                durationMs: safeDurationMs,
                fileSize: resolvedFileSize,
                fileExt: "aac",
                m4aUrl: resolvedM4aUrl,
                waveformSamples: waveform,
                quote: quote,
                dryRun: false,
                clientIdMs: clientIdMs
            )
        }
        return (resolvedVoiceUrl, resolvedM4aUrl, receipt)
    }

    /// Complete native voice send: demux `.m4a` → ADTS `.aac`, upload to Zalo's native iOS HTTP upload service,
    /// then send `subCmd = 31` (`chat.voice`) so the recipient sees a playable voice bubble.
    /// No proxy, no external hosting — Zalo voice rejects non-Zalo-CDN URLs.
    @discardableResult
    public func sendVoiceFile(
        audioData: Data,
        threadId: Int64,
        type: ZolaThreadType = .user,
        durationMs: Int = 0,
        quote: ZolaQuote? = nil,
        dryRun: Bool = false
    ) async throws -> Bool {
        let sent = try await uploadAndSendVoiceFile(
            audioData: audioData,
            threadId: threadId,
            type: type,
            durationMs: durationMs,
            quote: quote,
            dryRun: dryRun
        )
        return sent.receipt.ok
    }
}
