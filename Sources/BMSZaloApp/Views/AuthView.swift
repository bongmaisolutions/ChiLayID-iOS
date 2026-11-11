import SwiftUI
import ZolaKit

public struct AuthView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var phone: String = ""
    @State private var password: String = ""
    @State private var deliveryMethod: ZolaVerificationMethod = .callOrSms
    @State private var otpCode: String = ""
    @State private var sessionJsonInput: String = ""

    @State private var customModel: String = ""
    @State private var customOSVersion: String = "18.2"
    @State private var customDeviceName: String = ""
    @State private var customHardwareModel: String = ""
    @State private var showIdentityEditor: Bool = false

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner

                    if let error = vm.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                                .font(.footnote)
                            Spacer()
                            Button("Đóng") { vm.errorMessage = nil }
                                .font(.caption.bold())
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.14))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if let status = vm.statusBanner {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                            Text(status)
                                .font(.footnote)
                            Spacer()
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // 1. Saved Keychain Sessions
                    if !vm.savedKeychainAccounts.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                               ForEach(vm.savedKeychainAccounts, id: \.self) { account in
                                    HStack {
                                        Image(systemName: "key.fill")
                                            .foregroundStyle(.blue)
                                        Text("UID: \(account)")
                                            .font(.subheadline.monospaced())
                                        Spacer()
                                        Button("Khôi phục") {
                                            Task { await vm.loadSessionFromKeychain(account: account) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)

                                        Button(role: .destructive) {
                                            vm.deleteSessionFromKeychain(account: account)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    Divider()
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("Phiên đã lưu trong Keychain (ZolaKeychainSessionStore)", systemImage: "lock.shield.fill")
                                .font(.headline)
                        }
                    }

                    // 2. Native Phone + Password Login
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Số điện thoại (VD: 0912345678 hoặc +84...)", text: $phone)
                                .textFieldStyle(.roundedBorder)

                            SecureField("Mật khẩu Zalo", text: $password)
                                .textFieldStyle(.roundedBorder)

                            Picker("Phương thức nhận mã xác thực", selection: $deliveryMethod) {
                                Text("Cuộc gọi / SMS").tag(ZolaVerificationMethod.callOrSms)
                                Text("Thiết bị gần đây").tag(ZolaVerificationMethod.recentDevice)
                            }
                            .pickerStyle(.segmented)

                            Button {
                                Task {
                                    await vm.loginWithPhonePassword(
                                        phone: phone,
                                        password: password,
                                        deliveryMethod: deliveryMethod
                                    )
                                }
                            } label: {
                                HStack {
                                    if vm.isBusy {
                                        ProgressView()
                                            .padding(.trailing, 6)
                                    }
                                    Text("Đăng nhập Native iOS (AuthenV3Aes / ZCID)")
                                        .bold()
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.isBusy)

                            if vm.pendingChallenge != nil {
                                Divider()
                                Text("Nhập mã xác thực OTP / Thiết bị gần đây:")
                                    .font(.subheadline.bold())
                                HStack {
                                    TextField("Mã OTP 6 số", text: $otpCode)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Xác nhận OTP") {
                                        Task { await vm.submitVerificationCode(otpCode) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }

                            if let secureURL = vm.pendingSecureCheckURL {
                                Divider()
                                Link(destination: secureURL) {
                                    Label("Mở trang xác minh bảo mật Zalo", systemImage: "safari.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Đăng nhập SĐT + Mật khẩu (ZolaLoginClient)", systemImage: "person.badge.key.fill")
                            .font(.headline)
                    }

                    // 3. Import Session JSON (ZolaFileSessionStore)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dán nội dung tệp `session-<uid>.local.json` (tương thích 100% ZolaSession):")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $sessionJsonInput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 110)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )

                            Button {
                                Task { await vm.importSessionFromJSONString(sessionJsonInput) }
                            } label: {
                                Label("Nạp Phiên từ Chuỗi JSON", systemImage: "square.and.arrow.down.on.square.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(sessionJsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(.top, 6)
                    } label: {
                        Label("Khôi phục Phiên từ JSON (ZolaFileSessionStore)", systemImage: "doc.badge.gearshape.fill")
                            .font(.headline)
                    }

                    // 4. Device Identity Inspector (ZolaDeviceIdentity)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Thiết bị", value: "\(vm.currentDeviceIdentity.deviceName) (\(vm.currentDeviceIdentity.model))")
                            LabeledContent("Độ phân giải", value: "\(vm.currentDeviceIdentity.width)×\(vm.currentDeviceIdentity.height) @\(vm.currentDeviceIdentity.scale)x")
                            LabeledContent("Hardware Model", value: vm.currentDeviceIdentity.hardwareModel)
                            LabeledContent("ZCID", value: vm.currentDeviceIdentity.zcid)
                                .font(.caption.monospaced())
                            LabeledContent("IDFA", value: vm.currentDeviceIdentity.idfa)
                                .font(.caption.monospaced())

                            HStack {
                                Button("Tạo mới Identity") {
                                    vm.resetDeviceIdentity()
                                }
                                .buttonStyle(.bordered)

                                Button("Tùy chỉnh Thiết bị") {
                                    customModel = vm.currentDeviceIdentity.model
                                    customDeviceName = vm.currentDeviceIdentity.deviceName
                                    customHardwareModel = vm.currentDeviceIdentity.hardwareModel
                                    showIdentityEditor = true
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                        }
                        .font(.subheadline)
                        .padding(.top, 6)
                    } label: {
                        Label("Định danh Thiết bị iOS 261002 (ZolaDeviceIdentity)", systemImage: "iphone.gen3")
                            .font(.headline)
                    }
                }
                .padding()
                .frame(maxWidth: 680)
            }
            .navigationTitle("BMSZalo • Xác thực")
            .sheet(isPresented: $showIdentityEditor) {
                NavigationStack {
                    Form {
                        Section("Thông số phần cứng iOS giả lập") {
                            TextField("Model (VD: iPhone)", text: $customModel)
                            TextField("Phiên bản iOS (VD: 18.2)", text: $customOSVersion)
                            TextField("Tên thiết bị (Device Name)", text: $customDeviceName)
                            TextField("Mã phần cứng (VD: iPhone16,2)", text: $customHardwareModel)
                            LabeledContent("Device ID", value: vm.currentDeviceIdentity.deviceIdentifier)
                                .font(.caption)
                            LabeledContent("Vendor ID", value: vm.currentDeviceIdentity.vendorId)
                                .font(.caption)
                        }
                    }
                    .navigationTitle("Cấu hình Thiết bị")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Hủy") { showIdentityEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Lưu") {
                                vm.updateCustomDeviceIdentity(
                                    model: customModel,
                                    osVersion: customOSVersion,
                                    deviceName: customDeviceName,
                                    hardwareModel: customHardwareModel
                                )
                                showIdentityEditor = false
                            }
                        }
                    }
                }
            }
        }
    }

    private var headerBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 46))
                .foregroundStyle(.blue.gradient)
            Text("BMSZalo Native Suite")
                .font(.title.bold())
            Text("Giao thức Zalo iOS Native 261002802 • 100% Tự chủ • Không phụ thuộc bên thứ ba")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }
}
