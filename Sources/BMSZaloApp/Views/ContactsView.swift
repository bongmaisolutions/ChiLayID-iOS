import SwiftUI
import ZolaKit

public struct ContactsView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var searchQuery: String = ""
    @State private var selectedSection: Int = 0
    @State private var selectedUserForAction: ZolaUser?
    @State private var aliasInput: String = ""
    @State private var friendRequestMessage: String = "Xin chào, mình kết bạn trên Zalo nhé!"

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Chế độ Danh bạ", selection: $selectedSection) {
                    Text("Bạn bè (\(vm.friends.count))").tag(0)
                    Text("Lời mời (\(vm.incomingFriendRequests.count))").tag(1)
                    Text("Đã gửi (\(vm.sentFriendRequests.count))").tag(2)
                    Text("Gợi ý (\(vm.friendRecommendations.count))").tag(3)
                    Text("Tìm kiếm").tag(4)
                }
                .pickerStyle(.segmented)
                .padding()

                List {
                    switch selectedSection {
                    case 0:
                        friendsSection
                    case 1:
                        incomingRequestsSection
                    case 2:
                        sentRequestsSection
                    case 3:
                        recommendationsSection
                    case 4:
                        lookupSection
                    default:
                        EmptyView()
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Danh bạ & Kết bạn")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await vm.refreshContactsData() }
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(item: $selectedUserForAction) { user in
                userDetailSheet(user: user)
            }
        }
    }

    @ViewBuilder
    private var friendsSection: some View {
        let qFolded = ZolaTextNormalizer.foldVietnamese(searchQuery)
        let filtered = qFolded.isEmpty ? vm.friends : vm.friends.filter {
            ZolaTextNormalizer.foldVietnamese($0.displayName).contains(qFolded)
            || ZolaTextNormalizer.foldVietnamese($0.zaloName).contains(qFolded)
            || $0.phone.contains(searchQuery)
        }
        Section("Danh sách Bạn bè (\(filtered.count))") {
            TextField("Lọc nhanh tên hoặc SĐT...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
            ForEach(filtered) { friend in
                userRow(friend) {
                    Button("Chi tiết") {
                        aliasInput = friend.displayName
                        selectedUserForAction = friend
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var incomingRequestsSection: some View {
        Section("Lời mời Kết bạn Đang chờ (\(vm.incomingFriendRequests.count))") {
            if vm.incomingFriendRequests.isEmpty {
                Text("Không có lời mời kết bạn nào.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.incomingFriendRequests) { req in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(req.displayName)
                                .font(.headline)
                            Spacer()
                            Text("UID: \(String(req.uid))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if !req.message.isEmpty {
                            Text("“\(req.message)”")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Đồng ý") {
                                Task { await vm.acceptFriendRequest(from: req.uid) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Từ chối", role: .destructive) {
                                Task { await vm.rejectFriendRequest(from: req.uid) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var sentRequestsSection: some View {
        Section("Lời mời Đã gửi (\(vm.sentFriendRequests.count))") {
            if vm.sentFriendRequests.isEmpty {
                Text("Chưa gửi lời mời kết bạn nào.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.sentFriendRequests) { req in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(req.displayName)
                                .font(.headline)
                            Text("UID: \(String(req.uid)) • \(req.sourceLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Thu hồi", role: .destructive) {
                            Task { await vm.undoSentFriendRequest(to: req.uid) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recommendationsSection: some View {
        Section("Gợi ý Kết bạn (\(vm.friendRecommendations.count))") {
            ForEach(vm.friendRecommendations) { rec in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rec.displayName)
                            .font(.headline)
                        Text(rec.sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Kết bạn") {
                        Task {
                            await vm.sendFriendRequest(to: rec.uid, message: friendRequestMessage)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var lookupSection: some View {
        Section("Tra cứu theo Số điện thoại hoặc @Username") {
            HStack {
                TextField("Nhập SĐT hoặc @username...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                Button("Tìm") {
                    Task { await vm.searchUsers(query: searchQuery) }
                }
                .buttonStyle(.borderedProminent)
            }
            TextField("Lời nhắn kết bạn", text: $friendRequestMessage)
                .textFieldStyle(.roundedBorder)

            ForEach(vm.searchedUsers) { user in
                userRow(user) {
                    Button("Kết bạn") {
                        Task { await vm.sendFriendRequest(to: user.uid, message: friendRequestMessage) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Chi tiết") {
                        aliasInput = user.displayName
                        selectedUserForAction = user
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func userRow<Actions: View>(_ user: ZolaUser, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(
                    Text(String(user.displayName.prefix(1)).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(.blue)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.subheadline.bold())
                let phoneSuffix = user.phone.isEmpty ? "" : " • \(user.phone)"
                Text("UID: \(String(user.uid))\(phoneSuffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !user.statusText.isEmpty {
                    Text(user.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            actions()
        }
        .padding(.vertical, 2)
    }

    private func userDetailSheet(user: ZolaUser) -> some View {
        NavigationStack {
            Form {
                Section("Thông tin Cá nhân") {
                    LabeledContent("Tên hiển thị", value: user.displayName)
                    LabeledContent("Tên Zalo", value: user.zaloName)
                    LabeledContent("UID", value: String(user.uid))
                    if !user.phone.isEmpty {
                        LabeledContent("Số điện thoại", value: user.phone)
                    }
                    if !user.statusText.isEmpty {
                        LabeledContent("Tiểu sử", value: user.statusText)
                    }
                    if let dob = user.birthday, !dob.isEmpty {
                        LabeledContent("Ngày sinh", value: dob)
                    }
                }

                Section("Tên gợi nhớ (Alias)") {
                    TextField("Tên gợi nhớ mới", text: $aliasInput)
                    HStack {
                        Button("Lưu tên gợi nhớ") {
                            Task { await vm.updateFriendAlias(uid: user.uid, alias: aliasInput) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Xóa tên gợi nhớ", role: .destructive) {
                            Task { await vm.updateFriendAlias(uid: user.uid, alias: "") }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Cuộc gọi & Mã QR") {
                    HStack {
                        Button {
                            selectedUserForAction = nil
                            Task { await vm.startOutgoingCall(calleeUid: user.uid, isVideo: false) }
                        } label: {
                            Label("Gọi Thoại", systemImage: "phone.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            selectedUserForAction = nil
                            Task { await vm.startOutgoingCall(calleeUid: user.uid, isVideo: true) }
                        } label: {
                            Label("Gọi Video", systemImage: "video.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Lấy link QR Zalo") {
                        Task { await vm.loadUserQR(uid: user.uid) }
                    }
                    if let qr = vm.qrUrlsByUid[user.uid] {
                        Text(qr)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                Section("Chặn / Bỏ chặn") {
                    HStack {
                        Button("Chặn người dùng", role: .destructive) {
                            Task { await vm.toggleBlockUser(uid: user.uid, blocked: true) }
                        }
                        .buttonStyle(.bordered)

                        Button("Bỏ chặn") {
                            Task { await vm.toggleBlockUser(uid: user.uid, blocked: false) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .navigationTitle(user.displayName)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { selectedUserForAction = nil }
                }
            }
        }
    }
}
