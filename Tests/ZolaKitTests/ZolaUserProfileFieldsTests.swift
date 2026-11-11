import XCTest
@testable import ZolaKit

/// Field names mirror a live native `api/contact/getProfile` response (keys only were recorded):
/// avt, avt_version, cover, dob, dpn, ged, lastUpdateTime, last_action, name_score, oa_type, phone,
/// phone_status, profile_stt, receive_type, sdob, secret_msg, stt, type, uid, unmap_profile, usr, voice.
final class ZolaUserProfileFieldsTests: XCTestCase {
    private func nativeProfile(stt: Any = "Sống chậm lại một chút", sdob: Any = "12/08") -> [String: Any] {
        [
            "uid": 500_111, "dpn": "Khách Thử", "usr": "khachthu",
            "avt": "https://s120-ava-talk.zadn.vn/a/b/avatar.jpg",
            "cover": "https://cover-talk.zadn.vn/c/d/cover.jpg",
            "ged": 1, "stt": stt, "sdob": sdob, "dob": 0, "profile_stt": 1,
            "phone": "", "type": 0, "avt_version": 3,
        ]
    }

    func testNativeProfileMapsCoverBioGenderAndBirthday() {
        let user = ZolaUser.fromServerDict(nativeProfile())
        XCTAssertEqual(user.uid, 500_111)
        XCTAssertEqual(user.displayName, "Khách Thử")
        XCTAssertEqual(user.coverUrl, "https://cover-talk.zadn.vn/c/d/cover.jpg")
        XCTAssertEqual(user.fullAvatarUrl, user.avatarUrl, "The cover must never be used as the large avatar")
        XCTAssertEqual(user.statusText, "Sống chậm lại một chút")
        XCTAssertEqual(user.gender, 1)
        XCTAssertEqual(user.birthday, "12/08")
    }

    func testNumericFlagsAreNeverShownAsBioOrBirthday() {
        let user = ZolaUser.fromServerDict(nativeProfile(stt: 1, sdob: 0))
        XCTAssertEqual(user.statusText, "")
        XCTAssertNil(user.birthday)
    }

    func testUsersCachedBeforeProfileFieldsStillDecode() throws {
        let legacy = Data(#"{"uid":7,"displayName":"Cũ","zaloName":"","avatarUrl":"","fullAvatarUrl":"","phone":"","gender":0,"statusText":"","globalId":"","isFriend":true}"#.utf8)
        let user = try JSONDecoder().decode(ZolaUser.self, from: legacy)
        XCTAssertEqual(user.uid, 7)
        XCTAssertNil(user.coverUrl)
        XCTAssertNil(user.birthday)
        let roundTrip = try JSONDecoder().decode(ZolaUser.self, from: JSONEncoder().encode(ZolaUser.fromServerDict(nativeProfile())))
        XCTAssertEqual(roundTrip.coverUrl, "https://cover-talk.zadn.vn/c/d/cover.jpg")
    }
}
