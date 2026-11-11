import XCTest
@testable import ZolaKit

final class IncomingCallIdentityTests: XCTestCase {
    func testNewIncomingInviteUsesItsHeaderCallerInsteadOfPreviouslyBoundPartner() throws {
        // Same native envelope shape verified in mac35: userId is callee; srcId is caller.
        let element = try makeElement(cmd: 402, srcId: 100_000_102,
            body: #"{"error_code":0,"data":{"id":202,"userId":100000103,"Dname":"Test caller"}}"#)
        let result = ZolaVoipProtocol.interpretIncomingElement(element,
            activeCallId: 101, clientCallId: 101, activePartnerUid: 123_456_789, selfUid: 100_000_103)
        XCTAssertEqual(result.resolvedPartnerUid, 100_000_102)
        guard case let .incomingInvite(id, caller, _, _, _, _, _, _) = result.event else {
            return XCTFail("A new invite still needs its own identity before busy handling")
        }
        XCTAssertEqual(id, 202)
        XCTAssertEqual(caller, 100_000_102)
    }

    func testIncomingInviteNeverBorrowsPriorPartnerWhenHeaderIsCallee() throws {
        let element = try makeElement(cmd: 402, srcId: 100_000_103,
            body: #"{"error_code":0,"data":{"id":202,"userId":100000103}}"#)
        let result = ZolaVoipProtocol.interpretIncomingElement(element,
            activeCallId: 101, clientCallId: 101, activePartnerUid: 123_456_789, selfUid: 100_000_103)
        XCTAssertEqual(result.resolvedPartnerUid, 0)
        XCTAssertNil(result.event, "Malformed new invite cannot address signaling to the previous caller")
    }

    func testCurrentCallAnswerStillFallsBackToBoundPartner() throws {
        let element = try makeElement(cmd: 403, srcId: 100_000_103,
            body: #"{"error_code":0,"data":{"id":101,"status":0}}"#)
        let result = ZolaVoipProtocol.interpretIncomingElement(element,
            activeCallId: 101, clientCallId: 101, activePartnerUid: 100_000_102, selfUid: 100_000_103)
        XCTAssertEqual(result.resolvedPartnerUid, 100_000_102)
        guard case .answered = result.event else { return XCTFail("Active call answer remains supported") }
    }

    private func makeElement(cmd: Int16, srcId: Int32, body: String) throws -> ZolaUnpackedChatElement {
        try ZolaCrypto.unpackChatElementFrame(ZolaCrypto.packServerChatElementFrame(
            bodyData: Data(body.utf8), srcId: srcId, msgType: 1, cmd: cmd, subCmd: 0
        ).payload)
    }
}
