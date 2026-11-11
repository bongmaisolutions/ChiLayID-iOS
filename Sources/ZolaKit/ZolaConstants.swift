import Foundation

public enum ZolaConstants {
    public static let sdkVersion = "1.0.0"

    public static let clientTypeIOS: Int = 2
    public static let clientVersionIOS: Int = 261002802
    public static let apiVersionV3 = "3.0"
    public static let apiVersionFailover = "2.0"

    public static let defaultApiKey = "3bb9d514148ca6dd16ba88d6bff387bf"
    public static let defaultApiSecret = "ab7df2c3573d7f5d3727126670aad414"
    public static let defaultIdentityCipherKey = "IXX3RM3GABH3NS0AED3VV04N9ABCDA1D"

    public static let httpKeyData = Data("SUB3RM4NXUY3NS0NTH3MH04N9M1NHT1N".utf8)
    public static let socketKeyData = Data("P1BL2G5I7NJD2H3JAUD554G7645PH54F".utf8)
    public static let noneFriendKeyData = Data("ABA3RM4YXUY3NS0ETH3HG04N9B1RHH1U".utf8)

    public static let httpFailoverVersion: Int8 = 2
    public static let checksumMagic: UInt32 = 0x6CE7DAA0

    public static let cmdHttpSendNormal: Int16 = 130
    public static let cmdHttpSendE2ee: Int16 = 10130
    public static let cmdSend1To1WithProps: Int16 = 113
    public static let subCmdPlain: Int8 = 1
    /// `+[ChatSocketCmdHelper getSubCmdType:]` (`0x100c8c308`–`0x100c8c440`):
    /// `mediatype = 2` (`"chat.voice"`) -> `31` (`0x1f`)
    public static let subCmdSendVoice: Int8 = 31
    /// `mediatype = 11 | 28` (`"chat.photo"`) -> `32` (`0x20`)
    public static let subCmdSendPhoto: Int8 = 32
    /// `mediatype = 7 | 10` (`"chat.sticker"`, `+[ChatSocketCmdHelper createStickerMesasge:...]`) -> `36` (`0x24`)
    public static let subCmdSendSticker: Int8 = 36
    /// Backwards-compatible alias for `subCmd = 36` (`0x24`)
    public static let subCmdSendMedia: Int8 = 36
    /// `mediatype = 4` (`"chat.doodle"`) -> `37` (`0x25`)
    public static let subCmdSendDoodle: Int8 = 37
    /// `mediatype = 16` (`"recommened.link"` / `"recommened.user"` / `"recommened.calltime"`) -> `38` (`0x26`)
    public static let subCmdSendLinkBubble: Int8 = 38
    public static let subCmdMcrypt: Int8 = 41
    /// `chat.location.new` -> `43` (`0x2b`)
    public static let subCmdSendLocation: Int8 = 43
    /// `mediatype = 3` (`"chat.video.msg"`) -> `44` (`0x2c`)
    public static let subCmdSendVideo: Int8 = 44
    /// `mediatype = 41` (`"share.file"`) -> `46` (`0x2e`)
    public static let subCmdSendFile: Int8 = 46
    /// `mediatype = 42` (`"chat.gif"`) -> `49` (`0x31`)
    public static let subCmdSendGif: Int8 = 49
    /// `-[ReactionEntity createReactionChatElement]` (`0x100E06A38`) -> `55` (`0x37`)
    public static let subCmdSendReaction: Int8 = 55

    // MARK: `FriendRequestManager` Native `UXChatSocket` (`0x7d0`) Commands (`Zalo 261002`)
    /// `-[FriendRequestManager sendFriendRequestTo:...]` (`0x100e82abc`) -> `cmd = 373, subCmd = 3`
    public static let cmdFriendSendRequest: Int16 = 373
    public static let subCmdFriendSendRequest: Int8 = 3
    /// `-[FriendRequestManager acceptFriendRequestFrom:...]` (`0x100e7f75c`) -> `cmd = 374, subCmd = 1`
    public static let cmdFriendAcceptRequest: Int16 = 374
    public static let subCmdFriendAcceptRequest: Int8 = 1
    /// `-[FriendRequestManager denyFriendRequestFrom:...]` (`0x100e80694`) -> `cmd = 375, subCmd = 2`
    public static let cmdFriendRejectRequest: Int16 = 375
    public static let subCmdFriendRejectRequest: Int8 = 2
    /// `-[FriendRequestManager getFriendRequestStatus:...]` (`0x100e843cc`) -> `cmd = 378, subCmd = 1`
    /// `-[FriendRequestManager getFriendRequestStatus:...]` (`0x100e843cc`) -> `cmd = 378, subCmd = 1`
    public static let cmdFriendRequestStatus: Int16 = 378
    public static let subCmdFriendRequestStatus: Int8 = 1
    /// `-[FriendRequestManager loadSentFriendRequestsFromServerWithPageIndex:...]` (`0x100e738ac`) -> `cmd = 396, subCmd = 4`
    public static let cmdFriendListSent: Int16 = 396
    public static let subCmdFriendListSent: Int8 = 4
    /// `-[FriendRequestManager undoSentFriendRequestWithFriendIds:...]` (`0x100e93784`) -> `cmd = 397, subCmd = 1`
    public static let cmdFriendUndoRequest: Int16 = 397
    public static let subCmdFriendUndoRequest: Int8 = 1
    /// `-[FriendRequestManager getDiscoverFriendList:...]` (`0x100e89884`) -> `cmd = 1582, subCmd = 0`
    public static let cmdFriendDiscoverList: Int16 = 1582
    public static let subCmdFriendDiscoverList: Int8 = 0
    /// `-[FriendRequestManager getFriendRequestAndSuggestList:...]` (`0x100e7d168`) -> `cmd = 1584, subCmd = 2`
    public static let cmdFriendListRequests: Int16 = 1584
    public static let subCmdFriendListRequests: Int8 = 2

    public static let defaultFemcHost = "https://fe-mc.chat.zalo.me"
    public static let defaultMfetchHost = "https://fe-gr-chat.zalo.me"
    public static let defaultGroupApiHost = "https://group.api.zaloapp.com"
    public static let defaultTapiHost = "https://tapi.api.zaloapp.com"
    public static let defaultGetPageHost = "https://getpage.api.zaloapp.com"
    public static let defaultFriendHost = "https://friend.api.zaloapp.com"
    /// `register_talk_m_s` API base (helper endpoints: `/api/helper/getKeySet?`, `/api/helper/getListServers?`).
    public static let defaultRegisterHost = "https://register.zaloapp.com"
    public static let defaultFailoverHost = "https://failover.zingmp3.vn"
    public static let defaultFailoverUrlE2ee = "https://failover.zingmp3.vn/api/e2e"
    public static let defaultUploadConfigURL = "https://photo.talk.zing.vn/api/v1/video/upload-config"

    public static let defaultSendToMeId: Int64 = 204_278_670

    public static let userAgentNative = "Zalo/261002 (iPhone; iOS 26.3.1; Scale/3.00)"
    public static let userAgentUXHttp = "vng.com.vn.zalo.useragent"

    public static let defaultIDFA = "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB"
    public static let defaultShortModel = "iP16Pro"
    public static let defaultIOSVersion = "26.3.1"

    public static let sessionBoxHeaderName = "znw-ss-name"
    public static let sessionBoxHeaderValue = "znw-ss-value"

    public static let errorSessionExpired: Int = 102
    public static let errorInvalidSessionKey: Int = -67
    public static let errorFemcInvalidSession: Int = -96
    public static let minPollIntervalSeconds: Double = 0.8
    public static let maxSeenIds: Int = 2000
}
