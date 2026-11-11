import SwiftUI
import ZolaKit

public struct VoipCallView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var targetUidInput: String = ""

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    callStatusCard

                    if let invite = vm.incomingInviteInfo {
                        incomingCallBanner(invite)
                    }

                    if vm.isInCall {
                        activeCallControls
                    } else {
                        dialerCard
                    }
                }
                .padding()
                .frame(maxWidth: 640)
            }
            .navigationTitle("Cuộc gọi VoIP 1-1")
        }
    }

    private var callStatusCard: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(vm.isInCall ? Color.green.opacity(0.18) : Color.blue.opacity(0.14))
                    .frame(width: 92, height: 92)
                Image(systemName: vm.isCallVideo ? "video.fill" : "phone.connection.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(vm.isInCall ? .green : .blue)
            }
            Text(vm.callStatusText)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            if let callId = vm.activeCallId {
                Text("Call ID: #\(callId) • Partner UID: \(String(vm.activeCallPartnerUid))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text("Opus 16kHz / H.264 Annex-B • ZRTP RFC 6189 DH3k + SAS • SRTP AES-128-CTR + HMAC-SHA1-80")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func incomingCallBanner(_ invite: BMSZaloViewModel.IncomingCallInfo) -> some View {
        GroupBox {
            VStack(spacing: 12) {
                Text("Cuộc gọi \(invite.isVideo ? "Video" : "Thoại") đang đổ chuông từ \(invite.callerName) (UID: \(String(invite.callerUid)))")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                HStack(spacing: 20) {
                    Button {
                        Task { await vm.answerIncomingCall() }
                    } label: {
                        Label("Trả lời", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(role: .destructive) {
                        Task { await vm.rejectIncomingCall() }
                    } label: {
                        Label("Từ chối", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Cuộc gọi đến (UXChatSocket 0x7d0)", systemImage: "bell.and.waves.left.and.right.fill")
                .foregroundStyle(.green)
        }
    }

    private var activeCallControls: some View {
        GroupBox {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Button {
                        vm.toggleMicrophoneMute()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: vm.isMicMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.title2)
                            Text(vm.isMicMuted ? "Bật Mic" : "Tắt Mic")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(vm.isMicMuted ? .red : .primary)

                    Button {
                        vm.toggleSpeakerPhone()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: vm.isSpeakerPhoneOn ? "speaker.wave.3.fill" : "speaker.fill")
                                .font(.title2)
                            Text(vm.isSpeakerPhoneOn ? "Loa ngoài" : "Loa trong")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await vm.toggleLocalCamera() }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: vm.isLocalCameraOn ? "video.fill" : "video.slash.fill")
                                .font(.title2)
                            Text(vm.isLocalCameraOn ? "Tắt Cam" : "Bật Cam")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.flipCamera()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .font(.title2)
                            Text("Đổi Cam")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    Task { await vm.endOrCancelActiveCall() }
                } label: {
                    Label("Kết thúc Cuộc gọi", systemImage: "phone.down.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        } label: {
            Label("Điều khiển Cuộc gọi Đang diễn ra", systemImage: "waveform.circle.fill")
        }
    }

    private var dialerCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Nhập UID người nhận cuộc gọi...", text: $targetUidInput)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 14) {
                    Button {
                        if let uid = Int64(targetUidInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Task { await vm.startOutgoingCall(calleeUid: uid, isVideo: false) }
                        }
                    } label: {
                        Label("Gọi Thoại (Opus)", systemImage: "phone.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Int64(targetUidInput.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)

                    Button {
                        if let uid = Int64(targetUidInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Task { await vm.startOutgoingCall(calleeUid: uid, isVideo: true) }
                        }
                    } label: {
                        Label("Gọi Video (H.264)", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(Int64(targetUidInput.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                }

                if !vm.friends.isEmpty {
                    Divider()
                    Text("Chọn nhanh từ Danh bạ:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ForEach(vm.friends.prefix(10)) { friend in
                        HStack {
                            Text(friend.displayName)
                                .font(.subheadline)
                            Spacer()
                            Button {
                                Task { await vm.startOutgoingCall(calleeUid: friend.uid, isVideo: false) }
                            } label: {
                                Image(systemName: "phone.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                Task { await vm.startOutgoingCall(calleeUid: friend.uid, isVideo: true) }
                            } label: {
                                Image(systemName: "video.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Quay số Gọi 1-1 (ZolaVoipMediaEngine)", systemImage: "phone.arrow.up.right.fill")
        }
    }
}
