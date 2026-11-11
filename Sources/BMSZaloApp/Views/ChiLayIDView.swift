import SwiftUI
import ZolaKit

public struct ChiLayIDRootView: View {
    @StateObject private var store = ChiLayIDStore.shared
    @StateObject private var vm = BMSZaloViewModel()

    @State private var copyToastMessage: String?
    @State private var showAuthSheet: Bool = false
    @State private var callElapsedSeconds: Int = 0
    @State private var callTimer: Timer?

    public init() {}

    public var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Top Blue Header
                headerView

                // Body Content based on active tab
                Group {
                    switch store.activeTab {
                    case 0:
                        identitiesTabView
                    case 1:
                        callsTabView
                    case 2:
                        settingsTabView
                    default:
                        callsTabView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.96, green: 0.97, blue: 0.98)) // #F8FAFC

                // Bottom 3-Tab Bar
                bottomTabBar
            }

            // POPUP NỔI ACCOUNTID KHI CÓ CUỘC GỌI ZALO ĐẾN
            if vm.isCallRingingIncoming, let invite = vm.incomingInviteInfo {
                incomingCallPopup(invite: invite)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            } else if vm.isInCall {
                activeCallBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .edgesIgnoringSafeArea(.bottom)
        .task {
            // Tự động đăng nhập bằng phiên Zalo đã lưu sẵn trong Keychain trên iOS
            await vm.autoLoginIfPossible()
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthView(vm: vm)
        }
        .overlay(alignment: .center) {
            if let msg = copyToastMessage {
                Text(msg)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(20)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Popup Nổi AccountID Khi Có Cuộc Gọi Đến
    private func incomingCallPopup(invite: BMSZaloViewModel.IncomingCallInfo) -> some View {
        let (resolvedName, resolvedId) = store.resolveIdentity(uid: invite.callerUid, rawName: invite.callerName)
        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)

        return VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.09, green: 0.64, blue: 0.29)) // Green #16A34A
                        .frame(width: 38, height: 38)
                    Image(systemName: invite.isVideo ? "video.fill" : "phone.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 3) {
                    // DÒNG 1: Tên -- Giờ phút gọi - Đang đổ chuông (Không nhãn)
                    Text("\(resolvedName) -- \(timeStr) - Đang đổ chuông...")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    // DÒNG 2: Account ID: <Mã_AccountID> (Màu hổ phách #FBBF24 nổi bật)
                    Text("Account ID: \(resolvedId)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14)) // Amber #FBBF24
                }

                Spacer()
            }

            // Phím thao tác Nghe / Từ chối
            HStack(spacing: 12) {
                Button(action: {
                    Task {
                        await vm.rejectIncomingCall()
                        store.addCallRecord(callerName: resolvedName, accountId: resolvedId, durationSeconds: 0)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                        Text("Từ chối")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .cornerRadius(8)
                }

                Button(action: {
                    Task {
                        await vm.answerIncomingCall()
                        startCallTimer(callerName: resolvedName, accountId: resolvedId)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "phone.fill")
                        Text("Nghe máy")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.09, green: 0.64, blue: 0.29))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.96)) // Dark Navy #0F172A
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 50)
    }

    private var activeCallBanner: some View {
        let (resolvedName, resolvedId) = store.resolveIdentity(uid: vm.activeCallPartnerUid, rawName: "")
        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let m = callElapsedSeconds / 60
        let s = callElapsedSeconds % 60
        let durStr = String(format: "%02d:%02d", m, s)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(resolvedName) -- \(timeStr) - \(durStr)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("Account ID: \(resolvedId)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
            }

            Spacer()

            Button("Dập máy") {
                Task {
                    await vm.endOrCancelActiveCall()
                    stopCallTimer(callerName: resolvedName, accountId: resolvedId)
                }
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red)
            .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.64, blue: 0.29))
        .cornerRadius(12)
        .padding(.horizontal, 12)
        .padding(.top, 50)
    }

    private func startCallTimer(callerName: String, accountId: String) {
        callElapsedSeconds = 0
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            callElapsedSeconds += 1
        }
    }

    private func stopCallTimer(callerName: String, accountId: String) {
        callTimer?.invalidate()
        callTimer = nil
        store.addCallRecord(callerName: callerName, accountId: accountId, durationSeconds: callElapsedSeconds)
        callElapsedSeconds = 0
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.86, green: 0.15, blue: 0.46)) // #DB2777
                            .frame(width: 28, height: 28)
                        Text("ID")
                            .font(.system(size: 13, weight: .black))
                            .foregroundColor(.white)
                    }
                    Text("BMSZalo - ChiLayID")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                }

                Spacer()

                // Trạng thái Zalo
                if vm.isAuthenticated {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("UID: \(vm.ownUid)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(12)
                } else {
                    Button(action: { showAuthSheet = true }) {
                        Text("Đăng nhập Zalo")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange)
                            .cornerRadius(12)
                    }
                }
            }

            // Stats Subheader
            let totalIds = store.identities.count
            let totalCalls = store.callRecords.count
            let totalAvatars = store.avatarCount
            Text("Đã nạp: \(totalIds) AccountID gốc (\(totalAvatars) vân tay Avatar) • \(totalCalls) cuộc gọi")
                .font(.system(size: 12))
                .foregroundColor(Color(red: 0.88, green: 0.95, blue: 1.0)) // #E0F2FE

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color(red: 0.58, green: 0.64, blue: 0.72))
                TextField("Tìm theo Tên Zalo hoặc AccountID...", text: $store.searchQuery)
                    .font(.system(size: 13))
                    .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16))
                if !store.searchQuery.isEmpty {
                    Button(action: { store.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white)
            .cornerRadius(10)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(red: 0.0, green: 0.41, blue: 1.0)) // #0068FF
    }

    // MARK: - Tab 0: Danh bạ ID
    private var identitiesTabView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let list = store.filteredIdentities
                if list.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("Chưa có danh bạ. Nhấn vào Tab Cài đặt để nạp 6,377 liên hệ từ seed.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)
                } else {
                    HStack {
                        Text("⚡ Hiển thị \(list.count)/\(store.identities.count) liên hệ")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(red: 0.0, green: 0.41, blue: 1.0))
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    ForEach(list) { item in
                        identityCard(item)
                    }
                }
            }
            .padding(14)
        }
    }

    private func identityCard(_ item: ChiLayIDIdentity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(red: 0.0, green: 0.41, blue: 1.0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16))
                        if !item.aliasName.isEmpty {
                            Text("Gợi nhớ: \(item.aliasName)")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                    }
                }
                Spacer()

                Button(action: {
                    UIPasteboard.general.string = item.accountId
                    showToast("Đã chép: \(item.accountId)")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 11))
                        Text("Copy ID")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.0, green: 0.41, blue: 1.0))
                    .cornerRadius(8)
                }
            }

            // AccountID Row
            HStack(spacing: 6) {
                Text("ID")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.55, green: 0.16, blue: 0.84))
                    .cornerRadius(4)
                Text("AccountID gốc: \(item.accountId)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.0, green: 0.41, blue: 1.0))
            }

            // Avatar signature & Source badge
            HStack(spacing: 8) {
                if !item.avatarSignature.isEmpty {
                    Text("🎨 Vân tay 4x4 (\(item.avatarSignature.prefix(12))...)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text("⚪ Chưa có vân tay")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(item.source)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(14)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: 1)
        )
    }

    // MARK: - Tab 1: 📞 Cuộc gọi đến (Chuẩn đúng 2 dòng)
    private var callsTabView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                let list = store.filteredCalls
                if list.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "phone.badge.plus")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("Chưa có cuộc gọi Zalo nào được ghi nhận.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 60)
                } else {
                    ForEach(list) { call in
                        callCard(call)
                    }
                }
            }
            .padding(14)
        }
    }

    private func callCard(_ call: ChiLayIDCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // DÒNG 1: Tên -- Giờ:phút gọi - Tổng thời gian đàm thoại (Hoàn toàn không có nhãn)
            Text(call.line1Text)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16)) // #0F172A

            // DÒNG 2: Account ID: <Mã_AccountID> (Chữ đậm, màu xanh lá nổi bật)
            Text(call.line2Text)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(red: 0.09, green: 0.64, blue: 0.29)) // #16A34A
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: 1)
        )
    }

    // MARK: - Tab 2: ⚙️ Cài đặt
    private var settingsTabView: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Card 1: Tài khoản Zalo
                VStack(alignment: .leading, spacing: 10) {
                    Text("👤 Tài Khoản Zalo Trên iPhone")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16))

                    if vm.isAuthenticated {
                        HStack {
                            Circle().fill(Color.green).frame(width: 10, height: 10)
                            Text("Đã đăng nhập: UID \(vm.ownUid)")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button("Đăng xuất") {
                                vm.logout()
                            }
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                        }
                    } else {
                        Text("App tự động tìm và khôi phục phiên đăng nhập Zalo đã có trong Keychain máy iPhone.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)

                        Button(action: { showAuthSheet = true }) {
                            HStack {
                                Image(systemName: "key.fill")
                                Text("Đăng nhập tài khoản Zalo")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.white)
                            .background(Color(red: 0.0, green: 0.41, blue: 1.0))
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(16)
                .background(Color.white)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: 1))

                // Card 2: Nạp danh bạ Seed
                VStack(alignment: .leading, spacing: 10) {
                    Text("📦 Kho Dữ Liệu Danh Bạ")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16))

                    Text("Nạp 6,377 AccountID gốc từ file zalo_contacts_seed.json đóng gói trong ứng dụng.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Button(action: {
                        let count = store.importSeedContactsIfAvailable()
                        showToast("Đã đồng bộ kho Danh bạ! (+\(count) mới)")
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("📥 Nạp toàn bộ Danh bạ Zalo (seed.json)")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.white)
                        .background(Color(red: 0.09, green: 0.64, blue: 0.29)) // #16A34A
                        .cornerRadius(10)
                    }
                }
                .padding(16)
                .background(Color.white)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: 1))

                // Card 3: Trạng thái CRM
                VStack(alignment: .leading, spacing: 10) {
                    Text("🔌 Trạng Thái Đồng Bộ CRM")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(red: 0.06, green: 0.09, blue: 0.16))

                    HStack {
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.orange)
                        Text("Tạm thời ngắt kết nối CRM (Chạy độc lập trên máy)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
                .background(Color.white)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: 1))
            }
            .padding(14)
        }
    }

    // MARK: - Bottom Bar (3 Tabs)
    private var bottomTabBar: some View {
        HStack(spacing: 8) {
            tabButton(index: 0, title: "🆔 Danh bạ ID")
            tabButton(index: 1, title: "📞 Cuộc gọi đến")
            tabButton(index: 2, title: "⚙️ Cài đặt")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background(Color.white)
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: -2)
    }

    private func tabButton(index: Int, title: String) -> some View {
        let isSelected = store.activeTab == index
        return Button(action: {
            store.activeTab = index
        }) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSelected ? .white : Color(red: 0.28, green: 0.33, blue: 0.41))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color(red: 0.0, green: 0.41, blue: 1.0) : Color.clear)
                .cornerRadius(10)
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { copyToastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { copyToastMessage = nil }
        }
    }
}
