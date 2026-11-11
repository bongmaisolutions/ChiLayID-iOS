import Foundation
import XCTest
import ZolaKit // plain import on purpose: README examples may only use the public API.

/// Every code sample in README.md is copied here so `swift build --build-tests` fails when the README
/// drifts from the real API. The functions are compiled but never executed (they would hit the network).
enum ReadmeExamples {
    // MARK: Login

    static func loginWithPassword() async throws -> ZolaClient? {
        let auth = ZolaLoginClient()
        var outcome = try await auth.login(phone: "0901234567", password: "mat-khau")

        if case .challenge = outcome {
            // Zalo wants an OTP: ask for a code by call/SMS, then submit what the user typed.
            let request = try await auth.requestVerificationCode(
                phone: "0901234567",
                method: .callOrSms,
                existingChallenge: await auth.latestChallenge()
            )
            print(request.deliveryMessage)
            let otp = "123456" // from your UI
            outcome = try await auth.submitVerificationCode(
                phone: "0901234567",
                password: "mat-khau",
                code: otp,
                challenge: request.challenge
            )
        }

        switch outcome {
        case .success(let result):
            let session = try result.makeSession()
            try ZolaKeychainSessionStore().save(session) // Keychain, ThisDeviceOnly
            let api = Zola().login(session: session)
            print("UID:", await api.getOwnId())
            return api
        case .secureVerification(let check):
            print("Mở trang xác minh:", check.secureUrl)
        case .rejected(let code, let message, _):
            print("Đăng nhập thất bại:", code ?? -1, message ?? "")
        case .challenge:
            break
        }
        return nil
    }

    static func restoreSession() throws -> ZolaClient {
        try Zola().loadKeychainSession(uid: 100_000_101)
    }

    // MARK: Listen

    static func listen(api: ZolaClient) async throws {
        for try await event in api.events(intervalSeconds: 2) {
            switch event.type {
            case "message.new":
                guard let msg = event.message else { continue }
                print("[\(msg.isGroup ? "group" : "1-1") \(msg.threadId)] \(msg.senderName): \(msg.text)")
            case "message.reaction":
                print("reaction:", event.reaction as Any)
            case "session.expired":
                print("Phiên đã hết hạn, cần đăng nhập lại")
                return
            default:
                break
            }
        }
    }

    static func inbox(api: ZolaClient) async throws {
        let conversations = try await api.syncInbox(discoverGroups: true)
        await api.primeWatermarks(from: conversations)
        for c in conversations.prefix(20) {
            print(c.title, c.unreadCount, c.lastMessage?.text ?? "")
        }
    }

    // MARK: Messages

    static func messages(api: ZolaClient, incoming: ZolaMessage) async throws {
        let userId: Int64 = 100_000_102
        let groupId: Int64 = 900_000_201

        // Text 1-1 (sendMessage defaults to dryRun: true — pass false to really send)
        let receipt = try await api.sendMessage("Xin chào từ ZolaKit!", threadId: userId, type: .user, dryRun: false)
        print(receipt.sent, receipt.serverGlobalMsgId ?? 0)

        // Text to a group, with an @mention
        _ = try await api.sendGroupText(
            gid: groupId,
            text: "Chào @An",
            mentions: [ZolaMention(type: 0, uid: 100_000_101, pos: 5, len: 3)],
            dryRun: false
        )

        // Reply (quote) to a received message
        if let quote = incoming.quote {
            _ = try await api.sendQuotedText(text: "Đã nhận!", threadId: userId, quote: quote, dryRun: false)
        }

        // Photo / video / file / voice
        let jpeg = Data(), mp4 = Data(), pdf = Data(), m4a = Data()
        _ = try await api.uploadAndSendPhoto(imageData: jpeg, threadId: userId, type: .user, caption: "Ảnh nè")
        _ = try await api.uploadAndSendVideo(videoData: mp4, threadId: userId, type: .user)
        _ = try await api.uploadAndSendFile(fileData: pdf, fileName: "bao-gia.pdf", threadId: userId, type: .user)
        _ = try await api.uploadAndSendVoiceFile(audioData: m4a, threadId: userId, type: .user, durationMs: 3_000)

        // Sticker, link, location, contact card
        _ = try await api.sendStickerResolvingDetail(stickerId: 23_285, cateIdHint: 10_425, threadId: userId, type: .user)
        _ = try await api.sendLink1To1(to: userId, url: "https://zalo.me", dryRun: false)
        _ = try await api.sendLocation1To1(to: userId, latitude: 21.0288, longitude: 105.8520, title: "Hồ Gươm", dryRun: false)
        _ = try await api.sendContactCard1To1(to: userId, contactUid: 100_000_103, contactName: "Lê Chi", dryRun: false)

        // Reaction, recall, delete, typing, seen
        _ = try await api.addReaction("❤️", message: incoming, type: .user)
        _ = try await api.undo(message: incoming, threadId: userId, type: .user)
        _ = try await api.deleteMessage(incoming, threadId: userId, type: .user, onlyMe: true)
        _ = try await api.sendTypingEvent(threadId: userId, type: .user)
        _ = try await api.sendSeenEvent(messages: [incoming], type: .user)

        // Older group history
        let page = try await api.fetchOlderGroupHistory(gid: groupId, beforeGlobalMsgId: incoming.id)
        print(page.messages.count, page.exhausted)
    }

    // MARK: Contacts

    static func contacts(api: ZolaClient) async throws {
        if let user = try await api.findUser("0901234567") {
            print(user.uid, user.displayName, user.isFriend)
            let outcome = try await api.sendFriendRequest(toUid: user.uid, message: "Chào bạn, kết bạn nhé!")
            print(outcome)
        }

        switch try await api.findUserByPhone("0987654321") {
        case .found(let user): print("found", user.uid)
        case .notFound: print("Không có tài khoản Zalo")
        case .failed(let code, let message): print(code, message)
        }

        let friends = try await api.getAllFriends()
        let profile = try await api.getUserInfo(100_000_102)
        let incomingRequests = try await api.fetchFriendRequests()
        _ = try await api.acceptFriendRequest(fromUid: 100_000_104)
        _ = try await api.rejectFriendRequest(fromUid: 100_000_105)
        _ = try await api.undoFriendRequest(toUid: 100_000_106)
        _ = try await api.changeFriendAlias("Chị Chi kế toán", friendId: 100_000_103)
        _ = try await api.blockUser(100_000_107)
        print(friends.count, profile.displayName, incomingRequests.count)
    }

    // MARK: Account

    static func account(api: ZolaClient) async throws {
        let me = try await api.fetchAccountInfo()
        print(me.uid, me.displayName, me.avatarUrl)
        _ = try await api.sendToMe(text: "Ghi chú vào Cloud của tôi", dryRun: false)
        let alive = try await api.keepAlive()
        print(alive)
    }

    // MARK: Groups

    static func groups(api: ZolaClient) async throws {
        let groups = try await api.getAllGroups()
        let info = try await api.getGroupInfo(gid: 900_000_201)
        print(groups.count, info.name, info.totalMembers, info.adminIds)

        let created = try await api.createGroup(name: "Nhóm dự án", members: [100_000_102, 100_000_103])
        print(created)
        _ = try await api.addUserToGroup(groupId: 900_000_201, memberIds: [100_000_104])
        _ = try await api.removeUserFromGroup(groupId: 900_000_201, memberIds: [100_000_104])
        _ = try await api.changeGroupName("Nhóm dự án 2026", groupId: 900_000_201)
        let link = try await api.enableGroupLink(groupId: 900_000_201)
        print(link ?? "")
    }

    // MARK: Conversation settings

    static func conversationSettings(api: ZolaClient) async throws {
        _ = try await api.setPinnedConversations(pinned: true, threadIds: [100_000_102], type: .user)
        _ = try await api.setMute(threadId: 900_000_201, durationSeconds: 3_600, type: .group)
        let tags = try await api.fetchChatTags()
        print(tags.labelData.map(\.text))
        let tag = try await api.createChatTag(text: "Khách VIP", color: "#0068FF", dryRun: false)
        _ = try await api.updateConversationTags(
            threadId: 100_000_102, isGroup: false, addTagIds: [tag.id], removeTagIds: [], dryRun: false
        )
    }

    // MARK: Timeline & Stories

    static func timeline(api: ZolaClient) async throws {
        // Feed reads also default to dryRun: true (returns nil). Pass false to hit the server.
        if let page = try await api.fetchTimelineFeed(dryRun: false) {
            for post in page.posts {
                print(post.authorName, post.caption, post.photos.count, post.likeCount)
            }
            if let first = page.posts.first {
                let comments = try await api.fetchFeedComments(feedId: first.id, dryRun: false)
                print(comments?.comments.count ?? 0)
                _ = try await api.reactToFeed(feedId: first.id, like: true, dryRun: false)
                _ = try await api.commentOnFeed(feedId: first.id, text: "Đẹp quá!", dryRun: false)
            }
            if let next = page.nextCursor {
                _ = try await api.fetchTimelineFeed(cursor: next, dryRun: false)
            }
        }

        let feedId = try await api.postTimelineText("Hôm nay trời đẹp", privacy: .onlyMe, dryRun: false)
        if let feedId { _ = try await api.deleteTimelinePost(feedId: feedId, dryRun: false) }

        if let bar = try await api.fetchStoryUsers(dryRun: false) {
            for user in bar.users {
                let stories = try await api.fetchUserStories(userId: user.uid, dryRun: false)
                print(user.name, stories?.count ?? 0)
            }
        }
    }

    // MARK: Calls

    static func calls(api: ZolaClient) async throws {
        let myUid = Int64(await api.getOwnId()) ?? 0

        await api.setVoipEventHandler { event in
            switch event {
            case .incomingInvite(let callId, let partnerUid, let isVideo, let callerName, _, let rtp, _, let sessionId):
                print("Cuộc gọi đến từ \(callerName) (\(partnerUid)) call=\(callId) video=\(isVideo)")
                Task {
                    do {
                        try await api.answerVoipCall(partnerUid: partnerUid, callId: callId, isVideo: isVideo,
                                                     rtpAddress: rtp, sessionId: sessionId)
                        let engine = ZolaVoipMediaEngine(callId: callId)
                        engine.configureZrtcSession(isCaller: false, selfUid: myUid, partnerUid: partnerUid, sessionId: sessionId)
                        let parts = rtp.split(separator: ":")
                        if parts.count == 2, let port = UInt16(parts[1]) {
                            try engine.start(relay: .init(host: String(parts[0]), port: port), preferredCodec: .opus)
                        }
                    } catch {
                        print("Không nghe máy được:", error)
                    }
                }
            case .answered(let callId, _): print("Đã nghe máy", callId)
            case .ended(let callId, _, let reason): print("Kết thúc", callId, reason)
            case .failed(_, _, let code, let message): print("Lỗi", code, message)
            default: break
            }
        }
        try await api.startVoipIncomingListener()

        // Outgoing voice call
        let partner: Int64 = 100_000_102
        let call = try await api.startVoipCall(partnerUid: partner, isVideo: false)
        if let engine = await api.takePreparedVoipMediaEngine(forCallId: call.callId) {
            engine.setSpeakerphone(true)
            engine.setMuted(false)
        }

        // Hang up
        try await api.cancelVoipCall(partnerUid: partner, callId: call.callId, durationSeconds: 42, isConnected: true)
        await api.stopVoipIncomingListener()
    }

    static func videoFrames(engine: ZolaVoipMediaEngine) {
        engine.setVideoMode(enabled: true, cameraEnabled: true, preferFrontCamera: true)
        engine.onRemoteVideoPixelBuffer = { pixelBuffer, time in
            _ = (pixelBuffer, time) // render with AVSampleBufferDisplayLayer / Metal
        }
    }

    // MARK: Local history & stickers

    static func localHistory(api: ZolaClient, dbURL: URL) async throws {
        let store = try ZolaMessageStore(fileURL: dbURL) // SQLite WAL, 0600
        let uid = Int64(await api.getOwnId()) ?? 0
        let conversations = try await api.syncInbox()
        try store.upsertConversations(conversations.map { (accountUid: uid, conversation: $0) })
        let recent = try store.messages(accountUid: uid, threadId: 100_000_102, limit: 50)
        let hits = try store.matchingThreadKeys(query: "hop dong bao hanh") // không dấu vẫn khớp
        print(recent.count, hits)
    }

    static func stickers(api: ZolaClient) async {
        if let match = ZolaStickerSuggester.instantMatch(for: "cảm ơn nhé") {
            print(match)
        }
        let suggestions = await api.suggestContextualStickers(for: "cảm ơn nhé", limit: 12)
        print(suggestions.map(\.stickerId))
    }
}

final class ReadmeExamplesCompileTests: XCTestCase {
    func testReadmeExamplesCompile() {
        // Compiling this file is the test. Keep a reference so the enum is not stripped.
        XCTAssertNotNil(ReadmeExamples.self)
    }
}
