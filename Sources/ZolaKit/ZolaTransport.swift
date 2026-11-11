import Foundation
import zlib

public protocol ZolaNetworkTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Int, Data)
}

private final class ZolaNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class ZolaURLSessionTransport: ZolaNetworkTransport, @unchecked Sendable {
    private let urlSession: URLSession

    public init(timeoutSeconds: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds + 5
        self.urlSession = URLSession(configuration: config, delegate: ZolaNoRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    public func execute(_ request: URLRequest) async throws -> (Int, Data) {
        if let u = request.url?.absoluteString, ZolaClient.isForbiddenWebWpaURL(u) {
            throw ZolaError.safetyGate(
                "Đã chặn endpoint Zalo Web (*-wpa.chat.zalo.me) trên phiên iOS Native để tránh lỗi mã 602 (zpw_type)."
            )
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ZolaError.transport("Response is not HTTPURLResponse")
        }
        return (http.statusCode, data)
    }
}

public enum ZolaRequestBuilder {
    private static let percentSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: percentSafe) ?? value
    }

    public static func formEncode(_ params: [String: String]) -> String {
        params.keys.sorted().map { k in
            "\(urlEncode(k))=\(urlEncode(params[k] ?? ""))"
        }.joined(separator: "&")
    }

    public static func applySessionBoxHeaders(_ request: inout URLRequest, session: ZolaSession, urlString: String) {
        if let tok = session.sessionBoxToken(for: urlString), !tok.name.isEmpty, !tok.value.isEmpty {
            request.setValue(tok.name, forHTTPHeaderField: ZolaConstants.sessionBoxHeaderName)
            request.setValue(tok.value, forHTTPHeaderField: ZolaConstants.sessionBoxHeaderValue)
        } else {
            request.setValue(nil, forHTTPHeaderField: ZolaConstants.sessionBoxHeaderName)
            request.setValue(nil, forHTTPHeaderField: ZolaConstants.sessionBoxHeaderValue)
        }
    }

    /// Mode 1 `UXMutableURLRequest` (`encryptParams` unset): plaintext query + MD5 `sig` + `Cookie`.
    public static func buildPlaintextSignedGET(
        baseURL: String,
        params: [String: String],
        session: ZolaSession,
        callIdMs: Int64? = nil
    ) throws -> URLRequest {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        var merged: [String: String] = [
            "client_type": String(ZolaConstants.clientTypeIOS),
            "client_version": String(ZolaConstants.clientVersionIOS),
            "api_key": session.apiKey,
            "session_key": session.sessionKey,
            "v": ZolaConstants.apiVersionV3,
            "error_code_fallback": "1",
            "call_id": String(cid),
        ]
        for (k, v) in params { merged[k] = v }
        let sig = ZolaCrypto.makeSignature(params: merged, apiSecret: session.apiSecret)
        merged["sig"] = sig

        let qs = formEncode(merged)
        let sep = baseURL.hasSuffix("?") ? "" : (baseURL.contains("?") ? "&" : "?")
        let fullURLString = "\(baseURL)\(sep)\(qs)"
        guard let url = URL(string: fullURLString) else {
            throw ZolaError.invalidArgument("Invalid URL: \(baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        req.setValue("session_key=\(session.sessionKey); api_key=\(session.apiKey); sig=\(sig)", forHTTPHeaderField: "Cookie")
        applySessionBoxHeaders(&req, session: session, urlString: fullURLString)
        return req
    }

    /// Mode 2 `UXMutableURLRequest` (`encryptParams=1` AES-256-CBC `paramKey(zcid)` + `sig`).
    public static func buildEncryptedRequest(
        url baseURL: String,
        innerParams: [String: Any],
        session: ZolaSession,
        method: String = "POST",
        callIdMs: Int64? = nil
    ) throws -> URLRequest {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        var inner = innerParams
        if inner["api_key"] == nil { inner["api_key"] = session.apiKey }
        if inner["call_id"] == nil { inner["call_id"] = cid }
        if inner["v"] == nil { inner["v"] = ZolaConstants.apiVersionV3 }
        if inner["error_code_fallback"] == nil { inner["error_code_fallback"] = "1" }
        if inner["client_type"] == nil { inner["client_type"] = ZolaConstants.clientTypeIOS }
        if inner["client_version"] == nil { inner["client_version"] = ZolaConstants.clientVersionIOS }
        if inner["session_key"] == nil { inner["session_key"] = session.sessionKey }

        let encHex = try ZolaCrypto.encryptZCIDParams(inner, zcid: session.zcid)
        var outer: [String: String] = [
            "api_key": session.apiKey,
            "data": encHex,
            "encryptParams": "1",
        ]
        outer["sig"] = ZolaCrypto.makeSignature(params: outer, apiSecret: session.apiSecret)
        let encodedPairs = formEncode(outer)
        let zcidClean = session.zcid.hasPrefix("1_") ? String(session.zcid.dropFirst(2)) : session.zcid

        let upperMethod = method.uppercased()
        let finalURLString: String
        if upperMethod == "GET" {
            let sep = baseURL.hasSuffix("?") ? "" : (baseURL.contains("?") ? "&" : "?")
            finalURLString = "\(baseURL)\(sep)\(encodedPairs)"
        } else {
            finalURLString = baseURL
        }
        guard let url = URL(string: finalURLString) else {
            throw ZolaError.invalidArgument("Invalid URL: \(baseURL)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = upperMethod
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(ZolaCrypto.userAgent(forZCID: session.zcid), forHTTPHeaderField: "user-agent")
        req.setValue(zcidClean, forHTTPHeaderField: "zcid")
        req.setValue(session.sessionKey, forHTTPHeaderField: "session_key")
        req.setValue("session_key=\(session.sessionKey)", forHTTPHeaderField: "cookie")
        req.setValue("v2", forHTTPHeaderField: "v")
        req.setValue("0", forHTTPHeaderField: "retry")
        if upperMethod == "POST" {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            req.httpBody = Data(encodedPairs.utf8)
        }
        applySessionBoxHeaders(&req, session: session, urlString: finalURLString)
        return req
    }

    public static func buildChatRestInner(
        dataObject: [String: Any],
        session: ZolaSession,
        callIdMs: Int64? = nil
    ) throws -> [String: Any] {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let dataJson = try JSONSerialization.data(withJSONObject: dataObject, options: [.sortedKeys, .withoutEscapingSlashes])
        return [
            "api_key": session.apiKey,
            "call_id": cid,
            "v": ZolaConstants.apiVersionV3,
            "error_code_fallback": "1",
            "client_type": ZolaConstants.clientTypeIOS,
            "clientType": ZolaConstants.clientTypeIOS,
            "client_version": ZolaConstants.clientVersionIOS,
            "clientVersion": ZolaConstants.clientVersionIOS,
            "clientLanguage": 0,
            "trackingData": "",
            "trackingSource": 0,
            "session_key": session.sessionKey,
            "data": String(decoding: dataJson, as: UTF8.self),
        ]
    }

    public static func buildFailoverOctetPOST(
        session: ZolaSession,
        desId: Int32,
        globalMsgId: Int64,
        subCmd: Int8,
        bodyData: Data,
        e2ee: Bool = false,
        callIdMs: Int64? = nil
    ) throws -> (request: URLRequest, frame: ZolaFailoverFrame, endpointBase: String) {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let frame = try ZolaCrypto.packHttpFailoverFrame(
            srcId: Int32(truncatingIfNeeded: session.uid),
            desId: desId,
            globalMsgId: globalMsgId,
            subCmd: subCmd,
            bodyData: bodyData,
            sessionKey: session.sessionKey,
            e2ee: e2ee
        )
        let token = ZolaCrypto.makeFailoverToken(srcId: session.uid, length: frame.dataLength, apiKey: session.apiKey)
        let qs = "token=\(urlEncode(token))&client_type=\(ZolaConstants.clientTypeIOS)&client_version=\(ZolaConstants.clientVersionIOS)&api_key=\(session.apiKey)&session_key=\(urlEncode(session.sessionKey))&v=\(ZolaConstants.apiVersionFailover)&call_id=\(cid)"
        let endpointBase = e2ee ? session.failoverUrlE2ee : "\(session.failoverUrl)/api/message"
        let fullURLString = "\(endpointBase)?\(qs)"
        guard let url = URL(string: fullURLString) else {
            throw ZolaError.invalidArgument("Invalid failover URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = frame.frameBytes
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(ZolaCrypto.userAgent(forZCID: session.zcid), forHTTPHeaderField: "User-Agent")
        applySessionBoxHeaders(&req, session: session, urlString: fullURLString)
        return (req, frame, endpointBase)
    }

    // `buildFailoverVoipPOST` → Call/ZolaRequestBuilder+Voip.swift (CALL MODULE, khoá)

    /// Builds a POST request for fetching queued 1-1 offline messages (`cmd = 115, subCmd = 1`).
    public static func buildFailoverGetOfflinePOST(
        session: ZolaSession,
        e2ee: Bool = false,
        callIdMs: Int64? = nil
    ) throws -> (request: URLRequest, frame: ZolaFailoverFrame, endpointBase: String) {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let frame = try ZolaCrypto.packHttpFailoverGetOfflineFrame(
            srcId: Int32(truncatingIfNeeded: session.uid),
            sessionKey: session.sessionKey,
            e2ee: e2ee
        )
        // Offline queue request uses the full frame byte length for the failover token:
        let token = ZolaCrypto.makeFailoverToken(srcId: session.uid, length: frame.frameBytes.count, apiKey: session.apiKey)
        let qs = "token=\(urlEncode(token))&client_type=\(ZolaConstants.clientTypeIOS)&client_version=\(ZolaConstants.clientVersionIOS)&api_key=\(session.apiKey)&session_key=\(urlEncode(session.sessionKey))&v=\(ZolaConstants.apiVersionFailover)&call_id=\(cid)"
        let endpointBase = e2ee ? session.failoverUrlE2ee : "\(session.failoverUrl)/api/message"
        let fullURLString = "\(endpointBase)?\(qs)"
        guard let url = URL(string: fullURLString) else {
            throw ZolaError.invalidArgument("Invalid failover GetOffline URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = frame.frameBytes
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(ZolaCrypto.userAgent(forZCID: session.zcid), forHTTPHeaderField: "User-Agent")
        applySessionBoxHeaders(&req, session: session, urlString: fullURLString)
        return (req, frame, endpointBase)
    }

    public static func parseEnvelope(
        _ rawData: Data,
        session: inout ZolaSession,
        endpoint: String,
        noisedPublicKey: Int64? = nil,
        noisedGid: Int64? = nil,
        decryptZCID: Bool = false
    ) throws -> [String: Any] {
        let unzipped = gunzipDecompress(rawData) ?? rawData
        guard var env = try JSONSerialization.jsonObject(with: unzipped) as? [String: Any] else {
            throw ZolaError.transport("Non-JSON response on \(endpoint)")
        }
        let errCode = env["error_code"] != nil ? ZolaJSON.int(env["error_code"]) : nil
        let eCode = env["e"] != nil ? ZolaJSON.int(env["e"]) : nil
        let errMsg = ZolaJSON.string(env["error_message"] ?? env["errMessage"])

        if errCode == ZolaConstants.errorSessionExpired || eCode == ZolaConstants.errorSessionExpired || eCode == ZolaConstants.errorFemcInvalidSession {
            let code = errCode == ZolaConstants.errorSessionExpired ? ZolaConstants.errorSessionExpired : (eCode ?? ZolaConstants.errorSessionExpired)
            let reason = friendlySessionExpiredReason(errMsg, code: code)
            session.markExpired(code: code, reason: reason)
            throw ZolaError.sessionExpired(code: code, endpoint: endpoint, message: reason)
        }

        if ZolaJSON.int(env["isNoised"]) == 1, let b64 = env["data"] as? String, !b64.isEmpty {
            guard let pubKey = noisedPublicKey else {
                throw ZolaError.transport("isNoised=1 response missing publicKey")
            }
            env["data"] = try ZolaCrypto.decryptNoisedGroupData(base64: b64, uid: session.uid, publicKey: pubKey, gid: noisedGid)
        } else if decryptZCID, let hexStr = env["data"] as? String, !hexStr.isEmpty {
            env["data"] = try ZolaCrypto.decryptZCIDAny(hexStr, zcid: session.zcid)
        }
        return env
    }

    public static func friendlySessionExpiredReason(_ raw: String?, code: Int = 102) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Cần đăng nhập lại để đồng bộ tin nhắn"
        }
        let lower = trimmed.lowercased()
        if lower.contains("session key")
            || lower.contains("improperly submitted")
            || lower.contains("timeout")
            || lower.contains("obtain another key")
            || lower.contains("session expired")
            || lower.contains("session invalid")
            || lower.contains("phien het han")
            || lower.contains("phiên hết hạn")
        {
            return "Cần đăng nhập lại để đồng bộ tin nhắn"
        }
        return trimmed
    }

    /// Parses an API envelope for auxiliary directory/contact endpoints without tripping the session circuit-breaker.
    public static func parseEnvelopeNonLatching(
        _ rawData: Data,
        session: ZolaSession,
        decryptZCID: Bool = false
    ) -> [String: Any]? {
        let unzipped = gunzipDecompress(rawData) ?? rawData
        guard var env = (try? JSONSerialization.jsonObject(with: unzipped)) as? [String: Any] else {
            return nil
        }
        if decryptZCID, let hexStr = env["data"] as? String, !hexStr.isEmpty {
            if let dec = try? ZolaCrypto.decryptZCIDAny(hexStr, zcid: session.zcid) {
                env["data"] = dec
            } else if let rawDataBytes = Data(base64Encoded: hexStr),
                      let gunzipped = gunzipDecompress(rawDataBytes),
                      let decObj = try? JSONSerialization.jsonObject(with: gunzipped),
                      decObj is [String: Any] || decObj is [Any]
            {
                env["data"] = decObj
            }
        } else if let strData = env["data"] as? String, !strData.isEmpty {
            if let b64 = Data(base64Encoded: strData) {
                let unz = gunzipDecompress(b64) ?? b64
                if let obj = try? JSONSerialization.jsonObject(with: unz) {
                    env["data"] = obj
                }
            } else if let obj = try? JSONSerialization.jsonObject(with: Data(strData.utf8)) {
                env["data"] = obj
            }
        }
        return env
    }

    /// Builds a Mode 1 plaintext-signed multipart/form-data POST request (`submitPhones?` / `discoverContact?`).
    public static func buildPlaintextSignedMultipartPOST(
        baseURL: String,
        params: [String: String],
        fileFieldName: String = "file",
        fileName: String = "file",
        mimeType: String = "application/json",
        fileData: Data,
        session: ZolaSession,
        callIdMs: Int64? = nil
    ) throws -> URLRequest {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        var merged: [String: String] = [
            "client_type": String(ZolaConstants.clientTypeIOS),
            "client_version": String(ZolaConstants.clientVersionIOS),
            "api_key": session.apiKey,
            "session_key": session.sessionKey,
            "v": ZolaConstants.apiVersionV3,
            "error_code_fallback": "1",
            "call_id": String(cid),
        ]
        for (k, v) in params { merged[k] = v }
        let sig = ZolaCrypto.makeSignature(params: merged, apiSecret: session.apiSecret)
        merged["sig"] = sig

        let qs = formEncode(merged)
        let sep = baseURL.hasSuffix("?") ? "" : (baseURL.contains("?") ? "&" : "?")
        let fullURLString = "\(baseURL)\(sep)\(qs)"
        guard let url = URL(string: fullURLString) else {
            throw ZolaError.invalidArgument("Invalid URL: \(baseURL)")
        }

        let boundary = "Boundary+\(String(format: "%08X%08X", UInt32.random(in: 1...UInt32.max), UInt32.random(in: 1...UInt32.max)))"
        var body = Data()
        for key in merged.keys.sorted() {
            let val = merged[key] ?? ""
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(val)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        req.setValue("session_key=\(session.sessionKey); api_key=\(session.apiKey); sig=\(sig)", forHTTPHeaderField: "Cookie")
        applySessionBoxHeaders(&req, session: session, urlString: fullURLString)
        return req
    }

    public static func gzipCompress(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        var stream = z_stream()
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var compressed = Data(count: max(128, input.count + 64))
        let result: Int32 = input.withUnsafeBytes { inRaw in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
            stream.avail_in = uInt(input.count)
            return compressed.withUnsafeMutableBytes { outRaw in
                guard let outBase = outRaw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
                stream.next_out = outBase
                stream.avail_out = uInt(outRaw.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        compressed.count = Int(stream.total_out)
        return compressed
    }

    public static func gunzipDecompress(_ input: Data) -> Data? {
        guard input.count >= 18, input[input.startIndex] == 0x1F, input[input.startIndex + 1] == 0x8B else {
            return nil
        }
        var stream = z_stream()
        let status = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var decompressed = Data(capacity: input.count * 2)
        let chunkSize = 16_384
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        let inflateResult: Int32 = input.withUnsafeBytes { inRaw in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
            stream.avail_in = uInt(input.count)
            var ret: Int32 = Z_OK
            repeat {
                ret = chunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let have = chunkSize - Int(stream.avail_out)
                if have > 0 {
                    decompressed.append(chunk, count: have)
                }
            } while ret == Z_OK
            return ret
        }
        guard inflateResult == Z_STREAM_END else { return nil }
        return decompressed
    }
}
