import Foundation
import zlib

// ─────────────────────────────────────────────────────────────────────────────
// CALL MODULE (Sources/ZolaKit/Call) — native voice/video calling.
// Verified with two-way voice and video calls on real iPhones. Incoming calls share the
// UXChatSocket (0x7d0) with realtime chat, so change socket/keySet/session code with care.
// ─────────────────────────────────────────────────────────────────────────────

extension ZolaRequestBuilder {
    /// Builds an authenticated HTTP failover POST request wrapping a `VoipRequestOperation` binary payload (`cmd = 425/401/402/405/406/407/408`).
    public static func buildFailoverVoipPOST(
        session: ZolaSession,
        cmd: Int16,
        subCmd: Int8,
        voipBodyData: Data,
        callIdMs: Int64? = nil
    ) throws -> (request: URLRequest, frame: ZolaFailoverFrame, endpointBase: String) {
        let cid = callIdMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let frame = ZolaCrypto.packHttpFailoverVoipFrame(
            srcId: Int32(truncatingIfNeeded: session.uid),
            cmd: cmd,
            subCmd: subCmd,
            voipBodyData: voipBodyData,
            sessionKey: session.sessionKey
        )
        let token = ZolaCrypto.makeFailoverToken(srcId: session.uid, length: frame.dataLength, apiKey: session.apiKey)
        let qs = "token=\(urlEncode(token))&client_type=\(ZolaConstants.clientTypeIOS)&client_version=\(ZolaConstants.clientVersionIOS)&api_key=\(session.apiKey)&session_key=\(urlEncode(session.sessionKey))&v=\(ZolaConstants.apiVersionFailover)&call_id=\(cid)"
        let endpointBase = "\(session.failoverUrl)/api/message"
        let fullURLString = "\(endpointBase)?\(qs)"
        guard let url = URL(string: fullURLString) else {
            throw ZolaError.invalidArgument("Invalid failover VoIP URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = frame.frameBytes
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(ZolaCrypto.userAgent(forZCID: session.zcid), forHTTPHeaderField: "User-Agent")
        applySessionBoxHeaders(&req, session: session, urlString: fullURLString)
        return (req, frame, endpointBase)
    }
}
