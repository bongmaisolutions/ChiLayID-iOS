import Foundation
import SQLite3

private let zolaSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Vietnamese diacritic folding and text normalization shared by `ZolaMessageStore` and `ZolaStickerSuggester`.
public enum ZolaTextNormalizer {
    private static let vietnameseFoldMap: [Character: Character] = {
        var map: [Character: Character] = [:]
        let groups: [(Character, String)] = [
            ("a", "àáạảãâầấậẩẫăằắặẳẵ"),
            ("e", "èéẹẻẽêềếệểễ"),
            ("i", "ìíịỉĩ"),
            ("o", "òóọỏõôồốộổỗơờớợởỡ"),
            ("u", "ùúụủũưừứựửữ"),
            ("y", "ỳýỵỷỹ"),
            ("d", "đ"),
        ]
        for (ascii, chars) in groups {
            for ch in chars {
                map[ch] = ascii
                for up in String(ch).uppercased() {
                    map[up] = ascii
                }
            }
        }
        return map
    }()

    /// Lowercases `input`, strips Vietnamese diacritics (including `đ`/`Đ` -> `d`), and collapses whitespace.
    public static func foldVietnamese(_ input: String) -> String {
        let precomposed = input.precomposedStringWithCanonicalMapping
        var out = String()
        out.reserveCapacity(precomposed.count)
        var pendingSpace = false
        for ch in precomposed {
            if ch.isWhitespace {
                if !out.isEmpty {
                    pendingSpace = true
                }
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            if let mapped = vietnameseFoldMap[ch] {
                out.append(mapped)
            } else {
                for lowerCh in String(ch).lowercased() {
                    if let mappedLower = vietnameseFoldMap[lowerCh] {
                        out.append(mappedLower)
                    } else {
                        out.append(lowerCh)
                    }
                }
            }
        }
        return out
    }

    /// Lowercases `input` (preserving Vietnamese diacritics in NFC form) and collapses whitespace.
    public static func normalizePreservingDiacritics(_ input: String) -> String {
        let precomposed = input.precomposedStringWithCanonicalMapping.lowercased()
        let parts = precomposed.split(whereSeparator: \.isWhitespace)
        return parts.joined(separator: " ")
    }

    /// Returns `true` when `input` contains at least one accented Vietnamese letter (or `đ`/`Đ`).
    public static func hasVietnameseDiacritics(_ input: String) -> Bool {
        let preserved = normalizePreservingDiacritics(input)
        guard !preserved.isEmpty else { return false }
        return preserved != foldVietnamese(input)
    }
}

/// Persisted thread metadata row in `ZolaMessageStore` (`threads` SQLite table).
public struct ZolaStoredThreadRecord: Sendable, Equatable {
    public let accountUid: Int64
    public let threadId: Int64
    public let title: String
    public let avatarUrl: String
    public let isGroup: Bool
    public let isCloud: Bool
    public let lastTsMs: Int64
    public let unreadCount: Int
    public let memberCount: Int

    public init(
        accountUid: Int64,
        threadId: Int64,
        title: String,
        avatarUrl: String = "",
        isGroup: Bool = false,
        isCloud: Bool = false,
        lastTsMs: Int64 = 0,
        unreadCount: Int = 0,
        memberCount: Int = 0
    ) {
        self.accountUid = accountUid
        self.threadId = threadId
        self.title = title
        self.avatarUrl = avatarUrl
        self.isGroup = isGroup
        self.isCloud = isCloud
        self.lastTsMs = lastTsMs
        self.unreadCount = unreadCount
        self.memberCount = memberCount
    }
}

/// Thread-safe native `SQLite3` message & thread history store (`Tier 2` of the two-tier `Snapshot JSON + SQLite` architecture).
///
/// - Zero external dependencies (uses Apple's system `libsqlite3` in WAL mode).
/// - Losslessly persists `ZolaMessage` payloads (attachments, quotes, voice URLs, sticker metadata) with automatic
///   deduplication across `globalMsgId`, `cliMsgId`, optimistic-to-server ID upgrades, and 5-second echo windows.
public final class ZolaMessageStore: @unchecked Sendable {
    private let lock = NSLock()
    private let readLock = NSLock()
    private var db: OpaquePointer?
    private var readDb: OpaquePointer?
    public let path: String

    /// Opens or creates an on-disk SQLite database at `fileURL` with POSIX `0600` file permissions and WAL mode.
    public convenience init(fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try self.init(databasePath: fileURL.path, secureFilePermissions: true)
    }

    /// Opens a transient in-memory SQLite database (`:memory:`), ideal for deterministic unit tests.
    public static func inMemory() throws -> ZolaMessageStore {
        try ZolaMessageStore(databasePath: ":memory:", secureFilePermissions: false)
    }

    private init(databasePath: String, secureFilePermissions: Bool) throws {
        self.path = databasePath
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(databasePath, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed (\(rc))"
            if let handle { sqlite3_close(handle) }
            throw ZolaError.transport("SQLite open failed: \(msg)")
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 3_000)

        if secureFilePermissions, databasePath != ":memory:" {
            Self.applyPermissions0600(atPath: databasePath)
        }

        try execBatch("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE IF NOT EXISTS messages (
            account_uid INTEGER NOT NULL,
            thread_id INTEGER NOT NULL,
            msg_key TEXT NOT NULL,
            msg_id INTEGER NOT NULL,
            cli_msg_id INTEGER NOT NULL,
            ts_ms INTEGER NOT NULL,
            sender_id INTEGER NOT NULL,
            sender_name TEXT NOT NULL,
            msg_type TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL,
            search_text TEXT NOT NULL,
            is_self INTEGER NOT NULL,
            is_group INTEGER NOT NULL,
            payload_json BLOB NOT NULL,
            PRIMARY KEY (account_uid, thread_id, msg_key)
        );
        CREATE INDEX IF NOT EXISTS idx_messages_thread_ts
            ON messages(account_uid, thread_id, ts_ms ASC, msg_id ASC);
        CREATE INDEX IF NOT EXISTS idx_messages_cli_id
            ON messages(account_uid, thread_id, cli_msg_id);
        CREATE INDEX IF NOT EXISTS idx_messages_account_ts
            ON messages(account_uid, ts_ms DESC);
        CREATE TABLE IF NOT EXISTS threads (
            account_uid INTEGER NOT NULL,
            thread_id INTEGER NOT NULL,
            title TEXT NOT NULL,
            avatar_url TEXT NOT NULL,
            is_group INTEGER NOT NULL,
            is_cloud INTEGER NOT NULL,
            last_ts_ms INTEGER NOT NULL,
            unread_count INTEGER NOT NULL,
            member_count INTEGER NOT NULL,
            PRIMARY KEY (account_uid, thread_id)
        );
        CREATE INDEX IF NOT EXISTS idx_threads_last_ts
            ON threads(account_uid, last_ts_ms DESC);
        """)

        if databasePath != ":memory:" {
            var roHandle: OpaquePointer?
            let roFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            if sqlite3_open_v2(databasePath, &roHandle, roFlags, nil) == SQLITE_OK, let roHandle {
                sqlite3_busy_timeout(roHandle, 3_000)
                self.readDb = roHandle
            } else if let roHandle {
                sqlite3_close(roHandle)
            }
        }

        if secureFilePermissions, databasePath != ":memory:" {
            Self.applyPermissions0600(atPath: databasePath)
            Self.applyPermissions0600(atPath: databasePath + "-wal")
            Self.applyPermissions0600(atPath: databasePath + "-shm")
        }
    }

    deinit {
        readLock.lock()
        if let roHandle = readDb {
            sqlite3_close_v2(roHandle)
            readDb = nil
        }
        readLock.unlock()

        lock.lock()
        if let handle = db {
            sqlite3_close_v2(handle)
            db = nil
        }
        lock.unlock()
    }

    private func withReadConnection<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T? {
        if let roHandle = readDb {
            readLock.lock()
            defer { readLock.unlock() }
            return try body(roHandle)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { return nil }
        return try body(handle)
    }

    private static func applyPermissions0600(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: path
        )
    }

    private func execBatch(_ sql: String) throws {
        guard let handle = db else {
            throw ZolaError.transport("SQLite database is closed")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let reason = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            if let errMsg { sqlite3_free(errMsg) }
            throw ZolaError.transport("SQLite exec failed: \(reason)")
        }
    }

    private static func isLocalOptimisticMessage(_ msg: ZolaMessage) -> Bool {
        let src = msg.source.lowercased()
        if src == "sending" || src == "dry-run" || src == "send-failed" || src.hasPrefix("local") {
            return true
        }
        return msg.id > 0 && msg.cliMsgId > 0 && msg.id == msg.cliMsgId && msg.id >= 1_600_000_000_000
    }

    private static func canonicalMessageKey(for msg: ZolaMessage) -> String {
        if !isLocalOptimisticMessage(msg), msg.id > 0 {
            return "g:\(msg.id)"
        }
        if msg.cliMsgId > 0 {
            return "c:\(msg.cliMsgId)"
        }
        if msg.id > 0 {
            return "g:\(msg.id)"
        }
        let textSig = ZolaCrypto.sha256Hex8(Data(msg.text.utf8))
        return "t:\(msg.tsMs):\(msg.senderId):\(textSig)"
    }

    private static func searchableText(for msg: ZolaMessage) -> String {
        if msg.kind == "recalled" {
            return ""
        }
        var parts: [String] = []
        if !msg.text.isEmpty && msg.text != "sendBubbleMessage" {
            parts.append(msg.text)
        }
        if !msg.senderName.isEmpty {
            parts.append(msg.senderName)
        }
        for att in msg.attachments {
            if !att.title.isEmpty && att.title != "sendBubbleMessage" { parts.append(att.title) }
            if !att.descriptionText.isEmpty && att.descriptionText != "sendBubbleMessage" { parts.append(att.descriptionText) }
        }
        if let quote = msg.quote, !quote.text.isEmpty && quote.text != "sendBubbleMessage" {
            parts.append(quote.text)
        }
        return ZolaTextNormalizer.foldVietnamese(parts.joined(separator: " "))
    }

    /// Inserts or updates a single thread record.
    public func upsertThread(_ record: ZolaStoredThreadRecord) throws {
        guard record.accountUid > 0, record.threadId > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        try upsertThreadUnlocked(record)
    }

    /// Inserts or updates messages for `(accountUid, threadId)` inside an atomic transaction.
    /// Returns the number of persisted messages processed.
    @discardableResult
    public func upsertMessages(
        _ messages: [ZolaMessage],
        accountUid: Int64,
        threadId: Int64
    ) throws -> Int {
        guard accountUid > 0, threadId > 0, !messages.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        try execBatch("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let count = try upsertMessagesUnlocked(messages, accountUid: accountUid, threadId: threadId)
            try execBatch("COMMIT;")
            return count
        } catch {
            try? execBatch("ROLLBACK;")
            throw error
        }
    }

    /// Batch-persists multiple conversations and all of their messages in a single SQLite transaction.
    public func upsertConversations(_ items: [(accountUid: Int64, conversation: ZolaConversation)]) throws {
        guard !items.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        try execBatch("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for entry in items where entry.accountUid > 0 && entry.conversation.threadId > 0 {
                let conv = entry.conversation
                let latestTs = max(conv.lastMessage?.tsMs ?? 0, conv.messages.last?.tsMs ?? 0)
                try upsertThreadUnlocked(
                    ZolaStoredThreadRecord(
                        accountUid: entry.accountUid,
                        threadId: conv.threadId,
                        title: conv.title,
                        avatarUrl: conv.avatarUrl,
                        isGroup: conv.isGroup,
                        isCloud: conv.isCloud,
                        lastTsMs: latestTs,
                        unreadCount: conv.unreadCount,
                        memberCount: conv.memberCount
                    )
                )
                var allMsgs = conv.messages
                if let last = conv.lastMessage,
                   !allMsgs.contains(where: { ($0.id > 0 && $0.id == last.id) || ($0.cliMsgId > 0 && $0.cliMsgId == last.cliMsgId) }) {
                    allMsgs.append(last)
                }
                if !allMsgs.isEmpty {
                    _ = try upsertMessagesUnlocked(allMsgs, accountUid: entry.accountUid, threadId: conv.threadId)
                }
            }
            try execBatch("COMMIT;")
        } catch {
            try? execBatch("ROLLBACK;")
            throw error
        }
    }

    /// Loads up to `limit` persisted messages for `(accountUid, threadId)` in chronological order (`tsMs ASC, id ASC`).
    /// Pass `beforeTsMs` (and optionally `beforeMsgId` for same-millisecond albums) to paginate older messages.
    public func messages(
        accountUid: Int64,
        threadId: Int64,
        limit: Int = 250,
        beforeTsMs: Int64? = nil,
        beforeMsgId: Int64? = nil
    ) throws -> [ZolaMessage] {
        guard accountUid > 0, threadId > 0, limit > 0 else { return [] }
        return withReadConnection { handle in
            let sql: String
            let hasCompoundCursor = (beforeTsMs != nil && (beforeMsgId ?? 0) > 0)
            if hasCompoundCursor {
                sql = """
                SELECT payload_json
                FROM messages
                WHERE account_uid = ?1
                  AND thread_id = ?2
                  AND (ts_ms < ?3 OR (ts_ms = ?3 AND msg_id < ?4))
                ORDER BY ts_ms DESC, msg_id DESC
                LIMIT ?5;
                """
            } else if beforeTsMs != nil {
                sql = """
                SELECT payload_json
                FROM messages
                WHERE account_uid = ?1 AND thread_id = ?2 AND ts_ms < ?3
                ORDER BY ts_ms DESC, msg_id DESC
                LIMIT ?4;
                """
            } else {
                sql = """
                SELECT payload_json
                FROM messages
                WHERE account_uid = ?1 AND thread_id = ?2
                ORDER BY ts_ms DESC, msg_id DESC
                LIMIT ?3;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, accountUid)
            sqlite3_bind_int64(stmt, 2, threadId)
            if let cutoff = beforeTsMs {
                sqlite3_bind_int64(stmt, 3, cutoff)
                if hasCompoundCursor, let cursorId = beforeMsgId {
                    sqlite3_bind_int64(stmt, 4, cursorId)
                    sqlite3_bind_int64(stmt, 5, Int64(limit))
                } else {
                    sqlite3_bind_int64(stmt, 4, Int64(limit))
                }
            } else {
                sqlite3_bind_int64(stmt, 3, Int64(limit))
            }

            let decoder = JSONDecoder()
            var reversed: [ZolaMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let byteCount = Int(sqlite3_column_bytes(stmt, 0))
                guard byteCount > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { continue }
                let data = Data(bytes: rawPtr, count: byteCount)
                if let decoded = try? decoder.decode(ZolaMessage.self, from: data) {
                    reversed.append(decoded)
                }
            }
            return reversed.reversed()
        } ?? []
    }

    /// Returns the total number of persisted messages for `(accountUid, threadId)`.
    public func messageCount(accountUid: Int64, threadId: Int64) throws -> Int {
        guard accountUid > 0, threadId > 0 else { return 0 }
        return withReadConnection { handle in
            let sql = "SELECT COUNT(*) FROM messages WHERE account_uid = ?1 AND thread_id = ?2;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, accountUid)
            sqlite3_bind_int64(stmt, 2, threadId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        } ?? 0
    }

    /// Loads persisted thread metadata ordered by `lastTsMs DESC`.
    public func threads(accountUid: Int64? = nil) throws -> [ZolaStoredThreadRecord] {
        return withReadConnection { handle in
            let sql: String
            if accountUid != nil {
                sql = """
                SELECT account_uid, thread_id, title, avatar_url, is_group, is_cloud, last_ts_ms, unread_count, member_count
                FROM threads
                WHERE account_uid = ?1
                ORDER BY last_ts_ms DESC;
                """
            } else {
                sql = """
                SELECT account_uid, thread_id, title, avatar_url, is_group, is_cloud, last_ts_ms, unread_count, member_count
                FROM threads
                ORDER BY last_ts_ms DESC;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            if let uid = accountUid {
                sqlite3_bind_int64(stmt, 1, uid)
            }

            var out: [ZolaStoredThreadRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let uid = sqlite3_column_int64(stmt, 0)
                let tid = sqlite3_column_int64(stmt, 1)
                let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let avatar = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let isGrp = sqlite3_column_int64(stmt, 4) != 0
                let isCld = sqlite3_column_int64(stmt, 5) != 0
                let lastTs = sqlite3_column_int64(stmt, 6)
                let unread = Int(sqlite3_column_int64(stmt, 7))
                let memCount = Int(sqlite3_column_int64(stmt, 8))
                out.append(
                    ZolaStoredThreadRecord(
                        accountUid: uid,
                        threadId: tid,
                        title: title,
                        avatarUrl: avatar,
                        isGroup: isGrp,
                        isCloud: isCld,
                        lastTsMs: lastTs,
                        unreadCount: unread,
                        memberCount: memCount
                    )
                )
            }
            return out
        } ?? []
    }

    /// Searches historical message bodies (Vietnamese diacritic-insensitive) and returns matching `"<accountUid>:<threadId>"` keys.
    public func matchingThreadKeys(
        query: String,
        accountUid: Int64? = nil,
        limit: Int = 200
    ) throws -> Set<String> {
        let folded = ZolaTextNormalizer.foldVietnamese(query)
        guard !folded.isEmpty, limit > 0 else { return [] }
        return withReadConnection { handle in
            let escaped = folded
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"

            let sql: String
            if accountUid != nil {
                sql = """
                SELECT DISTINCT account_uid, thread_id
                FROM messages
                WHERE account_uid = ?1 AND search_text LIKE ?2 ESCAPE '\\'
                LIMIT ?3;
                """
            } else {
                sql = """
                SELECT DISTINCT account_uid, thread_id
                FROM messages
                WHERE search_text LIKE ?1 ESCAPE '\\'
                LIMIT ?2;
                """
            }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            if let uid = accountUid {
                sqlite3_bind_int64(stmt, 1, uid)
                sqlite3_bind_text(stmt, 2, pattern, -1, zolaSQLiteTransient)
                sqlite3_bind_int64(stmt, 3, Int64(limit))
            } else {
                sqlite3_bind_text(stmt, 1, pattern, -1, zolaSQLiteTransient)
                sqlite3_bind_int64(stmt, 2, Int64(limit))
            }

            var keys = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let uid = sqlite3_column_int64(stmt, 0)
                let tid = sqlite3_column_int64(stmt, 1)
                keys.insert("\(uid):\(tid)")
            }
            return keys
        } ?? []
    }

    /// Searches messages within a single conversation thread (Vietnamese diacritic-insensitive) ordered chronologically (`ts_ms ASC`).
    public func searchMessagesInThread(
        accountUid: Int64,
        threadId: Int64,
        query: String,
        limit: Int = 200
    ) throws -> [ZolaMessage] {
        let folded = ZolaTextNormalizer.foldVietnamese(query)
        guard accountUid > 0, threadId > 0, !folded.isEmpty, limit > 0 else { return [] }
        return withReadConnection { handle in
            let escaped = folded
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            let sql = """
            SELECT payload_json
            FROM messages
            WHERE account_uid = ?1 AND thread_id = ?2 AND search_text LIKE ?3 ESCAPE '\\'
            ORDER BY ts_ms DESC, msg_id DESC
            LIMIT ?4;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, accountUid)
            sqlite3_bind_int64(stmt, 2, threadId)
            sqlite3_bind_text(stmt, 3, pattern, -1, zolaSQLiteTransient)
            sqlite3_bind_int64(stmt, 4, Int64(limit))

            let decoder = JSONDecoder()
            var out: [ZolaMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bytes = Int(sqlite3_column_bytes(stmt, 0))
                guard bytes > 0, let rawPtr = sqlite3_column_blob(stmt, 0) else { continue }
                let data = Data(bytes: rawPtr, count: bytes)
                if let msg = try? decoder.decode(ZolaMessage.self, from: data) {
                    out.append(msg)
                }
            }
            return Array(out.reversed())
        } ?? []
    }

    /// Looks up a reaction target outside the currently loaded window; never crosses account/thread boundaries.
    public func message(accountUid: Int64, threadId: Int64, messageId: Int64, cliMsgId: Int64 = 0) throws -> ZolaMessage? {
        guard accountUid > 0, threadId > 0, messageId > 0 || cliMsgId > 0 else { return nil }
        return withReadConnection { handle -> ZolaMessage? in
            let sql = """
            SELECT payload_json FROM messages
            WHERE account_uid = ?1 AND thread_id = ?2
              AND ((?3 > 0 AND msg_id = ?3) OR (?4 > 0 AND cli_msg_id = ?4))
            ORDER BY CASE WHEN msg_id = ?3 THEN 0 ELSE 1 END
            LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, accountUid)
            sqlite3_bind_int64(stmt, 2, threadId)
            sqlite3_bind_int64(stmt, 3, messageId)
            sqlite3_bind_int64(stmt, 4, cliMsgId)
            guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            return try? JSONDecoder().decode(ZolaMessage.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
        } ?? nil
    }

    /// Permanently deletes a message from local SQLite history ("Xoá ở phía tôi").
    public func deleteMessage(
        accountUid: Int64,
        threadId: Int64,
        messageId: Int64,
        cliMsgId: Int64 = 0
    ) throws {
        guard accountUid > 0, threadId > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { return }

        let sql = """
        DELETE FROM messages
        WHERE account_uid = ?1
          AND thread_id = ?2
          AND (
              (?3 != 0 AND (msg_id = ?3 OR cli_msg_id = ?3 OR msg_key = ?5 OR msg_key = ?6))
              OR (?4 != 0 AND (cli_msg_id = ?4 OR msg_id = ?4 OR msg_key = ?7))
          );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, accountUid)
        sqlite3_bind_int64(stmt, 2, threadId)
        sqlite3_bind_int64(stmt, 3, messageId)
        sqlite3_bind_int64(stmt, 4, cliMsgId)
        sqlite3_bind_text(stmt, 5, "g:\(messageId)", -1, zolaSQLiteTransient)
        sqlite3_bind_text(stmt, 6, "c:\(messageId)", -1, zolaSQLiteTransient)
        sqlite3_bind_text(stmt, 7, "c:\(cliMsgId)", -1, zolaSQLiteTransient)
        _ = sqlite3_step(stmt)
    }

    /// Permanently deletes a thread and all of its local messages from SQLite.
    public func deleteThread(accountUid: Int64, threadId: Int64) throws {
        guard accountUid > 0, threadId > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { return }

        for sql in [
            "DELETE FROM messages WHERE account_uid = ?1 AND thread_id = ?2;",
            "DELETE FROM threads WHERE account_uid = ?1 AND thread_id = ?2;",
        ] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int64(stmt, 1, accountUid)
                sqlite3_bind_int64(stmt, 2, threadId)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Permanently deletes all local threads and messages belonging to `accountUid` (used when removing an account).
    public func deleteAccount(accountUid: Int64) throws {
        guard accountUid > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = db else { return }

        for sql in [
            "DELETE FROM messages WHERE account_uid = ?1;",
            "DELETE FROM threads WHERE account_uid = ?1;",
        ] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                sqlite3_bind_int64(stmt, 1, accountUid)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - Internal Unlocked Helpers

    private func upsertThreadUnlocked(_ record: ZolaStoredThreadRecord) throws {
        guard let handle = db else { return }
        var existingAvatar = ""
        var currentStmt: OpaquePointer?
        if sqlite3_prepare_v2(
            handle,
            "SELECT avatar_url FROM threads WHERE account_uid = ?1 AND thread_id = ?2 LIMIT 1;",
            -1,
            &currentStmt,
            nil
        ) == SQLITE_OK, let currentStmt {
            sqlite3_bind_int64(currentStmt, 1, record.accountUid)
            sqlite3_bind_int64(currentStmt, 2, record.threadId)
            if sqlite3_step(currentStmt) == SQLITE_ROW, let cStr = sqlite3_column_text(currentStmt, 0) {
                existingAvatar = String(cString: cStr)
            }
            sqlite3_finalize(currentStmt)
        }
        let resolvedAvatar = ZolaUser.preferFresherAvatarUrl(existing: existingAvatar, incoming: record.avatarUrl)

        let sql = """
        INSERT INTO threads (account_uid, thread_id, title, avatar_url, is_group, is_cloud, last_ts_ms, unread_count, member_count)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ON CONFLICT(account_uid, thread_id) DO UPDATE SET
            title = CASE WHEN excluded.title != '' THEN excluded.title ELSE threads.title END,
            avatar_url = CASE WHEN excluded.avatar_url != '' THEN excluded.avatar_url ELSE threads.avatar_url END,
            is_group = excluded.is_group,
            is_cloud = excluded.is_cloud,
            last_ts_ms = MAX(threads.last_ts_ms, excluded.last_ts_ms),
            unread_count = excluded.unread_count,
            member_count = MAX(threads.member_count, excluded.member_count);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ZolaError.transport("Failed to prepare upsertThread")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, record.accountUid)
        sqlite3_bind_int64(stmt, 2, record.threadId)
        sqlite3_bind_text(stmt, 3, record.title, -1, zolaSQLiteTransient)
        sqlite3_bind_text(stmt, 4, resolvedAvatar, -1, zolaSQLiteTransient)
        sqlite3_bind_int64(stmt, 5, record.isGroup ? 1 : 0)
        sqlite3_bind_int64(stmt, 6, record.isCloud ? 1 : 0)
        sqlite3_bind_int64(stmt, 7, record.lastTsMs)
        sqlite3_bind_int64(stmt, 8, Int64(record.unreadCount))
        sqlite3_bind_int64(stmt, 9, Int64(record.memberCount))
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            let reason = String(cString: sqlite3_errmsg(handle))
            throw ZolaError.transport("SQLite upsertThread failed: \(reason)")
        }
    }

    private func upsertMessagesUnlocked(
        _ messages: [ZolaMessage],
        accountUid: Int64,
        threadId: Int64
    ) throws -> Int {
        guard let handle = db else { return 0 }
        let encoder = JSONEncoder()

        let checkConfirmedCliSql = """
        SELECT msg_key FROM messages
        WHERE account_uid = ?1 AND thread_id = ?2 AND cli_msg_id = ?3 AND msg_key LIKE 'g:%'
        LIMIT 1;
        """
        let existingPayloadSql = """
        SELECT payload_json FROM messages
        WHERE account_uid = ?1 AND thread_id = ?2
          AND (msg_key = ?3 OR (?4 > 0 AND cli_msg_id = ?4))
        ORDER BY CASE WHEN msg_key = ?3 THEN 0 ELSE 1 END
        LIMIT 1;
        """
        let deleteOptimisticByCliSql = """
        DELETE FROM messages
        WHERE account_uid = ?1 AND thread_id = ?2
          AND kind != 'send-failed'
          AND kind != 'recalled'
          AND (msg_key = ?3 OR (cli_msg_id = ?4 AND msg_id = ?4));
        """
        let deleteEchoWindowSql = """
        DELETE FROM messages
        WHERE account_uid = ?1 AND thread_id = ?2
          AND msg_key = (
              SELECT msg_key
              FROM messages
              WHERE account_uid = ?1
                AND thread_id = ?2
                AND msg_key LIKE 'c:%'
                AND is_self = 1
                AND kind != 'send-failed'
                AND kind != 'recalled'
                AND text = ?3
                AND ABS(ts_ms - ?4) <= 5000
              ORDER BY ABS(ts_ms - ?4) ASC
              LIMIT 1
          );
        """
        let upsertSql = """
        INSERT INTO messages (
            account_uid, thread_id, msg_key, msg_id, cli_msg_id, ts_ms,
            sender_id, sender_name, msg_type, kind, text, search_text,
            is_self, is_group, payload_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        ON CONFLICT(account_uid, thread_id, msg_key) DO UPDATE SET
            msg_id = CASE WHEN excluded.msg_id > 0 THEN excluded.msg_id ELSE messages.msg_id END,
            cli_msg_id = CASE WHEN excluded.cli_msg_id > 0 THEN excluded.cli_msg_id ELSE messages.cli_msg_id END,
            ts_ms = CASE WHEN excluded.ts_ms > 0 THEN excluded.ts_ms ELSE messages.ts_ms END,
            sender_id = excluded.sender_id,
            is_self = excluded.is_self,
            is_group = excluded.is_group,
            sender_name = CASE WHEN excluded.sender_name != '' THEN excluded.sender_name ELSE messages.sender_name END,
            msg_type = CASE WHEN messages.kind = 'recalled' AND excluded.kind != 'recalled' THEN messages.msg_type ELSE excluded.msg_type END,
            kind = CASE WHEN messages.kind = 'recalled' AND excluded.kind != 'recalled' THEN messages.kind ELSE excluded.kind END,
            text = CASE WHEN messages.kind = 'recalled' AND excluded.kind != 'recalled' THEN messages.text ELSE excluded.text END,
            search_text = CASE WHEN messages.kind = 'recalled' AND excluded.kind != 'recalled' THEN messages.search_text ELSE excluded.search_text END,
            payload_json = CASE WHEN messages.kind = 'recalled' AND excluded.kind != 'recalled' THEN messages.payload_json ELSE excluded.payload_json END;
        """

        var checkStmt: OpaquePointer?
        var delCliStmt: OpaquePointer?
        var delEchoStmt: OpaquePointer?
        var upsertStmt: OpaquePointer?
        var existingStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, checkConfirmedCliSql, -1, &checkStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(handle, deleteOptimisticByCliSql, -1, &delCliStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(handle, deleteEchoWindowSql, -1, &delEchoStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(handle, upsertSql, -1, &upsertStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(handle, existingPayloadSql, -1, &existingStmt, nil) == SQLITE_OK,
              let checkStmt, let delCliStmt, let delEchoStmt, let upsertStmt, let existingStmt
        else {
            if let s = checkStmt { sqlite3_finalize(s) }
            if let s = delCliStmt { sqlite3_finalize(s) }
            if let s = delEchoStmt { sqlite3_finalize(s) }
            if let s = upsertStmt { sqlite3_finalize(s) }
            if let s = existingStmt { sqlite3_finalize(s) }
            throw ZolaError.transport("Failed to prepare SQLite message statements")
        }
        defer {
            sqlite3_finalize(checkStmt)
            sqlite3_finalize(delCliStmt)
            sqlite3_finalize(delEchoStmt)
            sqlite3_finalize(upsertStmt)
            sqlite3_finalize(existingStmt)
        }

        var count = 0
        for incoming in messages {
            var msg = incoming
            if msg.text == "sendBubbleMessage" && msg.attachments.isEmpty {
                continue
            }
            let isOptimistic = Self.isLocalOptimisticMessage(msg)
            let msgKey = Self.canonicalMessageKey(for: msg)

            // If this is an optimistic local message (`c:<cliMsgId>`), skip if a confirmed server row (`g:<globalId>`) already exists for the same `cliMsgId`.
            if isOptimistic, msg.cliMsgId > 0 {
                sqlite3_reset(checkStmt)
                sqlite3_clear_bindings(checkStmt)
                sqlite3_bind_int64(checkStmt, 1, accountUid)
                sqlite3_bind_int64(checkStmt, 2, threadId)
                sqlite3_bind_int64(checkStmt, 3, msg.cliMsgId)
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    continue
                }
            }

            // Merge under the existing write transaction, before deleting an optimistic predecessor.
            // Columns and payload are derived from the same result so search/reopen cannot diverge.
            sqlite3_reset(existingStmt)
            sqlite3_clear_bindings(existingStmt)
            sqlite3_bind_int64(existingStmt, 1, accountUid)
            sqlite3_bind_int64(existingStmt, 2, threadId)
            sqlite3_bind_text(existingStmt, 3, msgKey, -1, zolaSQLiteTransient)
            sqlite3_bind_int64(existingStmt, 4, msg.cliMsgId)
            if sqlite3_step(existingStmt) == SQLITE_ROW,
               let bytes = sqlite3_column_blob(existingStmt, 0) {
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(existingStmt, 0)))
                if let existing = try? JSONDecoder().decode(ZolaMessage.self, from: data) {
                    msg = ZolaMessage.merging(existing: existing, incoming: msg)
                }
            }
            sqlite3_reset(existingStmt)

            // When a confirmed server message arrives (`g:<globalMsgId>`), retire any pending optimistic row sharing `cliMsgId` or within a 5s outgoing echo window.
            if !isOptimistic {
                if msg.cliMsgId > 0 {
                    sqlite3_reset(delCliStmt)
                    sqlite3_clear_bindings(delCliStmt)
                    sqlite3_bind_int64(delCliStmt, 1, accountUid)
                    sqlite3_bind_int64(delCliStmt, 2, threadId)
                    sqlite3_bind_text(delCliStmt, 3, "c:\(msg.cliMsgId)", -1, zolaSQLiteTransient)
                    sqlite3_bind_int64(delCliStmt, 4, msg.cliMsgId)
                    _ = sqlite3_step(delCliStmt)
                } else if msg.isSelf, !msg.text.isEmpty, msg.tsMs > 0 {
                    sqlite3_reset(delEchoStmt)
                    sqlite3_clear_bindings(delEchoStmt)
                    sqlite3_bind_int64(delEchoStmt, 1, accountUid)
                    sqlite3_bind_int64(delEchoStmt, 2, threadId)
                    sqlite3_bind_text(delEchoStmt, 3, msg.text, -1, zolaSQLiteTransient)
                    sqlite3_bind_int64(delEchoStmt, 4, msg.tsMs)
                    _ = sqlite3_step(delEchoStmt)
                }
            }

            guard let payload = try? encoder.encode(msg) else { continue }
            let searchTxt = Self.searchableText(for: msg)

            sqlite3_reset(upsertStmt)
            sqlite3_clear_bindings(upsertStmt)
            sqlite3_bind_int64(upsertStmt, 1, accountUid)
            sqlite3_bind_int64(upsertStmt, 2, threadId)
            sqlite3_bind_text(upsertStmt, 3, msgKey, -1, zolaSQLiteTransient)
            sqlite3_bind_int64(upsertStmt, 4, msg.id)
            sqlite3_bind_int64(upsertStmt, 5, msg.cliMsgId)
            sqlite3_bind_int64(upsertStmt, 6, msg.tsMs)
            sqlite3_bind_int64(upsertStmt, 7, msg.senderId)
            sqlite3_bind_text(upsertStmt, 8, msg.senderName, -1, zolaSQLiteTransient)
            sqlite3_bind_text(upsertStmt, 9, msg.msgType, -1, zolaSQLiteTransient)
            sqlite3_bind_text(upsertStmt, 10, msg.kind, -1, zolaSQLiteTransient)
            sqlite3_bind_text(upsertStmt, 11, msg.text, -1, zolaSQLiteTransient)
            sqlite3_bind_text(upsertStmt, 12, searchTxt, -1, zolaSQLiteTransient)
            sqlite3_bind_int64(upsertStmt, 13, msg.isSelf ? 1 : 0)
            sqlite3_bind_int64(upsertStmt, 14, msg.isGroup ? 1 : 0)
            payload.withUnsafeBytes { rawBuf in
                _ = sqlite3_bind_blob(upsertStmt, 15, rawBuf.baseAddress, Int32(payload.count), zolaSQLiteTransient)
            }
            if sqlite3_step(upsertStmt) == SQLITE_DONE {
                count += 1
            }
        }
        return count
    }
}
