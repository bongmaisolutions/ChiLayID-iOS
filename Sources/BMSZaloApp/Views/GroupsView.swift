import SwiftUI
import ZolaKit

public struct GroupsView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var showCreateSheet: Bool = false
    @State private var showDetailSheet: Bool = false
    @State private var newGroupName: String = ""
    @State private var newGroupMemberUidsText: String = ""
    @State private var renameText: String = ""
    @State private var addMemberUidsText: String = ""

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Danh sách Nhóm đã tham gia (\(vm.groups.count))") {
                    if vm.groups.isEmpty {
                        Text("Chưa có nhóm nào được đồng bộ.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.groups) { grp in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.indigo.opacity(0.18))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "person.3.fill")
                                            .foregroundStyle(.indigo)
                                    )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(grp.name)
                                        .font(.headline)
                                    Text("GID: \(String(grp.gid)) • \(grp.totalMembers) thành viên")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Quản lý") {
                                    renameText = grp.name
                                    Task {
                                        await vm.inspectGroupDetail(groupId: grp.gid)
                                        showDetailSheet = true
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("Quản lý Nhóm")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Tạo nhóm mới", systemImage: "plus.circle.fill")
                    }
                    Button {
                        Task { await vm.refreshGroups() }
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                createGroupSheet
            }
            .sheet(isPresented: $showDetailSheet) {
                groupDetailSheet
            }
        }
    }

    private var createGroupSheet: some View {
        NavigationStack {
            Form {
                Section("Thông tin Nhóm Mới") {
                    TextField("Tên nhóm", text: $newGroupName)
                    TextField("Danh sách UID thành viên (cách nhau bằng dấu phẩy)", text: $newGroupMemberUidsText)
                }
            }
            .navigationTitle("Tạo Nhóm Zalo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { showCreateSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo nhóm") {
                        let uids = newGroupMemberUidsText
                            .split(separator: ",")
                            .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        Task {
                            await vm.createNewGroup(name: newGroupName, memberIds: uids)
                            showCreateSheet = false
                        }
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var groupDetailSheet: some View {
        NavigationStack {
            if let grp = vm.selectedGroupDetail {
                Form {
                    Section("Thông tin Chung") {
                        LabeledContent("Group ID", value: String(grp.gid))
                        LabeledContent("Người tạo (Creator UID)", value: String(grp.creatorId))
                        LabeledContent("Tổng thành viên", value: "\(grp.totalMembers)")
                        if !grp.desc.isEmpty {
                            LabeledContent("Mô tả", value: grp.desc)
                        }
                    }

                    Section("Đổi tên Nhóm") {
                        TextField("Tên nhóm mới", text: $renameText)
                        Button("Cập nhật tên nhóm") {
                            Task { await vm.renameGroup(groupId: grp.gid, newName: renameText) }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Section("Thêm Thành viên") {
                        TextField("Nhập UID (cách nhau dấu phẩy)", text: $addMemberUidsText)
                        Button("Thêm vào nhóm") {
                            let uids = addMemberUidsText
                                .split(separator: ",")
                                .compactMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            Task {
                                await vm.addMembersToGroup(groupId: grp.gid, memberIds: uids)
                                addMemberUidsText = ""
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Section("Link Tham gia Nhóm") {
                        if let link = vm.selectedGroupLinkDetail, !link.isEmpty {
                            Text(link)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("Bật Link Nhóm") {
                                Task { await vm.toggleGroupInviteLink(groupId: grp.gid, enable: true) }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Tắt Link Nhóm", role: .destructive) {
                                Task { await vm.toggleGroupInviteLink(groupId: grp.gid, enable: false) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Section("Danh sách Thành viên (\(grp.members.count))") {
                        ForEach(grp.members) { mem in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mem.displayName)
                                        .font(.subheadline.bold())
                                    Text("UID: \(String(mem.uid))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if grp.adminIds.contains(mem.uid) {
                                    Text("Quản trị viên")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                                Button(role: .destructive) {
                                    Task { await vm.removeMembersFromGroup(groupId: grp.gid, memberIds: [mem.uid]) }
                                } label: {
                                    Image(systemName: "person.badge.minus")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .navigationTitle(grp.name)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Đóng") { showDetailSheet = false }
                    }
                }
            } else {
                ProgressView("Đang tải chi tiết nhóm...")
            }
        }
    }
}
