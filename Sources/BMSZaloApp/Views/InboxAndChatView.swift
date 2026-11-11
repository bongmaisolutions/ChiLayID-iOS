import SwiftUI
import UniformTypeIdentifiers
import ZolaKit

public struct InboxAndChatView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var draftText: String = ""
    @State private var replyingToMessage: ZolaMessage?
    @State private var activeMentions: [ZolaMention] = []

    @State private var showRichComposerSheet: Bool = false
    @State private var showPinBoardSheet: Bool = false
    @State private var showPollSheet: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var fileImportKind: FileImportKind = .photo

    public enum FileImportKind {
        case photo
        case document
        case voice
    }

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationSplitView {
            inboxSidebar
        } detail: {
            if let conv = vm.currentConversation {
                chatDetailView(for: conv)
            } else {
                ContentUnavailableView(
                    "Chọn một cuộc trò chuyện",
                    systemImage: "message.badge.waveform.fill",
                    description: Text("Chọn hội thoại bên trái hoặc đồng bộ hộp thư để bắt đầu nhắn tin.")
                )
            }
        }
        .sheet(isPresented: $showRichComposerSheet) {
            RichAttachmentSheet(vm: vm, draftText: $draftText, activeMentions: $activeMentions)
        }
        .sheet(isPresented: $showPinBoardSheet) {
            PinBoardSheetView(vm: vm)
        }
        .sheet(isPresented: $showPollSheet) {
            GroupPollSheetView(vm: vm)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    switch fileImportKind {
                    case .photo:
                        await vm.uploadAndSendPhotoFile(url: url, caption: draftText)
                    case .document:
                        await vm.uploadAndSendDocumentFile(url: url)
                    case .voice:
                        if let data = try? Data(contentsOf: url) {
                            await vm.uploadAndSendVoiceData(data, durationMs: 3000)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inbox Sidebar

    private var inboxSidebar: some View {
        VStack(spacing: 0) {
            searchAndFilterHeader
            Divider()
            conversationsListView
        }
        .navigationTitle("Tin nhắn (\(vm.filteredConversations.count))")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await vm.syncInboxNow() }
                } label: {
                    Label("Đồng bộ Inbox", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private var searchAndFilterHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Tìm kiếm không dấu (VD: ha noi)...", text: $vm.searchQuery)
                    .textFieldStyle(.plain)
                if !vm.searchQuery.isEmpty {
                    Button {
                        vm.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            filterChipsBar

            if vm.inboxFilter == .byTag && !vm.chatTags.isEmpty {
                tagChipsBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BMSZaloViewModel.InboxFilter.allCases) { filter in
                    let isSelected = (vm.inboxFilter == filter)
                    Button {
                        vm.inboxFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? Color.blue : Color.secondary.opacity(0.15))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var tagChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.chatTags, id: \.id) { tag in
                    let isSelected = (vm.selectedTagId == tag.id)
                    Button {
                        vm.selectedTagId = tag.id
                    } label: {
                        Text("\(tag.emoji) \(tag.text)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? Color.orange : Color.secondary.opacity(0.12))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var conversationsListView: some View {
        List(selection: $vm.selectedThreadId) {
            ForEach(vm.filteredConversations) { conv in
                ConversationRowView(
                    conv: conv,
                    isPinned: vm.pinnedThreadIds.contains(conv.threadId),
                    isMuted: vm.mutedThreadIds.contains(conv.threadId)
                )
                .tag(conv.threadId)
                .contextMenu {
                    conversationContextMenu(for: conv)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func conversationContextMenu(for conv: ZolaConversation) -> some View {
        Button {
            Task { await vm.togglePinConversation(conv) }
        } label: {
            Label(
                vm.pinnedThreadIds.contains(conv.threadId) ? "Bỏ ghim hội thoại" : "Ghim hội thoại",
                systemImage: "pin"
            )
        }

        Button {
            Task { await vm.toggleMuteConversation(conv) }
        } label: {
            Label("Bật / Tắt thông báo", systemImage: "bell.slash")
        }

        if !conv.isGroup {
            Divider()
            Button {
                Task { await vm.startOutgoingCall(calleeUid: conv.threadId, isVideo: false) }
            } label: {
                Label("Gọi thoại VoIP", systemImage: "phone.fill")
            }
            Button {
                Task { await vm.startOutgoingCall(calleeUid: conv.threadId, isVideo: true) }
            } label: {
                Label("Gọi Video VoIP", systemImage: "video.fill")
            }
        }

        if !vm.chatTags.isEmpty {
            Menu("Gắn thẻ phân loại") {
                ForEach(vm.chatTags, id: \.id) { tag in
                    let hasTag = tag.matchesThread(threadId: conv.threadId, title: conv.title)
                    Button {
                        Task {
                            await vm.assignTagToConversation(tag: tag, conv: conv, assign: !hasTag)
                        }
                    } label: {
                        Label(
                            "\(tag.emoji) \(tag.text)",
                            systemImage: hasTag ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Chat Detail View

    private func chatDetailView(for conv: ZolaConversation) -> some View {
        VStack(spacing: 0) {
            // Pin Board Header Bar
            HStack {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.orange)
                if let topPin = vm.currentThreadPinBoard.first {
                    Text("Ghim: \(topPin.title.isEmpty ? "Tin nhắn đã ghim #\(topPin.id)" : topPin.title)")
                        .font(.caption.bold())
                        .lineLimit(1)
                } else {
                    Text("Bảng ghim hội thoại (\(conv.isGroup ? "Nhóm" : "1-1"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mở Bảng ghim") {
                    Task {
                        await vm.loadPinBoardForCurrentThread()
                        showPinBoardSheet = true
                    }
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .controlSize(.small)

                if conv.isGroup {
                    Button("Tải tin cũ hơn") {
                        Task { await vm.fetchOlderHistoryForCurrentThread() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))

            Divider()

            // Message History ScrollView
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.currentMessages) { message in
                            MessageBubbleView(
                                message: message,
                                onReply: { replyingToMessage = message },
                                onReact: { icon in
                                    Task { await vm.reactToMessage(message, icon: icon) }
                                },
                                onPin: {
                                    Task { await vm.pinMessageInCurrentThread(message) }
                                },
                                onRecall: {
                                    Task { await vm.recallMessage(message) }
                                },
                                onDelete: {
                                    Task { await vm.deleteMessageOnlyMe(message) }
                                },
                                onOpenPoll: { pollId in
                                    Task {
                                        await vm.inspectGroupPoll(pollId: pollId)
                                        showPollSheet = true
                                    }
                                }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: vm.currentMessages.count) { _, _ in
                    if let lastId = vm.currentMessages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            // Typing Indicator
            if let typingUid = vm.typingUsersByThread[conv.threadId] {
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text("UID \(typingUid) đang soạn tin nhắn...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }

            // Contextual Vietnamese Telex Sticker Suggestion Bar
            if !vm.stickerSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Label("Gợi ý Sticker Telex:", systemImage: "sparkles")
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                        ForEach(vm.stickerSuggestions, id: \.id) { sticker in
                            Button {
                                Task {
                                    await vm.sendStickerItem(sticker)
                                }
                            } label: {
                                Text("😊 \(sticker.label.isEmpty ? "#\(sticker.stickerId)" : sticker.label)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color.secondary.opacity(0.06))
            }

            // Reply Quote Banner
            if let quote = replyingToMessage {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Đang trả lời \(quote.senderName.isEmpty ? "UID \(quote.senderId)" : quote.senderName)")
                            .font(.caption.bold())
                        Text(quote.text.isEmpty ? "[Đính kèm]" : quote.text)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        replyingToMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.08))
            }

            Divider()

            // Composer Bar
            HStack(spacing: 8) {
                Menu {
                    Button {
                        fileImportKind = .photo
                        showFileImporter = true
                    } label: {
                        Label("Gửi Ảnh (Photo / Album)", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        fileImportKind = .document
                        showFileImporter = true
                    } label: {
                        Label("Gửi Tài liệu / File", systemImage: "doc.fill")
                    }
                    Button {
                        fileImportKind = .voice
                        showFileImporter = true
                    } label: {
                        Label("Gửi Tin nhắn Thoại (.m4a/.aac/.amr)", systemImage: "waveform")
                    }
                    Divider()
                    Button {
                        showRichComposerSheet = true
                    } label: {
                        Label("Sticker, Link, Vị trí, Danh thiếp, @Mention...", systemImage: "plus.app.fill")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                TextField("Nhập tin nhắn (hỗ trợ gõ Telex gợi ý Sticker)...", text: $draftText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftText) { _, newValue in
                        vm.updateStickerSuggestions(for: newValue)
                    }
                    .onSubmit {
                        sendDraftNow()
                    }

                Button {
                    sendDraftNow()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .navigationTitle(conv.title)
        .toolbar {
            if !conv.isGroup {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await vm.startOutgoingCall(calleeUid: conv.threadId, isVideo: false) }
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    Button {
                        Task { await vm.startOutgoingCall(calleeUid: conv.threadId, isVideo: true) }
                    } label: {
                        Image(systemName: "video.fill")
                    }
                }
            }
        }
    }

    private func sendDraftNow() {
        let text = draftText
        let quote = replyingToMessage
        let mentions = activeMentions
        draftText = ""
        replyingToMessage = nil
        activeMentions = []
        vm.stickerSuggestions = []
        Task {
            await vm.sendTextMessage(text: text, quote: quote, mentions: mentions)
        }
    }
}

// MARK: - Subviews

private struct ConversationRowView: View {
    let conv: ZolaConversation
    let isPinned: Bool
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(conv.isCloud ? Color.purple.opacity(0.2) : (conv.isGroup ? Color.blue.opacity(0.2) : Color.green.opacity(0.2)))
                    .frame(width: 42, height: 42)
                Image(systemName: conv.isCloud ? "icloud.fill" : (conv.isGroup ? "person.3.fill" : "person.fill"))
                    .foregroundStyle(conv.isCloud ? .purple : (conv.isGroup ? .blue : .green))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(conv.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if conv.unreadCount > 0 {
                        Text("\(conv.unreadCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }

                Text(lastMessagePreview(conv.lastMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func lastMessagePreview(_ msg: ZolaMessage?) -> String {
        guard let msg else { return "Chưa có tin nhắn" }
        if !msg.text.isEmpty { return msg.text }
        if let firstAtt = msg.attachments.first {
            return "[\(firstAtt.kind.uppercased())] \(firstAtt.title)"
        }
        return "[Tin nhắn]"
    }
}

private struct MessageBubbleView: View {
    let message: ZolaMessage
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onPin: () -> Void
    let onRecall: () -> Void
    let onDelete: () -> Void
    let onOpenPoll: (String) -> Void

    private let reactionIcons = ["❤️", "👍", "😆", "😮", "😢", "😡"]

    var body: some View {
        HStack {
            if message.isSelf { Spacer(minLength: 48) }

            VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 4) {
                if !message.isSelf, !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }

                if let quote = message.quote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trả lời \(quote.senderName.isEmpty ? "UID \(quote.ownerId)" : quote.senderName):")
                            .font(.caption2.bold())
                        Text(quote.previewSummary)
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Main Content
                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                    } else if let firstAtt = message.attachments.first {
                        Text("[\(firstAtt.kind.uppercased())]")
                            .font(.body)
                    } else {
                        Text("[\(message.kind)]")
                            .font(.body)
                    }

                    // Attachments
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, att in
                        HStack(spacing: 6) {
                            Image(systemName: iconForAttachment(att.kind))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(att.title.isEmpty ? att.kind.uppercased() : att.title)
                                    .font(.caption.bold())
                                let urlStr = att.url.isEmpty ? att.thumbUrl : att.url
                                if !urlStr.isEmpty, let url = URL(string: urlStr) {
                                    Link(urlStr, destination: url)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(6)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // Group Poll / Board Card
                    if let board = message.boardCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(board.title, systemImage: "chart.bar.doc.horizontal.fill")
                                .font(.caption.bold())
                            if let pollId = board.pollId {
                                Button("Xem chi tiết Bình chọn (#\(pollId))") {
                                    onOpenPoll(pollId)
                                }
                                .font(.caption2.bold())
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .background(message.isSelf ? Color.blue : Color.secondary.opacity(0.16))
                .foregroundStyle(message.isSelf ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contextMenu {
                    Button("Trả lời (Quote)", action: onReply)
                    Menu("Thả cảm xúc (Reaction)") {
                        ForEach(reactionIcons, id: \.self) { icon in
                            Button(icon) { onReact(icon) }
                        }
                    }
                    Button("Ghim lên Bảng ghim", action: onPin)
                    if message.isSelf {
                        Button("Thu hồi tin nhắn (Recall)", role: .destructive, action: onRecall)
                    }
                    Button("Xóa ở phía tôi", role: .destructive, action: onDelete)
                }

                // Reactions Summary
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, icon in
                            Text(icon)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if !message.isSelf { Spacer(minLength: 48) }
        }
    }

    private func iconForAttachment(_ kind: String) -> String {
        switch kind.lowercased() {
        case "photo", "image": return "photo"
        case "video": return "video.fill"
        case "voice": return "waveform"
        case "file": return "doc.fill"
        case "sticker": return "face.smiling.fill"
        case "gif": return "sparkles.rectangle.stack"
        case "link", "webcontent", "article": return "link"
        default: return "paperclip"
        }
    }
}

// MARK: - Rich Attachment, Link, Location, Contact Card & Sticker Sheet

private struct RichAttachmentSheet: View {
    @ObservedObject var vm: BMSZaloViewModel
    @Binding var draftText: String
    @Binding var activeMentions: [ZolaMention]
    @Environment(\.dismiss) private var dismiss

    @State private var linkUrl: String = "https://zalo.me"
    @State private var linkCaption: String = ""
    @State private var locName: String = "Hồ Hoàn Kiếm"
    @State private var locAddress: String = "Hoàn Kiếm, Hà Nội"
    @State private var locLat: String = "21.0285"
    @State private var locLon: String = "105.8542"
    @State private var contactUid: String = ""
    @State private var contactPhone: String = ""
    @State private var stickerQuery: String = "xin chào"
    @State private var mentionUid: String = ""
    @State private var mentionTagText: String = "@BanBe"
    @State private var cloudNoteText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Ghi chú nhanh vào Cloud của tôi (sendToMe)") {
                    TextField("Nội dung lưu vào Cloud của tôi...", text: $cloudNoteText)
                    Button("Gửi vào Cloud của tôi") {
                        Task {
                            await vm.sendToMyCloud(text: cloudNoteText)
                            dismiss()
                        }
                    }
                    .disabled(cloudNoteText.isEmpty)
                }

                Section("Tìm & Gửi Sticker (getStickers / sendSticker)") {
                    HStack {
                        TextField("Từ khóa Sticker...", text: $stickerQuery)
                        Button("Tìm") {
                            Task { await vm.searchStickersByKeyword(stickerQuery) }
                        }
                    }
                    if !vm.searchedStickers.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(vm.searchedStickers, id: \.id) { sticker in
                                    Button {
                                        Task {
                                            await vm.sendStickerItem(sticker)
                                            dismiss()
                                        }
                                    } label: {
                                        VStack {
                                            Image(systemName: "face.smiling.inverse")
                                                .font(.title)
                                            Text("#\(sticker.stickerId)")
                                                .font(.caption2)
                                        }
                                        .padding(8)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Section("Gửi Thẻ Liên kết (resolveLinkMetadata + sendLink1To1)") {
                    TextField("URL liên kết", text: $linkUrl)
                    TextField("Chú thích kèm theo (tùy chọn)", text: $linkCaption)
                    Button("Gửi Thẻ Liên kết") {
                        Task {
                            await vm.sendLinkBubble(url: linkUrl, title: linkUrl, desc: linkCaption)
                            dismiss()
                        }
                    }
                }

                Section("Gửi Vị trí (sendLocation1To1)") {
                    TextField("Tên địa điểm", text: $locName)
                    TextField("Địa chỉ", text: $locAddress)
                    HStack {
                        TextField("Vĩ độ (Lat)", text: $locLat)
                        TextField("Kinh độ (Lon)", text: $locLon)
                    }
                    Button("Gửi Vị trí") {
                        Task {
                            await vm.sendLocationBubble(
                                lat: Double(locLat) ?? 21.0285,
                                lon: Double(locLon) ?? 105.8542,
                                locationName: locName,
                                address: locAddress
                            )
                            dismiss()
                        }
                    }
                }

                Section("Gửi Danh thiếp (sendContactCard1To1)") {
                    TextField("UID người dùng", text: $contactUid)
                    TextField("Số điện thoại (tùy chọn)", text: $contactPhone)
                    Button("Gửi Danh thiếp") {
                        Task {
                            if let uid = Int64(contactUid.trimmingCharacters(in: .whitespaces)) {
                                await vm.sendBusinessCardBubble(contactUid: uid, contactName: "UID \(uid)", phone: contactPhone)
                                dismiss()
                            }
                        }
                    }
                    .disabled(Int64(contactUid.trimmingCharacters(in: .whitespaces)) == nil)
                }

                Section("Thêm @Mention vào tin nhắn nhóm") {
                    TextField("UID thành viên được tag", text: $mentionUid)
                    TextField("Chuỗi hiển thị (VD: @NguyenVanA)", text: $mentionTagText)
                    Button("Chèn @Mention vào khung soạn thảo") {
                        if let uid = Int64(mentionUid.trimmingCharacters(in: .whitespaces)) {
                            let pos = draftText.utf16.count
                            draftText += (draftText.isEmpty ? "" : " ") + mentionTagText + " "
                            let startPos = pos + (pos == 0 ? 0 : 1)
                            activeMentions.append(ZolaMention(type: 0, uid: uid, pos: startPos, len: mentionTagText.utf16.count))
                            dismiss()
                        }
                    }
                    .disabled(Int64(mentionUid.trimmingCharacters(in: .whitespaces)) == nil || mentionTagText.isEmpty)
                }
            }
            .navigationTitle("Công cụ Gửi Nâng cao")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Pin Board & Group Poll Sheets

private struct PinBoardSheetView: View {
    @ObservedObject var vm: BMSZaloViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.currentThreadPinBoard.isEmpty {
                    Text("Chưa có mục ghim nào trong hội thoại này.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.currentThreadPinBoard, id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title.isEmpty ? "Mục ghim #\(item.id)" : item.title)
                                    .font(.headline)
                                Text("Topic ID: \(item.id) • Msg ID: \(item.messageId) • Người gửi: \(item.senderUid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Bỏ ghim", role: .destructive) {
                                Task { await vm.unpinItemInCurrentThread(item) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Bảng Ghim Hội Thoại")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Làm mới") {
                        Task { await vm.loadPinBoardForCurrentThread() }
                    }
                }
            }
        }
    }
}

private struct GroupPollSheetView: View {
    @ObservedObject var vm: BMSZaloViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let poll = vm.activeGroupPoll {
                List {
                    Section("Câu hỏi Bình chọn") {
                        Text(poll.question)
                            .font(.headline)
                        Text("Tổng số phiếu: \(poll.totalVotes ?? 0) • Trạng thái: \(poll.state == 2 ? "Đã đóng" : "Đang mở")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Các phương án lựa chọn") {
                        ForEach(poll.answers, id: \.id) { opt in
                            HStack {
                                Text(opt.content)
                                Spacer()
                                Text("\(opt.votes ?? 0) bình chọn")
                                    .font(.caption.bold())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                .navigationTitle("Chi tiết Bình chọn")
            } else {
                ProgressView("Đang tải bình chọn...")
            }
        }
    }
}
