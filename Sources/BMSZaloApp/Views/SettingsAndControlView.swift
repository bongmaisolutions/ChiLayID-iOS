import SwiftUI
import ZolaKit

public struct SettingsAndControlView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var newTagTitle: String = ""
    @State private var newTagColor: String = "#0068FF"
    @State private var customEndpointURL: String = "https://talk-m.zaloapp.com/api/social/profile/getmute"
    @State private var customMethod: String = "GET"
    @State private var customParamsJSON: String = "{}"
    @State private var exportedSessionJSON: String = ""

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            Form {
                // 1. Safety & Protocol Control
                Section("Chế độ An toàn Giao thức (Protocol Safety Gates)") {
                    Toggle("Chế độ Thử nghiệm (dryRun — không phát mạng thật)", isOn: $vm.isDryRun)
                    Toggle("Cho phép gửi tin nhắn vào Nhóm (groupSendEnabled)", isOn: $vm.isGroupSendEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chu kỳ đồng bộ sự kiện: \(Int(vm.eventPollIntervalSeconds)) giây")
                            .font(.subheadline)
                        Slider(value: $vm.eventPollIntervalSeconds, in: 1...10, step: 1)
                    }
                }

                // 2. Account & Session Info
                if let session = vm.activeSession {
                    Section("Thông tin Phiên Hiện tại (ZolaSession)") {
                        LabeledContent("UID", value: String(session.uid))
                        if let profile = vm.activeAccountProfile {
                            LabeledContent("Tên tài khoản", value: profile.displayName)
                        }
                        LabeledContent("ZCID", value: session.zcid)
                            .font(.caption.monospaced())
                        LabeledContent("Có khóa EncryptV2 (KeySet)", value: session.hasValidKeySet ? "Có" : "Không")

                        Button("Xuất JSON Phiên hiện tại") {
                            exportedSessionJSON = vm.exportActiveSessionJSON() ?? ""
                        }
                        if !exportedSessionJSON.isEmpty {
                            TextEditor(text: $exportedSessionJSON)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(height: 100)
                        }

                        Button("Đăng xuất Phiên hiện tại", role: .destructive) {
                            vm.logout()
                        }
                    }
                }

                // 3. Chat Tags Management
                Section("Quản lý Thẻ Phân loại Hội thoại (cmd 2140..2172)") {
                    HStack {
                        TextField("Tên thẻ mới", text: $newTagTitle)
                        TextField("Mã màu Hex", text: $newTagColor)
                            .frame(width: 95)
                        Button("Tạo thẻ") {
                            Task {
                                await vm.createChatTag(title: newTagTitle, colorHex: newTagColor)
                                newTagTitle = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newTagTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    ForEach(vm.chatTags) { tag in
                        HStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 10, height: 10)
                            Text(tag.text)
                                .font(.subheadline.bold())
                            Text("(\(tag.conversations.count) hội thoại)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await vm.deleteChatTag(tag) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                // 4. Quick Messages & Auto Replies
                Section("Tin nhắn Nhanh & Tự động Trả lời (Zalo Business)") {
                    Button("Tải Tin nhắn nhanh & Auto-Reply") {
                        Task { await vm.loadQuickMessagesAndAutoReplies() }
                    }
                    if !vm.quickMessagesSummary.isEmpty {
                        Text("Quick Messages:")
                            .font(.caption.bold())
                        Text(vm.quickMessagesSummary)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(8)
                    }
                    if !vm.autoRepliesSummary.isEmpty {
                        Text("Auto Replies:")
                            .font(.caption.bold())
                        Text(vm.autoRepliesSummary)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(8)
                    }
                }

                // 5. Custom ZCID Encrypted API Explorer
                Section("Trình Thám hiểm API Mã hóa ZCID (`api.custom`)") {
                    TextField("Endpoint URL", text: $customEndpointURL)
                        .font(.caption.monospaced())
                    Picker("HTTP Method", selection: $customMethod) {
                        Text("GET").tag("GET")
                        Text("POST").tag("POST")
                    }
                    .pickerStyle(.segmented)
                    TextField("Params JSON (VD: {\"version\":0})", text: $customParamsJSON)
                        .font(.caption.monospaced())

                    Button("Thực thi Request Mã hóa") {
                        Task {
                            await vm.executeCustomEndpoint(
                                url: customEndpointURL,
                                method: customMethod,
                                paramsJSON: customParamsJSON
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if !vm.customApiResponseJSON.isEmpty {
                        Text(vm.customApiResponseJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                // 6. Real-Time Diagnostic Logs
                Section("Nhật ký Hoạt động Giao thức (\(vm.diagnosticLogs.count))") {
                    ForEach(vm.diagnosticLogs.prefix(50)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("[\(entry.category)]")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.blue)
                                Spacer()
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Cài đặt & Điều khiển")
        }
    }
}
