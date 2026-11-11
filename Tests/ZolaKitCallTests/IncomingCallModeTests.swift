import XCTest
@testable import ZolaKit

final class IncomingCallModeTests: XCTestCase {
    func testNativeVoiceInviteWithVideoCapabilitiesStaysVoice() throws {
        // Live sanitized capture 2026-11-04: cmd402/sub0, no outer mode flags,
        // video objects at both levels, but explicit extendData.callType=0.
        for wrapped in [false, true] {
            let ext: [String: Any] = ["callType": 0, "video": ["codec": []]]
            let rawExt: Any = wrapped ? String(data: try JSONSerialization.data(withJSONObject: ext), encoding: .utf8)! : ext
            let result = try interpret(["video": ["codec": []], "extendData": rawExt])
            XCTAssertFalse(result, "Codec capabilities do not turn a voice invite into a camera call")
        }
    }

    func testNativeVideoInviteWithSameCapabilitiesStaysVideo() throws {
        // Same live shape as voice; callType=1 is the observed difference.
        XCTAssertTrue(try interpret(["video": ["codec": []],
                                    "extendData": ["callType": 1, "video": ["codec": []]]]))
    }

    func testNestedVoiceModeOverridesOuterVideoCapabilityObject() throws {
        let extra: [String: Any] = ["extendData": ["callType": 0, "video": ["codec": []]]]
        let serialized = String(data: try JSONSerialization.data(withJSONObject: extra), encoding: .utf8)!
        XCTAssertFalse(try interpret(["video": ["codec": []], "extraData": serialized]))
    }

    func testLegacyExplicitVideoFlagStillWorksWithoutExtendDataMode() throws {
        XCTAssertTrue(try interpret(["isVideo": 1]))
        XCTAssertFalse(try interpret([:]))
    }

    private func interpret(_ fields: [String: Any]) throws -> Bool {
        var data = fields
        data["id"] = 123
        data["userId"] = 100_000_103
        let body = try JSONSerialization.data(withJSONObject: ["error_code": 0, "data": data])
        let element = try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packServerChatElementFrame(
            bodyData: body, srcId: 100_000_102, msgType: 1, cmd: 402, subCmd: 0).payload)
        let parsed = ZolaVoipProtocol.interpretIncomingElement(element, activeCallId: 0,
            clientCallId: 0, activePartnerUid: 0, selfUid: 100_000_103)
        guard case let .incomingInvite(_, _, video, _, _, _, _, _) = parsed.event else {
            XCTFail("Expected valid incoming invite")
            return false
        }
        return video
    }
}
