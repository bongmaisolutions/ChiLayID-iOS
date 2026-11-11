import Foundation
#if canImport(AVFoundation) && canImport(AudioToolbox)
import AVFoundation
import AudioToolbox
#endif

/// Pure-Swift M4A/MP4 (AAC in MP4 container) → ADTS (.aac) demuxer.
/// Zalo voice requires `.aac` (ADTS) format; iOS records AAC frames inside an `.m4a`
/// container. We demux the AAC frames and wrap each in a 7-byte ADTS header.
/// No re-encode — only container demuxing.
public enum ZolaADTS {
    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private struct Box {
        let type: String
        let start: Int
        let end: Int
    }

    private static func u32(_ buf: Data, _ off: Int) -> UInt32 {
        (UInt32(buf[off]) << 24) | (UInt32(buf[off + 1]) << 16) | (UInt32(buf[off + 2]) << 8) | UInt32(buf[off + 3])
    }

    private static func u64(_ buf: Data, _ off: Int) -> UInt64 {
        (UInt64(u32(buf, off)) << 32) | UInt64(u32(buf, off + 4))
    }

    private static func u16(_ buf: Data, _ off: Int) -> UInt16 {
        (UInt16(buf[off]) << 8) | UInt16(buf[off + 1])
    }

    private static func latin1(_ buf: Data, _ off: Int, _ len: Int) -> String {
        String(decoding: buf[off..<(off + len)].map { $0 }, as: UTF8.self)
    }

    private static func readBoxHeader(_ buf: Data, _ offset: Int, _ limitEnd: Int) -> Box? {
        guard offset >= 0, limitEnd <= buf.count, offset + 8 <= limitEnd else { return nil }
        let raw32 = u32(buf, offset)
        let type = latin1(buf, offset + 4, 4)
        let maxRemaining = limitEnd - offset
        var size: Int
        var headerSize = 8
        if raw32 == 1 {
            guard maxRemaining >= 16 else { return nil }
            let raw64 = u64(buf, offset + 8)
            guard raw64 >= 16, raw64 <= UInt64(maxRemaining) else { return nil }
            size = Int(raw64)
            headerSize = 16
        } else if raw32 == 0 {
            size = maxRemaining
        } else {
            guard raw32 <= UInt32(maxRemaining) else { return nil }
            size = Int(raw32)
        }
        guard size >= headerSize, size <= maxRemaining else { return nil }
        return Box(type: type, start: offset + headerSize, end: offset + size)
    }

    private static func findChildBoxes(_ buf: Data, _ start: Int, _ end: Int, _ wantedType: String) -> [Box] {
        var boxes: [Box] = []
        var off = start
        while off < end {
            guard let box = readBoxHeader(buf, off, end) else { break }
            if box.type == wantedType { boxes.append(box) }
            off = box.end
        }
        return boxes
    }

    private static func findContainerChild(_ buf: Data, _ start: Int, _ end: Int, _ wantedType: String) -> Box? {
        findChildBoxes(buf, start, end, wantedType).first
    }

    private static func findBoxRecursive(_ buf: Data, _ start: Int, _ end: Int, _ wantedType: String, _ depth: Int = 0) -> Box? {
        guard depth <= 4 else { return nil }
        var off = start
        while off < end {
            guard let box = readBoxHeader(buf, off, end) else { break }
            if box.type == wantedType {
                return box
            }
            if box.type == "wave" {
                if let nested = findBoxRecursive(buf, box.start, box.end, wantedType, depth + 1) {
                    return nested
                }
            }
            off = box.end
        }
        return nil
    }

    // Walk ES descriptor tree to find DecSpecificInfo (tag 0x05).
    private static func parseAudioSpecificConfig(_ buf: Data, _ start: Int, _ end: Int, _ depth: Int = 0) -> Data? {
        guard depth <= 8 else { return nil }
        var off = start
        while off + 2 <= end {
            let tag = buf[off]
            off += 1
            var size = 0
            var lenBytes = 0
            while off < end && lenBytes < 4 {
                let b = buf[off]
                off += 1
                lenBytes += 1
                size = (size << 7) | Int(b & 0x7f)
                if (b & 0x80) == 0 { break }
            }
            let payloadEnd = min(off + size, end)
            if tag == 0x05 {
                // Data slices keep the parent's indices — copy so the ASC parser can index from 0.
                return Data(buf[off..<payloadEnd])
            }
            if tag == 0x03 {
                if off + 3 <= payloadEnd {
                    let flags = buf[off + 2]
                    var innerOff = off + 3
                    if (flags & 0x80) != 0 {
                        innerOff += 2
                    }
                    if (flags & 0x40) != 0 {
                        if innerOff < payloadEnd {
                            let urlLen = Int(buf[innerOff])
                            innerOff += 1 + urlLen
                        } else {
                            innerOff = payloadEnd
                        }
                    }
                    if (flags & 0x20) != 0 {
                        innerOff += 2
                    }
                    if innerOff < payloadEnd,
                       let found = parseAudioSpecificConfig(buf, innerOff, payloadEnd, depth + 1)
                    {
                        return found
                    }
                }
            } else if tag == 0x04 {
                if off + 13 < payloadEnd,
                   let found = parseAudioSpecificConfig(buf, off + 13, payloadEnd, depth + 1)
                {
                    return found
                }
            }
            off = payloadEnd
        }
        return nil
    }

    // AudioSpecificConfig: 5 bits audioObjectType, 4 bits freqIdx (or 24-bit freq), 4 bits channelConfig
    private static func parseAsc(_ asc: Data?) -> (aot: Int, freqIdx: Int, chanCfg: Int)? {
        guard let asc, !asc.isEmpty else { return nil }
        var pos = 0
        func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byteIndex = pos >> 3
                let byte = byteIndex < asc.count ? Int(asc[byteIndex]) : 0
                v = (v << 1) | ((byte >> (7 - (pos & 7))) & 1)
                pos += 1
            }
            return v
        }
        var aot = read(5)
        if aot == 31 {
            aot = 32 + read(6)
        }
        var freqIdx = read(4)
        if freqIdx == 15 {
            let explicitRate = read(24)
            freqIdx = sampleRates.firstIndex(of: explicitRate) ?? -1
        }
        let chanCfg = read(4)
        if aot == 5 || aot == 29 {
            let extFreqIdx = read(4)
            if extFreqIdx == 15 {
                _ = read(24)
            }
            var coreAot = read(5)
            if coreAot == 31 {
                coreAot = 32 + read(6)
            }
            if coreAot >= 1 && coreAot <= 4 {
                aot = coreAot
            } else {
                aot = 2
            }
        }
        return (aot, freqIdx, chanCfg)
    }

    private static func buildAdtsHeader(_ frameLen: Int, _ aot: Int, _ freqIdx: Int, _ chanCfg: Int) -> Data {
        let profile = max(0, (aot == 0 ? 2 : aot) - 1)
        let len = frameLen + 7
        var b = Data(count: 7)
        b[0] = 0xff
        b[1] = 0xf1
        b[2] = UInt8(((profile & 0x3) << 6) | ((freqIdx & 0xf) << 2) | ((chanCfg & 0x4) >> 2))
        b[3] = UInt8(((chanCfg & 0x3) << 6) | ((len >> 11) & 0x3))
        b[4] = UInt8((len >> 3) & 0xff)
        b[5] = UInt8(((len & 0x7) << 5) | 0x1f)
        b[6] = 0xfc
        return b
    }

    private static func looksLikeAdts(_ buf: Data) -> Bool {
        buf.count > 7 && buf[0] == 0xff && (buf[1] & 0xf0) == 0xf0
    }

    private static func extractAacFrames(_ buf: Data) -> (frames: [(offset: Int, size: Int)], aot: Int, freqIdx: Int, chanCfg: Int)? {
        guard let moov = findContainerChild(buf, 0, buf.count, "moov") else { return nil }
        for trak in findChildBoxes(buf, moov.start, moov.end, "trak") {
            guard let mdia = findContainerChild(buf, trak.start, trak.end, "mdia"),
                  let minf = findContainerChild(buf, mdia.start, mdia.end, "minf"),
                  let stbl = findContainerChild(buf, minf.start, minf.end, "stbl"),
                  let stsd = findContainerChild(buf, stbl.start, stbl.end, "stsd"),
                  let stsc = findContainerChild(buf, stbl.start, stbl.end, "stsc"),
                  let stsz = findContainerChild(buf, stbl.start, stbl.end, "stsz"),
                  let stco = findContainerChild(buf, stbl.start, stbl.end, "stco")
                    ?? findContainerChild(buf, stbl.start, stbl.end, "co64")
            else { continue }

            // stsd: version/flags(4) + entryCount(4) + entries
            var p = stsd.start + 4
            guard p + 4 <= stsd.end else { continue }
            let entryCount = min(Int(u32(buf, p)), 64); p += 4
            var mp4aEntry: Box? = nil
            var i = 0
            while i < entryCount && p < stsd.end {
                guard let box = readBoxHeader(buf, p, stsd.end) else { break }
                if box.type == "mp4a" { mp4aEntry = box; break }
                p = box.end
                i += 1
            }
            guard let mp4a = mp4aEntry, mp4a.start + 28 <= mp4a.end else { continue }

            let soundVersion = Int(u16(buf, mp4a.start + 8))
            let headerLen: Int
            let fallbackChannels: Int
            let fallbackSampleRate: Int
            if soundVersion == 2, mp4a.start + 64 <= mp4a.end {
                let rawStructBytes = u32(buf, mp4a.start + 28)
                let maxEntryLen = mp4a.end - mp4a.start
                if rawStructBytes >= 72, rawStructBytes - 8 <= UInt32(maxEntryLen) {
                    headerLen = Int(rawStructBytes) - 8
                } else {
                    headerLen = 64
                }
                let srDouble = Double(bitPattern: u64(buf, mp4a.start + 32))
                fallbackSampleRate = (srDouble.isFinite && srDouble > 0 && srDouble <= 1_000_000)
                    ? Int(srDouble.rounded())
                    : 44_100
                let rawCh = u32(buf, mp4a.start + 40)
                fallbackChannels = (rawCh > 0 && rawCh <= 7) ? Int(rawCh) : 1
            } else if soundVersion == 1, mp4a.start + 44 <= mp4a.end {
                headerLen = 44
                fallbackChannels = Int(u16(buf, mp4a.start + 16))
                fallbackSampleRate = Int(u16(buf, mp4a.start + 24))
            } else {
                headerLen = 28
                fallbackChannels = Int(u16(buf, mp4a.start + 16))
                fallbackSampleRate = Int(u16(buf, mp4a.start + 24))
            }
            let childStart = mp4a.start + headerLen
            var asc: Data? = nil
            if childStart < mp4a.end,
               let esds = findBoxRecursive(buf, childStart, mp4a.end, "esds"),
               esds.start + 4 <= esds.end
            {
                asc = parseAudioSpecificConfig(buf, esds.start + 4, esds.end)
            }
            var aot = 2, freqIdx = -1, chanCfg = -1
            if let parsed = parseAsc(asc) {
                aot = (parsed.aot >= 1 && parsed.aot <= 4) ? parsed.aot : 2
                freqIdx = parsed.freqIdx
                chanCfg = parsed.chanCfg
            }
            if freqIdx < 0 || freqIdx >= sampleRates.count {
                freqIdx = sampleRates.firstIndex(of: fallbackSampleRate) ?? 4
            }
            if chanCfg <= 0 || chanCfg > 7 {
                chanCfg = (fallbackChannels > 0 && fallbackChannels <= 7) ? fallbackChannels : 1
            }

            // stsz: sampleSize(4) + sampleCount(4) + sizes[]
            p = stsz.start + 4
            guard p + 8 <= stsz.end else { continue }
            let uniformSize = Int(u32(buf, p)); p += 4
            let sampleCount = Int(u32(buf, p)); p += 4
            guard sampleCount > 0 && sampleCount <= 100_000 else { return nil }
            var sampleSizes = [Int](repeating: 0, count: sampleCount)
            if uniformSize > 0 {
                for idx in 0..<sampleCount { sampleSizes[idx] = uniformSize }
            } else {
                for idx in 0..<sampleCount {
                    guard p + 4 <= stsz.end else { return nil }
                    sampleSizes[idx] = Int(u32(buf, p)); p += 4
                }
            }

            // stsc: entries [firstChunk, samplesPerChunk, descIndex]
            p = stsc.start + 4
            guard p + 4 <= stsc.end else { continue }
            let stscCount = Int(u32(buf, p)); p += 4
            var stscEntries: [(firstChunk: Int, samplesPerChunk: Int)] = []
            for _ in 0..<stscCount {
                guard p + 12 <= stsc.end else { break }
                stscEntries.append((Int(u32(buf, p)), Int(u32(buf, p + 4))))
                p += 12
            }
            guard !stscEntries.isEmpty else { continue }

            // chunk offsets
            let isCo64 = latin1(buf, stco.start - 4, 4) == "co64"
            p = stco.start + 4
            guard p + 4 <= stco.end else { continue }
            let rawChunkCount = u32(buf, p); p += 4
            guard rawChunkCount > 0, rawChunkCount <= 100_000 else { continue }
            let chunkCount = Int(rawChunkCount)
            var chunkOffsets = [Int](repeating: 0, count: chunkCount)
            var validChunks = 0
            for idx in 0..<chunkCount {
                if isCo64 {
                    guard p + 8 <= stco.end else { break }
                    let rawOff = u64(buf, p); p += 8
                    guard rawOff <= UInt64(buf.count) else { return nil }
                    chunkOffsets[idx] = Int(rawOff)
                    validChunks += 1
                } else {
                    guard p + 4 <= stco.end else { break }
                    let rawOff = u32(buf, p); p += 4
                    guard rawOff <= UInt32(buf.count) else { return nil }
                    chunkOffsets[idx] = Int(rawOff)
                    validChunks += 1
                }
            }
            guard validChunks > 0 else { continue }

            var frames: [(offset: Int, size: Int)] = []
            var sampleIdx = 0
            var stscIdx = 0
            var chunk = 1
            while chunk <= validChunks {
                while stscIdx + 1 < stscEntries.count && stscEntries[stscIdx + 1].firstChunk <= chunk {
                    stscIdx += 1
                }
                let spc = stscEntries[stscIdx].samplesPerChunk
                var off = chunkOffsets[chunk - 1]
                var s = 0
                while s < spc && sampleIdx < sampleCount {
                    let sz = sampleSizes[sampleIdx]
                    guard off >= 0, sz >= 0, sz <= buf.count - off else { return nil }
                    frames.append((off, sz))
                    off += sz
                    sampleIdx += 1
                    s += 1
                }
                chunk += 1
            }
            guard !frames.isEmpty else { continue }
            return (frames, aot, freqIdx, chanCfg)
        }
        return nil
    }

    /// Converts an M4A/MP4 buffer with AAC frames into ADTS `.aac` data.
    /// Returns `nil` if input is not a parseable AAC-in-MP4 file; passes through ADTS input unchanged.
    public static func m4aToAdtsAac(_ rawBuf: Data) -> Data? {
        let buf = rawBuf.startIndex == 0 ? rawBuf : Data(rawBuf)
        guard buf.count >= 32 else { return nil }
        if looksLikeAdts(buf) { return buf }
        guard let ftyp = readBoxHeader(buf, 0, buf.count), ftyp.type == "ftyp" else { return nil }
        guard let track = extractAacFrames(buf) else { return nil }
        var out = Data()
        out.reserveCapacity(track.frames.reduce(0) { $0 + $1.size + 7 })
        for f in track.frames {
            out.append(buildAdtsHeader(f.size, track.aot, track.freqIdx, track.chanCfg))
            out.append(buf[f.offset..<(f.offset + f.size)])
        }
        return out
    }

    /// Converts ANY decodable audio payload (`.m4a`, `.aac` ADTS, `.wav`, `.caf`, `.mp3`, …) into
    /// a canonical ADTS `.aac` stream (`0xFF 0xF1` sync) for Zalo voice upload.
    ///
    /// Fast path: `m4aToAdtsAac` demuxes AAC-in-MP4 / passes ADTS through unchanged. When that fails
    /// (LinearPCM `.caf`/`.wav`, `.mp3`, exotic `.m4a` layouts) the payload is decoded to LPCM and
    /// re-encoded to `kAudioFormatMPEG4AAC` inside an `kAudioFileAAC_ADTSType` file via `ExtAudioFile`.
    /// Returns `nil` only when the input is truly undecodable — never throws.
    public static func convertToAdtsData(_ inputData: Data) async -> Data? {
        if let direct = m4aToAdtsAac(inputData) { return direct }
        #if canImport(AVFoundation) && canImport(AudioToolbox)
        return await Task.detached(priority: .userInitiated) {
            Self.transcodeToAdtsWithExtAudioFile(inputData)
        }.value
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation) && canImport(AudioToolbox)
    /// `ExtAudioFile` transcode pipeline: source bytes -> temp file -> LPCM int16 client format ->
    /// `kAudioFileAAC_ADTSType` output file carrying `kAudioFormatMPEG4AAC`. The intermediate `.aac`
    /// file is already ADTS-framed, so its bytes are returned verbatim.
    private static func transcodeToAdtsWithExtAudioFile(_ inputData: Data) -> Data? {
        let fm = FileManager.default
        let sniffedExt = ZolaAudioNormalizer.sniffAudioFileExtension(inputData) ?? "dat"
        let inURL = fm.temporaryDirectory.appendingPathComponent("zola-voice-in-\(UUID().uuidString).\(sniffedExt)")
        let outURL = fm.temporaryDirectory.appendingPathComponent("zola-voice-out-\(UUID().uuidString).aac")
        defer {
            try? fm.removeItem(at: inURL)
            try? fm.removeItem(at: outURL)
        }
        guard (try? inputData.write(to: inURL, options: .atomic)) != nil else { return nil }

        var inRef: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(inURL as CFURL, &inRef) == noErr, let inFile = inRef else { return nil }
        defer { ExtAudioFileDispose(inFile) }

        var srcASBD = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(inFile, kExtAudioFileProperty_FileDataFormat, &propSize, &srcASBD) == noErr,
              srcASBD.mSampleRate >= 8_000, srcASBD.mChannelsPerFrame > 0
        else { return nil }

        // AAC-LC legal sample rates; clamp the source rate into the nearest legal bucket.
        let legalRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        let outRate = legalRates.min(by: { abs($0 - srcASBD.mSampleRate) < abs($1 - srcASBD.mSampleRate) }) ?? 44_100
        let outChannels = min(UInt32(srcASBD.mChannelsPerFrame), 2)

        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: srcASBD.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * outChannels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * outChannels,
            mChannelsPerFrame: outChannels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let clientSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileSetProperty(inFile, kExtAudioFileProperty_ClientDataFormat, clientSize, &clientASBD) == noErr else {
            return nil
        }

        var outASBD = AudioStreamBasicDescription(
            mSampleRate: outRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: outChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outRef: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(
            outURL as CFURL,
            kAudioFileAAC_ADTSType,
            &outASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outRef
        ) == noErr, let outFile = outRef else {
            return nil
        }
        // All exit paths funnel through `pumpWriter` then a single `ExtAudioFileDispose` so the
        // output file is flushed exactly once before its bytes are read back.
        let pumpWriter: () -> Bool = {
            // Keep `writerClientASBD == clientASBD` (exact source PCM sample rate & `outChannels`) so
            // `ExtAudioFileWrite` performs accurate internal sample-rate conversion into `outRate` AAC.
            var writerClientASBD = clientASBD
            guard ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat, clientSize, &writerClientASBD) == noErr else {
                return false
            }

            let framesPerRead: UInt32 = 8_192
            let bytesPerRead = Int(framesPerRead * clientASBD.mBytesPerFrame)
            var readBuffer = Data(count: bytesPerRead)
            var writeFailed = false
            while !writeFailed {
                var frameCount = framesPerRead
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: clientASBD.mChannelsPerFrame,
                        mDataByteSize: UInt32(bytesPerRead),
                        mData: nil
                    )
                )
                let readStatus: OSStatus = readBuffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
                    abl.mBuffers.mData = ptr.baseAddress
                    return ExtAudioFileRead(inFile, &frameCount, &abl)
                }
                guard readStatus == noErr else { return false }
                if frameCount == 0 { break }
                let writeStatus: OSStatus = abl.mBuffers.mData.map { _ in
                    withUnsafePointer(to: &abl) { ablPtr in
                        ExtAudioFileWrite(outFile, frameCount, ablPtr)
                    }
                } ?? -1
                if writeStatus != noErr { writeFailed = true }
                if frameCount < framesPerRead { break }
            }
            return !writeFailed
        }

        let pumped = pumpWriter()
        let disposed = ExtAudioFileDispose(outFile)
        guard pumped, disposed == noErr else { return nil }
        guard let adts = try? Data(contentsOf: outURL), adts.count > 7, adts[adts.startIndex] == 0xFF else {
            return nil
        }
        return adts
    }
    #endif

    /// Computes normalized integer waveform bars (`10...96`) from ADTS `.aac` or `.m4a` AAC data
    /// for Zalo's `chat.voice` `param.waveformSamples` field.
    public static func extractWaveformSamples(_ rawBuf: Data, barCount: Int = 24) -> [Int] {
        guard barCount > 0, !rawBuf.isEmpty else { return [] }
        let buf = rawBuf.startIndex == 0 ? rawBuf : Data(rawBuf)
        let adts: Data
        if looksLikeAdts(buf) {
            adts = buf
        } else if let converted = m4aToAdtsAac(buf) {
            adts = converted
        } else {
            return []
        }
        guard adts.count >= 8 else { return [] }

        var frameEnergies: [Double] = []
        var off = 0
        while off + 7 <= adts.count {
            guard adts[off] == 0xff, (adts[off + 1] & 0xf0) == 0xf0 else {
                off += 1
                continue
            }
            let hasCrc = (adts[off + 1] & 0x01) == 0
            let headerLen = hasCrc ? 9 : 7
            let frameLen = ((Int(adts[off + 3] & 0x03) << 11) | (Int(adts[off + 4]) << 3) | (Int(adts[off + 5]) >> 5))
            guard frameLen > headerLen, off + frameLen <= adts.count else { break }

            let payloadLen = frameLen - headerLen
            let pStart = off + headerLen
            let pEnd = off + frameLen
            let step = max(1, payloadLen / 32)
            var devSum = 0
            var sampleCount = 0
            var idx = pStart
            while idx < pEnd {
                devSum += abs(Int(adts[idx]) - 128)
                sampleCount += 1
                idx += step
            }
            let avgDev = sampleCount > 0 ? Double(devSum) / Double(sampleCount) : 0
            frameEnergies.append(Double(payloadLen) * 0.7 + avgDev * 0.8)
            off += frameLen
        }
        guard !frameEnergies.isEmpty else { return [] }

        var buckets = [Double](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let startIdx = (i * frameEnergies.count) / barCount
            let endIdx = max(startIdx + 1, ((i + 1) * frameEnergies.count) / barCount)
            let clampedStart = min(startIdx, frameEnergies.count - 1)
            let clampedEnd = min(max(clampedStart + 1, endIdx), frameEnergies.count)
            var sum = 0.0
            for j in clampedStart..<clampedEnd {
                sum += frameEnergies[j]
            }
            buckets[i] = sum / Double(clampedEnd - clampedStart)
        }

        let minE = buckets.min() ?? 0
        let maxE = buckets.max() ?? 0
        if maxE - minE < 1.0 {
            let flat = min(96, max(12, Int((maxE / 3.0).rounded())))
            return [Int](repeating: flat, count: barCount)
        }
        return buckets.map { val in
            let scaled = 12.0 + ((val - minE) / (maxE - minE)) * 84.0
            return min(96, max(10, Int(scaled.rounded())))
        }
    }
}
