import Foundation
import CoreFoundation

/// Read-only poll data from native 261002. Schema is verified statically against
/// PollEntity (0x100d85ffc/0x100d869f4), PollItem (0x100d88a38), and
/// UserVoteProfile (0x100d885e0). Fixtures are synthetic, not captured server traffic.
public struct ZolaGroupPollDetail: Codable, Equatable, Sendable {
    public struct Voter: Codable, Equatable, Sendable {
        public let uid: Int64
        public let name: String
    }
    public struct Answer: Codable, Equatable, Sendable {
        public let id: String
        public let content: String
        public let votes: Int?
        public let checked: Bool?
        public let voterUids: [Int64]
        public let voters: [Voter]
    }
    public let pollId: String
    public let groupId: Int64
    public let version: Int64?
    public let question: String
    public var answers: [Answer]
    public let totalVotes: Int?
    public let anonymous: Bool?
    public let hideVotePreview: Bool?
    public let multiChoice: Bool?
    public let state: Int?
    public let creatorUid: Int64?
    public let creatorName: String?
    public var hasVoterDetails: Bool

    public var mayShowVoters: Bool { anonymous == false && hideVotePreview == false }

    public func applying(to card: ZolaBoardCard) -> ZolaBoardCard {
        var result = card
        if !question.isEmpty { result.title = question }
        result.options = answers.map { ZolaPollOption(label: $0.content, votes: $0.votes, votedBySelf: $0.checked) }
        result.totalVotes = totalVotes
        result.isAnonymous = anonymous
        result.allowMultiChoice = multiChoice
        if let state { result.isClosed = state == 2 }
        result.creatorUid = creatorUid ?? card.creatorUid
        result.creatorName = creatorName ?? card.creatorName
        return result
    }
}

public enum ZolaGroupPollWire {
    public enum Read: Int16, Sendable { case detail = 1641, answers = 1646 }

    /// GroupPollRequestManager 0x1055e6d3c / 0x1055e6fa8 → 0x1055e77a8:
    /// append the signed 64-bit poll ID in native little-endian order, no prefix.
    /// UXSocketStreamManager 0x103b37304: sourceType=3, messageType=1, subCmd=0.
    public static func requestFrame(pollId: String, read: Read, srcId: Int32, seqId: Int32) throws -> ZolaChatElementFrame {
        guard let id = positiveID(pollId), srcId > 0 else {
            throw ZolaError.invalidArgument("Mã bình chọn hoặc tài khoản không hợp lệ")
        }
        var data = Data()
        data.appendInt64LE(id)
        return ZolaCrypto.packChatElementFrame(bodyData: data, srcId: srcId, srcType: 3,
            msgType: 1, cmd: read.rawValue, subCmd: 0, seqId: seqId)
    }

    /// Input is the `data` dictionary after the shared native response/circuit breaker.
    /// Native detail callback 0x1009b9074 reads data.poll, unlike 1646's data.answers.
    public static func detail(from data: [String: Any], expectedPollId: String, groupId: Int64) throws -> ZolaGroupPollDetail {
        guard let poll = data["poll"] as? [String: Any],
              let id = positiveID(poll["id"]), id == positiveID(expectedPollId),
              positiveID(poll["groupId"]) == groupId, groupId > 0 else {
            throw ZolaError.transport("Chi tiết bình chọn không khớp hội thoại")
        }
        let anonymous = flag(poll["isAnonymous"])
        let hidden = flag(poll["isHideVotePreview"])
        return ZolaGroupPollDetail(pollId: String(id), groupId: groupId,
            version: integer(poll["verId"]), question: text(poll["question"]),
            answers: parseAnswers(poll["answers"], showVoters: anonymous == false && hidden == false),
            totalVotes: count(poll["numVote"]), anonymous: anonymous, hideVotePreview: hidden,
            multiChoice: flag(poll["isMultiChoice"]), state: count(poll["state"]),
            creatorUid: positiveID(poll["createUid"]), creatorName: nonemptyText(poll["creatorName"]),
            hasVoterDetails: false)
    }

    public static func applyingAnswers(_ data: [String: Any], to detail: ZolaGroupPollDetail) throws -> ZolaGroupPollDetail {
        // Only the verified data.poll envelope proves poll+group identity.1646's
        // answers-only response cannot be correlated by cmd after a timeout.
        var verified = try self.detail(from: data, expectedPollId: detail.pollId, groupId: detail.groupId)
        verified.hasVoterDetails = false
        return verified
    }

    private static func parseAnswers(_ value: Any?, showVoters: Bool) -> [ZolaGroupPollDetail.Answer] {
        guard let values = value as? [Any], values.count <= 1000 else { return [] }
        return values.compactMap { value in
            guard let item = value as? [String: Any], let id = integer(item["id"]), id >= 0,
                  let content = nonemptyText(item["content"]) else { return nil }
            let rawVoters = showVoters ? (item["usersVote"] as? [Any] ?? []) : []
            let rawProfiles = showVoters ? (item["usersVoteProfile"] as? [[String: Any]] ?? []) : []
            var seen = Set<Int64>()
            let voters = rawProfiles.prefix(1000).compactMap { profile -> ZolaGroupPollDetail.Voter? in
                guard let uid = positiveID(profile["uid"]), seen.insert(uid).inserted else { return nil }
                return .init(uid: uid, name: text(profile["dpn"]))
            }
            return .init(id: String(id), content: content, votes: count(item["numVote"]),
                checked: flag(item["isChecked"]), voterUids: Array(Set(rawVoters.prefix(1000).compactMap(positiveID))).sorted(), voters: voters)
        }
    }
    static func integer(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return Int64(n.stringValue)
        }
        if let s = value as? String { return Int64(s) }
        return nil
    }
    static func positiveID(_ value: Any?) -> Int64? { integer(value).flatMap { $0 > 0 ? $0 : nil } }
    private static func count(_ value: Any?) -> Int? { integer(value).flatMap { $0 >= 0 ? Int(exactly: $0) : nil } }
    private static func flag(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let s = value as? String, let n = Int(s) { return n != 0 }
        return nil
    }
    private static func text(_ value: Any?) -> String { String((value as? String ?? "").prefix(16_384)) }
    private static func nonemptyText(_ value: Any?) -> String? { let s = text(value); return s.isEmpty ? nil : s }
}

/// One queue per ZolaClient: sendAndWait matches command IDs, so concurrent reads
/// for different polls do not overlap. This is NOT proof of response identity:
/// timed-out replies can arrive later, so every accepted response also needs IDs.
actor ZolaGroupPollReadQueue {
    private var tail: Task<Void, Never>?
    func run(_ work: @escaping @Sendable () async throws -> ZolaGroupPollDetail) async throws -> ZolaGroupPollDetail {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); return try await work() }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// Account-scoped, bounded disk cache. The caller owns the file location; the
/// account ID in the envelope prevents a wrong-account file from being reused.
public actor ZolaGroupPollCache {
    private struct Entry: Codable { let detail: ZolaGroupPollDetail; let savedAt: Date }
    private struct Envelope: Codable { let formatVersion: Int; let accountUid: Int64; let entries: [String: Entry] }
    private let accountUid: Int64
    private let fileURL: URL
    private var entries: [String: Entry] = [:]
    private var loaded = false
    public init(accountUid: Int64, fileURL: URL) { self.accountUid = accountUid; self.fileURL = fileURL }
    public func value(pollId: String, groupId: Int64, maxAge: TimeInterval = 60, now: Date = Date()) -> ZolaGroupPollDetail? {
        loadIfNeeded()
        guard let entry = entries["\(groupId):\(pollId)"], now.timeIntervalSince(entry.savedAt) >= 0,
              now.timeIntervalSince(entry.savedAt) <= maxAge else { return nil }
        return entry.detail
    }
    public func store(_ detail: ZolaGroupPollDetail, now: Date = Date()) throws {
        loadIfNeeded()
        let key = "\(detail.groupId):\(detail.pollId)"
        if let old = entries[key], let oldVersion = old.detail.version, let version = detail.version, oldVersion > version { return }
        entries[key] = Entry(detail: detail, savedAt: now)
        if entries.count > 100, let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key { entries.removeValue(forKey: oldest) }
        let data = try JSONEncoder().encode(Envelope(formatVersion: 2, accountUid: accountUid, entries: entries))
        guard data.count <= 4 * 1024 * 1024 else { entries.removeValue(forKey: key); return }
        try ZolaFileSessionStore.writeData0600(data, to: fileURL)
    }
    private func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: fileURL), let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.formatVersion == 2, envelope.accountUid == accountUid, envelope.entries.count <= 100 else { return }
        entries = envelope.entries
    }
}
