import Foundation
import Combine
import ZolaKit
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
public final class BMSZaloViewModel: ObservableObject {
    // MARK: - Auth & Session State
    @Published public var isAuthenticated: Bool = false
    @Published public var isBusy: Bool = false
    @Published public var statusBanner: String?
    @Published public var errorMessage: String?

    @Published public var savedKeychainAccounts: [String] = []
    @Published public var activeSession: ZolaSession?
    @Published public var activeAccountProfile: ZolaUser?
    @Published public var currentDeviceIdentity: ZolaDeviceIdentity

    // Pending challenge / secure check state during login
    @Published public var pendingChallenge: ZolaLoginChallenge?
    @Published public var pendingPhone: String = ""
    @Published public var pendingPassword: String = ""
    @Published public var pendingSecureCheckURL: URL?

    // MARK: - Safety & Control Toggles
    @Published public var isDryRun: Bool = true
    @Published public var isGroupSendEnabled: Bool = false
    @Published public var eventPollIntervalSeconds: Double = 2.0

    // MARK: - Inbox & Chat State
    public enum InboxFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "Tất cả"
        case unread = "Chưa đọc"
        case groups = "Nhóm"
        case direct = "Cá nhân"
        case pinned = "Đã ghim"
        case cloud = "Cloud của tôi"
        case byTag = "Theo phân loại"
        public var id: String { rawValue }
    }

    @Published public var inboxFilter: InboxFilter = .all
    @Published public var selectedTagId: Int?
    @Published public var searchQuery: String = ""
    @Published public var conversations: [ZolaConversation] = []
    @Published public var selectedThreadId: Int64?
    @Published public var messagesByThread: [Int64: [ZolaMessage]] = [:]
    @Published public var typingUsersByThread: [Int64: Int64] = [:]

    @Published public var pinnedThreadIds: Set<Int64> = []
    @Published public var mutedThreadIds: Set<Int64> = []
    @Published public var chatTags: [ZolaLabel] = []
    @Published public var currentThreadPinBoard: [ZolaPinnedMessage] = []
    @Published public var currentPinBoardVersion: Int64 = 0
    @Published public var activeGroupPoll: ZolaGroupPollDetail?

    // Stickers & Quick Messages
    @Published public var stickerSuggestions: [ZolaStickerItem] = []
    @Published public var searchedStickers: [ZolaStickerItem] = []
    @Published public var quickMessagesSummary: String = ""
    @Published public var autoRepliesSummary: String = ""

    // MARK: - Contacts & Friends State
    @Published public var friends: [ZolaUser] = []
    @Published public var incomingFriendRequests: [ZolaFriendRequest] = []
    @Published public var sentFriendRequests: [ZolaFriendRequest] = []
    @Published public var friendRecommendations: [ZolaFriendRequest] = []
    @Published public var searchedUsers: [ZolaUser] = []
    @Published public var qrUrlsByUid: [Int64: String] = [:]

    // MARK: - Groups State
    @Published public var groups: [ZolaGroup] = []
    @Published public var selectedGroupDetail: ZolaGroup?
    @Published public var selectedGroupLinkDetail: String?

    // MARK: - Timeline & Stories State
    @Published public var timelinePosts: [ZolaFeedPost] = []
    @Published public var timelineCursor: ZolaFeedCursor?
    @Published public var timelineHasMore: Bool = false
    @Published public var storyUsers: [ZolaStoryUser] = []
    @Published public var activeStoryItems: [ZolaStoryItem] = []
    @Published public var feedCommentsByPostId: [Int64: [ZolaFeedComment]] = [:]

    // MARK: - VoIP Call State
    @Published public var isInCall: Bool = false
    @Published public var isCallRingingIncoming: Bool = false
    @Published public var isCallVideo: Bool = false
    @Published public var isMicMuted: Bool = false
    @Published public var isSpeakerPhoneOn: Bool = true
    @Published public var isLocalCameraOn: Bool = false
    @Published public var isPartnerCameraOn: Bool = false
    @Published public var activeCallId: Int32?
    @Published public var activeCallPartnerUid: Int64 = 0
    @Published public var callStatusText: String = "Sẵn sàng gọi VoIP"
    @Published public var incomingInviteInfo: IncomingCallInfo?

    public struct IncomingCallInfo: Sendable, Equatable {
        public let callId: Int32
        public let callerUid: Int64
        public let callerName: String
        public let avatarUrl: String
        public let isVideo: Bool
        public let rtpAddress: String
        public let rtcpAddress: String
        public let sessionId: String
    }

    // MARK: - Diagnostics & Activity Log
    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let category: String
        public let message: String
    }
    @Published public var diagnosticLogs: [LogEntry] = []
    @Published public var customApiResponseJSON: String = ""

    // MARK: - Underlying ZolaKit Actors & Stores
    public private(set) var api: ZolaClient?
    private let loginClient = ZolaLoginClient()
    private let keychainStore = ZolaKeychainSessionStore()
    private let identityStore = ZolaDeviceIdentityStore()
    public private(set) var messageStore: ZolaMessageStore?

    private var eventStreamTask: Task<Void, Never>?
    private var voipEventTask: Task<Void, Never>?
    private var callListenerTask: Task<Void, Never>?
    #if canImport(AVFoundation)
    public private(set) var mediaEngine: ZolaVoipMediaEngine?
    #endif

    private let savedUidsDefaultsKey = "bmszalo.savedAccountUids"

    public init() {
        self.currentDeviceIdentity = ZolaDeviceIdentity.currentDevice(store: identityStore)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("BMSZalo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbUrl = dir.appendingPathComponent("bmszalo_messages.sqlite3")
        self.messageStore = try? ZolaMessageStore(fileURL: dbUrl)

        refreshSavedAccounts()
        ZolaClient.diagnosticHandler = { [weak self] line in
            Task { @MainActor [weak self] in
                self?.log("ZolaKit", line)
            }
        }
    }

    public func log(_ category: String, _ message: String) {
        let entry = LogEntry(timestamp: Date(), category: category, message: message)
        diagnosticLogs.insert(entry, at: 0)
        if diagnosticLogs.count > 400 {
            diagnosticLogs.removeLast(diagnosticLogs.count - 400)
        }
    }

    public var ownUid: Int64 {
        activeSession?.uid ?? 0
    }

    // MARK: - 1. Authentication & Session Management

    public func refreshSavedAccounts() {
        let list = UserDefaults.standard.stringArray(forKey: savedUidsDefaultsKey) ?? []
        savedKeychainAccounts = list
    }

    private func rememberSavedAccount(_ uidString: String) {
        var list = UserDefaults.standard.stringArray(forKey: savedUidsDefaultsKey) ?? []
        if !list.contains(uidString) {
            list.insert(uidString, at: 0)
            UserDefaults.standard.set(list, forKey: savedUidsDefaultsKey)
        }
        savedKeychainAccounts = list
    }

    public func loginWithPhonePassword(
        phone: String,
        password: String,
        deliveryMethod: ZolaVerificationMethod = .callOrSms
    ) async {
        guard !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else {
            errorMessage = "Vui lòng nhập số điện thoại và mật khẩu."
            return
        }
        isBusy = true
        errorMessage = nil
        statusBanner = "Đang xác thực tài khoản Zalo..."
        log("Auth", "Starting login for \(phone) (delivery: \(deliveryMethod.rawValue))")

        do {
            let outcome = try await loginClient.login(phone: phone, password: password)
            await handleLoginOutcome(outcome, phone: phone, password: password, deliveryMethod: deliveryMethod)
        } catch {
            errorMessage = "Đăng nhập thất bại: \(error.localizedDescription)"
            log("Auth", "Login error: \(error.localizedDescription)")
        }
        isBusy = false
    }

    public func submitVerificationCode(_ code: String) async {
        guard let challenge = pendingChallenge else {
            errorMessage = "Không có yêu cầu mã xác thực nào đang chờ."
            return
        }
        isBusy = true
        errorMessage = nil
        statusBanner = "Đang kiểm tra mã OTP..."
        do {
            let outcome = try await loginClient.submitVerificationCode(
                phone: pendingPhone,
                password: pendingPassword,
                code: code,
                challenge: challenge
            )
            await handleLoginOutcome(outcome, phone: pendingPhone, password: pendingPassword, deliveryMethod: .callOrSms)
        } catch {
            errorMessage = "Xác thực OTP thất bại: \(error.localizedDescription)"
            log("Auth", "OTP error: \(error.localizedDescription)")
        }
        isBusy = false
    }

    private func handleLoginOutcome(
        _ outcome: ZolaLoginOutcome,
        phone: String,
        password: String,
        deliveryMethod: ZolaVerificationMethod
    ) async {
        switch outcome {
        case .success(let result):
            do {
                let session = try result.makeSession()
                pendingChallenge = nil
                pendingSecureCheckURL = nil
                await activateSession(session, saveToKeychain: true)
                statusBanner = "Đăng nhập thành công (UID: \(session.uid))"
                log("Auth", "Login succeeded for UID \(session.uid)")
            } catch {
                errorMessage = "Không thể khởi tạo phiên: \(error.localizedDescription)"
            }

        case .challenge(let fields, let errorCode, let errorMessageText):
            pendingPhone = phone
            pendingPassword = password
            let initialChallenge = ZolaLoginChallenge(fields: fields, errorCode: errorCode, errorMessage: errorMessageText)
            pendingChallenge = initialChallenge
            do {
                let requested = try await loginClient.requestVerificationCode(
                    phone: phone,
                    method: deliveryMethod,
                    existingChallenge: initialChallenge
                )
                pendingChallenge = requested.challenge
                statusBanner = "Zalo yêu cầu xác thực OTP: \(requested.deliveryMessage.isEmpty ? "Vui lòng nhập mã xác thực" : requested.deliveryMessage)"
                log("Auth", "OTP challenge requested: \(requested.deliveryMessage)")
            } catch {
                statusBanner = "Zalo yêu cầu mã xác thực OTP: \(errorMessageText ?? "Vui lòng nhập mã xác thực")"
                log("Auth", "OTP challenge received: \(error.localizedDescription)")
            }

        case .secureVerification(let check):
            pendingSecureCheckURL = URL(string: check.secureUrl)
            statusBanner = "Tài khoản yêu cầu xác minh bảo mật qua trình duyệt."
            log("Auth", "Secure verification URL: \(check.secureUrl)")

        case .rejected(let code, let message, _):
            errorMessage = "Đăng nhập bị từ chối (\(code ?? -1)): \(message ?? "")"
            log("Auth", "Rejected (\(code ?? -1)): \(message ?? "")")
        }
    }

    public func loadSessionFromKeychain(account: String) async {
        isBusy = true
        errorMessage = nil
        do {
            if let session = try keychainStore.load(account: account) {
                await activateSession(session, saveToKeychain: false)
                statusBanner = "Đã khôi phục phiên từ Keychain (UID: \(session.uid))"
            } else {
                errorMessage = "Không tìm thấy phiên cho tài khoản \(account) trong Keychain."
            }
        } catch {
            errorMessage = "Lỗi đọc Keychain: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func autoLoginIfPossible() async {
        guard !isAuthenticated else { return }
        refreshSavedAccounts()
        if let first = savedKeychainAccounts.first {
            await loadSessionFromKeychain(account: first)
        }
    }

    public func deleteSessionFromKeychain(account: String) {
        do {
            try keychainStore.delete(account: account)
            var list = UserDefaults.standard.stringArray(forKey: savedUidsDefaultsKey) ?? []
            list.removeAll { $0 == account }
            UserDefaults.standard.set(list, forKey: savedUidsDefaultsKey)
            refreshSavedAccounts()
            statusBanner = "Đã xóa phiên \(account) khỏi Keychain."
        } catch {
            errorMessage = "Lỗi xóa Keychain: \(error.localizedDescription)"
        }
    }

    public func importSessionFromJSONString(_ jsonString: String) async {
        guard let data = jsonString.data(using: .utf8) else {
            errorMessage = "Chuỗi JSON không hợp lệ."
            return
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("import-session-\(UUID().uuidString).json")
        do {
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let session = try ZolaFileSessionStore.loadInteropJSON(from: tempURL)
            await activateSession(session, saveToKeychain: true)
            statusBanner = "Đã nạp phiên JSON cho UID \(session.uid)"
        } catch {
            errorMessage = "Không thể đọc JSON phiên: \(error.localizedDescription)"
        }
    }

    public func importSessionFromFile(url: URL) async {
        do {
            let session = try ZolaFileSessionStore.loadInteropJSON(from: url)
            await activateSession(session, saveToKeychain: true)
            statusBanner = "Đã nhập tệp phiên thành công (UID: \(session.uid))"
        } catch {
            errorMessage = "Không thể đọc tệp phiên: \(error.localizedDescription)"
        }
    }

    public func exportActiveSessionJSON() -> String? {
        guard let session = activeSession else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveActiveSessionToFile(url: URL) {
        guard let session = activeSession else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(session)
            try ZolaFileSessionStore.writeData0600(data, to: url)
            statusBanner = "Đã lưu phiên ra tệp an toàn (0600): \(url.lastPathComponent)"
        } catch {
            errorMessage = "Lỗi xuất tệp phiên: \(error.localizedDescription)"
        }
    }

    public func activateSession(_ session: ZolaSession, saveToKeychain: Bool) async {
        stopBackgroundStreams()

        if saveToKeychain {
            try? keychainStore.save(session, account: String(session.uid))
            rememberSavedAccount(String(session.uid))
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let wmFile = appSupport
            .appendingPathComponent("BMSZalo", isDirectory: true)
            .appendingPathComponent("watermarks-\(session.uid).json")

        let client = Zola().login(session: session, watermarkFileURL: wmFile)
        self.api = client
        self.activeSession = session
        self.isAuthenticated = true

        loadCachedHistoryFromSQLite()
        startRealtimeEventStreams()
        await syncAllInitialData()
    }

    public func logout() {
        stopBackgroundStreams()
        api = nil
        activeSession = nil
        activeAccountProfile = nil
        isAuthenticated = false
        conversations = []
        messagesByThread = [:]
        selectedThreadId = nil
        statusBanner = "Đã đăng xuất phiên hiện tại."
        log("Auth", "Logged out")
    }

    // MARK: - Device Identity Management

    public func resetDeviceIdentity() {
        identityStore.clear()
        currentDeviceIdentity = ZolaDeviceIdentity.currentDevice(store: identityStore)
        statusBanner = "Đã tạo mới Device Identity."
        log("Identity", "Generated new device identity: \(currentDeviceIdentity.model) (\(currentDeviceIdentity.zcid))")
    }

    public func updateCustomDeviceIdentity(model: String, osVersion: String, deviceName: String, hardwareModel: String) {
        let updated = ZolaDeviceIdentity(
            idfa: currentDeviceIdentity.idfa,
            zcid: currentDeviceIdentity.zcid,
            deviceIdentifier: currentDeviceIdentity.deviceIdentifier,
            model: model.isEmpty ? currentDeviceIdentity.model : model,
            deviceName: deviceName.isEmpty ? currentDeviceIdentity.deviceName : deviceName,
            width: currentDeviceIdentity.width,
            height: currentDeviceIdentity.height,
            vendorId: currentDeviceIdentity.vendorId,
            hardwareModel: hardwareModel.isEmpty ? currentDeviceIdentity.hardwareModel : hardwareModel,
            scale: currentDeviceIdentity.scale
        )
        currentDeviceIdentity = updated
        statusBanner = "Đã cập nhật cấu hình thiết bị giả lập iOS."
    }

    // MARK: - 2. Initial Sync & Real-Time Event Stream

    public func syncAllInitialData() async {
        guard let api = api else { return }
        isBusy = true
        log("Sync", "Starting full initial sync (inbox, friends, groups, tags, settings)")

        async let accountTask: ZolaUser? = try? await api.fetchAccountInfo()
        async let inboxTask: Void = syncInboxNow(discoverGroups: true)
        async let contactsTask: Void = refreshContactsData()
        async let groupsTask: Void = refreshGroups()
        async let settingsTask: Void = refreshConversationSettingsAndTags()

        activeAccountProfile = await accountTask
        _ = await (inboxTask, contactsTask, groupsTask, settingsTask)

        isBusy = false
    }

    public func syncInboxNow(discoverGroups: Bool = true) async {
        guard let api = api else { return }
        do {
            let synced = try await api.syncInbox(discoverGroups: discoverGroups)
            await api.primeWatermarks(from: synced)
            applyConversationsSnapshot(synced)
            log("Inbox", "Synced \(synced.count) conversations")
        } catch {
            errorMessage = "Đồng bộ hộp thư lỗi: \(error.localizedDescription)"
            log("Inbox", "syncInbox failed: \(error.localizedDescription)")
        }
    }

    private func applyConversationsSnapshot(_ synced: [ZolaConversation]) {
        self.conversations = synced
        for conv in synced {
            messagesByThread[conv.threadId] = conv.messages
        }
        if let store = messageStore, ownUid > 0 {
            try? store.upsertConversations(synced.map { (accountUid: ownUid, conversation: $0) })
        }
        if selectedThreadId == nil, let first = synced.first {
            selectedThreadId = first.threadId
        }
    }

    private func loadCachedHistoryFromSQLite() {
        guard let store = messageStore,
              ownUid > 0,
              let storedThreads = try? store.threads(accountUid: ownUid),
              !storedThreads.isEmpty else { return }

        var restored: [ZolaConversation] = []
        for row in storedThreads {
            let msgs = (try? store.messages(accountUid: ownUid, threadId: row.threadId, limit: 150)) ?? []
            messagesByThread[row.threadId] = msgs
            restored.append(
                ZolaConversation(
                    threadId: row.threadId,
                    isGroup: row.isGroup,
                    isCloud: row.isCloud,
                    title: row.title,
                    avatarUrl: row.avatarUrl,
                    lastMessage: msgs.last,
                    unreadCount: row.unreadCount,
                    needsReply: false,
                    memberCount: row.memberCount,
                    messages: msgs
                )
            )
        }
        if conversations.isEmpty {
            conversations = restored
        }
        log("SQLite", "Restored \(restored.count) conversations from local SQLite store")
    }

    public func startRealtimeEventStreams() {
        stopBackgroundStreams()
        guard let api = api else { return }

        let interval = max(1.0, eventPollIntervalSeconds)
        eventStreamTask = Task { [weak self] in
            do {
                for try await event in api.events(intervalSeconds: interval) {
                    guard !Task.isCancelled else { break }
                    self?.handleRealtimeEvent(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.log("Events", "Event stream ended: \(error.localizedDescription)")
            }
        }

        callListenerTask = Task { [weak self] in
            await api.setVoipEventHandler { [weak self] voipEvent in
                Task { @MainActor [weak self] in
                    await self?.handleVoipEvent(voipEvent)
                }
            }
            try? await api.startVoipIncomingListener()
            self?.log("VoIP", "Incoming call listener started on UXChatSocket 0x7d0")
        }
    }

    public func stopBackgroundStreams() {
        eventStreamTask?.cancel()
        eventStreamTask = nil
        voipEventTask?.cancel()
        voipEventTask = nil
        callListenerTask?.cancel()
        callListenerTask = nil
        if let api = api {
            Task { await api.stopVoipIncomingListener() }
        }
    }

    private func handleRealtimeEvent(_ event: ZolaEvent) {
        switch event.type {
        case "message.new", "message.updated":
            if let msg = event.message {
                appendOrUpdateMessage(msg)
                log("Message", "[\(msg.threadId)] \(msg.senderName.isEmpty ? String(msg.senderId) : msg.senderName): \(msg.text)")
            }
        case "message.reaction":
            if let reaction = event.reaction {
                log("Reaction", "Msg \(reaction.messageId) reaction \(reaction.emoji) in thread \(reaction.threadId)")
            }
        case "message.typing":
            if let typing = event.typing {
                typingUsersByThread[typing.threadId] = typing.actorId
                let tid = typing.threadId
                let actor = typing.actorId
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self?.typingUsersByThread[tid] == actor {
                        self?.typingUsersByThread.removeValue(forKey: tid)
                    }
                }
            }
        case "message.delivery":
            if let delivery = event.delivery {
                log("Delivery", "Thread \(delivery.threadId) status updated")
            }
        case "session.expired":
            let code = event.errorCode ?? 0
            errorMessage = "Phiên đăng nhập hết hạn (Mã: \(code))"
            log("Auth", "Session expired (\(code))")
        default:
            log("Events", "Event \(event.type) at \(event.tsMs)")
        }
    }

    private func appendOrUpdateMessage(_ msg: ZolaMessage) {
        var list = messagesByThread[msg.threadId] ?? []
        if let idx = list.firstIndex(where: { $0.id == msg.id && msg.id > 0 }) {
            list[idx] = msg
        } else {
            list.append(msg)
            list.sort { $0.tsMs < $1.tsMs }
        }
        messagesByThread[msg.threadId] = list

        if let convIdx = conversations.firstIndex(where: { $0.threadId == msg.threadId }) {
            let old = conversations[convIdx]
            let updated = ZolaConversation(
                threadId: old.threadId,
                isGroup: old.isGroup,
                isCloud: old.isCloud,
                title: old.title,
                avatarUrl: old.avatarUrl,
                lastMessage: msg,
                unreadCount: selectedThreadId == old.threadId ? 0 : old.unreadCount + (msg.isSelf ? 0 : 1),
                needsReply: !msg.isSelf,
                memberCount: old.memberCount,
                messages: list
            )
            conversations.remove(at: convIdx)
            conversations.insert(updated, at: 0)
            if let store = messageStore, ownUid > 0 {
                try? store.upsertConversations([(accountUid: ownUid, conversation: updated)])
            }
        } else {
            let newConv = ZolaConversation(
                threadId: msg.threadId,
                isGroup: msg.isGroup,
                isCloud: msg.isCloud,
                title: msg.senderName.isEmpty ? "Hội thoại \(msg.threadId)" : msg.senderName,
                avatarUrl: "",
                lastMessage: msg,
                unreadCount: msg.isSelf ? 0 : 1,
                needsReply: !msg.isSelf,
                memberCount: 2,
                messages: list
            )
            conversations.insert(newConv, at: 0)
        }
    }

    // MARK: - Filtered Conversations & Active Thread

    public var filteredConversations: [ZolaConversation] {
        var base = conversations
        switch inboxFilter {
        case .all:
            break
        case .unread:
            base = base.filter { $0.unreadCount > 0 || $0.needsReply }
        case .groups:
            base = base.filter { $0.isGroup }
        case .direct:
            base = base.filter { !$0.isGroup }
        case .pinned:
            base = base.filter { pinnedThreadIds.contains($0.threadId) }
        case .cloud:
            base = base.filter { $0.isCloud || $0.threadId == ownUid }
        case .byTag:
            if let tagId = selectedTagId,
               let tag = chatTags.first(where: { $0.id == tagId }) {
                base = base.filter { tag.matchesThread(threadId: $0.threadId, title: $0.title) }
            }
        }

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }

        let sqliteMatchedKeys: Set<String>
        if let store = messageStore, ownUid > 0 {
            sqliteMatchedKeys = (try? store.matchingThreadKeys(query: trimmed, accountUid: ownUid)) ?? []
        } else {
            sqliteMatchedKeys = []
        }
        let qFolded = ZolaTextNormalizer.foldVietnamese(trimmed)
        return base.filter { conv in
            let key = "\(ownUid):\(conv.threadId)"
            return ZolaTextNormalizer.foldVietnamese(conv.title).contains(qFolded)
                || ZolaTextNormalizer.foldVietnamese(conv.lastMessage?.text ?? "").contains(qFolded)
                || sqliteMatchedKeys.contains(key)
        }
    }

    public var currentConversation: ZolaConversation? {
        guard let tid = selectedThreadId else { return nil }
        return conversations.first(where: { $0.threadId == tid })
    }

    public var currentMessages: [ZolaMessage] {
        guard let tid = selectedThreadId else { return [] }
        return messagesByThread[tid] ?? currentConversation?.messages ?? []
    }

    public func selectConversation(_ conv: ZolaConversation) {
        selectedThreadId = conv.threadId
        if messagesByThread[conv.threadId] == nil {
            messagesByThread[conv.threadId] = conv.messages
        }
        Task {
            await loadPinBoardForCurrentThread()
        }
    }

    // MARK: - 3. Messaging & Rich Media Actions

    public func updateStickerSuggestions(for input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            stickerSuggestions = []
            return
        }
        stickerSuggestions = ZolaStickerSuggester.searchCatalog(query: trimmed)
        if let api = api {
            Task {
                let remote = await api.suggestContextualStickers(for: trimmed, limit: 12)
                if !remote.isEmpty {
                    self.stickerSuggestions = remote
                }
            }
        }
    }

    public func searchStickersByKeyword(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let local = ZolaStickerSuggester.searchCatalog(query: trimmed)
        searchedStickers = local
        guard let api = api else { return }
        do {
            let remote = try await api.searchStickers(trimmed, limit: 20)
            if !remote.isEmpty {
                searchedStickers = remote
            }
        } catch {
            log("Sticker", "Sticker search fallback to catalog: \(error.localizedDescription)")
        }
    }

    public func sendTextMessage(
        text: String,
        quote: ZolaMessage? = nil,
        mentions: [ZolaMention] = []
    ) async {
        guard let api = api, let conv = currentConversation else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let threadType: ZolaThreadType = conv.isGroup ? .group : .user
        do {
            if !isDryRun {
                _ = try? await api.sendTypingEvent(threadId: conv.threadId, type: threadType)
            }

            let receipt: ZolaSendReceipt
            if let quotedMsg = quote {
                let zQuote = ZolaQuote.fromMessage(quotedMsg)
                receipt = try await api.sendQuotedText(
                    text: trimmed,
                    threadId: conv.threadId,
                    quote: zQuote,
                    type: threadType,
                    dryRun: isDryRun
                )
            } else if conv.isGroup {
                receipt = try await api.sendGroupText(
                    gid: conv.threadId,
                    text: trimmed,
                    mentions: mentions,
                    dryRun: isDryRun
                )
            } else {
                receipt = try await api.sendMessage(
                    ZolaMessagePayload(msg: trimmed),
                    threadId: conv.threadId,
                    type: .user,
                    dryRun: isDryRun
                )
            }

            if isDryRun {
                statusBanner = "[Dry-Run] Đã đóng gói tin nhắn '\(trimmed)' tới \(conv.title) (\(receipt.frameSize) bytes). Tắt Dry-Run để gửi thật."
            }
            let msgId = receipt.serverGlobalMsgId ?? receipt.clientIdMs
            appendOptimisticOutgoingMessage(text: trimmed, conv: conv, msgId: msgId, quote: quote, mentions: mentions)
            log("Send", "Sent text to \(conv.threadId) (dryRun=\(isDryRun), id=\(msgId))")
        } catch {
            errorMessage = "Gửi tin nhắn thất bại: \(error.localizedDescription)"
            log("Send", "sendMessage error: \(error.localizedDescription)")
        }
    }

    public func sendToMyCloud(text: String) async {
        guard let api = api else { return }
        do {
            let res = try await api.sendToMe(text: text, dryRun: isDryRun)
            let msgId = res.serverGlobalMsgId ?? res.clientIdMs
            statusBanner = isDryRun
                ? "[Dry-Run] Đã chuẩn bị gói tin gửi vào Cloud của tôi"
                : "Đã lưu vào Cloud của tôi (ID: \(msgId))"
            log("Cloud", "sendToMe dryRun=\(isDryRun) msgId=\(msgId)")
        } catch {
            errorMessage = "Lỗi gửi Cloud của tôi: \(error.localizedDescription)"
        }
    }

    public func sendStickerItem(_ sticker: ZolaStickerItem) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            if conv.isGroup {
                let res = try await api.sendStickerGroup(
                    gid: conv.threadId,
                    stickerId: Int32(truncatingIfNeeded: sticker.stickerId),
                    cateId: Int32(truncatingIfNeeded: sticker.cateId > 0 ? sticker.cateId : 10425),
                    stickerType: Int8(truncatingIfNeeded: sticker.stickerType > 0 ? sticker.stickerType : 7),
                    dryRun: isDryRun,
                    groupSendEnabled: isGroupSendEnabled
                )
                log("Sticker", "Group sticker sent \(res.clientIdMs) (dryRun=\(isDryRun))")
            } else {
                let res = try await api.sendStickerResolvingDetail(
                    stickerId: sticker.stickerId,
                    cateIdHint: sticker.cateId,
                    typeHint: Int64(sticker.stickerType),
                    threadId: conv.threadId,
                    type: .user,
                    dryRun: isDryRun
                )
                log("Sticker", "1-1 sticker sent \(res.clientIdMs) (dryRun=\(isDryRun))")
            }
            statusBanner = isDryRun ? "[Dry-Run] Đã chuẩn bị gửi Sticker #\(sticker.stickerId)" : "Đã gửi Sticker #\(sticker.stickerId)"
        } catch {
            errorMessage = "Gửi sticker thất bại: \(error.localizedDescription)"
        }
    }

    public func uploadAndSendPhotoFile(url fileURL: URL, caption: String = "") async {
        guard let api = api, let conv = currentConversation else { return }
        isBusy = true
        do {
            let data = try Data(contentsOf: fileURL)
            let res = try await api.uploadAndSendPhoto(
                imageData: data,
                fileName: fileURL.lastPathComponent,
                threadId: conv.threadId,
                type: conv.isGroup ? .group : .user,
                caption: caption,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi ảnh (\(res.photoUrl))"
        } catch {
            errorMessage = "Lỗi gửi ảnh: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func uploadAndSendDocumentFile(url fileURL: URL) async {
        guard let api = api, let conv = currentConversation else { return }
        isBusy = true
        do {
            let data = try Data(contentsOf: fileURL)
            let res = try await api.uploadAndSendFile(
                fileData: data,
                fileName: fileURL.lastPathComponent,
                threadId: conv.threadId,
                type: conv.isGroup ? .group : .user,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi tệp \(fileURL.lastPathComponent) (\(res.fileUrl))"
        } catch {
            errorMessage = "Lỗi gửi tệp: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func uploadAndSendVideoFile(url fileURL: URL, caption: String = "") async {
        guard let api = api, let conv = currentConversation else { return }
        isBusy = true
        do {
            let data = try Data(contentsOf: fileURL)
            let res = try await api.uploadAndSendVideo(
                videoData: data,
                fileName: fileURL.lastPathComponent,
                threadId: conv.threadId,
                type: conv.isGroup ? .group : .user,
                caption: caption,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi video (\(res.videoUrl))"
        } catch {
            errorMessage = "Lỗi gửi video: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func uploadAndSendVoiceData(_ data: Data, durationMs: Int) async {
        guard let api = api, let conv = currentConversation else { return }
        isBusy = true
        do {
            let res = try await api.uploadAndSendVoiceFile(
                audioData: data,
                threadId: conv.threadId,
                type: conv.isGroup ? .group : .user,
                durationMs: durationMs,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi tin nhắn thoại (\(res.voiceUrl))"
        } catch {
            errorMessage = "Lỗi gửi tin nhắn thoại: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func sendLinkBubble(url: String, title: String, desc: String) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            let res = try await api.sendLink1To1(
                to: conv.threadId,
                url: url,
                title: title,
                descriptionText: desc,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi link (\(res.clientIdMs))"
        } catch {
            errorMessage = "Lỗi gửi link: \(error.localizedDescription)"
        }
    }

    public func sendLocationBubble(lat: Double, lon: Double, locationName: String, address: String) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            let res = try await api.sendLocation1To1(
                to: conv.threadId,
                latitude: lat,
                longitude: lon,
                title: locationName,
                address: address,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi vị trí '\(locationName)' (\(res.clientIdMs))"
        } catch {
            errorMessage = "Lỗi gửi vị trí: \(error.localizedDescription)"
        }
    }

    public func sendBusinessCardBubble(contactUid: Int64, contactName: String, phone: String?) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            let res = try await api.sendContactCard1To1(
                to: conv.threadId,
                contactUid: contactUid,
                contactName: contactName,
                phone: phone ?? "",
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi danh thiếp UID \(contactUid) (\(res.clientIdMs))"
        } catch {
            errorMessage = "Lỗi gửi danh thiếp: \(error.localizedDescription)"
        }
    }

    public func reactToMessage(_ message: ZolaMessage, icon: String) async {
        guard let api = api else { return }
        do {
            _ = try await api.addReaction(
                icon,
                message: message,
                type: message.isGroup ? .group : .user,
                dryRun: isDryRun
            )
            statusBanner = "Đã thả biểu cảm \(icon)"
        } catch {
            errorMessage = "Lỗi thả biểu cảm: \(error.localizedDescription)"
        }
    }

    public func recallMessage(_ message: ZolaMessage) async {
        guard let api = api else { return }
        do {
            _ = try await api.undo(
                message: message,
                threadId: message.threadId,
                type: message.isGroup ? .group : .user,
                dryRun: isDryRun
            )
            statusBanner = "Đã thu hồi tin nhắn #\(message.id)"
        } catch {
            errorMessage = "Thu hồi tin nhắn thất bại: \(error.localizedDescription)"
        }
    }

    public func deleteMessageOnlyMe(_ message: ZolaMessage) async {
        guard let api = api else { return }
        do {
            _ = try await api.deleteMessage(
                message,
                threadId: message.threadId,
                type: message.isGroup ? .group : .user,
                onlyMe: true,
                dryRun: isDryRun
            )
            messagesByThread[message.threadId]?.removeAll { $0.id == message.id }
            statusBanner = "Đã xóa tin nhắn ở phía bạn."
        } catch {
            errorMessage = "Xóa tin nhắn thất bại: \(error.localizedDescription)"
        }
    }

    public func fetchOlderHistoryForCurrentThread() async {
        guard let api = api, let conv = currentConversation else { return }
        let currentList = messagesByThread[conv.threadId] ?? []
        let oldestMsg = currentList.first(where: { $0.hasRealServerGlobalId }) ?? currentList.first
        do {
            let older: [ZolaMessage]
            if conv.isGroup {
                older = try await api.fetchOlderGroupHistory(
                    gid: conv.threadId,
                    beforeGlobalMsgId: oldestMsg?.id ?? 0
                ).messages
            } else {
                older = (try? messageStore?.messages(accountUid: ownUid, threadId: conv.threadId, limit: 250)) ?? []
            }
            for msg in older {
                appendOrUpdateMessage(msg)
            }
            statusBanner = "Đã tải thêm \(older.count) tin nhắn lịch sử."
        } catch {
            errorMessage = "Tải lịch sử thất bại: \(error.localizedDescription)"
        }
    }

    // MARK: - Pin Board, Polls & Conversation Settings

    public func loadPinBoardForCurrentThread() async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            if let board = try await api.fetchNativePinBoard(
                threadId: conv.threadId,
                isGroup: conv.isGroup,
                dryRun: isDryRun
            ) {
                currentThreadPinBoard = board.messages
                currentPinBoardVersion = board.version
            } else {
                currentThreadPinBoard = []
            }
        } catch {
            log("PinBoard", "Fetch pin board error: \(error.localizedDescription)")
        }
    }

    public func pinMessageInCurrentThread(_ message: ZolaMessage) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            if conv.isGroup {
                _ = try await api.pinNativeGroupMessage(
                    message,
                    dryRun: isDryRun,
                    groupSendEnabled: isGroupSendEnabled
                )
            } else {
                _ = try await api.pinNativeUserMessage(
                    message,
                    boardVersion: currentPinBoardVersion,
                    dryRun: isDryRun
                )
            }
            statusBanner = "Đã ghim tin nhắn #\(message.id)"
            await loadPinBoardForCurrentThread()
        } catch {
            errorMessage = "Ghim tin nhắn thất bại: \(error.localizedDescription)"
        }
    }

    public func unpinItemInCurrentThread(_ item: ZolaPinnedMessage) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            if conv.isGroup {
                _ = try await api.unpinNativeGroupMessage(
                    threadId: conv.threadId,
                    boardId: item.id,
                    dryRun: isDryRun,
                    groupSendEnabled: isGroupSendEnabled
                )
            } else {
                _ = try await api.unpinNativeUserMessage(
                    threadId: conv.threadId,
                    boardId: item.id,
                    boardVersion: currentPinBoardVersion,
                    dryRun: isDryRun
                )
            }
            statusBanner = "Đã bỏ ghim #\(item.id)"
            await loadPinBoardForCurrentThread()
        } catch {
            errorMessage = "Bỏ ghim thất bại: \(error.localizedDescription)"
        }
    }

    public func inspectGroupPoll(pollId: String) async {
        guard let api = api, let conv = currentConversation else { return }
        do {
            activeGroupPoll = try await api.fetchGroupPoll(
                pollId: pollId,
                groupId: conv.threadId,
                includeVoters: true
            )
        } catch {
            errorMessage = "Không tải được chi tiết bình chọn: \(error.localizedDescription)"
        }
    }

    public func refreshConversationSettingsAndTags() async {
        guard let api = api else { return }
        if let pinnedStrings = try? await api.getPinConversations() {
            var ids = Set<Int64>()
            for raw in pinnedStrings {
                let digits = raw.filter(\.isNumber)
                if let parsed = Int64(digits), parsed > 0 {
                    ids.insert(parsed)
                }
            }
            self.pinnedThreadIds = ids
        }
        if let muteList = try? await api.fetchMuteList() {
            self.mutedThreadIds = muteList.mutedUserIds.union(muteList.mutedGroupIds)
        }
        if let tagsRes = try? await api.fetchChatTags(), !tagsRes.labelData.isEmpty {
            self.chatTags = tagsRes.labelData
        } else if let labelsRes = try? await api.fetchLabels() {
            self.chatTags = labelsRes.labelData
        }
    }

    public func togglePinConversation(_ conv: ZolaConversation) async {
        guard let api = api else { return }
        let shouldPin = !pinnedThreadIds.contains(conv.threadId)
        do {
            _ = try await api.setPinnedConversations(
                pinned: shouldPin,
                threadIds: [conv.threadId],
                type: conv.isGroup ? .group : .user,
                dryRun: isDryRun
            )
            if shouldPin {
                pinnedThreadIds.insert(conv.threadId)
            } else {
                pinnedThreadIds.remove(conv.threadId)
            }
            statusBanner = shouldPin ? "Đã ghim hội thoại \(conv.title)" : "Đã bỏ ghim hội thoại \(conv.title)"
        } catch {
            errorMessage = "Lỗi ghim hội thoại: \(error.localizedDescription)"
        }
    }

    public func toggleMuteConversation(_ conv: ZolaConversation, durationSeconds: Int = -1) async {
        guard let api = api else { return }
        let isCurrentlyMuted = mutedThreadIds.contains(conv.threadId)
        do {
            _ = try await api.setMute(
                threadId: conv.threadId,
                durationSeconds: durationSeconds,
                unmute: isCurrentlyMuted,
                type: conv.isGroup ? .group : .user,
                dryRun: isDryRun
            )
            if isCurrentlyMuted {
                mutedThreadIds.remove(conv.threadId)
                statusBanner = "Đã bật lại thông báo cho \(conv.title)"
            } else {
                mutedThreadIds.insert(conv.threadId)
                statusBanner = "Đã tắt thông báo cho \(conv.title)"
            }
        } catch {
            errorMessage = "Lỗi cài đặt thông báo: \(error.localizedDescription)"
        }
    }

    public func createChatTag(title: String, colorHex: String = "#0068FF") async {
        guard let api = api else { return }
        do {
            _ = try await api.createChatTag(text: title, color: colorHex, dryRun: isDryRun)
            await refreshConversationSettingsAndTags()
            statusBanner = "Đã tạo thẻ phân loại '\(title)'"
        } catch {
            errorMessage = "Lỗi tạo thẻ phân loại: \(error.localizedDescription)"
        }
    }

    public func assignTagToConversation(tag: ZolaLabel, conv: ZolaConversation, assign: Bool) async {
        guard let api = api else { return }
        do {
            _ = try await api.updateConversationTags(
                threadId: conv.threadId,
                isGroup: conv.isGroup,
                addTagIds: assign ? [tag.id] : [],
                removeTagIds: assign ? [] : [tag.id],
                dryRun: isDryRun
            )
            await refreshConversationSettingsAndTags()
            statusBanner = assign ? "Đã gắn thẻ '\(tag.text)' cho \(conv.title)" : "Đã gỡ thẻ '\(tag.text)'"
        } catch {
            errorMessage = "Lỗi cập nhật thẻ hội thoại: \(error.localizedDescription)"
        }
    }

    public func deleteChatTag(_ tag: ZolaLabel) async {
        guard let api = api else { return }
        do {
            try await api.deleteChatTags(ids: [tag.id], dryRun: isDryRun)
            chatTags.removeAll { $0.id == tag.id }
            statusBanner = "Đã xóa thẻ '\(tag.text)'"
        } catch {
            errorMessage = "Lỗi xóa thẻ: \(error.localizedDescription)"
        }
    }

    public func loadQuickMessagesAndAutoReplies() async {
        guard let api = api else { return }
        if let qm = try? await api.getQuickMessageList(),
           let data = try? JSONSerialization.data(withJSONObject: qm, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            quickMessagesSummary = str
        }
        if let ar = try? await api.getAutoReplyList(),
           let data = try? JSONSerialization.data(withJSONObject: ar, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            autoRepliesSummary = str
        }
    }

    private func appendOptimisticOutgoingMessage(
        text: String,
        conv: ZolaConversation,
        msgId: Int64,
        quote: ZolaMessage?,
        mentions: [ZolaMention]
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let resolvedId = msgId > 0 ? msgId : nowMs
        let msg = ZolaMessage(
            id: resolvedId,
            cliMsgId: nowMs,
            threadId: conv.threadId,
            isGroup: conv.isGroup,
            senderId: ownUid,
            senderName: activeAccountProfile?.displayName ?? "Tôi",
            toId: conv.threadId,
            tsMs: nowMs,
            msgType: "webchat",
            kind: "text",
            text: text,
            attachments: [],
            quote: quote.map { ZolaQuote.fromMessage($0) },
            isSelf: true,
            isCloud: conv.isCloud,
            mcrypt: 0,
            source: "BMSZalo",
            reactions: [],
            mentions: mentions
        )
        appendOrUpdateMessage(msg)
    }

    // MARK: - 4. Contacts & Friends Actions

    public func refreshContactsData() async {
        guard let api = api else { return }
        async let allFriends = try? await api.getAllFriends()
        async let incoming = try? await api.fetchFriendRequests()
        async let sent = try? await api.fetchSentFriendRequests()
        async let recom = try? await api.getFriendRecommendations()

        if let f = await allFriends { self.friends = f }
        if let inc = await incoming { self.incomingFriendRequests = inc }
        if let s = await sent { self.sentFriendRequests = s }
        if let r = await recom { self.friendRecommendations = r }
    }

    public func searchUsers(query: String) async {
        guard let api = api else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        do {
            if trimmed.hasPrefix("@") {
                if let u = try await api.findUserByUsername(String(trimmed.dropFirst())) {
                    searchedUsers = [u]
                } else {
                    searchedUsers = []
                }
            } else {
                if let u = try await api.findUser(trimmed) {
                    searchedUsers = [u]
                } else {
                    searchedUsers = []
                }
            }
        } catch {
            errorMessage = "Tìm kiếm người dùng thất bại: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func sendFriendRequest(to uid: Int64, message: String) async {
        guard let api = api else { return }
        do {
            _ = try await api.sendFriendRequest(toUid: uid, message: message, dryRun: isDryRun)
            statusBanner = "Đã gửi lời mời kết bạn tới UID \(uid)"
            await refreshContactsData()
        } catch {
            errorMessage = "Gửi kết bạn thất bại: \(error.localizedDescription)"
        }
    }

    public func acceptFriendRequest(from uid: Int64) async {
        guard let api = api else { return }
        do {
            _ = try await api.acceptFriendRequest(fromUid: uid, dryRun: isDryRun)
            statusBanner = "Đã đồng ý kết bạn với UID \(uid)"
            await refreshContactsData()
        } catch {
            errorMessage = "Đồng ý kết bạn thất bại: \(error.localizedDescription)"
        }
    }

    public func rejectFriendRequest(from uid: Int64) async {
        guard let api = api else { return }
        do {
            _ = try await api.rejectFriendRequest(fromUid: uid, dryRun: isDryRun)
            statusBanner = "Đã từ chối lời mời kết bạn từ \(uid)"
            await refreshContactsData()
        } catch {
            errorMessage = "Từ chối kết bạn thất bại: \(error.localizedDescription)"
        }
    }

    public func undoSentFriendRequest(to uid: Int64) async {
        guard let api = api else { return }
        do {
            _ = try await api.undoFriendRequest(toUid: uid, dryRun: isDryRun)
            statusBanner = "Đã thu hồi lời mời kết bạn tới \(uid)"
            await refreshContactsData()
        } catch {
            errorMessage = "Thu hồi lời mời thất bại: \(error.localizedDescription)"
        }
    }

    public func updateFriendAlias(uid: Int64, alias: String) async {
        guard let api = api else { return }
        do {
            if alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await api.removeFriendAlias(uid, dryRun: isDryRun)
                statusBanner = "Đã xóa tên gợi nhớ cho \(uid)"
            } else {
                _ = try await api.changeFriendAlias(alias, friendId: uid, dryRun: isDryRun)
                statusBanner = "Đã đặt tên gợi nhớ '\(alias)'"
            }
            await refreshContactsData()
        } catch {
            errorMessage = "Đổi tên gợi nhớ thất bại: \(error.localizedDescription)"
        }
    }

    public func toggleBlockUser(uid: Int64, blocked: Bool) async {
        guard let api = api else { return }
        do {
            if blocked {
                _ = try await api.blockUser(uid, dryRun: isDryRun)
                statusBanner = "Đã chặn UID \(uid)"
            } else {
                _ = try await api.unblockUser(uid, dryRun: isDryRun)
                statusBanner = "Đã bỏ chặn UID \(uid)"
            }
        } catch {
            errorMessage = "Thao tác chặn thất bại: \(error.localizedDescription)"
        }
    }

    public func loadUserQR(uid: Int64) async {
        guard let api = api else { return }
        do {
            let map = try await api.getQR([uid])
            for (k, v) in map {
                qrUrlsByUid[k] = v
            }
        } catch {
            errorMessage = "Không lấy được mã QR: \(error.localizedDescription)"
        }
    }

    // MARK: - 5. Groups Management

    public func refreshGroups() async {
        guard let api = api else { return }
        do {
            groups = try await api.getAllGroups()
        } catch {
            log("Groups", "getAllGroups failed: \(error.localizedDescription)")
        }
    }

    public func inspectGroupDetail(groupId: Int64) async {
        guard let api = api else { return }
        do {
            selectedGroupDetail = try await api.getGroupInfo(gid: groupId)
            selectedGroupLinkDetail = try? await api.getGroupLinkDetail(groupId: groupId)
        } catch {
            errorMessage = "Tải thông tin nhóm lỗi: \(error.localizedDescription)"
        }
    }

    public func createNewGroup(name: String, memberIds: [Int64]) async {
        guard let api = api else { return }
        do {
            let res = try await api.createGroup(name: name, members: memberIds, dryRun: isDryRun)
            statusBanner = "Đã tạo nhóm '\(name)' (\(res.keys.joined(separator: ",")))"
            await refreshGroups()
        } catch {
            errorMessage = "Tạo nhóm thất bại: \(error.localizedDescription)"
        }
    }

    public func renameGroup(groupId: Int64, newName: String) async {
        guard let api = api else { return }
        do {
            _ = try await api.changeGroupName(newName, groupId: groupId, dryRun: isDryRun)
            statusBanner = "Đã đổi tên nhóm thành '\(newName)'"
            await inspectGroupDetail(groupId: groupId)
            await refreshGroups()
        } catch {
            errorMessage = "Đổi tên nhóm thất bại: \(error.localizedDescription)"
        }
    }

    public func addMembersToGroup(groupId: Int64, memberIds: [Int64]) async {
        guard let api = api else { return }
        do {
            _ = try await api.addUserToGroup(groupId: groupId, memberIds: memberIds, dryRun: isDryRun)
            statusBanner = "Đã thêm \(memberIds.count) thành viên vào nhóm"
            await inspectGroupDetail(groupId: groupId)
        } catch {
            errorMessage = "Thêm thành viên thất bại: \(error.localizedDescription)"
        }
    }

    public func removeMembersFromGroup(groupId: Int64, memberIds: [Int64]) async {
        guard let api = api else { return }
        do {
            _ = try await api.removeUserFromGroup(groupId: groupId, memberIds: memberIds, dryRun: isDryRun)
            statusBanner = "Đã xóa thành viên khỏi nhóm"
            await inspectGroupDetail(groupId: groupId)
        } catch {
            errorMessage = "Xóa thành viên thất bại: \(error.localizedDescription)"
        }
    }

    public func toggleGroupInviteLink(groupId: Int64, enable: Bool) async {
        guard let api = api else { return }
        do {
            if enable {
                selectedGroupLinkDetail = try await api.enableGroupLink(groupId: groupId, dryRun: isDryRun)
                statusBanner = "Đã bật link tham gia nhóm"
            } else {
                _ = try await api.disableGroupLink(groupId: groupId, dryRun: isDryRun)
                selectedGroupLinkDetail = nil
                statusBanner = "Đã tắt link tham gia nhóm"
            }
        } catch {
            errorMessage = "Cập nhật link nhóm lỗi: \(error.localizedDescription)"
        }
    }

    // MARK: - 6. Timeline ("Nhật ký") & Stories ("Khoảnh khắc")

    public func loadTimelineAndStories(resetCursor: Bool = true) async {
        guard let api = api else { return }
        isBusy = true
        do {
            let cursorToUse = resetCursor ? nil : timelineCursor
            if let page = try await api.fetchTimelineFeed(cursor: cursorToUse, dryRun: isDryRun) {
                if resetCursor {
                    timelinePosts = page.posts
                } else {
                    timelinePosts.append(contentsOf: page.posts)
                }
                timelineCursor = page.nextCursor
                timelineHasMore = page.nextCursor != nil
            }

            if let storiesRes = try await api.fetchStoryUsers(dryRun: isDryRun) {
                storyUsers = storiesRes.users
            }
            if isDryRun {
                statusBanner = "[Dry-Run] Đã tạo request lấy Nhật ký & Khoảnh khắc. Tắt Dry-Run để tải dữ liệu thật."
            }
        } catch {
            errorMessage = "Lỗi tải Nhật ký / Khoảnh khắc: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func loadStoriesForUser(_ storyUser: ZolaStoryUser) async {
        guard let api = api else { return }
        if !storyUser.stories.isEmpty {
            activeStoryItems = storyUser.stories
            return
        }
        do {
            if let stories = try await api.fetchUserStories(userId: storyUser.uid, dryRun: isDryRun) {
                activeStoryItems = stories
            }
        } catch {
            errorMessage = "Lỗi tải Khoảnh khắc của \(storyUser.name): \(error.localizedDescription)"
        }
    }

    public func publishTimelinePost(
        caption: String,
        privacy: ZolaFeedPrivacy = .friends,
        photoURL: URL? = nil
    ) async {
        guard let api = api else { return }
        isBusy = true
        do {
            if let photoURL = photoURL {
                let imageData = try Data(contentsOf: photoURL)
                let feedId = try await api.postTimelinePhoto(
                    jpegData: imageData,
                    width: 1080,
                    height: 1080,
                    caption: caption,
                    privacy: privacy,
                    dryRun: isDryRun
                )
                statusBanner = isDryRun
                    ? "[Dry-Run] Đã chuẩn bị bài đăng ảnh Nhật ký"
                    : "Đã đăng ảnh lên Nhật ký (ID: \(feedId ?? 0))"
            } else {
                let feedId = try await api.postTimelineText(
                    caption,
                    privacy: privacy,
                    dryRun: isDryRun
                )
                statusBanner = isDryRun
                    ? "[Dry-Run] Đã chuẩn bị bài đăng chữ Nhật ký"
                    : "Đã đăng Nhật ký (ID: \(feedId ?? 0))"
            }
            await loadTimelineAndStories(resetCursor: true)
        } catch {
            errorMessage = "Đăng Nhật ký thất bại: \(error.localizedDescription)"
        }
        isBusy = false
    }

    public func toggleLikePost(_ post: ZolaFeedPost) async {
        guard let api = api else { return }
        do {
            _ = try await api.reactToFeed(
                feedId: post.id,
                like: !post.isLiked,
                dryRun: isDryRun
            )
            statusBanner = post.isLiked ? "Đã bỏ thích bài viết #\(post.id)" : "Đã thích bài viết #\(post.id)"
            await loadTimelineAndStories(resetCursor: true)
        } catch {
            errorMessage = "Thích bài viết thất bại: \(error.localizedDescription)"
        }
    }

    public func loadCommentsForPost(_ post: ZolaFeedPost) async {
        guard let api = api else { return }
        do {
            if let page = try await api.fetchFeedComments(
                feedId: post.id,
                dryRun: isDryRun
            ) {
                feedCommentsByPostId[post.id] = page.comments
            }
        } catch {
            errorMessage = "Tải bình luận bài viết lỗi: \(error.localizedDescription)"
        }
    }

    public func commentOnPost(_ post: ZolaFeedPost, text: String) async {
        guard let api = api else { return }
        do {
            _ = try await api.commentOnFeed(
                feedId: post.id,
                text: text,
                dryRun: isDryRun
            )
            statusBanner = "Đã gửi bình luận vào bài viết #\(post.id)"
            await loadCommentsForPost(post)
        } catch {
            errorMessage = "Bình luận thất bại: \(error.localizedDescription)"
        }
    }

    public func deletePost(_ post: ZolaFeedPost) async {
        guard let api = api else { return }
        do {
            _ = try await api.deleteTimelinePost(
                feedId: post.id,
                dryRun: isDryRun
            )
            timelinePosts.removeAll { $0.id == post.id }
            statusBanner = "Đã xóa bài viết #\(post.id)"
        } catch {
            errorMessage = "Xóa bài viết thất bại: \(error.localizedDescription)"
        }
    }

    // MARK: - 7. 1-1 VoIP Audio / Video Call (Opus + H.264 over ZRTP/SRTP)

    private func handleVoipEvent(_ event: ZolaVoipCallEvent) async {
        guard let api = api else { return }
        switch event {
        case .connecting:
            callStatusText = "Đang kết nối cuộc gọi..."
            isInCall = true

        case .ringing(let callId, let partnerUid):
            activeCallId = callId
            activeCallPartnerUid = partnerUid
            callStatusText = "Đang đổ chuông (#\(callId))..."
            isInCall = true

        case .answered(let callId, let partnerUid):
            activeCallId = callId
            activeCallPartnerUid = partnerUid
            isInCall = true
            isCallRingingIncoming = false
            callStatusText = "Đang trong cuộc gọi (#\(callId))"
            #if canImport(AVFoundation)
            if let prepared = await api.takePreparedVoipMediaEngine(forCallId: callId) {
                self.mediaEngine = prepared
                prepared.setSpeakerphone(isSpeakerPhoneOn)
                prepared.setMuted(isMicMuted)
            }
            #endif

        case .busy(let callId, _):
            callStatusText = "Máy bận (#\(callId))"
            cleanupActiveCall()

        case .rejected(let callId, _, _, let reason):
            callStatusText = "Cuộc gọi bị từ chối (#\(callId)) \(reason)"
            cleanupActiveCall()

        case .ended(let callId, _, let reason):
            callStatusText = "Cuộc gọi kết thúc (#\(callId)): \(reason)"
            cleanupActiveCall()

        case .incomingInvite(let callId, let partnerUid, let isVideo, let callerName, let avatarUrl, let rtp, let rtcp, let sessionId):
            activeCallId = callId
            activeCallPartnerUid = partnerUid
            isCallVideo = isVideo
            isCallRingingIncoming = true
            callStatusText = "Cuộc gọi \(isVideo ? "Video" : "Thoại") đến từ \(callerName.isEmpty ? "UID \(partnerUid)" : callerName)"
            incomingInviteInfo = IncomingCallInfo(
                callId: callId,
                callerUid: partnerUid,
                callerName: callerName.isEmpty ? "UID \(partnerUid)" : callerName,
                avatarUrl: avatarUrl,
                isVideo: isVideo,
                rtpAddress: rtp,
                rtcpAddress: rtcp,
                sessionId: sessionId
            )
            try? await api.ackVoipRinging(partnerUid: partnerUid, callId: callId, dryRun: isDryRun)

        case .partnerCameraChanged(let callId, _, let isCameraOn, _):
            isPartnerCameraOn = isCameraOn
            log("VoIP", "Partner camera changed (\(callId)): \(isCameraOn)")

        case .failed(_, _, let code, let message):
            callStatusText = "Lỗi cuộc gọi (\(code)): \(message)"
            cleanupActiveCall()
        }
    }

    public func startOutgoingCall(calleeUid: Int64, isVideo: Bool) async {
        guard let api = api else { return }
        activeCallPartnerUid = calleeUid
        isCallVideo = isVideo
        isLocalCameraOn = isVideo
        isInCall = true
        callStatusText = "Đang gọi UID \(calleeUid)..."
        do {
            let receipt = try await api.startVoipCall(partnerUid: calleeUid, isVideo: isVideo, dryRun: isDryRun)
            activeCallId = receipt.callId
            log("VoIP", "Started outgoing \(isVideo ? "video" : "audio") call #\(receipt.callId) to \(calleeUid)")
        } catch {
            errorMessage = "Không thể bắt đầu cuộc gọi: \(error.localizedDescription)"
            cleanupActiveCall()
        }
    }

    public func answerIncomingCall() async {
        guard let api = api, let info = incomingInviteInfo else { return }
        do {
            try await api.answerVoipCall(
                partnerUid: info.callerUid,
                callId: info.callId,
                isVideo: info.isVideo,
                rtpAddress: info.rtpAddress,
                rtcpAddress: info.rtcpAddress,
                sessionId: info.sessionId,
                dryRun: isDryRun
            )
            isCallRingingIncoming = false
            incomingInviteInfo = nil
        } catch {
            errorMessage = "Trả lời cuộc gọi lỗi: \(error.localizedDescription)"
        }
    }

    public func rejectIncomingCall() async {
        guard let api = api, let callId = activeCallId else { return }
        try? await api.rejectVoipCall(
            partnerUid: activeCallPartnerUid,
            callId: callId,
            isVideo: isCallVideo,
            dryRun: isDryRun
        )
        cleanupActiveCall()
    }

    public func endOrCancelActiveCall() async {
        guard let api = api, let callId = activeCallId else {
            cleanupActiveCall()
            return
        }
        try? await api.cancelVoipCall(
            partnerUid: activeCallPartnerUid,
            callId: callId,
            isVideo: isCallVideo,
            durationSeconds: 0,
            isConnected: isInCall,
            dryRun: isDryRun
        )
        cleanupActiveCall()
    }

    public func toggleMicrophoneMute() {
        isMicMuted.toggle()
        #if canImport(AVFoundation)
        mediaEngine?.setMuted(isMicMuted)
        #endif
    }

    public func toggleSpeakerPhone() {
        isSpeakerPhoneOn.toggle()
        #if canImport(AVFoundation)
        mediaEngine?.setSpeakerphone(isSpeakerPhoneOn)
        #endif
    }

    public func toggleLocalCamera() async {
        guard let api = api, let callId = activeCallId else { return }
        isLocalCameraOn.toggle()
        #if canImport(AVFoundation)
        if !isCallVideo && isLocalCameraOn {
            try? await api.upgradeVoipToVideo(partnerUid: activeCallPartnerUid, callId: callId, dryRun: isDryRun)
            isCallVideo = true
        }
        mediaEngine?.setVideoMode(enabled: isLocalCameraOn, cameraEnabled: isLocalCameraOn, preferFrontCamera: true)
        #endif
        try? await api.sendVoipCameraState(
            partnerUid: activeCallPartnerUid,
            callId: callId,
            isCameraOn: isLocalCameraOn,
            dryRun: isDryRun
        )
    }

    public func flipCamera() {
        #if canImport(AVFoundation)
        mediaEngine?.flipCamera()
        #endif
    }

    private func cleanupActiveCall() {
        #if canImport(AVFoundation)
        mediaEngine?.stop()
        mediaEngine = nil
        #endif
        isInCall = false
        isCallRingingIncoming = false
        incomingInviteInfo = nil
        activeCallId = nil
        isLocalCameraOn = false
        isPartnerCameraOn = false
    }

    // MARK: - 8. Custom Encrypted API Explorer

    public func executeCustomEndpoint(url: String, method: String, paramsJSON: String) async {
        guard let api = api else { return }
        isBusy = true
        do {
            let paramsData = paramsJSON.data(using: .utf8) ?? Data("{}".utf8)
            let paramsDict = (try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any]) ?? [:]
            let result = try await api.custom(url: url, params: paramsDict, method: method)
            if let prettyData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: prettyData, encoding: .utf8) {
                customApiResponseJSON = str
            } else {
                customApiResponseJSON = "\(result)"
            }
            statusBanner = "Đã gọi API tùy chỉnh thành công."
        } catch {
            customApiResponseJSON = "ERROR: \(error.localizedDescription)"
            errorMessage = "Gọi API tùy chỉnh lỗi: \(error.localizedDescription)"
        }
        isBusy = false
    }
}
