import SwiftUI
import ZolaKit

/// Root SwiftUI View for BMSZalo on iOS / iPadOS / macOS.
/// Embed `BMSZaloRootView()` inside your Xcode App target's `WindowGroup` or use `BMSZaloSceneApp`.
public struct BMSZaloRootView: View {
    @StateObject private var vm: BMSZaloViewModel

    public init(viewModel: BMSZaloViewModel? = nil) {
        _vm = StateObject(wrappedValue: viewModel ?? BMSZaloViewModel())
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Protocol Control & Safety Status Bar
            protocolControlHeaderBar

            // Incoming VoIP Call Banner Overlay
            if let invite = vm.incomingInviteInfo, vm.isCallRingingIncoming {
                incomingCallBanner(invite: invite)
            }

            // Status / Error Toast Banner
            if let err = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                        .font(.caption.bold())
                    Spacer()
                    Button("Đóng") { vm.errorMessage = nil }
                        .font(.caption.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.9))
                .foregroundStyle(.white)
            } else if let status = vm.statusBanner {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(status)
                        .font(.caption.bold())
                    Spacer()
                    Button("Ẩn") { vm.statusBanner = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.88))
                .foregroundStyle(.white)
            }

            // Main Content
            if vm.isAuthenticated {
                TabView {
                    InboxAndChatView(vm: vm)
                        .tabItem {
                            Label("Tin nhắn", systemImage: "message.fill")
                        }

                    ContactsView(vm: vm)
                        .tabItem {
                            Label("Danh bạ", systemImage: "person.2.fill")
                        }

                    GroupsView(vm: vm)
                        .tabItem {
                            Label("Nhóm", systemImage: "person.3.fill")
                        }

                    TimelineAndStoriesView(vm: vm)
                        .tabItem {
                            Label("Nhật ký", systemImage: "newspaper.fill")
                        }

                    VoipCallView(vm: vm)
                        .tabItem {
                            Label("Gọi VoIP", systemImage: "phone.badge.waveform.fill")
                        }

                    SettingsAndControlView(vm: vm)
                        .tabItem {
                            Label("Chủ động", systemImage: "slider.horizontal.3")
                        }
                }
            } else {
                AuthView(vm: vm)
            }
        }
    }

    private var protocolControlHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isAuthenticated ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(vm.isAuthenticated ? "UID: \(vm.ownUid)" : "Chưa đăng nhập")
                    .font(.caption.bold())
            }

            Spacer()

            Toggle(isOn: $vm.isDryRun) {
                Text(vm.isDryRun ? "Dry-Run (An toàn)" : "LIVE (Gửi thật)")
                    .font(.caption2.bold())
                    .foregroundStyle(vm.isDryRun ? .orange : .green)
            }
            .toggleStyle(.button)
            .controlSize(.mini)

            Toggle(isOn: $vm.isGroupSendEnabled) {
                Text("Group Media: \(vm.isGroupSendEnabled ? "BẬT" : "TẮT")")
                    .font(.caption2.bold())
            }
            .toggleStyle(.button)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1))
    }

    private func incomingCallBanner(invite: BMSZaloViewModel.IncomingCallInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: invite.isVideo ? "video.fill" : "phone.down.waves.left.and.right")
                .font(.title3)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cuộc gọi \(invite.isVideo ? "Video" : "Thoại") đến từ \(invite.callerName.isEmpty ? "UID \(invite.callerUid)" : invite.callerName)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text("Call ID #\(invite.callId) • UID \(invite.callerUid)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button("Nghe") {
                Task { await vm.answerIncomingCall() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.green)

            Button("Từ chối") {
                Task { await vm.rejectIncomingCall() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(10)
        .background(Color.green)
    }
}
