import Foundation
import ZolaKit

/// Cross-platform JSON RPC Bridge allowing Web (`WKWebView` / Browser WebSocket) and Android / Desktop hosts
/// to drive every `BMSZaloViewModel` and `ZolaClient` capability with a unified JSON command envelope.
@MainActor
public final class BMSZaloBridgeController {
    public let viewModel: BMSZaloViewModel

    public struct BridgeRequest: Codable, Sendable {
        public let requestId: String?
        public let action: String
        public let params: [String: String]?

        public init(requestId: String? = nil, action: String, params: [String: String]? = nil) {
            self.requestId = requestId
            self.action = action
            self.params = params
        }
    }

    public struct BridgeResponse: Codable, Sendable {
        public let requestId: String?
        public let ok: Bool
        public let action: String
        public let message: String
        public let payloadJSON: String?

        public init(
            requestId: String? = nil,
            ok: Bool,
            action: String,
            message: String,
            payloadJSON: String? = nil
        ) {
            self.requestId = requestId
            self.ok = ok
            self.action = action
            self.message = message
            self.payloadJSON = payloadJSON
        }
    }

    public init(viewModel: BMSZaloViewModel) {
        self.viewModel = viewModel
    }

    /// Evaluates a JSON-encoded `BridgeRequest` and returns a JSON-encoded `BridgeResponse`.
    public func handleJSONCommand(_ rawJSON: String) async -> String {
        guard let data = rawJSON.data(using: .utf8),
              let req = try? JSONDecoder().decode(BridgeRequest.self, from: data) else {
            return encodeResponse(BridgeResponse(
                ok: false,
                action: "invalid",
                message: "Malformed BridgeRequest JSON"
            ))
        }

        let p = req.params ?? [:]
        let vm = self.viewModel

        switch req.action {
        case "getStateSnapshot":
            let snap: [String: Any] = [
                "isAuthenticated": vm.isAuthenticated,
                "ownUid": String(vm.ownUid),
                "isDryRun": vm.isDryRun,
                "isGroupSendEnabled": vm.isGroupSendEnabled,
                "conversationsCount": vm.conversations.count,
                "friendsCount": vm.friends.count,
                "groupsCount": vm.groups.count,
                "timelinePostsCount": vm.timelinePosts.count,
                "isInCall": vm.isInCall,
                "callStatusText": vm.callStatusText
            ]
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Snapshot ready",
                payloadJSON: toJSONString(snap)
            ))

        case "loginPhonePassword":
            let phone = p["phone"] ?? ""
            let password = p["password"] ?? ""
            let method: ZolaVerificationMethod = (p["deliveryMethod"] == "recentDevice") ? .recentDevice : .callOrSms
            await vm.loginWithPhonePassword(phone: phone, password: password, deliveryMethod: method)
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: vm.errorMessage == nil,
                action: req.action,
                message: vm.statusBanner ?? vm.errorMessage ?? "Completed"
            ))

        case "submitOTP":
            let code = p["code"] ?? ""
            await vm.submitVerificationCode(code)
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: vm.errorMessage == nil,
                action: req.action,
                message: vm.statusBanner ?? vm.errorMessage ?? "Completed"
            ))

        case "importSessionJSON":
            let json = p["sessionJSON"] ?? ""
            await vm.importSessionFromJSONString(json)
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: vm.isAuthenticated,
                action: req.action,
                message: vm.statusBanner ?? vm.errorMessage ?? "Imported"
            ))

        case "setSafetyToggles":
            if let dryStr = p["isDryRun"] {
                vm.isDryRun = (dryStr == "true" || dryStr == "1")
            }
            if let grpStr = p["isGroupSendEnabled"] {
                vm.isGroupSendEnabled = (grpStr == "true" || grpStr == "1")
            }
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Updated safety toggles (dryRun=\(vm.isDryRun), groupSend=\(vm.isGroupSendEnabled))"
            ))

        case "syncInbox":
            await vm.syncInboxNow(discoverGroups: true)
            let convs = vm.conversations.map { c in
                [
                    "threadId": String(c.threadId),
                    "title": c.title,
                    "isGroup": c.isGroup,
                    "unreadCount": c.unreadCount,
                    "lastPreview": c.lastMessage?.previewText ?? ""
                ] as [String: Any]
            }
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Synced \(convs.count) conversations",
                payloadJSON: toJSONString(convs)
            ))

        case "sendMessage":
            if let tidStr = p["threadId"],
               let tid = Int64(tidStr),
               let conv = vm.conversations.first(where: { $0.threadId == tid }) {
                vm.selectConversation(conv)
            }
            let text = p["text"] ?? ""
            await vm.sendTextMessage(text: text)
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: vm.errorMessage == nil,
                action: req.action,
                message: vm.statusBanner ?? vm.errorMessage ?? "Sent"
            ))

        case "getFriends":
            await vm.refreshContactsData()
            let list = vm.friends.map { u in
                ["uid": String(u.uid), "displayName": u.displayName, "phone": u.phone]
            }
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Loaded \(list.count) friends",
                payloadJSON: toJSONString(list)
            ))

        case "getGroups":
            await vm.refreshGroups()
            let list = vm.groups.map { g in
                ["gid": String(g.gid), "name": g.name, "totalMembers": g.totalMembers] as [String: Any]
            }
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Loaded \(list.count) groups",
                payloadJSON: toJSONString(list)
            ))

        case "loadTimeline":
            await vm.loadTimelineAndStories(resetCursor: true)
            let posts = vm.timelinePosts.map { post in
                [
                    "id": String(post.id),
                    "authorName": post.authorName,
                    "caption": post.caption,
                    "likeCount": post.likeCount,
                    "commentCount": post.commentCount
                ] as [String: Any]
            }
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Loaded \(posts.count) timeline posts",
                payloadJSON: toJSONString(posts)
            ))

        case "startVoipCall":
            let calleeUid = Int64(p["calleeUid"] ?? "") ?? 0
            let isVideo = (p["isVideo"] == "true" || p["isVideo"] == "1")
            await vm.startOutgoingCall(calleeUid: calleeUid, isVideo: isVideo)
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: vm.errorMessage == nil,
                action: req.action,
                message: vm.callStatusText
            ))

        case "endVoipCall":
            await vm.endOrCancelActiveCall()
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: true,
                action: req.action,
                message: "Ended call"
            ))

        default:
            return encodeResponse(BridgeResponse(
                requestId: req.requestId,
                ok: false,
                action: req.action,
                message: "Unknown action: \(req.action)"
            ))
        }
    }

    private func encodeResponse(_ response: BridgeResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"action":"error","message":"Encoding error"}"#
        }
        return str
    }

    private func toJSONString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
