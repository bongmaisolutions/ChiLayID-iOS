import CommonCrypto
import CryptoKit
import Foundation
import zlib

extension Data {
    mutating func appendInt8(_ v: Int8) {
        append(UInt8(bitPattern: v))
    }

    mutating func appendUInt8(_ v: UInt8) {
        append(v)
    }

    mutating func appendInt16LE(_ v: Int16) {
        let u = UInt16(bitPattern: v)
        append(UInt8(u & 0xFF))
        append(UInt8((u >> 8) & 0xFF))
    }

    mutating func appendUInt16LE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendInt32LE(_ v: Int32) {
        let u = UInt32(bitPattern: v)
        appendUInt32LE(u)
    }

    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    mutating func appendInt64LE(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8((u >> shift) & 0xFF))
        }
    }

    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw ZolaError.crypto("Out-of-bounds u16 read") }
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1]) << 8
        return b0 | b1
    }

    func readInt16LE(at offset: Int) throws -> Int16 {
        Int16(bitPattern: try readUInt16LE(at: offset))
    }

    func readUInt32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw ZolaError.crypto("Out-of-bounds u32 read") }
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1]) << 8
        let b2 = UInt32(self[startIndex + offset + 2]) << 16
        let b3 = UInt32(self[startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func readInt32LE(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try readUInt32LE(at: offset))
    }

    func readInt64LE(at offset: Int) throws -> Int64 {
        guard offset >= 0, offset + 8 <= count else { throw ZolaError.crypto("Out-of-bounds i64 read") }
        var u: UInt64 = 0
        for i in 0..<8 {
            u |= UInt64(self[startIndex + offset + i]) << (i * 8)
        }
        return Int64(bitPattern: u)
    }
}

public struct ZolaFailoverFrame: Sendable, Equatable {
    public let frameBytes: Data
    public let cmd: Int16
    public let subCmd: Int8
    public let frameSize: UInt32
    public let dataLength: Int
    public let checksum: UInt32
}

public struct ZolaUnpackedFailoverFrame: Sendable, Equatable {
    public let frameSize: UInt32
    public let version: Int8
    public let checksum: UInt32
    public let srcId: Int32
    public let cmd: Int16
    public let subCmd: Int8
    public let sessionKey: String
    public let desId: Int32
    public let globalMsgId: Int64
    public let bodyData: Data
}

public struct ZolaChatElementFrame: Sendable, Equatable {
    public let payload: Data
    public let frameSize: UInt32
    public let checksum: UInt32
    public let headerLength: Int
}

public struct ZolaUnpackedChatElement: Sendable, Equatable {
    public let frameSize: UInt32
    public let version: Int8
    public let checksum: UInt32
    public let needAck: UInt8
    public let msgType: Int8
    public let seqId: Int32
    public let srcId: Int32
    public let srcType: Int8
    public let cmd: Int16
    public let subCmd: Int8
    public let desId: Int32
    public let desType: Int8
    public let globalMsgId: Int64
    public let bodyData: Data
    public let retCode: Int32
    public let decodedBodyData: Data

    public init(
        frameSize: UInt32,
        version: Int8,
        checksum: UInt32,
        needAck: UInt8,
        msgType: Int8,
        seqId: Int32,
        srcId: Int32,
        srcType: Int8,
        cmd: Int16,
        subCmd: Int8,
        desId: Int32 = 0,
        desType: Int8 = 0,
        globalMsgId: Int64 = 0,
        bodyData: Data,
        retCode: Int32 = 0,
        decodedBodyData: Data? = nil
    ) {
        self.frameSize = frameSize
        self.version = version
        self.checksum = checksum
        self.needAck = needAck
        self.msgType = msgType
        self.seqId = seqId
        self.srcId = srcId
        self.srcType = srcType
        self.cmd = cmd
        self.subCmd = subCmd
        self.desId = desId
        self.desType = desType
        self.globalMsgId = globalMsgId
        self.bodyData = bodyData
        self.retCode = retCode
        self.decodedBodyData = decodedBodyData ?? bodyData
    }

    /// Parses `decodedBodyData` (gunzipped or plain UTF-8 JSON) into a dictionary (`ChatElement jsonDataToDictionary` at `0x103b90d04`).
    public func parseJSONDictionary() -> [String: Any]? {
        guard !decodedBodyData.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: decodedBodyData)) as? [String: Any]
    }
}

public enum ZolaCrypto {
    public static let zeroIV16 = Data(repeating: 0, count: 16)

    public static func md5Hex(_ string: String) -> String {
        md5Hex(Data(string.utf8))
    }

    public static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex8(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    public static func hex(_ data: Data, uppercase: Bool = false) -> String {
        let fmt = uppercase ? "%02X" : "%02x"
        return data.map { String(format: fmt, $0) }.joined()
    }

    public static func unhex(_ hexString: String) throws -> Data {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let utf8 = Array(trimmed.utf8)
        guard utf8.count % 2 == 0 else {
            throw ZolaError.crypto("Odd hex length (\(utf8.count))")
        }
        var out = Data(capacity: utf8.count / 2)
        for i in stride(from: 0, to: utf8.count, by: 2) {
            guard let s = String(bytes: [utf8[i], utf8[i + 1]], encoding: .utf8),
                  let byte = UInt8(s, radix: 16) else {
                throw ZolaError.crypto("Invalid hex character at index \(i)")
            }
            out.append(byte)
        }
        return out
    }

    public static func aesCBC(
        _ input: Data,
        key: Data,
        iv: Data = zeroIV16,
        decrypt: Bool = false,
        pkcs7Padding: Bool = true
    ) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else {
            throw ZolaError.crypto("Invalid AES key (\(key.count)) or IV (\(iv.count)) length")
        }
        if !pkcs7Padding && input.count % kCCBlockSizeAES128 != 0 {
            throw ZolaError.crypto("Unpadded AES input must be 16-byte aligned")
        }
        if decrypt && (input.isEmpty || input.count % kCCBlockSizeAES128 != 0) {
            throw ZolaError.crypto("AES ciphertext must be non-empty 16-byte multiple")
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            input.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(pkcs7Padding ? kCCOptionPKCS7Padding : 0),
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress,
                            input.count,
                            outBuf.baseAddress,
                            capacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ZolaError.crypto("CCCrypt failed with status \(status)")
        }
        output.count = moved
        return output
    }

    public static func aesECB(
        _ input: Data,
        key: Data,
        decrypt: Bool = false,
        pkcs7Padding: Bool = true
    ) throws -> Data {
        guard [16, 24, 32].contains(key.count) else {
            throw ZolaError.crypto("Invalid AES-ECB key (\(key.count)) length")
        }
        if !pkcs7Padding && input.count % kCCBlockSizeAES128 != 0 {
            throw ZolaError.crypto("Unpadded AES-ECB input must be 16-byte aligned")
        }
        if decrypt && (input.isEmpty || input.count % kCCBlockSizeAES128 != 0) {
            throw ZolaError.crypto("AES-ECB ciphertext must be non-empty 16-byte multiple")
        }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let options = CCOptions((pkcs7Padding ? kCCOptionPKCS7Padding : 0) | kCCOptionECBMode)
        let status = output.withUnsafeMutableBytes { outBuf in
            input.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBuf.baseAddress,
                        key.count,
                        nil,
                        inBuf.baseAddress,
                        input.count,
                        outBuf.baseAddress,
                        capacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ZolaError.crypto("CCCrypt ECB failed with status \(status)")
        }
        output.count = moved
        return output
    }

    /// Decrypts inner `identifier` (`simpleInfo`, AES-128-ECB PKCS#7) and `zotp` (`decryptZOTP:withKey:` `0x101384fa4`,
    /// AES-128-CBC zero-IV PKCS#7) hex fields using the 16-byte `zcid` prefix.
    public static func decryptZCIDPrefixECB(_ hexBlob: String, zcid: String) throws -> [String: Any] {
        let ct = try unhex(hexBlob)
        let stripped = zcid.hasPrefix("1_") ? String(zcid.dropFirst(2)) : zcid
        let candidates = [
            Data(String(zcid.prefix(16)).utf8),
            Data(String(stripped.prefix(16)).utf8),
        ]
        for key in candidates where key.count == 16 {
            if let pt = try? aesCBC(ct, key: key, iv: zeroIV16, decrypt: true, pkcs7Padding: true) {
                let raw = gunzipOrInflate(pt) ?? pt
                if let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                    return obj
                }
            }
            if let pt = try? aesECB(ct, key: key, decrypt: true, pkcs7Padding: true) {
                let raw = gunzipOrInflate(pt) ?? pt
                if let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
                    return obj
                }
            }
        }
        throw ZolaError.crypto("Unable to decrypt ZCID prefix payload")
    }

    public static func encryptZCIDPrefixECB(_ inner: [String: Any], zcid: String) throws -> String {
        let key = Data(String(zcid.prefix(16)).utf8)
        guard key.count == 16 else {
            throw ZolaError.crypto("zcid prefix shorter than 16 bytes")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys, .withoutEscapingSlashes])
        let ct = try aesECB(jsonData, key: key, decrypt: false, pkcs7Padding: true)
        return hex(ct, uppercase: false)
    }

    /// Encrypts multi-block `zotp` payloads matching `-[StartupFlowManager decryptZOTP:withKey:]` (`0x101384fa4`, AES-128-CBC zero-IV PKCS#7).
    public static func encryptZCIDPrefixCBC(_ inner: [String: Any], zcid: String) throws -> String {
        let key = Data(String(zcid.prefix(16)).utf8)
        guard key.count == 16 else {
            throw ZolaError.crypto("zcid prefix shorter than 16 bytes")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys, .withoutEscapingSlashes])
        let ct = try aesCBC(jsonData, key: key, iv: zeroIV16, decrypt: false, pkcs7Padding: true)
        return hex(ct, uppercase: false)
    }

    /// Derive 32-byte ASCII parameter key from `zcid` (16 even chars forward + 16 odd chars reversed).
    public static func paramKey(zcid: String) throws -> Data {
        let stripped = zcid.hasPrefix("1_") ? String(zcid.dropFirst(2)) : zcid
        let chars = Array(stripped)
        guard chars.count >= 32 else {
            throw ZolaError.crypto("zcid too short (\(chars.count))")
        }
        let even = chars.indices.filter { $0 % 2 == 0 }.prefix(16).map { chars[$0] }
        let odd = chars.indices.reversed().filter { $0 % 2 == 1 }.prefix(16).map { chars[$0] }
        let keyData = Data(String(even + odd).utf8)
        guard keyData.count == 32 else {
            throw ZolaError.crypto("Derived paramKey length != 32")
        }
        return keyData
    }

    public static func platformString(shortModel: String, osVersion: String, jailbroken: Bool = false) -> String {
        let cleanModel = shortModel
            .replacingOccurrences(of: ",", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOS = osVersion
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = cleanModel.isEmpty ? ZolaConstants.defaultShortModel : cleanModel
        let resolvedOS = cleanOS.isEmpty ? ZolaConstants.defaultIOSVersion : cleanOS
        return "\(resolvedModel)_@\(resolvedOS)_@\(jailbroken ? "JB" : "NJ")"
    }

    public static func pad0A(_ data: Data) -> Data {
        let rem = 16 - (data.count % 16)
        return data + Data(repeating: 0x0A, count: rem)
    }

    /// Generates `1_<HEX>` client `zcid` matching Zalo 261002 (`0x1000ab604`–`0x1000ab638`: AES-256-CBC zero-IV with `kCCOptionPKCS7Padding`).
    public static func generateZCID(
        idfa: String,
        platform: String,
        timestampMs: Int64,
        identityCipherKey: String = ZolaConstants.defaultIdentityCipherKey
    ) throws -> String {
        let cleanIDFA = idfa.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPlatform = platform.replacingOccurrences(of: ",", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let pt = Data("\(cleanIDFA),\(cleanPlatform),\(timestampMs)".utf8)
        let ct = try aesCBC(pt, key: Data(identityCipherKey.utf8), iv: zeroIV16, decrypt: false, pkcs7Padding: true)
        return "1_" + hex(ct, uppercase: true)
    }

    /// Recovers `(imei, platform)` from an encrypted `zcid` (`1_<hex>`), supporting both standard PKCS#7 and legacy `0x0A` padding.
    public static func extractZCIDIdentity(
        zcid: String,
        identityCipherKey: String = ZolaConstants.defaultIdentityCipherKey
    ) -> (imei: String, platform: String) {
        let fallbackPlatform = platformString(
            shortModel: ZolaConstants.defaultShortModel,
            osVersion: ZolaConstants.defaultIOSVersion,
            jailbroken: false
        )
        let stripped = zcid.hasPrefix("1_") ? String(zcid.dropFirst(2)) : zcid
        guard stripped.count >= 32,
              let ct = try? unhex(stripped),
              ct.count % 16 == 0
        else {
            return (ZolaConstants.defaultIDFA, fallbackPlatform)
        }
        let keyData = Data(identityCipherKey.utf8)
        let decrypted: Data? =
            (try? aesCBC(ct, key: keyData, iv: zeroIV16, decrypt: true, pkcs7Padding: true))
            ?? (try? aesCBC(ct, key: keyData, iv: zeroIV16, decrypt: true, pkcs7Padding: false))
        guard var plain = decrypted else {
            return (ZolaConstants.defaultIDFA, fallbackPlatform)
        }
        while let last = plain.last, last <= 0x20 {
            plain.removeLast()
        }
        guard let rawStr = String(data: plain, encoding: .utf8) else {
            return (ZolaConstants.defaultIDFA, fallbackPlatform)
        }
        let parts = rawStr.split(separator: ",").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return (ZolaConstants.defaultIDFA, fallbackPlatform)
        }
        return (parts[0], parts[1])
    }

    /// Builds the Zalo iOS Native `User-Agent` matching the `zcid`'s embedded `<shortModel>_@<osVersion>_@NJ` platform string.
    /// Existing sessions using `defaultProfile.zcid` (or non-native fallback) yield `ZolaConstants.userAgentNative` byte-for-byte.
    public static func userAgent(forZCID zcid: String, scale: String? = nil) -> String {
        let (_, platform) = extractZCIDIdentity(zcid: zcid)
        let segments = platform.components(separatedBy: "_@")
        let shortModel = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ZolaConstants.defaultShortModel
        let osVersion = (segments.count >= 2 ? segments[1] : ZolaConstants.defaultIOSVersion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isPad = shortModel.lowercased().hasPrefix("ipad")
        let family = isPad ? "iPad" : "iPhone"
        let cleanOS = osVersion.isEmpty ? ZolaConstants.defaultIOSVersion : osVersion
        let twoXShortModels: Set<String> = ["ipxr", "ip11", "ipse", "ipse2", "ipse3", "ip6", "ip6s", "ip7", "ip8"]
        let defaultScale = (isPad || twoXShortModels.contains(shortModel.lowercased())) ? "2.00" : "3.00"
        let trimmedScale = scale?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedScale = trimmedScale.isEmpty ? defaultScale : trimmedScale
        return "Zalo/261002 (\(family); iOS \(cleanOS); Scale/\(resolvedScale))"
    }

    public static func makeSignature(
        params: [String: String],
        apiSecret: String = ZolaConstants.defaultApiSecret
    ) -> String {
        let sortedKeys = params.keys
            .filter { $0 != "sig" }
            .sorted { $0.lowercased() < $1.lowercased() }
        let concat = sortedKeys.map { "\($0)=\(params[$0] ?? "")" }.joined() + apiSecret
        return md5Hex(concat)
    }

    public static func encryptZCIDParams(_ inner: [String: Any], zcid: String) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys, .withoutEscapingSlashes])
        let ct = try aesCBC(jsonData, key: try paramKey(zcid: zcid), iv: zeroIV16, decrypt: false, pkcs7Padding: true)
        return hex(ct, uppercase: true)
    }

    /// Decrypts a Mode 2 `zcid`-encrypted hex payload into either a JSON dictionary (`[String: Any]`)
    /// or a top-level JSON array (`[Any]`, e.g. `api/friend/loginfriend?`), transparently gunzipping if compressed.
    public static func decryptZCIDAny(_ hexBlob: String, zcid: String) throws -> Any {
        let ct = try unhex(hexBlob)
        let pt = try aesCBC(ct, key: try paramKey(zcid: zcid), iv: zeroIV16, decrypt: true, pkcs7Padding: true)
        let decompressed = gunzipOrInflate(pt) ?? pt
        let obj = try JSONSerialization.jsonObject(with: decompressed)
        guard obj is [String: Any] || obj is [Any] else {
            throw ZolaError.crypto("Decrypted zcid payload is neither a JSON object nor an array")
        }
        return obj
    }

    public static func decryptZCIDParams(_ hexBlob: String, zcid: String) throws -> [String: Any] {
        guard let obj = try decryptZCIDAny(hexBlob, zcid: zcid) as? [String: Any] else {
            throw ZolaError.crypto("Decrypted zcid payload is not a JSON object")
        }
        return obj
    }

    /// Pure-Foundation binary header sniffer for PNG, JPEG (SOF0..SOF15), GIF, and WebP dimensions.
    public static func sniffImageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data.prefix(65_536))
        guard b.count >= 10 else { return nil }

        // PNG: 89 50 4E 47 0D 0A 1A 0A + length(4) + "IHDR"(4) + width(4 BE) + height(4 BE)
        if b.count >= 24,
           b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47,
           b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52
        {
            let w = (Int(b[16]) << 24) | (Int(b[17]) << 16) | (Int(b[18]) << 8) | Int(b[19])
            let h = (Int(b[20]) << 24) | (Int(b[21]) << 16) | (Int(b[22]) << 8) | Int(b[23])
            return (w > 0 && h > 0 && w <= 32_768 && h <= 32_768) ? (w, h) : nil
        }

        // GIF87a / GIF89a: "GIF8" + ("7a" | "9a") + width(2 LE) + height(2 LE)
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38,
           (b[4] == 0x37 || b[4] == 0x39), b[5] == 0x61
        {
            let w = Int(b[6]) | (Int(b[7]) << 8)
            let h = Int(b[8]) | (Int(b[9]) << 8)
            return (w > 0 && h > 0 && w <= 32_768 && h <= 32_768) ? (w, h) : nil
        }

        // WebP: "RIFF".... "WEBP" + ("VP8 " | "VP8L" | "VP8X")
        if b.count >= 25,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50
        {
            if b.count >= 30,
               b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x20,
               b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A
            {
                let w = (Int(b[26]) | (Int(b[27]) << 8)) & 0x3FFF
                let h = (Int(b[28]) | (Int(b[29]) << 8)) & 0x3FFF
                return (w > 0 && h > 0) ? (w, h) : nil
            }
            if b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x4C, b[20] == 0x2F {
                let bits = UInt32(b[21]) | (UInt32(b[22]) << 8) | (UInt32(b[23]) << 16) | (UInt32(b[24]) << 24)
                let w = Int(bits & 0x3FFF) + 1
                let h = Int((bits >> 14) & 0x3FFF) + 1
                return (w > 0 && h > 0) ? (w, h) : nil
            }
            if b.count >= 30, b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x58 {
                let w = (Int(b[24]) | (Int(b[25]) << 8) | (Int(b[26]) << 16)) + 1
                let h = (Int(b[27]) | (Int(b[28]) << 8) | (Int(b[29]) << 16)) + 1
                return (w > 0 && h > 0 && w <= 32_768 && h <= 32_768) ? (w, h) : nil
            }
        }

        // JPEG: FF D8 ... SOF marker (C0..CF excluding C4, C8, CC)
        if b[0] == 0xFF, b[1] == 0xD8 {
            var pos = 2
            while pos + 1 < b.count {
                if b[pos] != 0xFF {
                    pos += 1
                    continue
                }
                while pos < b.count && b[pos] == 0xFF {
                    pos += 1
                }
                guard pos < b.count else { break }
                let marker = b[pos]
                pos += 1
                if marker == 0xD9 || marker == 0xDA { break }
                if marker == 0x00 || marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
                guard pos + 2 <= b.count else { break }
                let segLen = (Int(b[pos]) << 8) | Int(b[pos + 1])
                guard segLen >= 2, pos + segLen <= b.count else { break }
                if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                    guard segLen >= 7, pos + 7 <= b.count else { break }
                    let h = (Int(b[pos + 3]) << 8) | Int(b[pos + 4])
                    let w = (Int(b[pos + 5]) << 8) | Int(b[pos + 6])
                    return (w > 0 && h > 0 && w <= 32_768 && h <= 32_768) ? (w, h) : nil
                }
                pos += segLen
            }
        }

        return nil
    }

    // MARK: - Group Directory `isNoised=1` AES-256-CBC Codec

    public static func noisedGroupAESKey(uid: Int64, publicKey: Int64, gid: Int64? = nil) -> Data {
        let seed = gid != nil ? "\(uid)\(gid!)\(publicKey)" : "\(uid)\(publicKey)"
        return Data(md5Hex(seed).utf8)
    }

    public static func decryptNoisedGroupData(
        base64: String,
        uid: Int64,
        publicKey: Int64,
        gid: Int64? = nil
    ) throws -> [String: Any] {
        guard let ct = Data(base64Encoded: base64) else {
            throw ZolaError.crypto("Invalid Base64 in noised group payload")
        }
        let pt = try aesCBC(ct, key: noisedGroupAESKey(uid: uid, publicKey: publicKey, gid: gid), iv: zeroIV16, decrypt: true, pkcs7Padding: true)
        guard let obj = try JSONSerialization.jsonObject(with: pt) as? [String: Any] else {
            throw ZolaError.crypto("Decrypted noised group data is not a JSON object")
        }
        return obj
    }

    public static func encryptNoisedGroupData(
        _ object: [String: Any],
        uid: Int64,
        publicKey: Int64,
        gid: Int64? = nil
    ) throws -> String {
        let pt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let ct = try aesCBC(pt, key: noisedGroupAESKey(uid: uid, publicKey: publicKey, gid: gid), iv: zeroIV16, decrypt: false, pkcs7Padding: true)
        return ct.base64EncodedString()
    }

    // MARK: - Cyclic XOR & HttpSendMsgManager / ChatElement Framing

    public static func xorCyclic(_ data: Data, key: Data) -> Data {
        guard !key.isEmpty else { return data }
        let kBytes = Array(key)
        let kLen = kBytes.count
        var out = Data(capacity: data.count)
        for (idx, b) in data.enumerated() {
            out.append(b ^ kBytes[idx % kLen])
        }
        return out
    }

    public static func encryptHTTPData(
        _ payload: Data,
        srcId: Int32,
        frameSize: UInt32,
        keyData: Data = ZolaConstants.httpKeyData
    ) -> Data {
        var fsData = Data()
        fsData.appendUInt32LE(frameSize)
        var sidData = Data()
        sidData.appendInt32LE(srcId)
        let k1 = xorCyclic(keyData, key: fsData)
        let k2 = xorCyclic(k1, key: sidData)
        return xorCyclic(payload, key: k2)
    }

    public static func makeFailoverToken(
        srcId: Int64,
        length: Int,
        apiKey: String = ZolaConstants.defaultApiKey
    ) -> String {
        let pt = Data("\(srcId);\(length)".utf8)
        return xorCyclic(pt, key: Data(apiKey.utf8)).base64EncodedString()
    }

    public static func packHttpFailoverFrame(
        srcId: Int32,
        desId: Int32,
        globalMsgId: Int64,
        subCmd: Int8,
        bodyData: Data,
        sessionKey: String,
        e2ee: Bool = false,
        httpKey: Data = ZolaConstants.httpKeyData
    ) throws -> ZolaFailoverFrame {
        guard bodyData.count <= Int(UInt16.max) else {
            throw ZolaError.crypto("bodyData exceeds u16 limit (\(bodyData.count))")
        }
        let cmd: Int16 = e2ee ? 10130 : 130
        let skBytes = Data(sessionKey.utf8)
        let sessionSize = UInt16(skBytes.count)

        var innerBuf = Data()
        if !e2ee {
            innerBuf.appendInt32LE(desId)
        }
        innerBuf.appendInt64LE(globalMsgId)
        if !e2ee {
            innerBuf.appendInt8(subCmd)
            innerBuf.appendUInt16LE(UInt16(bodyData.count))
        }
        innerBuf.append(bodyData)

        let dataLen = skBytes.count + innerBuf.count + 3 - (e2ee ? 1 : 0)
        let frameSize = UInt32(dataLen + 16)
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
        if !e2ee {
            plainFrame.appendInt8(1)
        }
        plainFrame.append(innerBuf)

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

    public static func unpackHttpFailoverFrame(
        _ rawFrame: Data,
        httpKey: Data = ZolaConstants.httpKeyData
    ) throws -> ZolaUnpackedFailoverFrame {
        guard rawFrame.count >= 16 else {
            throw ZolaError.crypto("HTTP failover frame too short (\(rawFrame.count) < 16)")
        }
        let frameSize = try rawFrame.readUInt32LE(at: 0)
        let version = Int8(bitPattern: rawFrame[rawFrame.startIndex + 4])
        let checksum = try rawFrame.readUInt32LE(at: 5)
        let srcId = try rawFrame.readInt32LE(at: 9)
        let cmd = try rawFrame.readInt16LE(at: 13)
        let subCmd = Int8(bitPattern: rawFrame[rawFrame.startIndex + 15])

        guard Int(frameSize) == rawFrame.count else {
            throw ZolaError.crypto("Frame size mismatch: header=\(frameSize) actual=\(rawFrame.count)")
        }
        let expectedCsum = UInt32(truncatingIfNeeded: Int64(srcId) + Int64(cmd) + Int64(subCmd)) ^ ZolaConstants.checksumMagic
        guard checksum == expectedCsum else {
            throw ZolaError.crypto("HTTP failover checksum mismatch")
        }

        let plain = encryptHTTPData(Data(rawFrame.dropFirst(16)), srcId: srcId, frameSize: frameSize, keyData: httpKey)
        let skLen = Int(try plain.readUInt16LE(at: 0))
        guard 2 + skLen <= plain.count else {
            throw ZolaError.crypto("Truncated sessionKey in failover frame")
        }
        let sessionKey = String(decoding: plain.subdata(in: 2..<(2 + skLen)), as: UTF8.self)
        let isE2ee = cmd == 10130
        var pos = 2 + skLen
        let desId: Int32
        let globalMsgId: Int64
        let innerSubCmd: Int8
        let bodyData: Data

        if cmd == 115 {
            desId = 0
            globalMsgId = 0
            innerSubCmd = subCmd
            bodyData = pos < plain.count ? plain.subdata(in: pos..<plain.count) : Data()
        } else if !isE2ee {
            pos += 1 // i8(1)
            desId = try plain.readInt32LE(at: pos)
            globalMsgId = try plain.readInt64LE(at: pos + 4)
            innerSubCmd = Int8(bitPattern: plain[plain.startIndex + pos + 12])
            let bodyLen = Int(try plain.readUInt16LE(at: pos + 13))
            pos += 15
            guard pos + bodyLen <= plain.count else {
                throw ZolaError.crypto("Truncated bodyData in failover frame")
            }
            bodyData = plain.subdata(in: pos..<(pos + bodyLen))
        } else {
            desId = 0
            globalMsgId = try plain.readInt64LE(at: pos)
            innerSubCmd = subCmd
            bodyData = plain.subdata(in: (pos + 8)..<plain.count)
        }

        return ZolaUnpackedFailoverFrame(
            frameSize: frameSize,
            version: version,
            checksum: checksum,
            srcId: srcId,
            cmd: cmd,
            subCmd: innerSubCmd,
            sessionKey: sessionKey,
            desId: desId,
            globalMsgId: globalMsgId,
            bodyData: bodyData
        )
    }

    // MARK: - Inner TLV + `subCmd=41` `CrypKey` Codec

    /// Standard IEEE 802.3 CRC-32 checksum used by `ZaloUploadHTTPBackground` (`x-md-hv: f=1; v=<crc32>` and `crc` chunk param).
    public static func crc32(_ data: Data) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { rawBuf -> UInt32 in
            guard let base = rawBuf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            let seed = zlib.crc32(0, nil, 0)
            return UInt32(truncatingIfNeeded: zlib.crc32(seed, base, uInt(data.count)))
        }
    }

    private static func truncateUTF8Safely(_ string: String, maxBytes: Int) -> Data {
        let full = Data(string.utf8)
        guard full.count > maxBytes else { return full }
        var out = Data()
        out.reserveCapacity(maxBytes)
        for scalar in string.unicodeScalars {
            let sBytes = Data(String(scalar).utf8)
            if out.count + sBytes.count > maxBytes { break }
            out.append(sBytes)
        }
        return out
    }

    /// Encodes `QuoteData` (`TLV tag = 2` payload without the leading `0x02` tag byte) matching `ChatSocketCmdHelper` (`0x100c8883c`–`0x100c88a84`).
    public static func buildQuotePropertyData(_ quote: ZolaQuote) -> Data {
        let srvType = ZolaQuote.wireServerMsgType(forMsgType: quote.msgType, explicit: quote.serverMsgType)
        let resolvedTs = quote.tsMs > 0 ? quote.tsMs : quote.cliMsgId
        let orgBytes = truncateUTF8Safely(quote.text, maxBytes: 16_384)
        let attachBytes = truncateUTF8Safely(quote.attachJson, maxBytes: 16_384)
        var out = Data(capacity: 42 + orgBytes.count + attachBytes.count)
        out.appendInt32LE(Int32(truncatingIfNeeded: quote.ownerId))
        out.appendInt64LE(quote.cliMsgId)
        out.appendInt64LE(quote.globalMsgId)
        out.appendInt64LE(resolvedTs)
        out.appendInt16LE(srvType)
        out.appendUInt16LE(UInt16(truncatingIfNeeded: orgBytes.count))
        out.append(orgBytes)
        out.appendUInt16LE(UInt16(truncatingIfNeeded: attachBytes.count))
        out.append(attachBytes)
        out.appendInt64LE(quote.ttl)
        return out
    }

    /// Parses `QuoteData` (`TLV tag = 2` payload after consuming the `0x02` tag byte) and advances `pos`.
    public static func parseQuotePropertyData(_ data: Data, at pos: inout Int) throws -> ZolaQuote {
        guard pos + 32 <= data.count else {
            throw ZolaError.crypto("Truncated TLV tag=2 QuoteData header")
        }
        let ownerRaw = try data.readInt32LE(at: pos)
        let ownerId = ownerRaw >= 0 ? Int64(ownerRaw) : Int64(UInt32(bitPattern: ownerRaw))
        let cliMsgId = try data.readInt64LE(at: pos + 4)
        let globalMsgId = try data.readInt64LE(at: pos + 12)
        let tsMs = try data.readInt64LE(at: pos + 20)
        let srvType = try data.readInt16LE(at: pos + 28)
        let orgLen = Int(try data.readUInt16LE(at: pos + 30))
        pos += 32
        guard pos + orgLen + 2 <= data.count else {
            throw ZolaError.crypto("Truncated TLV tag=2 QuoteData orgMsg")
        }
        let orgStart = data.startIndex + pos
        let orgMsg = String(decoding: data.subdata(in: orgStart..<(orgStart + orgLen)), as: UTF8.self)
        pos += orgLen
        let attachLen = Int(try data.readUInt16LE(at: pos))
        pos += 2
        guard pos + attachLen + 8 <= data.count else {
            throw ZolaError.crypto("Truncated TLV tag=2 QuoteData attach/ttl")
        }
        let attachStart = data.startIndex + pos
        let attachJson = String(decoding: data.subdata(in: attachStart..<(attachStart + attachLen)), as: UTF8.self)
        pos += attachLen
        let ttl = try data.readInt64LE(at: pos)
        pos += 8
        return ZolaQuote(
            ownerId: ownerId,
            cliMsgId: cliMsgId,
            globalMsgId: globalMsgId,
            msgType: ZolaQuote.msgTypeFromServerMsgType(srvType),
            text: orgMsg,
            tsMs: tsMs,
            senderName: "",
            serverMsgType: srvType,
            attachJson: attachJson,
            ttl: ttl
        )
    }

    /// Encodes `MentionData` (`TLV tag = 11` payload without the leading tag byte) matching
    /// `+[ChatSocketCmdHelper createMentionDataWithDictionary:]` (`0x100c88e0c`): `u16 count`, then per item
    /// `i8 type, i16 pos, i16 len` and `i32 uid` only when `type == 0`. Little-endian host memcpy (`0x103ab1660`, `0x103ab15b8`).
    public static func buildMentionPropertyData(_ mentions: [ZolaMention]) -> Data {
        var out = Data(capacity: 2 + mentions.count * 9)
        out.appendUInt16LE(UInt16(truncatingIfNeeded: mentions.count))
        for mention in mentions {
            out.appendInt8(mention.type)
            out.appendInt16LE(Int16(truncatingIfNeeded: mention.pos))
            out.appendInt16LE(Int16(truncatingIfNeeded: mention.len))
            if mention.type == 0 {
                out.appendInt32LE(Int32(truncatingIfNeeded: mention.uid))
            }
        }
        return out
    }

    /// Parses `MentionData` (`TLV tag = 11` payload after consuming the tag byte) and advances `pos`.
    public static func parseMentionPropertyData(_ data: Data, at pos: inout Int) throws -> [ZolaMention] {
        guard pos + 2 <= data.count else {
            throw ZolaError.crypto("Truncated TLV tag=11 count")
        }
        let count = Int(try data.readUInt16LE(at: pos))
        pos += 2
        var mentions: [ZolaMention] = []
        mentions.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 5 <= data.count else { throw ZolaError.crypto("Truncated TLV tag=11 item") }
            let type = Int8(bitPattern: data[data.startIndex + pos])
            let start = Int(try data.readInt16LE(at: pos + 1))
            let length = Int(try data.readInt16LE(at: pos + 3))
            pos += 5
            var uid: Int64 = -1
            if type == 0 {
                guard pos + 4 <= data.count else { throw ZolaError.crypto("Truncated TLV tag=11 uid") }
                uid = Int64(UInt32(bitPattern: try data.readInt32LE(at: pos)))
                pos += 4
            }
            mentions.append(ZolaMention(type: type, uid: uid, pos: start, len: length))
        }
        return mentions
    }

    /// Rejects ranges the wire cannot carry (`i16` UTF-16 offsets, `i32` uid) or that fall outside `text`.
    private static func validateMentions(_ mentions: [ZolaMention], text: String) throws {
        guard mentions.count <= Int(UInt16.max) else {
            throw ZolaError.invalidArgument("Too many mentions")
        }
        let textLength = text.utf16.count
        for mention in mentions {
            guard mention.pos >= 0, mention.len > 0, mention.pos + mention.len <= textLength,
                  mention.pos <= Int(Int16.max), mention.len <= Int(Int16.max)
            else {
                throw ZolaError.invalidArgument("Mention range \(mention.pos)+\(mention.len) is outside text (UTF-16 length \(textLength))")
            }
            if mention.type == 0, !(1...Int64(UInt32.max)).contains(mention.uid) {
                throw ZolaError.invalidArgument("Mention uid must be a positive 32-bit id")
            }
        }
    }

    public static func buildTextMsgBodyData(
        text: String,
        isGroup: Bool = false,
        includeIOSProps: Bool = false,
        trackingIdHex: String? = nil,
        clientIdMs: Int64 = 0,
        containType: Int16 = 0,
        ttlMs: Int64 = 0,
        quote: ZolaQuote? = nil,
        mentions: [ZolaMention] = [],
        cryptKey: Data? = nil,
        iv16: Data? = nil,
        legacyCmd101: Bool = false
    ) throws -> (bodyData: Data, innerCmd: Int16, subCmd: Int8) {
        let utf8 = Data(text.utf8)
        var subCmd: Int8 = 1
        var msgPayload = utf8

        if !isGroup, let ck = cryptKey, !ck.isEmpty {
            let iv: Data
            if let iv16 {
                guard iv16.count == 16 else { throw ZolaError.crypto("IV must be 16 bytes") }
                iv = iv16
            } else {
                var randomBytes = [UInt8](repeating: 0, count: 16)
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
                iv = Data(randomBytes)
            }
            let ct = try aesCBC(utf8, key: ck, iv: iv, decrypt: false, pkcs7Padding: true)
            // The ciphertext length is a u16 on the wire; `UInt16(ct.count)` traps above 65535
            // (a pasted ~70KB log crashed the app). Reject it as a normal send failure instead.
            guard ct.count <= Int(UInt16.max) else {
                throw ZolaError.invalidArgument(
                    "Tin nhắn quá dài (\(utf8.count) byte). Hãy chia nhỏ tin nhắn hoặc gửi dưới dạng tệp."
                )
            }
            var mc = Data(capacity: 19 + ct.count)
            mc.appendInt8(1)
            mc.append(iv)
            mc.appendUInt16LE(UInt16(ct.count))
            mc.append(ct)
            msgPayload = mc
            subCmd = 41
        }

        var propCount: UInt8 = 0
        var props = Data()

        // `getPropertiesData:` (`0x100c87290`) always writes tag 11 first.
        if !mentions.isEmpty {
            try validateMentions(mentions, text: text)
            propCount += 1
            props.appendInt8(11)
            props.append(buildMentionPropertyData(mentions))
        }
        if let quote {
            propCount += 1
            props.appendInt8(2)
            props.append(buildQuotePropertyData(quote))
        }
        if includeIOSProps {
            // Canonical tag 0x07 (70 bytes total) matching iOS 261002802 wire format
            let extJson = Data(#"{"emoji":{"content":0},"shouldParseLinkOrContact":1}"#.utf8)
            propCount += 1
            props.appendInt8(7)
            props.appendInt8(0)
            props.appendInt64LE(-1)
            props.appendInt32LE(1)
            props.appendInt32LE(Int32(extJson.count))
            props.append(extJson)
        }
        if ttlMs > 0 {
            propCount += 1
            props.appendInt8(8)
            props.appendInt64LE(ttlMs)
        }
        if containType != 0 {
            propCount += 1
            props.appendInt8(10)
            props.appendInt16LE(containType)
        }
        if includeIOSProps {
            // Canonical tag 0x05 (94 bytes total) preserving exact iOS key order: id, ts, logSrcType, fwLvl
            let tid = trackingIdHex ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let refJson = Data(#"{"id":"\#(tid)","ts":\#(clientIdMs),"logSrcType":5,"fwLvl":0}"#.utf8)
            propCount += 1
            props.appendInt8(5)
            props.appendInt32LE(3)
            props.appendInt32LE(Int32(refJson.count))
            props.append(refJson)
        }

        if !isGroup {
            if legacyCmd101 && quote == nil {
                guard propCount == 0 else { throw ZolaError.crypto("cmd=101 cannot carry TLV properties") }
                return (msgPayload, 101, subCmd)
            }
            var out = Data(capacity: 3 + props.count + msgPayload.count)
            out.appendInt16LE(Int16(subCmd))
            out.appendUInt8(propCount)
            out.append(props)
            out.append(msgPayload)
            return (out, 113, subCmd)
        }

        if propCount == 0 {
            return (msgPayload, 201, subCmd)
        }
        var out = Data(capacity: 3 + props.count + msgPayload.count)
        out.appendInt16LE(Int16(subCmd))
        out.appendUInt8(propCount)
        out.append(props)
        out.append(msgPayload)
        return (out, 207, subCmd)
    }

    /// Builds native iOS 1-1 sticker message body (`cmd = 113, subCmd = 36` / `0x24`) matching
    /// `+[ChatSocketCmdHelper createStickerMesasge:...]` (`0x100c882fc`–`0x100c884ac`) and
    /// `+[ChatSocketCmdHelper createStickerDataWithChatEntity:]` (`0x100c87ce4`–`0x100c882f8`).
    public static func buildStickerMsgBodyData(
        stickerId: Int32,
        cateId: Int32,
        stickerType: Int8 = 7,
        quote: ZolaQuote? = nil,
        includeIOSProps: Bool = false,
        trackingIdHex: String? = nil,
        clientIdMs: Int64 = 0,
        jsonTracking: String = ""
    ) -> (bodyData: Data, innerCmd: Int16, subCmd: Int8) {
        let subCmd: Int8 = ZolaConstants.subCmdSendSticker
        var propCount: UInt8 = 0
        var props = Data()

        if let quote {
            propCount += 1
            props.appendInt8(2)
            props.append(buildQuotePropertyData(quote))
        }
        if includeIOSProps {
            let tid = trackingIdHex ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let refJson = Data(#"{"id":"\#(tid)","ts":\#(clientIdMs),"logSrcType":5,"fwLvl":0}"#.utf8)
            propCount += 1
            props.appendInt8(5)
            props.appendInt32LE(3)
            props.appendInt32LE(Int32(refJson.count))
            props.append(refJson)
        }

        let trackingBytes = Data(jsonTracking.utf8)
        var stickerPayload = Data(capacity: 13 + trackingBytes.count)
        stickerPayload.appendInt32LE(stickerId)
        stickerPayload.appendInt32LE(cateId)
        stickerPayload.appendInt8(stickerType)
        stickerPayload.appendInt32LE(Int32(trackingBytes.count))
        if !trackingBytes.isEmpty {
            stickerPayload.append(trackingBytes)
        }

        var out = Data(capacity: 3 + props.count + stickerPayload.count)
        out.appendInt16LE(Int16(subCmd))
        out.appendUInt8(propCount)
        out.append(props)
        out.append(stickerPayload)
        return (out, 113, subCmd)
    }

    /// Builds native iOS 1-1 media/voice/call-recommend message body (`cmd = 113`, `subCmd = 31` `chat.voice`,
    /// `32` `chat.photo`, `36` media, `37` doodle, `38` recommend/call bubble, `44` `chat.video.msg`, `46` file, `49` gif)
    /// matching `ChatSocketCmdHelper::createMediaChatEntity:` (`0x100c87718`) and
    /// `+[ChatElement createMesageData:withTitle:withDescription:withHref:withThumb:withChildnum:withAction:withParam:]` (`0x103b8fd20`).
    public static func buildMediaMsgBodyData(
        subCmd: Int8,
        message: String = "",
        title: String = "",
        description: String = "",
        href: String = "",
        thumb: String = "",
        childnum: Int16 = 0,
        action: String = "",
        param: String = "",
        quote: ZolaQuote? = nil,
        includeIOSProps: Bool = false,
        trackingIdHex: String? = nil,
        clientIdMs: Int64 = 0,
        extraDataJSON: String? = nil
    ) -> (bodyData: Data, innerCmd: Int16, subCmd: Int8) {
        var propCount: UInt8 = 0
        var props = Data()

        if let quote {
            propCount += 1
            props.appendInt8(2)
            props.append(buildQuotePropertyData(quote))
        }
        if includeIOSProps {
            let tid = trackingIdHex ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let refJson = Data(#"{"id":"\#(tid)","ts":\#(clientIdMs),"logSrcType":5,"fwLvl":0}"#.utf8)
            propCount += 1
            props.appendInt8(5)
            props.appendInt32LE(3)
            props.appendInt32LE(Int32(refJson.count))
            props.append(refJson)
        }
        // `-[ChatEntity getExtraDataDicToSend]` (`0x100d52b90`) → `getPropertiesData:` writes tag 16 after tag 5:
        // byte 0x10 + `integerToBytes:` Int32LE length + UTF-8 JSON (`0x100c87524`–`0x100c8755c`).
        if let extraDataJSON, !extraDataJSON.isEmpty {
            let extra = Data(extraDataJSON.utf8)
            propCount += 1
            props.appendInt8(16)
            props.appendInt32LE(Int32(extra.count))
            props.append(extra)
        }

        func clampUTF8(_ raw: String, maxBytes: Int = 8_192) -> Data {
            let bytes = Data(raw.utf8)
            guard bytes.count > maxBytes else { return bytes }
            var end = maxBytes
            while end > 0 && (bytes[bytes.startIndex + end] & 0xC0) == 0x80 {
                end -= 1
            }
            return Data(bytes.prefix(end))
        }

        let msgBytes = clampUTF8(message, maxBytes: 8_192)
        let titleBytes = clampUTF8(title, maxBytes: 2_048)
        let descBytes = clampUTF8(description, maxBytes: 4_096)
        let hrefBytes = clampUTF8(href, maxBytes: 4_096)
        let thumbBytes = clampUTF8(thumb, maxBytes: 4_096)
        let actionBytes = clampUTF8(action, maxBytes: 256)
        let paramBytes = clampUTF8(param, maxBytes: 16_384)

        var out = Data(
            capacity: 3 + props.count + msgBytes.count + 14
                + titleBytes.count + descBytes.count + hrefBytes.count
                + thumbBytes.count + actionBytes.count + paramBytes.count
        )
        out.appendInt16LE(Int16(subCmd))
        out.appendUInt8(propCount)
        out.append(props)
        out.append(msgBytes)

        out.appendInt16LE(Int16(truncatingIfNeeded: titleBytes.count))
        out.append(titleBytes)
        out.appendInt16LE(Int16(truncatingIfNeeded: descBytes.count))
        out.append(descBytes)
        out.appendInt16LE(Int16(truncatingIfNeeded: hrefBytes.count))
        out.append(hrefBytes)
        out.appendInt16LE(Int16(truncatingIfNeeded: thumbBytes.count))
        out.append(thumbBytes)
        out.appendInt16LE(childnum)
        out.appendInt16LE(Int16(truncatingIfNeeded: actionBytes.count))
        out.append(actionBytes)
        out.appendInt16LE(Int16(truncatingIfNeeded: paramBytes.count))
        out.append(paramBytes)

        return (out, 113, subCmd)
    }

    public static func decryptMcryptTextAndPropertiesBody(
        _ bodyData: Data,
        cryptKey: Data
    ) throws -> (subCmd: Int16, propCount: Int, text: String, quote: ZolaQuote?, mentions: [ZolaMention]) {
        guard bodyData.count >= 3 else {
            throw ZolaError.crypto("bodyData too short (< 3)")
        }
        let subCmd = try bodyData.readInt16LE(at: 0)
        let propCount = Int(bodyData[bodyData.startIndex + 2])
        var pos = 3
        var parsedQuote: ZolaQuote?
        var parsedMentions: [ZolaMention] = []
        for _ in 0..<propCount {
            guard pos < bodyData.count else { throw ZolaError.crypto("Truncated TLV tag") }
            let tag = bodyData[bodyData.startIndex + pos]
            pos += 1
            switch tag {
            case 2:
                parsedQuote = try parseQuotePropertyData(bodyData, at: &pos)
            case 3:
                guard pos + 2 <= bodyData.count else { throw ZolaError.crypto("Truncated TLV tag=3 count") }
                let mentionCount = Int(try bodyData.readUInt16LE(at: pos))
                pos += 2
                for _ in 0..<mentionCount {
                    guard pos + 5 <= bodyData.count else { throw ZolaError.crypto("Truncated TLV tag=3 item") }
                    let mentionType = Int8(bitPattern: bodyData[bodyData.startIndex + pos])
                    pos += 5
                    if mentionType == 0 {
                        pos += 4
                    }
                }
            case 5, 6, 9:
                guard pos + 8 <= bodyData.count else { throw ZolaError.crypto("Truncated TLV tag=\(tag)") }
                let jlen = Int(try bodyData.readInt32LE(at: pos + 4))
                guard jlen >= 0 else { throw ZolaError.crypto("Negative TLV tag=\(tag) length") }
                pos += 8 + jlen
            case 7:
                guard pos + 17 <= bodyData.count else { throw ZolaError.crypto("Truncated TLV tag=7") }
                let jlen = Int(try bodyData.readInt32LE(at: pos + 13))
                guard jlen >= 0 else { throw ZolaError.crypto("Negative TLV tag=7 length") }
                pos += 17 + jlen
            case 8:
                pos += 8
            case 10:
                pos += 2
            case 11:
                parsedMentions = try parseMentionPropertyData(bodyData, at: &pos)
            case 12, 13, 15, 16, 17:
                guard pos + 4 <= bodyData.count else { throw ZolaError.crypto("Truncated TLV tag=\(tag)") }
                let jlen = Int(try bodyData.readInt32LE(at: pos))
                guard jlen >= 0 else { throw ZolaError.crypto("Negative TLV tag=\(tag) length") }
                pos += 4 + jlen
            default:
                throw ZolaError.crypto("Unknown TLV property tag \(tag)")
            }
            guard pos <= bodyData.count else {
                throw ZolaError.crypto("TLV property overflow on tag \(tag)")
            }
        }
        let msgPayload = bodyData.subdata(in: (bodyData.startIndex + pos)..<bodyData.endIndex)
        if subCmd == 41 {
            guard msgPayload.count >= 19, msgPayload[msgPayload.startIndex] == 1 else {
                throw ZolaError.crypto("Invalid mcrypt v1 envelope")
            }
            let iv = msgPayload.subdata(in: (msgPayload.startIndex + 1)..<(msgPayload.startIndex + 17))
            let ctLen = Int(try msgPayload.readUInt16LE(at: 17))
            guard 19 + ctLen <= msgPayload.count else {
                throw ZolaError.crypto("Truncated mcrypt ciphertext")
            }
            let ct = msgPayload.subdata(in: (msgPayload.startIndex + 19)..<(msgPayload.startIndex + 19 + ctLen))
            let pt = try aesCBC(ct, key: cryptKey, iv: iv, decrypt: true, pkcs7Padding: true)
            return (subCmd, propCount, String(decoding: pt, as: UTF8.self), parsedQuote, parsedMentions)
        }
        return (subCmd, propCount, String(decoding: msgPayload, as: UTF8.self), parsedQuote, parsedMentions)
    }

    public static func decryptMcryptTextBody(
        _ bodyData: Data,
        cryptKey: Data
    ) throws -> (subCmd: Int16, propCount: Int, text: String) {
        let unpacked = try decryptMcryptTextAndPropertiesBody(bodyData, cryptKey: cryptKey)
        return (unpacked.subCmd, unpacked.propCount, unpacked.text)
    }

    /// Builds a binary HTTP failover frame for fetching queued 1-1 offline messages (`cmd = 115, subCmd = 1`).
    public static func packHttpFailoverGetOfflineFrame(
        srcId: Int32,
        sessionKey: String,
        e2ee: Bool = false,
        httpKey: Data = ZolaConstants.httpKeyData
    ) throws -> ZolaFailoverFrame {
        let cmd: Int16 = e2ee ? 10130 : 115
        let subCmd: Int8 = 1
        let skBytes = Data(sessionKey.utf8)
        let sessionSize = UInt16(skBytes.count)
        let dataLen = skBytes.count + 3 + (e2ee ? 8 : 0)
        let frameSize = UInt32(dataLen + 16)
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
        if e2ee {
            plainFrame.appendInt64LE(0)
        }
        plainFrame.appendInt8(0)

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

    /// Decrypts `mcrypt == 1` message bodies and extracts any embedded `TLV tag = 2` `ZolaQuote` using the 16-byte `CrypKey`.
    public static func decryptMessageTextAndQuoteIfNeeded(
        rawText: String,
        ivValue: Any? = nil,
        mcrypt: Int,
        cryptKey: Data
    ) -> (text: String, quote: ZolaQuote?) {
        guard mcrypt == 1, cryptKey.count == 16, !rawText.isEmpty else {
            return (rawText, nil)
        }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case 1: Separate IV provided in `inner["iv"]` (base64 or hex) + `msg` ciphertext (base64 or hex)
        if let ivStr = (ivValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ivStr.isEmpty {
            let ivData = Data(base64Encoded: ivStr) ?? (try? unhex(ivStr))
            let ctData = Data(base64Encoded: trimmed) ?? (try? unhex(trimmed))
            if let iv = ivData, iv.count == 16, let ct = ctData, !ct.isEmpty, ct.count % 16 == 0,
               let pt = try? aesCBC(ct, key: cryptKey, iv: iv, decrypt: true, pkcs7Padding: true),
               let str = String(data: pt, encoding: .utf8), !str.isEmpty
            {
                return (str, nil)
            }
        }

        // Case 2: `msg` is base64/hex of `mcrypt v1` envelope (`0x01 + iv16 + u16_le(ctLen) + ct`) or full `bodyData`
        if let rawBytes = Data(base64Encoded: trimmed) ?? (try? unhex(trimmed)) {
            if rawBytes.count >= 19, rawBytes[rawBytes.startIndex] == 1 {
                let iv = rawBytes.subdata(in: (rawBytes.startIndex + 1)..<(rawBytes.startIndex + 17))
                if let ctLenU16 = try? rawBytes.readUInt16LE(at: 17) {
                    let ctLen = Int(ctLenU16)
                    if 19 + ctLen == rawBytes.count, ctLen > 0, ctLen % 16 == 0 {
                        let ct = rawBytes.subdata(in: (rawBytes.startIndex + 19)..<(rawBytes.startIndex + 19 + ctLen))
                        if let pt = try? aesCBC(ct, key: cryptKey, iv: iv, decrypt: true, pkcs7Padding: true),
                           let str = String(data: pt, encoding: .utf8), !str.isEmpty
                        {
                            return (str, nil)
                        }
                    }
                }
            }
            if let unpacked = try? decryptMcryptTextAndPropertiesBody(rawBytes, cryptKey: cryptKey),
               (!unpacked.text.isEmpty || unpacked.quote != nil)
            {
                return (unpacked.text, unpacked.quote)
            }
        }

        return (rawText, nil)
    }

    /// Decrypts `mcrypt == 1` message bodies using the 16-byte `CrypKey` when `msg`/`content` is encrypted.
    public static func decryptMessageTextIfNeeded(
        rawText: String,
        ivValue: Any? = nil,
        mcrypt: Int,
        cryptKey: Data
    ) -> String {
        decryptMessageTextAndQuoteIfNeeded(
            rawText: rawText,
            ivValue: ivValue,
            mcrypt: mcrypt,
            cryptKey: cryptKey
        ).text
    }

    // MARK: - `UXChatSocket` & `UXVoipSocket` `ChatElement` Wire Frame Codec

    public static func gunzipOrInflate(_ data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let isGzip = (b0 == 0x1F && b1 == 0x8B)
        let isZlib = (b0 == 0x78 && ((UInt16(b0) << 8 | UInt16(b1)) % 31 == 0))
        guard isGzip || isZlib else { return nil }

        return data.withUnsafeBytes { rawInput -> Data? in
            guard let inPtr = rawInput.bindMemory(to: Bytef.self).baseAddress else { return nil }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr)
            stream.avail_in = uInt(data.count)
            guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                return nil
            }
            defer { inflateEnd(&stream) }

            var output = Data()
            let chunkSize = 8192
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let maxDecompressedBytes = 4 * 1024 * 1024

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                    if output.count > maxDecompressedBytes {
                        return nil
                    }
                }
                if status == Z_STREAM_END {
                    return output
                }
                if status != Z_OK {
                    return nil
                }
                if produced == 0 && stream.avail_in == 0 {
                    return nil
                }
            }
        }
    }

    public static func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { rawInput -> Data? in
            guard let inPtr = rawInput.bindMemory(to: Bytef.self).baseAddress else { return nil }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inPtr)
            stream.avail_in = uInt(data.count)
            guard deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                15 + 16,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else {
                return nil
            }
            defer { deflateEnd(&stream) }

            var output = Data()
            let chunkSize = 8192
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk[0..<produced])
                }
                if status == Z_STREAM_END {
                    return output
                }
                if status != Z_OK {
                    return nil
                }
            }
        }
    }

    public static func packChatElementFrame(
        bodyData: Data,
        srcId: Int32,
        srcType: Int8,
        msgType: Int8,
        cmd: Int16,
        subCmd: Int8,
        seqId: Int32,
        needAck: UInt8 = 1,
        desId: Int32 = 0,
        desType: Int8 = 0,
        globalMsgId: Int64 = 0,
        version: Int8 = ZolaConstants.httpFailoverVersion,
        socketKey: Data = ZolaConstants.socketKeyData
    ) -> ZolaChatElementFrame {
        let hdrLen = msgType == 2 ? 36 : 23
        let frameSize = UInt32(hdrLen + bodyData.count)
        let normAck = Int64(needAck != 0 ? 1 : 0)
        var baseSum: Int64 = normAck + Int64(msgType) + Int64(seqId) + Int64(srcId) + Int64(srcType) + Int64(cmd) + Int64(subCmd)
        if msgType == 2 {
            baseSum = baseSum &+ Int64(desId) &+ Int64(desType) &+ globalMsgId
        }
        let checksum = UInt32(truncatingIfNeeded: baseSum) ^ ZolaConstants.checksumMagic

        var hdr = Data(capacity: hdrLen)
        hdr.appendUInt32LE(frameSize)
        hdr.appendInt8(version)
        hdr.appendUInt32LE(checksum)
        hdr.appendUInt8(needAck)
        hdr.appendInt8(msgType)
        hdr.appendInt32LE(seqId)
        hdr.appendInt32LE(srcId)
        hdr.appendInt8(srcType)
        hdr.appendInt16LE(cmd)
        hdr.appendInt8(subCmd)
        if msgType == 2 {
            hdr.appendInt32LE(desId)
            hdr.appendInt8(desType)
            hdr.appendInt64LE(globalMsgId)
        }

        let encBody = (bodyData.isEmpty || version == 1)
            ? bodyData
            : encryptHTTPData(bodyData, srcId: srcId, frameSize: frameSize, keyData: socketKey)
        return ZolaChatElementFrame(
            payload: hdr + encBody,
            frameSize: frameSize,
            checksum: checksum,
            headerLength: hdrLen
        )
    }

    /// Packs a server-to-client (`sendBack = 1`) `ChatElement` frame (`msgType = 1, 3, 4`) matching `UXSocketParser process:` (`0x103b0818c`).
    public static func packServerChatElementFrame(
        bodyData: Data = Data(),
        gzipBody: Bool = false,
        srcId: Int32,
        srcType: Int8 = 3,
        msgType: Int8 = 3,
        cmd: Int16,
        subCmd: Int8 = 0,
        seqId: Int32 = 1,
        needAck: UInt8 = 0,
        retCode: Int32 = 0,
        version: Int8 = ZolaConstants.httpFailoverVersion,
        socketKey: Data = ZolaConstants.socketKeyData
    ) -> ZolaChatElementFrame {
        let rawPayload: Data
        if gzipBody, !bodyData.isEmpty, let compressed = gzipCompress(bodyData) {
            rawPayload = compressed
        } else {
            rawPayload = bodyData
        }
        let hasRetCode = (msgType == 3 || msgType == 4)
        let hdrLen = hasRetCode ? 27 : 23
        let frameSize = UInt32(hdrLen + rawPayload.count)
        let normAck = Int64(needAck != 0 ? 1 : 0)
        var baseSum: Int64 = normAck + Int64(msgType) + Int64(seqId) + Int64(srcId) + Int64(srcType) + Int64(cmd) + Int64(subCmd)
        if hasRetCode {
            baseSum = baseSum &+ Int64(retCode)
        }
        let checksum = UInt32(truncatingIfNeeded: baseSum) ^ ZolaConstants.checksumMagic

        var hdr = Data(capacity: hdrLen)
        hdr.appendUInt32LE(frameSize)
        hdr.appendInt8(version)
        hdr.appendUInt32LE(checksum)
        hdr.appendUInt8(needAck)
        hdr.appendInt8(msgType)
        hdr.appendInt32LE(seqId)
        hdr.appendInt32LE(srcId)
        hdr.appendInt8(srcType)
        hdr.appendInt16LE(cmd)
        hdr.appendInt8(subCmd)
        if hasRetCode {
            hdr.appendInt32LE(retCode)
        }

        let encBody = (rawPayload.isEmpty || version == 1)
            ? rawPayload
            : encryptHTTPData(rawPayload, srcId: srcId, frameSize: frameSize, keyData: socketKey)
        return ZolaChatElementFrame(
            payload: hdr + encBody,
            frameSize: frameSize,
            checksum: checksum,
            headerLength: hdrLen
        )
    }

    public static func unpackChatElementFrame(
        _ raw: Data,
        socketKey: Data = ZolaConstants.socketKeyData
    ) throws -> ZolaUnpackedChatElement {
        guard raw.count >= 23 else {
            throw ZolaError.crypto("ChatElement frame too short (\(raw.count) < 23)")
        }
        let frameSize = try raw.readUInt32LE(at: 0)
        guard Int(frameSize) == raw.count else {
            throw ZolaError.crypto("ChatElement frameSize mismatch")
        }
        let version = Int8(bitPattern: raw[raw.startIndex + 4])
        let checksum = try raw.readUInt32LE(at: 5)
        let needAck = raw[raw.startIndex + 9]
        let msgType = Int8(bitPattern: raw[raw.startIndex + 10])
        let seqId = try raw.readInt32LE(at: 11)
        let srcId = try raw.readInt32LE(at: 15)
        let srcType = Int8(bitPattern: raw[raw.startIndex + 19])
        let cmd = try raw.readInt16LE(at: 20)
        let subCmd = Int8(bitPattern: raw[raw.startIndex + 22])

        var desId: Int32 = 0
        var desType: Int8 = 0
        var globalMsgId: Int64 = 0
        var retCode: Int32 = 0
        var hdrLen = 23
        if msgType == 2 {
            guard raw.count >= 36 else {
                throw ZolaError.crypto("msgType=2 ChatElement frame too short (< 36)")
            }
            desId = try raw.readInt32LE(at: 23)
            desType = Int8(bitPattern: raw[raw.startIndex + 27])
            globalMsgId = try raw.readInt64LE(at: 28)
            hdrLen = 36
        } else if msgType == 3 || msgType == 4 {
            guard raw.count >= 27 else {
                throw ZolaError.crypto("msgType=\(msgType) ChatElement frame too short (< 27)")
            }
            retCode = try raw.readInt32LE(at: 23)
            desId = retCode
            hdrLen = 27
        }

        let normAck = Int64(needAck != 0 ? 1 : 0)
        var baseSum: Int64 = normAck + Int64(msgType) + Int64(seqId) + Int64(srcId) + Int64(srcType) + Int64(cmd) + Int64(subCmd)
        if msgType == 2 {
            baseSum = baseSum &+ Int64(desId) &+ Int64(desType) &+ globalMsgId
        } else if (msgType == 3 || msgType == 4) && hdrLen == 27 {
            baseSum = baseSum &+ Int64(retCode)
        }
        let expectedCsum = UInt32(truncatingIfNeeded: baseSum) ^ ZolaConstants.checksumMagic
        guard checksum == expectedCsum else {
            throw ZolaError.crypto("ChatElement checksum mismatch")
        }

        let encBody = raw.subdata(in: hdrLen..<raw.count)
        let bodyData: Data
        if encBody.isEmpty {
            bodyData = Data()
        } else if version == 1 {
            bodyData = encBody
        } else {
            bodyData = encryptHTTPData(encBody, srcId: srcId, frameSize: frameSize, keyData: socketKey)
        }
        let decodedBodyData: Data
        if !bodyData.isEmpty, msgType != 4, let inflated = gunzipOrInflate(bodyData) {
            decodedBodyData = inflated
        } else {
            decodedBodyData = bodyData
        }
        return ZolaUnpackedChatElement(
            frameSize: frameSize,
            version: version,
            checksum: checksum,
            needAck: needAck,
            msgType: msgType,
            seqId: seqId,
            srcId: srcId,
            srcType: srcType,
            cmd: cmd,
            subCmd: subCmd,
            desId: desId,
            desType: desType,
            globalMsgId: globalMsgId,
            bodyData: bodyData,
            retCode: retCode,
            decodedBodyData: decodedBodyData
        )
    }

    // MARK: - `UXAsyncSocket` (`UXChatSocket` `0x7d0` & `UXVoipSocket`) `AUTHEN` (`cmd=1, subCmd=5` & `AuthenV3Aes` `subCmd=3/4`) + Heartbeat (`cmd=2, subCmd=2`)

    public static let ppLoginXorKeyData = Data("PPLOGINyfusJDHJEUD554g7645gh54FGDHDFZCEPITB".utf8)
    public static let authenV3AesStatic16 = Data([
        0x48, 0xED, 0x3A, 0x1F, 0x52, 0xF9, 0x39, 0x41,
        0xE3, 0x21, 0x0D, 0x3F, 0x2E, 0x5D, 0xE4, 0x10,
    ])
    public static let authenV3AesTail4 = Data([0x1D, 0x1F, 0x5B, 0x30]) // LE32 `0x305b1f1d`

    /// Builds `packSocketAuthenFrame` (`0x103a72d3c`) for `UXChatSocket` (`0x7d0`).
    /// Defaults to canonical `subCmd = 5` (used whenever `keySetValue` is present on `0x7d0`, embedding plain UTF-8
    /// `sessionKey` inside the double-encrypted `EncryptProtocolVer2` + `X25519` envelope). Pass `subCmd = 2` only
    /// for legacy loopback vector tests.
    public static func packSocketAuthenFrame(
        srcId: Int32,
        sessionKey: String,
        deviceModel: String = ZolaCrypto.platformString(
            shortModel: ZolaConstants.defaultShortModel,
            osVersion: ZolaConstants.defaultIOSVersion,
            jailbroken: false
        ),
        imei: String = ZolaConstants.defaultIDFA,
        platformType: UInt8 = 2,
        clientVersion: UInt32 = 261_002_802,
        networkType: UInt16 = 0,
        nonce: UInt32 = 0,
        flag4: UInt8 = 1,
        subCmd: Int8 = 5,
        seqId: Int32 = 1
    ) -> ZolaChatElementFrame {
        let skBytes = Data(sessionKey.utf8)
        let modelBytes = Data(deviceModel.utf8)
        let imeiBytes = Data(imei.utf8)

        if subCmd == 2 {
            let encodedSk = Data(xorCyclic(skBytes, key: ppLoginXorKeyData).base64EncodedString().utf8)
            var legacyBody = Data(capacity: 15 + modelBytes.count + imeiBytes.count + encodedSk.count)
            legacyBody.appendUInt8(platformType)
            legacyBody.appendUInt32LE(nonce)
            legacyBody.appendUInt16LE(networkType)
            legacyBody.appendUInt32LE(clientVersion)
            legacyBody.appendUInt16LE(UInt16(truncatingIfNeeded: modelBytes.count))
            legacyBody.append(modelBytes)
            legacyBody.appendUInt16LE(UInt16(truncatingIfNeeded: imeiBytes.count))
            legacyBody.append(imeiBytes)
            legacyBody.append(encodedSk)
            return packChatElementFrame(
                bodyData: legacyBody,
                srcId: srcId,
                srcType: 3,
                msgType: 1,
                cmd: 1,
                subCmd: 2,
                seqId: seqId,
                needAck: 1,
                desId: srcId,
                desType: 3
            )
        }

        // Canonical `subCmd = 5` (`0x103a72fe8` / `0x103a73308`–`0x103a73318`):
        // [u8 platform=2][u32LE cd4][u16LE netType][u32LE clientVer][u8 flag4=1]
        // [u16LE+deviceModel][u16LE+imei][6 zero bytes][u16LE+sessionKeyUTF8]
        var body = Data(capacity: 24 + modelBytes.count + imeiBytes.count + skBytes.count)
        body.appendUInt8(platformType)
        body.appendUInt32LE(nonce)
        body.appendUInt16LE(networkType)
        body.appendUInt32LE(clientVersion)
        if subCmd >= 4 {
            body.appendUInt8(flag4)
        }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: modelBytes.count))
        body.append(modelBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: imeiBytes.count))
        body.append(imeiBytes)
        body.appendUInt16LE(0)
        body.appendUInt32LE(0)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: skBytes.count))
        body.append(skBytes)

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 1,
            subCmd: subCmd,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Derives the 32-byte `AuthenV3Aes` AES-256-CBC key (`0x103a73054`–`0x103a73080`):
    /// `Key32 = BE32(timestampSec) || BE64(aesPrivateId) || 48ed3a1f52f93941e3210d3f2e5de410 || 1d1f5b30`.
    public static func deriveAuthenV3AesKey(timestampSec: UInt32, aesPrivateId: Int64) -> Data {
        var key = Data(capacity: 32)
        key.append(UInt8((timestampSec >> 24) & 0xFF))
        key.append(UInt8((timestampSec >> 16) & 0xFF))
        key.append(UInt8((timestampSec >> 8) & 0xFF))
        key.append(UInt8(timestampSec & 0xFF))
        let privBits = UInt64(bitPattern: aesPrivateId)
        for shift in stride(from: 56, through: 0, by: -8) {
            key.append(UInt8((privBits >> shift) & 0xFF))
        }
        key.append(authenV3AesStatic16)
        key.append(authenV3AesTail4)
        return key
    }

    /// Fallback `AuthenV3Aes` `AUTHEN` builder (`subCmd = 4` on `0x7d0` without `keySetValue`, or `subCmd = 3` on `0x7d1`/`0x7d2`).
    public static func packSocketAuthenV3AesFrame(
        srcId: Int32,
        sessionKey: String,
        aesPublicId: Int64,
        aesPrivateId: Int64,
        timestampSec: UInt32 = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970)),
        subCmd: Int8 = 4,
        deviceModel: String = ZolaCrypto.platformString(
            shortModel: ZolaConstants.defaultShortModel,
            osVersion: ZolaConstants.defaultIOSVersion,
            jailbroken: false
        ),
        imei: String = ZolaConstants.defaultIDFA,
        platformType: UInt8 = 2,
        clientVersion: UInt32 = 261_002_802,
        networkType: UInt16 = 0,
        flag4: UInt8 = 1,
        seqId: Int32 = 1
    ) throws -> ZolaChatElementFrame {
        guard aesPublicId >= 1, aesPrivateId >= 1 else {
            throw ZolaError.invalidArgument("AuthenV3Aes requires aesPublicId >= 1 and aesPrivateId >= 1")
        }
        guard subCmd == 3 || subCmd == 4 else {
            throw ZolaError.invalidArgument("AuthenV3Aes only applies to subCmd 3 or 4")
        }
        let key32 = deriveAuthenV3AesKey(timestampSec: timestampSec, aesPrivateId: aesPrivateId)
        let encryptedSk = try aesCBC(Data(sessionKey.utf8), key: key32, iv: zeroIV16, decrypt: false, pkcs7Padding: true)
        let encodedSkBytes = Data(encryptedSk.base64EncodedString().utf8)
        let modelBytes = Data(deviceModel.utf8)
        let imeiBytes = Data(imei.utf8)

        var body = Data(capacity: 29 + modelBytes.count + imeiBytes.count + encodedSkBytes.count)
        body.appendUInt8(platformType)
        body.appendUInt32LE(timestampSec)
        body.appendUInt16LE(networkType)
        body.appendUInt32LE(clientVersion)
        if subCmd >= 4 {
            body.appendUInt8(flag4)
        }
        body.appendUInt16LE(UInt16(truncatingIfNeeded: modelBytes.count))
        body.append(modelBytes)
        body.appendUInt16LE(UInt16(truncatingIfNeeded: imeiBytes.count))
        body.append(imeiBytes)
        body.appendUInt8(1)
        body.appendUInt32LE(subCmd == 4 ? 1 : 0)
        body.appendInt64LE(aesPublicId)
        body.append(encodedSkBytes)

        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 1,
            subCmd: subCmd,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `UXChatSocket` Heartbeat Ping (`cmd = 2, subCmd = 2`, 29B `ChatElement` -> 57B encrypted `0x04` wire frame).
    public static func packSocketHeartbeatFrame(
        srcId: Int32,
        counter: UInt32 = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970)),
        seqId: Int32
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 6)
        body.appendUInt8(0x01)
        body.appendUInt8(0x02)
        body.appendUInt32LE(counter)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: 2,
            subCmd: 2,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `UXChatSocket` `createGetOfflineCmdByCommandType:withSubCommand:withGlobalId:withCounter:` (`0x100c84df0`):
    /// `cmd = 121` (1-1) or `cmd = 224` (group), `subCmd = 1` (initial after AUTHEN) / `0` (next page),
    /// 9-byte binary payload `Int64LE(lastGlobalMsgId) || UInt8(counter)` (`needAck = 0`, `msgType = 1`).
    public static func packSocketGetOfflineFrame(
        srcId: Int32,
        lastGlobalMsgId: Int64,
        counter: UInt8 = 50,
        isGroup: Bool = false,
        subCmd: Int8 = 1,
        seqId: Int32
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 9)
        body.appendInt64LE(max(0, lastGlobalMsgId))
        body.appendUInt8(counter == 0 ? 50 : counter)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: isGroup ? 224 : 121,
            subCmd: subCmd,
            seqId: seqId,
            needAck: 0,
            desId: srcId,
            desType: 3
        )
    }

    /// Builds `UXChatSocket` `createDeliveredElementWithInfo:withCommandType:isSeen:` (`0x100c852a0`):
    /// `cmd = 102` (1-1) or `cmd = 202` (group), `subCmd = 3`, `msgType = 1`, `needAck = 1`,
    /// UTF-8 JSON body `{"data": [...], "seen": isSeen}`.
    public static func packSocketDeliveredAckFrame(
        srcId: Int32,
        items: [[String: Any]],
        isGroup: Bool = false,
        isSeen: Int = 0,
        seqId: Int32
    ) -> ZolaChatElementFrame? {
        guard !items.isEmpty else { return nil }
        let payloadObj: [String: Any] = [
            "data": items,
            "seen": isSeen,
        ]
        guard JSONSerialization.isValidJSONObject(payloadObj),
              let jsonData = try? JSONSerialization.data(withJSONObject: payloadObj, options: [.withoutEscapingSlashes])
        else {
            return nil
        }
        return packChatElementFrame(
            bodyData: jsonData,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: isGroup ? 202 : 102,
            subCmd: 3,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 3
        )
    }

    /// Native reaction delivery ACK: ChatDataManager.ackReactionMsgs (0x100947fbc),
    /// ChatSocketCmdHelper.createOthersDeliveredCmdForMessages (0x100c855a4).
    /// Body is concatenated envelope global IDs as Int64 LE, not target IDs or message ACK JSON.
    public static func packSocketReactionAckFrame(
        srcId: Int32,
        globalMessageIds: [Int64],
        isGroup: Bool,
        seqId: Int32
    ) -> ZolaChatElementFrame? {
        guard !globalMessageIds.isEmpty, globalMessageIds.allSatisfy({ $0 > 0 }) else { return nil }
        var body = Data(capacity: globalMessageIds.count * 8)
        for id in globalMessageIds { body.appendInt64LE(id) }
        return packChatElementFrame(bodyData: body, srcId: srcId, srcType: 3, msgType: 1,
                                    cmd: isGroup ? 1786 : 1781, subCmd: isGroup ? 1 : 0,
                                    seqId: seqId, needAck: 0)
    }

    // MARK: - `VoipRequestOperation` & `ZRTCPacket` codecs → Call/ZolaCrypto+Voip.swift (CALL MODULE, khoá)

    // MARK: - `FriendRequestManager` Native `UXChatSocket` (`0x7d0`) Codec (`1584/2`, `396/4`, `378/1`, `373/3`, `374/1`, `375/2`, `397/1`)

    /// Builds `-[FriendRequestManager getFriendRequestAndSuggestList:...]` (`0x100e7d168`, `cmd = 1584, subCmd = 2`, 19B body).
    public static func packFriendListRequestsFrame(
        srcId: Int32,
        avatarSize: Int32 = 120,
        suggestLimit: Int32 = 10,
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 19)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(0)
        body.appendInt16LE(0)
        body.appendInt32LE(avatarSize)
        body.appendInt32LE(suggestLimit)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendListRequests,
            subCmd: ZolaConstants.subCmdFriendListRequests,
            seqId: seqId,
            needAck: 1,
            desId: 0,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager loadSentFriendRequestsFromServerWithPageIndex:pageSize:loadMore:requestType:...]`
    /// (`0x100e738ac`, `cmd = 396, subCmd = 4`, 22B body).
    public static func packFriendListSentFrame(
        srcId: Int32,
        page: Int32 = 1,
        count: Int32 = 100,
        avatarSize: Int32 = 120,
        requestType: UInt8 = 2,
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 22)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(max(1, page))
        body.appendInt32LE(max(1, count))
        body.appendInt32LE(avatarSize)
        body.appendInt32LE(0)
        body.appendUInt8(requestType)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendListSent,
            subCmd: ZolaConstants.subCmdFriendListSent,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager getFriendRequestStatus:...]` (`0x100e843cc`, `cmd = 378, subCmd = 1`, 13B body).
    public static func packFriendRequestStatusFrame(
        srcId: Int32,
        targetUid: Int32,
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 13)
        body.appendInt32LE(targetUid)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(0)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendRequestStatus,
            subCmd: ZolaConstants.subCmdFriendRequestStatus,
            seqId: seqId,
            needAck: 1,
            desId: 0,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager sendFriendRequestTo:...]` (`0x100e82abc` + `0x100e83480`, `cmd = 373, subCmd = 3`).
    public static func packFriendSendRequestFrame(
        srcId: Int32,
        toUid: Int32,
        message: String = "",
        sourceType: Int32 = -1,
        srcParams: String = "",
        isBlockViewFeed: Bool = false,
        alias: String? = nil,
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        let msgBytes = Data(message.utf8)
        let paramsBytes = Data(srcParams.utf8)
        let aliasTrimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aliasBytes = Data(aliasTrimmed.utf8)
        let hasAlias = !aliasBytes.isEmpty
        let tlvCount: UInt8 = hasAlias ? 2 : 1

        var body = Data(capacity: 24 + msgBytes.count + paramsBytes.count + aliasBytes.count)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(toUid)
        body.appendInt32LE(sourceType)
        body.appendInt32LE(Int32(msgBytes.count))
        if !msgBytes.isEmpty {
            body.append(msgBytes)
        }
        body.appendInt32LE(Int32(paramsBytes.count))
        if !paramsBytes.isEmpty {
            body.append(paramsBytes)
        }
        body.appendUInt8(tlvCount)
        body.appendUInt8(1)
        body.appendUInt8(isBlockViewFeed ? 1 : 0)
        if hasAlias {
            body.appendUInt8(2)
            body.appendUInt16LE(UInt16(truncatingIfNeeded: aliasBytes.count))
            body.append(aliasBytes)
        }
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendSendRequest,
            subCmd: ZolaConstants.subCmdFriendSendRequest,
            seqId: seqId,
            needAck: 1,
            desId: 0,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager acceptFriendRequestFrom:...]` (`0x100e7f75c`, `cmd = 374, subCmd = 1`, 14B+ body).
    public static func packFriendAcceptRequestFrame(
        srcId: Int32,
        fromUid: Int32,
        srcParams: String = "",
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        let paramsBytes = Data(srcParams.utf8)
        var body = Data(capacity: 14 + paramsBytes.count)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(Int32(paramsBytes.count))
        if !paramsBytes.isEmpty {
            body.append(paramsBytes)
        }
        body.appendInt32LE(fromUid)
        body.appendUInt8(0)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendAcceptRequest,
            subCmd: ZolaConstants.subCmdFriendAcceptRequest,
            seqId: seqId,
            needAck: 1,
            desId: 0,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager denyFriendRequestFrom:...]` (`0x100e80694`, `cmd = 375, subCmd = 2`, 15B body).
    public static func packFriendRejectRequestFrame(
        srcId: Int32,
        fromUid: Int32,
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        var body = Data(capacity: 15)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt16LE(0)
        body.appendInt32LE(0)
        body.appendInt32LE(fromUid)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendRejectRequest,
            subCmd: ZolaConstants.subCmdFriendRejectRequest,
            seqId: seqId,
            needAck: 1,
            desId: 0,
            desType: 0
        )
    }

    /// Builds `-[FriendRequestManager undoSentFriendRequestWithFriendIds:...]` (`0x100e93784`, `cmd = 397, subCmd = 1`).
    public static func packFriendUndoRequestFrame(
        srcId: Int32,
        toUid: Int32,
        srcParams: String = "",
        platformType: UInt8 = 2,
        clientVersion: Int32 = Int32(ZolaConstants.clientVersionIOS),
        seqId: Int32 = 2
    ) -> ZolaChatElementFrame {
        let paramsBytes = Data(srcParams.utf8)
        var body = Data(capacity: 17 + paramsBytes.count)
        body.appendUInt8(platformType)
        body.appendInt32LE(clientVersion)
        body.appendInt32LE(Int32(paramsBytes.count))
        if !paramsBytes.isEmpty {
            body.append(paramsBytes)
        }
        body.appendInt32LE(1) // friendIds.count = 1
        body.appendInt32LE(toUid)
        return packChatElementFrame(
            bodyData: body,
            srcId: srcId,
            srcType: 3,
            msgType: 1,
            cmd: ZolaConstants.cmdFriendUndoRequest,
            subCmd: ZolaConstants.subCmdFriendUndoRequest,
            seqId: seqId,
            needAck: 1,
            desId: srcId,
            desType: 0
        )
    }
}

/// Encrypted transport codec for Zalo iOS Native `UXChatSocket` (`0x7d0`) implementing `EncryptProtocolVer2` (`ProV21`)
/// (`setParamsForEncryptProtocolVer2:withKeySetId:` `0x103b5b99c`, `encryptMsgV2x` `0x103b3945c`, `encrypt_inner` `0x103b39b80`,
/// `decryptMsgV2x_inner` `0x103b39158`, and `p2t` X25519 `0x104606240`).
public struct ZolaSocketCrypto: Sendable {
    public private(set) var keySetId: String
    private var currentKey: SymmetricKey
    private var previousKey: SymmetricKey?
    private let clientPrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(
        keySetId: String,
        keySetValueBase64: String,
        previousKeySetValueBase64: String? = nil,
        clientPrivateKeyRaw32: Data? = nil
    ) throws {
        let cleanId = keySetId.trimmingCharacters(in: .whitespacesAndNewlines)
        let idBytes = Data(cleanId.utf8)
        guard !idBytes.isEmpty, idBytes.count <= 255 else {
            throw ZolaError.invalidArgument("Socket keySetId must be 1..255 UTF-8 bytes")
        }
        let cleanVal = keySetValueBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decodedKey = Data(base64Encoded: cleanVal), decodedKey.count == 32 else {
            throw ZolaError.crypto("Socket keySetValue must Base64-decode to 32 bytes")
        }
        self.keySetId = cleanId
        self.currentKey = SymmetricKey(data: decodedKey)
        if let prevB64 = previousKeySetValueBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prevB64.isEmpty,
           let prevData = Data(base64Encoded: prevB64),
           prevData.count == 32 {
            self.previousKey = SymmetricKey(data: prevData)
        } else {
            self.previousKey = nil
        }
        if let rawPriv = clientPrivateKeyRaw32 {
            guard rawPriv.count == 32 else {
                throw ZolaError.invalidArgument("X25519 ephemeral private key must be 32 bytes")
            }
            self.clientPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPriv)
        } else {
            self.clientPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        }
    }

    public var clientPublicKeyData: Data {
        clientPrivateKey.publicKey.rawRepresentation
    }

    /// Updates `keySetId`/`keySetValue` while preserving the previous 32-byte key in `previousKey` (`env + 0x1540`)
    /// so in-flight inbound frames can still retry once during key rotation (`RE-DECRYPT WITH OLD KEY ONE TIME AGAIN`).
    public mutating func rotateKeySet(keySetId: String, keySetValueBase64: String) throws {
        let cleanId = keySetId.trimmingCharacters(in: .whitespacesAndNewlines)
        let idBytes = Data(cleanId.utf8)
        guard !idBytes.isEmpty, idBytes.count <= 255 else {
            throw ZolaError.invalidArgument("Socket keySetId must be 1..255 UTF-8 bytes")
        }
        let cleanVal = keySetValueBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decodedKey = Data(base64Encoded: cleanVal), decodedKey.count == 32 else {
            throw ZolaError.crypto("Socket keySetValue must Base64-decode to 32 bytes")
        }
        self.previousKey = self.currentKey
        self.keySetId = cleanId
        self.currentKey = SymmetricKey(data: decodedKey)
    }

    private static func makeNonce(_ explicitNonce: Data?) throws -> AES.GCM.Nonce {
        if let explicitNonce {
            guard explicitNonce.count == 12 else {
                throw ZolaError.invalidArgument("AES-GCM nonce must be 12 bytes")
            }
            return try AES.GCM.Nonce(data: explicitNonce)
        }
        return AES.GCM.Nonce()
    }

    /// Double-encrypts the initial `AUTHEN` `ChatElement` (`type == 1` -> `wireType = 0x08` when `CE.version == 2`):
    /// 1. Inner `AES-256-GCM(key = Base64Decode(keySetValue), AAD = empty)` over `CE[5..frameSize]` + `[keySetId][u8 len]`
    /// 2. Outer `AES-256-GCM(key = X25519(clientEphPriv32, serverPub32), AAD = empty)` + `[clientEphPub32][serverPubEcho32]`
    public func sealAuthenFrame(
        _ chatElementPayload: Data,
        serverPubKeyBase64: String,
        innerNonce: Data? = nil,
        outerNonce: Data? = nil
    ) throws -> Data {
        guard chatElementPayload.count >= 23 else {
            throw ZolaError.crypto("AUTHEN ChatElement too short (\(chatElementPayload.count) < 23)")
        }
        let ceFrameSize = try chatElementPayload.readUInt32LE(at: 0)
        guard Int(ceFrameSize) == chatElementPayload.count else {
            throw ZolaError.crypto("AUTHEN ChatElement frameSize mismatch (\(ceFrameSize) != \(chatElementPayload.count))")
        }
        let ceVersion = chatElementPayload[chatElementPayload.startIndex + 4]
        guard ceVersion == 1 || ceVersion == 2 else {
            throw ZolaError.crypto("Unsupported ChatElement version \(ceVersion)")
        }

        let cleanSrvB64 = serverPubKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let srvPubBytes = Data(base64Encoded: cleanSrvB64), srvPubBytes.count == 32 else {
            throw ZolaError.crypto("SocketEntity.pubKey must Base64-decode to 32 bytes")
        }
        let serverPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: srvPubBytes)
        let sharedSecret = try clientPrivateKey.sharedSecretFromKeyAgreement(with: serverPubKey)
        let outerKey = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }

        let ceBodyFrom5 = chatElementPayload.subdata(in: 5..<chatElementPayload.count)
        let resolvedInnerNonce = try Self.makeNonce(innerNonce)
        let innerBox = try AES.GCM.seal(ceBodyFrom5, using: currentKey, nonce: resolvedInnerNonce, authenticating: Data())

        let ksIdBytes = Data(keySetId.utf8)
        var plainOuter = Data(capacity: ceBodyFrom5.count + 29 + ksIdBytes.count)
        plainOuter.append(innerBox.ciphertext)
        plainOuter.append(innerBox.tag)
        plainOuter.append(contentsOf: innerBox.nonce)
        plainOuter.append(ksIdBytes)
        plainOuter.appendUInt8(UInt8(ksIdBytes.count))

        let resolvedOuterNonce = try Self.makeNonce(outerNonce)
        let outerBox = try AES.GCM.seal(plainOuter, using: outerKey, nonce: resolvedOuterNonce, authenticating: Data())
        let ephPubBytes = clientPrivateKey.publicKey.rawRepresentation
        let wireType = (ceVersion &+ 2) &+ 4 // `2 -> 0x08`, `1 -> 0x07`
        let totalWireLen = UInt32(5 + outerBox.ciphertext.count + 16 + 12 + 32 + 32)

        var out = Data(capacity: Int(totalWireLen))
        out.appendUInt32LE(totalWireLen)
        out.appendUInt8(wireType)
        out.append(outerBox.ciphertext)
        out.append(outerBox.tag)
        out.append(contentsOf: outerBox.nonce)
        out.append(ephPubBytes)
        out.append(srvPubBytes)
        return out
    }

    /// Encrypts any post-`AUTHEN` outbound `ChatElement` frame (`wireType = 0x04` for `version=2`, `0x03` for `version=1`)
    /// using single-layer `AES-256-GCM(key = Base64Decode(keySetValue), AAD = empty)`:
    /// `[u32LE totalWireLen = N + 33][u8 wireType][innerCT (N B)][innerTag (16B)][innerNonce (12B)]`.
    public func sealFrame(_ chatElementPayload: Data, nonce: Data? = nil) throws -> Data {
        guard chatElementPayload.count >= 23 else {
            throw ZolaError.crypto("ChatElement too short (\(chatElementPayload.count) < 23)")
        }
        let ceFrameSize = try chatElementPayload.readUInt32LE(at: 0)
        guard Int(ceFrameSize) == chatElementPayload.count else {
            throw ZolaError.crypto("ChatElement frameSize mismatch (\(ceFrameSize) != \(chatElementPayload.count))")
        }
        let ceVersion = chatElementPayload[chatElementPayload.startIndex + 4]
        guard ceVersion == 1 || ceVersion == 2 else {
            throw ZolaError.crypto("Unsupported ChatElement version \(ceVersion)")
        }
        let ceBodyFrom5 = chatElementPayload.subdata(in: 5..<chatElementPayload.count)
        let resolvedNonce = try Self.makeNonce(nonce)
        let box = try AES.GCM.seal(ceBodyFrom5, using: currentKey, nonce: resolvedNonce, authenticating: Data())
        let wireType = ceVersion &+ 2
        let totalWireLen = UInt32(5 + box.ciphertext.count + 16 + 12)

        var out = Data(capacity: Int(totalWireLen))
        out.appendUInt32LE(totalWireLen)
        out.appendUInt8(wireType)
        out.append(box.ciphertext)
        out.append(box.tag)
        out.append(contentsOf: box.nonce)
        return out
    }

    /// Decrypts any inbound post-`AUTHEN` frame (`AUTHEN-RESP`, VoIP `cmd 4xx`, chat push, or ping ACK; `wireType = 0x03 | 0x04`)
    /// matching `decryptMsgV2x_inner` (`0x103b39158`), automatically retrying once with `previousKey` on GCM tag mismatch,
    /// and returns the reconstructed `ChatElement` bytes ready for `ZolaCrypto.unpackChatElementFrame`.
    public func openFrame(_ wireFrame: Data) throws -> Data {
        guard wireFrame.count >= 51 else {
            throw ZolaError.crypto("Encrypted socket frame too short (\(wireFrame.count) < 51)")
        }
        let totalWireLen = try wireFrame.readUInt32LE(at: 0)
        guard Int(totalWireLen) == wireFrame.count else {
            throw ZolaError.crypto("Encrypted socket frame length mismatch (\(totalWireLen) != \(wireFrame.count))")
        }
        let wireType = wireFrame[wireFrame.startIndex + 4]
        guard wireType == 3 || wireType == 4 else {
            throw ZolaError.crypto("Unsupported inbound socket wireType \(wireType)")
        }
        let ctEnd = wireFrame.count - 28
        let tagEnd = wireFrame.count - 12
        let ciphertext = wireFrame.subdata(in: 5..<ctEnd)
        let tag = wireFrame.subdata(in: ctEnd..<tagEnd)
        let nonce = try AES.GCM.Nonce(data: wireFrame.subdata(in: tagEnd..<wireFrame.count))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: currentKey, authenticating: Data())
        } catch {
            if let oldKey = previousKey,
               let recovered = try? AES.GCM.open(sealedBox, using: oldKey, authenticating: Data()) {
                plaintext = recovered
            } else {
                throw ZolaError.crypto("AES-256-GCM authentication failed on socket frame (wireType=\(wireType))")
            }
        }

        let ceFrameSize = UInt32(wireFrame.count - 28)
        let ceVersion = wireType &- 2
        var reconstructed = Data(capacity: Int(ceFrameSize))
        reconstructed.appendUInt32LE(ceFrameSize)
        reconstructed.appendUInt8(ceVersion)
        reconstructed.append(plaintext)
        return reconstructed
    }

    /// Server-side / loopback-test verifier that opens a double-encrypted `0x08` (`0x07`) `AUTHEN` wire frame,
    /// returning the reconstructed `ChatElement` payload, extracted `keySetId`, and client's 32-byte X25519 ephemeral public key.
    public static func openAuthenFrame(
        _ wireFrame: Data,
        serverPrivateKeyRaw32: Data,
        resolveKeySetValue: (String) -> Data?
    ) throws -> (chatElementPayload: Data, keySetId: String, clientPublicKey: Data) {
        guard serverPrivateKeyRaw32.count == 32 else {
            throw ZolaError.invalidArgument("Server X25519 private key must be 32 bytes")
        }
        // Minimum: 5 header + (18 innerCT + 28 innerGCM + 2 keySetId+len) + 28 outerGCM + 64 pubs = 145 bytes
        guard wireFrame.count >= 145 else {
            throw ZolaError.crypto("Encrypted AUTHEN wire frame too short (\(wireFrame.count) < 145)")
        }
        let totalWireLen = try wireFrame.readUInt32LE(at: 0)
        guard Int(totalWireLen) == wireFrame.count else {
            throw ZolaError.crypto("Encrypted AUTHEN length mismatch (\(totalWireLen) != \(wireFrame.count))")
        }
        let wireType = wireFrame[wireFrame.startIndex + 4]
        guard wireType == 7 || wireType == 8 else {
            throw ZolaError.crypto("Unsupported AUTHEN wireType \(wireType)")
        }

        let srvEchoStart = wireFrame.count - 32
        let ephPubStart = srvEchoStart - 32
        let outerNonceStart = ephPubStart - 12
        let outerTagStart = outerNonceStart - 16

        let serverPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverPrivateKeyRaw32)
        let serverPubExpected = serverPriv.publicKey.rawRepresentation
        let serverPubEcho = wireFrame.subdata(in: srvEchoStart..<wireFrame.count)
        guard serverPubEcho == serverPubExpected else {
            throw ZolaError.crypto("AUTHEN serverPubKey echo mismatch")
        }

        let clientEphPubBytes = wireFrame.subdata(in: ephPubStart..<srvEchoStart)
        let clientPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientEphPubBytes)
        let shared = try serverPriv.sharedSecretFromKeyAgreement(with: clientPub)
        let outerKey = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }

        let outerCT = wireFrame.subdata(in: 5..<outerTagStart)
        let outerTag = wireFrame.subdata(in: outerTagStart..<outerNonceStart)
        let outerNonce = try AES.GCM.Nonce(data: wireFrame.subdata(in: outerNonceStart..<ephPubStart))
        let outerBox = try AES.GCM.SealedBox(nonce: outerNonce, ciphertext: outerCT, tag: outerTag)
        let plainOuter = try AES.GCM.open(outerBox, using: outerKey, authenticating: Data())

        guard plainOuter.count >= 48 else {
            throw ZolaError.crypto("AUTHEN inner payload too short (\(plainOuter.count))")
        }
        let ksLen = Int(plainOuter[plainOuter.endIndex - 1])
        guard ksLen >= 1, plainOuter.count >= 18 + 28 + ksLen + 1 else {
            throw ZolaError.crypto("Invalid keySetId trailer length \(ksLen)")
        }
        let ksIdStart = plainOuter.count - 1 - ksLen
        let ksIdData = plainOuter.subdata(in: ksIdStart..<(plainOuter.count - 1))
        let ksId = String(decoding: ksIdData, as: UTF8.self)
        guard let innerKeyBytes = resolveKeySetValue(ksId), innerKeyBytes.count == 32 else {
            throw ZolaError.server(code: ZolaConstants.errorInvalidSessionKey, message: "Unknown or expired keySetId")
        }

        let innerNonceStart = ksIdStart - 12
        let innerTagStart = innerNonceStart - 16
        let innerCT = plainOuter.subdata(in: 0..<innerTagStart)
        let innerTag = plainOuter.subdata(in: innerTagStart..<innerNonceStart)
        let innerNonce = try AES.GCM.Nonce(data: plainOuter.subdata(in: innerNonceStart..<ksIdStart))
        let innerBox = try AES.GCM.SealedBox(nonce: innerNonce, ciphertext: innerCT, tag: innerTag)
        let ceBodyFrom5 = try AES.GCM.open(innerBox, using: SymmetricKey(data: innerKeyBytes), authenticating: Data())

        let ceVersion = (wireType &- 4) &- 2
        let ceFrameSize = UInt32(5 + ceBodyFrom5.count)
        var reconstructed = Data(capacity: Int(ceFrameSize))
        reconstructed.appendUInt32LE(ceFrameSize)
        reconstructed.appendUInt8(ceVersion)
        reconstructed.append(ceBodyFrom5)
        return (reconstructed, ksId, clientEphPubBytes)
    }
}
