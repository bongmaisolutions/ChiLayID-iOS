import Foundation
import Combine

public struct ChiLayIDIdentity: Identifiable, Codable, Equatable {
    public var id: String { accountId }
    public let accountId: String
    public var displayName: String
    public var aliasName: String
    public var avatarSignature: String
    public var source: String
    public var lastSeen: Date

    public init(
        accountId: String,
        displayName: String,
        aliasName: String = "",
        avatarSignature: String = "",
        source: String = "SEED",
        lastSeen: Date = Date()
    ) {
        self.accountId = accountId
        self.displayName = displayName
        self.aliasName = aliasName
        self.avatarSignature = avatarSignature
        self.source = source
        self.lastSeen = lastSeen
    }
}

public struct ChiLayIDCallRecord: Identifiable, Codable, Equatable {
    public let id: String
    public var callerName: String
    public var callerAccountId: String
    public var startTime: Date
    public var durationSeconds: Int
    public var avatarSignature: String

    public init(
        id: String = UUID().uuidString,
        callerName: String,
        callerAccountId: String,
        startTime: Date = Date(),
        durationSeconds: Int = 0,
        avatarSignature: String = ""
    ) {
        self.id = id
        self.callerName = callerName
        self.callerAccountId = callerAccountId
        self.startTime = startTime
        self.durationSeconds = durationSeconds
        self.avatarSignature = avatarSignature
    }

    public var formattedTime: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: startTime)
    }

    public var formattedDuration: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Dòng 1: Tên -- Giờ phút gọi - Tổng thời gian đàm thoại (Không nhãn)
    /// Ví dụ: Ngọc Phượng -- 18:08 - 00:35
    public var line1Text: String {
        "\(callerName) -- \(formattedTime) - \(formattedDuration)"
    }

    /// Dòng 2: Account ID: <Mã_AccountID>
    public var line2Text: String {
        let clean = callerAccountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = clean.isEmpty ? "Đang nhận diện..." : clean
        return "Account ID: \(display)"
    }
}

public final class ChiLayIDStore: ObservableObject {
    public static let shared = ChiLayIDStore()

    @Published public var identities: [ChiLayIDIdentity] = []
    @Published public var callRecords: [ChiLayIDCallRecord] = []
    @Published public var searchQuery: String = ""
    @Published public var activeTab: Int = 1 // Mặc định mở Tab 1: Cuộc gọi đến
    @Published public var isCrmEnabled: Bool = false // Tạm thời tắt kết nối CRM theo yêu cầu
    @Published public var isSyncing: Bool = false
    @Published public var syncStatusMessage: String = ""
    @Published public var crmServerUrl: String = "http://192.168.1.5:5000/api/crm/call"

    private let cacheFileName = "chilayid_identities_cache.json"
    private let callsFileName = "chilayid_calls_cache.json"

    public init() {
        loadCalls()
        loadIdentities()
    }

    public var filteredIdentities: [ChiLayIDIdentity] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return Array(identities.prefix(100))
        }
        return identities.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.aliasName.lowercased().contains(q) ||
            $0.accountId.contains(q)
        }
    }

    public var filteredCalls: [ChiLayIDCallRecord] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return callRecords
        }
        return callRecords.filter {
            $0.callerName.lowercased().contains(q) ||
            $0.callerAccountId.contains(q)
        }
    }

    public var avatarCount: Int {
        identities.filter { !$0.avatarSignature.isEmpty }.count
    }

    // MARK: - Nhận diện danh tính người gọi
    public func resolveIdentity(uid: Int64, rawName: String) -> (name: String, accountId: String) {
        let uidStr = String(uid)
        // 1. Tra cứu theo UID
        if uid > 0, let match = identities.first(where: { $0.accountId == uidStr }) {
            let name = match.displayName.isEmpty ? rawName : match.displayName
            return (name, match.accountId)
        }

        // 2. Tra cứu theo Tên người gọi trong danh bạ 6,377 liên hệ
        let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !cleanName.isEmpty {
            if let match = identities.first(where: {
                $0.displayName.lowercased() == cleanName ||
                $0.aliasName.lowercased() == cleanName ||
                cleanName.hasPrefix($0.displayName.lowercased())
            }) {
                return (match.displayName, match.accountId)
            }
        }

        // 3. Fallback nếu chưa có trong danh bạ
        let fallbackName = rawName.isEmpty ? (uid > 0 ? "Khách gọi Zalo (UID \(uid))" : "Khách gọi Zalo") : rawName
        let fallbackId = uid > 0 ? uidStr : "Chưa xác định"
        return (fallbackName, fallbackId)
    }

    public func addCallRecord(callerName: String, accountId: String, durationSeconds: Int = 0) {
        let newRec = ChiLayIDCallRecord(
            callerName: callerName,
            callerAccountId: accountId,
            startTime: Date(),
            durationSeconds: durationSeconds
        )
        // Đưa lên đầu danh sách
        self.callRecords.insert(newRec, at: 0)
        saveCalls()
    }

    // MARK: - Import Seed
    @discardableResult
    public func importSeedContactsIfAvailable() -> Int {
        var seedUrl: URL? = nil

        #if SWIFT_PACKAGE
        seedUrl = Bundle.module.url(forResource: "zalo_contacts_seed", withExtension: "json")
        #endif

        if seedUrl == nil {
            seedUrl = Bundle.main.url(forResource: "zalo_contacts_seed", withExtension: "json")
        }

        if seedUrl == nil {
            // Thử tìm trong Documents hoặc App Bundle subdirectories
            let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let customUrl = docDir?.appendingPathComponent("zalo_contacts_seed.json"), FileManager.default.fileExists(atPath: customUrl.path) {
                seedUrl = customUrl
            }
        }

        guard let url = seedUrl, let data = try? Data(contentsOf: url) else {
            return 0
        }

        struct RawSeedItem: Decodable {
            let accountId: String?
            let displayName: String?
            let aliasName: String?
            let avatarSignature: String?
            let timestamp: Int64?
        }

        guard let items = try? JSONDecoder().decode([RawSeedItem].self, from: data) else {
            return 0
        }

        var count = 0
        var map: [String: ChiLayIDIdentity] = [:]
        for id in identities {
            map[id.accountId] = id
        }

        for item in items {
            guard let uid = item.accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
                continue
            }
            let name = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let alias = item.aliasName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let av = item.avatarSignature?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if var existing = map[uid] {
                if !name.isEmpty && existing.displayName.isEmpty { existing.displayName = name }
                if !alias.isEmpty && existing.aliasName.isEmpty { existing.aliasName = alias }
                if !av.isEmpty && existing.avatarSignature.isEmpty { existing.avatarSignature = av }
                map[uid] = existing
            } else {
                map[uid] = ChiLayIDIdentity(
                    accountId: uid,
                    displayName: name.isEmpty ? "Khách hàng Zalo" : name,
                    aliasName: alias,
                    avatarSignature: av,
                    source: "SEED"
                )
                count += 1
            }
        }

        self.identities = Array(map.values).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        saveIdentities()
        return count
    }

    // MARK: - Persistence
    private func getDocumentsURL(for fileName: String) -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    public func saveIdentities() {
        guard let url = getDocumentsURL(for: cacheFileName),
              let data = try? JSONEncoder().encode(identities) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func loadIdentities() {
        if let url = getDocumentsURL(for: cacheFileName),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ChiLayIDIdentity].self, from: data),
           !decoded.isEmpty {
            self.identities = decoded
        } else {
            // Tự nạp từ seed bundle nếu cache trống
            importSeedContactsIfAvailable()
        }
    }

    public func saveCalls() {
        guard let url = getDocumentsURL(for: callsFileName),
              let data = try? JSONEncoder().encode(callRecords) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func loadCalls() {
        if let url = getDocumentsURL(for: callsFileName),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([ChiLayIDCallRecord].self, from: data),
           !decoded.isEmpty {
            self.callRecords = decoded
        } else {
            let now = Date()
            self.callRecords = [
                ChiLayIDCallRecord(callerName: "Ngọc Phượng", callerAccountId: "275078606", startTime: now.addingTimeInterval(-3600 * 2), durationSeconds: 35),
                ChiLayIDCallRecord(callerName: "Nguyễn Phước Thiện", callerAccountId: "174638858", startTime: now.addingTimeInterval(-3600 * 4), durationSeconds: 41),
                ChiLayIDCallRecord(callerName: "Quỳnh Anh 3 - Quỳnh Anh 7", callerAccountId: "434481207", startTime: now.addingTimeInterval(-3600 * 5), durationSeconds: 36),
                ChiLayIDCallRecord(callerName: "Quỳnh Anh 3 - Quỳnh Anh 7", callerAccountId: "434481207", startTime: now.addingTimeInterval(-3600 * 6), durationSeconds: 52),
                ChiLayIDCallRecord(callerName: "Bùi Tấn Tước - CTY CNTT Bông Mai", callerAccountId: "145003477", startTime: now.addingTimeInterval(-3600 * 7), durationSeconds: 7)
            ]
            saveCalls()
        }
    }
}
