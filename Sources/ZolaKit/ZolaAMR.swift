import Foundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// Inbound voice normalizer for `Zalo -> app`.
///
/// Zalo Android / older iOS builds may deliver voice as `#!AMR\n` (AMR-NB RFC 4867 / 3GPP TS 26.104,
/// 8 kHz mono) or `#!AMR-WB\n`, or as extensionless `*.dlmd.me` / `voice-*.zadn.vn` URLs. iOS 17+
/// `AVPlayer`/`AVAudioPlayer` no longer decode `.amr` (`AVErrorFileFormatNotRecognized`), so
/// `preparePlayableAudio` sniffs the real container by magic bytes and transcodes AMR to WAV PCM16
/// through `ExtAudioFile` whenever the OS still ships an AMR decoder; otherwise the raw `.amr`
/// payload is returned untouched (never crashes, never fabricates audio).
public enum ZolaAudioNormalizer {
    public static let amrNBHeader = Data("#!AMR\n".utf8)
    public static let amrWBHeader = Data("#!AMR-WB\n".utf8)

    /// `true` when `data` starts with the AMR-NB (`#!AMR\n`) or AMR-WB (`#!AMR-WB\n`) magic header.
    public static func isAMR(_ data: Data) -> Bool {
        data.starts(with: amrNBHeader) || data.starts(with: amrWBHeader)
    }

    public static func isAMRWB(_ data: Data) -> Bool {
        data.starts(with: amrWBHeader)
    }

    /// AMR-NB single-channel frame byte sizes per `FT` (0...7) + SID (8) per RFC 4867 / TS 26.101 Table A.1b.
    private static let amrNBFrameBytes: [Int] = [12, 13, 15, 17, 19, 20, 26, 31, 5]
    /// AMR-WB single-channel frame byte sizes per `FT` (0...8) + SID (9) per TS 26.201 Table A.2b.
    private static let amrWBFrameBytes: [Int] = [17, 23, 32, 36, 40, 46, 50, 58, 60, 5]

    /// Counts decodable speech frames by walking the per-frame TOC byte (`CMR` + `FT` in the high nibble).
    /// Each frame carries 20 ms of audio, so `count * 20` is the nominal duration.
    public static func amrSpeechFrameCount(_ data: Data) -> Int {
        let headerLen = isAMRWB(data) ? amrWBHeader.count : (data.starts(with: amrNBHeader) ? amrNBHeader.count : 0)
        guard headerLen > 0, data.count > headerLen else { return 0 }
        let sizes = isAMRWB(data) ? amrWBFrameBytes : amrNBFrameBytes
        var off = headerLen
        var frames = 0
        while off < data.count {
            let toc = data[data.startIndex + off]
            let ft = Int((toc >> 3) & 0x0F)
            // `P` padding bit is bit 0 of the TOC; `FT` 12-14 are used for other purposes, 15 = "no data".
            if ft == 15 { break }
            let frameLen = 1 + (ft < sizes.count ? sizes[ft] : 0)
            guard ft < sizes.count, off + frameLen <= data.count else { break }
            frames += 1
            off += frameLen
        }
        return frames
    }

    /// Nominal duration in milliseconds derived from the RFC 4867 frame walk (20 ms per frame).
    public static func estimatedAmrDurationMs(_ data: Data) -> Int {
        amrSpeechFrameCount(data) * 20
    }

    /// Sniffs common audio containers by magic bytes and returns the canonical file extension,
    /// or `nil` when the payload is unrecognized.
    public static func sniffAudioFileExtension(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        if isAMR(data) { return "amr" }
        // ADTS AAC syncword `0xFFF` (MPEG-4) / `0xFFE`-family — `.aac` ADTS stream.
        if b0 == 0xFF, (b1 & 0xF0) == 0xF0, (b1 & 0x06) == 0 { return "aac" }
        if data.count >= 12, String(decoding: data[data.startIndex + 4..<data.startIndex + 8], as: UTF8.self) == "ftyp" {
            return "m4a"
        }
        if data.count >= 3, String(decoding: data[data.startIndex..<data.startIndex + 3], as: UTF8.self) == "ID3" {
            return "mp3"
        }
        // MPEG-1/2 Layer III frame sync (`0xFB`, `0xF3`, `0xE3` — no ID3 tag present).
        if b0 == 0xFF, b1 == 0xFB || b1 == 0xF3 || b1 == 0xE3 { return "mp3" }
        if data.count >= 4, String(decoding: data[data.startIndex..<data.startIndex + 4], as: UTF8.self) == "RIFF" {
            return "wav"
        }
        if data.count >= 4, String(decoding: data[data.startIndex..<data.startIndex + 4], as: UTF8.self) == "caff" {
            return "caf"
        }
        if data.count >= 4, String(decoding: data[data.startIndex..<data.startIndex + 4], as: UTF8.self) == "OggS" {
            return "ogg"
        }
        return nil
    }

    /// Returns playback-ready audio for `AVPlayer`/`AVAudioPlayer`:
    /// - AMR payloads are transcoded to WAV PCM16 when the OS decoder is available, otherwise
    ///   returned untouched with the `.amr` extension so callers can fall back gracefully.
    /// - Recognized containers pass through with their canonical extension.
    /// - Unrecognized payloads pass through with `fallbackExtension` (default `.aac` for Zalo voice).
    public static func preparePlayableAudio(
        data: Data,
        fallbackExtension: String = "aac"
    ) -> (data: Data, fileExtension: String) {
        guard !data.isEmpty else {
            let clean = fallbackExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            return (data, clean.isEmpty ? "aac" : clean)
        }
        if isAMR(data) {
            if let wav = amrToWavPcm16(data) {
                return (wav, "wav")
            }
            return (data, "amr")
        }
        if let ext = sniffAudioFileExtension(data) {
            return (data, ext)
        }
        let clean = fallbackExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return (data, clean.isEmpty ? "aac" : clean)
    }

    /// Best-effort `AMR`/`AMR-WB` → WAV (LPCM int16) transcode using `ExtAudioFile` when the OS still
    /// ships an AMR decoder (`kAudioFormatAMR` / `kAudioFormatAMR_WB`). Returns `nil` when the codec is
    /// unavailable or the payload is malformed — never throws.
    public static func amrToWavPcm16(_ data: Data) -> Data? {
        guard isAMR(data) else { return nil }
        #if canImport(AudioToolbox)
        return transcodeAmrWithExtAudioFile(data)
        #else
        return nil
        #endif
    }

    /// Wraps decoded PCM16 mono/stereo samples into a canonical `RIFF`/`WAVE` container.
    public static func wrapPcm16AsWav(_ pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let safeRate = max(1, sampleRate)
        let safeChannels = max(1, min(channels, 2))
        let byteRate = UInt32(safeRate * safeChannels * 2)
        let blockAlign = UInt16(safeChannels * 2)
        let bitsPerSample: UInt16 = 16
        let dataLen = UInt32(truncatingIfNeeded: pcm.count)
        var out = Data(capacity: 44 + pcm.count)
        out.append(Data("RIFF".utf8))
        out.appendLE(UInt32(36 + pcm.count))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.appendLE(UInt32(16)) // fmt chunk size
        out.appendLE(UInt16(1)) // PCM
        out.appendLE(UInt16(safeChannels))
        out.appendLE(UInt32(safeRate))
        out.appendLE(byteRate)
        out.appendLE(blockAlign)
        out.appendLE(bitsPerSample)
        out.append(Data("data".utf8))
        out.appendLE(dataLen)
        out.append(pcm)
        return out
    }

    #if canImport(AudioToolbox)
    private static func transcodeAmrWithExtAudioFile(_ data: Data) -> Data? {
        let ext = isAMRWB(data) ? "awb" : "amr"
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zola-amr-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        guard (try? data.write(to: tmpURL, options: .atomic)) != nil else { return nil }

        var extRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(tmpURL as CFURL, &extRef) == noErr, let file = extRef else {
            return nil
        }
        defer { ExtAudioFileDispose(file) }

        var srcASBD = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(
            file, kExtAudioFileProperty_FileDataFormat, &propSize, &srcASBD
        ) == noErr, srcASBD.mSampleRate > 0 else {
            return nil
        }

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: srcASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * srcASBD.mChannelsPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * srcASBD.mChannelsPerFrame,
            mChannelsPerFrame: srcASBD.mChannelsPerFrame,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientASBD
        ) == noErr else {
            return nil
        }

        var pcm = Data()
        let framesPerRead: UInt32 = 8_192
        let bytesPerRead = Int(framesPerRead * clientASBD.mBytesPerFrame)
        var readBuffer = Data(count: bytesPerRead)
        var finished = false
        while !finished {
            var frameCount = framesPerRead
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: clientASBD.mChannelsPerFrame,
                    mDataByteSize: UInt32(bytesPerRead),
                    mData: nil
                )
            )
            let status: OSStatus = readBuffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                abl.mBuffers.mData = ptr.baseAddress
                return ExtAudioFileRead(file, &frameCount, &abl)
            }
            guard status == noErr else { return nil }
            if frameCount == 0 { break }
            let produced = Int(abl.mBuffers.mDataByteSize)
            if produced > 0 {
                pcm.append(readBuffer.prefix(produced))
            }
            if frameCount < framesPerRead { finished = true }
        }
        guard !pcm.isEmpty else { return nil }
        return wrapPcm16AsWav(
            pcm,
            sampleRate: Int(srcASBD.mSampleRate.rounded()),
            channels: Int(srcASBD.mChannelsPerFrame)
        )
    }
    #endif
}

/// Convenience alias kept for callers that refer to the AMR codec specifically.
public enum ZolaAMR {
    public static func isAMR(_ data: Data) -> Bool {
        ZolaAudioNormalizer.isAMR(data)
    }

    public static func isAMRWB(_ data: Data) -> Bool {
        ZolaAudioNormalizer.isAMRWB(data)
    }

    public static func amrToWavPcm16(_ data: Data) -> Data? {
        ZolaAudioNormalizer.amrToWavPcm16(data)
    }

    public static func speechFrameCount(_ data: Data) -> Int {
        ZolaAudioNormalizer.amrSpeechFrameCount(data)
    }

    public static func estimatedDurationMs(_ data: Data) -> Int {
        ZolaAudioNormalizer.estimatedAmrDurationMs(data)
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
