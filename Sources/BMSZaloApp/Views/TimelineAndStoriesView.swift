import SwiftUI
import UniformTypeIdentifiers
import ZolaKit

public struct TimelineAndStoriesView: View {
    @ObservedObject var vm: BMSZaloViewModel

    @State private var showComposeSheet: Bool = false
    @State private var selectedStoryUser: ZolaStoryUser?
    @State private var activePostForComments: ZolaFeedPost?

    public init(vm: BMSZaloViewModel) {
        self.vm = vm
    }

    public var body: some View {
        NavigationStack {
            List {
                // 1. Story Bar ("Khoảnh khắc" cmd 1340/1341)
                Section("Khoảnh khắc (Stories • cmd 1340/1341)") {
                    if vm.storyUsers.isEmpty {
                        Text("Nhấn Làm mới để tải Khoảnh khắc từ bạn bè.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(vm.storyUsers) { sUser in
                                    Button {
                                        selectedStoryUser = sUser
                                        Task { await vm.loadStoriesForUser(sUser) }
                                    } label: {
                                        VStack(spacing: 6) {
                                            Circle()
                                                .strokeBorder(
                                                    sUser.hasUnseen ? Color.blue : Color.secondary.opacity(0.4),
                                                    lineWidth: 2.5
                                                )
                                                .frame(width: 58, height: 58)
                                                .overlay(
                                                    Text(String(sUser.name.prefix(1)).uppercased())
                                                        .font(.title3.bold())
                                                )
                                            Text(sUser.name)
                                                .font(.caption2)
                                                .lineLimit(1)
                                                .frame(width: 66)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                // 2. Timeline Posts ("Nhật ký" cmd 1230/1233/1796/296/191/190)
                Section("Nhật ký (Timeline Feed • \(vm.timelinePosts.count) bài viết)") {
                    if vm.timelinePosts.isEmpty {
                        Text("Chưa có bài viết nào được tải. Nhấn Làm mới ở góc phải để đồng bộ Nhật ký.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.timelinePosts) { post in
                            TimelinePostRow(
                                post: post,
                                onLike: {
                                    Task { await vm.toggleLikePost(post) }
                                },
                                onComment: {
                                    activePostForComments = post
                                    Task { await vm.loadCommentsForPost(post) }
                                },
                                onDelete: {
                                    Task { await vm.deletePost(post) }
                                }
                            )
                        }

                        if vm.timelineHasMore {
                            Button("Tải thêm bài viết cũ hơn...") {
                                Task { await vm.loadTimelineAndStories(resetCursor: false) }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle("Nhật ký & Khoảnh khắc")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showComposeSheet = true
                    } label: {
                        Label("Đăng bài", systemImage: "square.and.pencil")
                    }
                    Button {
                        Task { await vm.loadTimelineAndStories(resetCursor: true) }
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showComposeSheet) {
                TimelineComposerSheet(vm: vm)
            }
            .sheet(item: $selectedStoryUser) { storyUser in
                StoryViewerSheet(vm: vm, storyUser: storyUser)
            }
            .sheet(item: $activePostForComments) { post in
                FeedCommentsSheet(vm: vm, post: post)
            }
        }
    }
}

private struct TimelinePostRow: View {
    let post: ZolaFeedPost
    let onLike: () -> Void
    let onComment: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(Color.blue.opacity(0.16))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Text(String(post.authorName.prefix(1)).uppercased())
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.authorName)
                        .font(.subheadline.bold())
                    Text("Feed ID: \(String(post.id))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if !post.caption.isEmpty {
                Text(post.caption)
                    .font(.body)
            }

            if !post.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(post.photos) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.14))
                                    .frame(width: 140, height: 100)
                                    .overlay(
                                        Image(systemName: "photo.fill")
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                    )
                                Text(photo.url)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 140)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 20) {
                Button(action: onLike) {
                    Label(
                        "\(post.likeCount) Thích",
                        systemImage: post.isLiked ? "heart.fill" : "heart"
                    )
                    .foregroundStyle(post.isLiked ? .red : .primary)
                }
                .buttonStyle(.borderless)

                Button(action: onComment) {
                    Label("\(post.commentCount) Bình luận", systemImage: "bubble.right")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption.bold())
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}

private struct TimelineComposerSheet: View {
    @ObservedObject var vm: BMSZaloViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var caption: String = ""
    @State private var privacy: ZolaFeedPrivacy = .friends
    @State private var selectedPhotoURL: URL?
    @State private var showPhotoPicker: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Nội dung Bài viết") {
                    TextEditor(text: $caption)
                        .frame(height: 120)
                }

                Section("Quyền riêng tư (ZolaFeedPrivacy)") {
                    Picker("Ai có thể xem", selection: $privacy) {
                        Text("Tất cả bạn bè (.friends)").tag(ZolaFeedPrivacy.friends)
                        Text("Chỉ mình tôi (.onlyMe)").tag(ZolaFeedPrivacy.onlyMe)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Đính kèm Ảnh (cmd 166/3 -> 1796/1)") {
                    if let photoURL = selectedPhotoURL {
                        HStack {
                            Image(systemName: "photo.fill")
                                .foregroundStyle(.blue)
                            Text(photoURL.lastPathComponent)
                            Spacer()
                            Button("Bỏ chọn", role: .destructive) {
                                selectedPhotoURL = nil
                            }
                        }
                    }
                    Button("Chọn ảnh JPEG/PNG...") {
                        showPhotoPicker = true
                    }
                }
            }
            .navigationTitle("Đăng Nhật ký")
            .fileImporter(
                isPresented: $showPhotoPicker,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result {
                    selectedPhotoURL = urls.first
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đăng") {
                        Task {
                            await vm.publishTimelinePost(
                                caption: caption,
                                privacy: privacy,
                                photoURL: selectedPhotoURL
                            )
                            dismiss()
                        }
                    }
                    .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedPhotoURL == nil)
                }
            }
        }
    }
}

private struct StoryViewerSheet: View {
    @ObservedObject var vm: BMSZaloViewModel
    let storyUser: ZolaStoryUser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.activeStoryItems.isEmpty {
                    Text("Đang tải hoặc chưa có Khoảnh khắc nào.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.activeStoryItems) { story in
                        let kindLabel = story.isVideo ? "Video" : (story.isText ? "Văn bản" : "Ảnh")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Story #\(String(story.id)) • Loại: \(kindLabel)")
                                .font(.headline)
                            if !story.caption.isEmpty {
                                Text(story.caption)
                                    .font(.body)
                            }
                            if !story.mediaUrl.isEmpty {
                                Text(story.mediaUrl)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.blue)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Khoảnh khắc • \(storyUser.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}

private struct FeedCommentsSheet: View {
    @ObservedObject var vm: BMSZaloViewModel
    let post: ZolaFeedPost
    @Environment(\.dismiss) private var dismiss

    @State private var commentInput: String = ""

    var body: some View {
        NavigationStack {
            VStack {
                List {
                    let comments = vm.feedCommentsByPostId[post.id] ?? []
                    if comments.isEmpty {
                        Text("Chưa có bình luận nào.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(comments) { cmt in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cmt.authorName)
                                    .font(.subheadline.bold())
                                Text(cmt.text)
                                    .font(.body)
                            }
                        }
                    }
                }

                HStack {
                    TextField("Viết bình luận...", text: $commentInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Gửi") {
                        let text = commentInput
                        commentInput = ""
                        Task { await vm.commentOnPost(post, text: text) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(commentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Bình luận (#\(String(post.id)))")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
    }
}
