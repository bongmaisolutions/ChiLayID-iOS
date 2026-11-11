import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

/// Persisted per-installation native device identity & ZDK `2001.*` device token record.
public struct ZolaStoredDeviceRecord: Codable, Sendable, Equatable {
    public var idfa: String
    public var vendorId: String
    public var zcid: String
    public var zcidTimestampMs: Int64
    public var hardwareModel: String?
    public var platformModel: String?
    public var zdkSdkId: String?
    public var deviceIdentifier: String?
    public var deviceIdentifierExpiresAtMs: Int64?

    public init(
        idfa: String,
        vendorId: String,
        zcid: String,
        zcidTimestampMs: Int64,
        hardwareModel: String? = nil,
        platformModel: String? = nil,
        zdkSdkId: String? = nil,
        deviceIdentifier: String? = nil,
        deviceIdentifierExpiresAtMs: Int64? = nil
    ) {
        self.idfa = idfa
        self.vendorId = vendorId
        self.zcid = zcid
        self.zcidTimestampMs = zcidTimestampMs
        self.hardwareModel = hardwareModel
        self.platformModel = platformModel
        self.zdkSdkId = zdkSdkId
        self.deviceIdentifier = deviceIdentifier
        self.deviceIdentifierExpiresAtMs = deviceIdentifierExpiresAtMs
    }
}

/// Persistent `ThisDeviceOnly` Keychain + Mac Catalyst `0600` vault store for per-device identity (`kSecurityIndentifierKey` + `ZDKDeviceTracker`).
public final class ZolaDeviceIdentityStore: @unchecked Sendable {
    public static let shared = ZolaDeviceIdentityStore()

    public let service: String
    public let account: String
    private let inMemoryOnly: Bool
    private let lock = NSLock()
    private var memoryRecord: ZolaStoredDeviceRecord?

    public init(
        service: String = "com.zolakit.device-identity",
        account: String = "primary-device",
        inMemory: Bool = false
    ) {
        self.service = service
        self.account = account
        self.inMemoryOnly = inMemory
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    #if targetEnvironment(macCatalyst) || os(macOS)
    private static func safeVaultComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "default" : cleaned
    }

    internal func macVaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ZolaKit", isDirectory: true)
            .appendingPathComponent("KeychainVault", isDirectory: true)
            .appendingPathComponent(Self.safeVaultComponent(service), isDirectory: true)
            .appendingPathComponent("\(Self.safeVaultComponent(account)).json")
    }
    #endif

    public func load() -> ZolaStoredDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        if let memoryRecord {
            return memoryRecord
        }
        if inMemoryOnly {
            return nil
        }

        #if targetEnvironment(macCatalyst)
        let vaultURL = macVaultFileURL()
        if FileManager.default.fileExists(atPath: vaultURL.path),
           let data = try? Data(contentsOf: vaultURL),
           let decoded = try? JSONDecoder().decode(ZolaStoredDeviceRecord.self, from: data) {
            memoryRecord = decoded
            return decoded
        }
        #endif

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let decoded = try? JSONDecoder().decode(ZolaStoredDeviceRecord.self, from: data) {
            memoryRecord = decoded
            return decoded
        }

        #if os(macOS)
        let vaultURL = macVaultFileURL()
        if FileManager.default.fileExists(atPath: vaultURL.path),
           let data = try? Data(contentsOf: vaultURL),
           let decoded = try? JSONDecoder().decode(ZolaStoredDeviceRecord.self, from: data) {
            memoryRecord = decoded
            return decoded
        }
        #endif

        return nil
    }

    public func save(_ record: ZolaStoredDeviceRecord) {
        lock.lock()
        defer { lock.unlock() }
        memoryRecord = record
        guard !inMemoryOnly,
              let data = try? JSONEncoder().encode(record) else {
            return
        }

        #if targetEnvironment(macCatalyst)
        try? ZolaFileSessionStore.writeData0600(data, to: macVaultFileURL())
        #else
        let query = baseQuery()
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attrs { addQuery[k] = v }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        #if os(macOS)
        if status != errSecSuccess {
            try? ZolaFileSessionStore.writeData0600(data, to: macVaultFileURL())
        }
        #endif
        #endif
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        memoryRecord = nil
        guard !inMemoryOnly else { return }
        #if targetEnvironment(macCatalyst) || os(macOS)
        let vaultURL = macVaultFileURL()
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        #endif
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }
}

/// iOS/iPadOS client device profile used for mobile authentication requests.
public struct ZolaDeviceIdentity: Sendable, Equatable {
    public var idfa: String
    public var vendorId: String
    public var zcid: String             // "1_…" client zcid
    public var deviceIdentifier: String // "2001.…" client device id
    public var model: String            // e.g. "iP16Pro_@26.3.1_@NJ"
    public var deviceName: String       // e.g. "iPhone 16 Pro"
    public var hardwareModel: String    // e.g. "iPhone17,1"
    public var width: Int
    public var height: Int
    public var scale: String

    public init(
        idfa: String,
        zcid: String,
        deviceIdentifier: String,
        model: String,
        deviceName: String,
        width: Int = 402,
        height: Int = 874,
        vendorId: String? = nil,
        hardwareModel: String = "iPhone17,1",
        scale: String = "3.00"
    ) {
        self.idfa = idfa
        self.vendorId = vendorId ?? idfa
        self.zcid = zcid
        self.deviceIdentifier = deviceIdentifier
        self.model = model
        self.deviceName = deviceName
        self.hardwareModel = hardwareModel
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// Deterministic reference profile preserved for unit tests and legacy session fallbacks.
    public static let defaultProfile = ZolaDeviceIdentity(
        idfa: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
        zcid: "1_166DBF93CC1D91B465795984762712B0AA167703FF97280D3055408744E639F4F1408DC182A12753B9D08FC854AC79697DBCB304DA0B41582329736B39A00D2C0A80B69183E713FA16E48BF31233647D",
        deviceIdentifier: "2001.SSZ-ZolaKitSyntheticPlaceholderDeviceId-34.1",
        model: "iP16Pro_@26.3.1_@NJ",
        deviceName: "iPhone 16 Pro",
        width: 402,
        height: 874,
        vendorId: "5A0C1E2D-7B3F-4C11-9D2E-0123456789AB",
        hardwareModel: "iPhone17,1",
        scale: "3.00"
    )

    public struct HardwareSpec: Sendable, Equatable {
        public let hardwareModel: String
        public let shortModel: String
        public let deviceName: String
        public let width: Int
        public let height: Int
        public let scale: String
    }

    /// Resolves an Apple `hw.machine` identifier (e.g. `"iPhone17,1"`, `"iPhone18,1"`, `"iPad16,3"`) into Zalo's native model metadata.
    public static func resolveHardwareSpec(rawMachine: String, isPadFallback: Bool = false) -> HardwareSpec {
        let trimmed = rawMachine.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        // iPhone X – 11 series
        case "iPhone10,3", "iPhone10,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPX", deviceName: "iPhone X", width: 375, height: 812, scale: "3.00")
        case "iPhone11,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPXS", deviceName: "iPhone XS", width: 375, height: 812, scale: "3.00")
        case "iPhone11,4", "iPhone11,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPXSMax", deviceName: "iPhone XS Max", width: 414, height: 896, scale: "3.00")
        case "iPhone11,8":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPXR", deviceName: "iPhone XR", width: 414, height: 896, scale: "2.00")
        case "iPhone12,1":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP11", deviceName: "iPhone 11", width: 414, height: 896, scale: "2.00")
        case "iPhone12,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP11Pro", deviceName: "iPhone 11 Pro", width: 375, height: 812, scale: "3.00")
        case "iPhone12,5":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP11ProMax", deviceName: "iPhone 11 Pro Max", width: 414, height: 896, scale: "3.00")
        case "iPhone12,8":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPSE2", deviceName: "iPhone SE", width: 375, height: 667, scale: "2.00")
        // iPhone 12 series
        case "iPhone13,1":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP12Mini", deviceName: "iPhone 12 mini", width: 375, height: 812, scale: "3.00")
        case "iPhone13,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP12", deviceName: "iPhone 12", width: 390, height: 844, scale: "3.00")
        case "iPhone13,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP12Pro", deviceName: "iPhone 12 Pro", width: 390, height: 844, scale: "3.00")
        case "iPhone13,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP12ProMax", deviceName: "iPhone 12 Pro Max", width: 428, height: 926, scale: "3.00")
        // iPhone 13 & SE 3 series
        case "iPhone14,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP13Mini", deviceName: "iPhone 13 mini", width: 375, height: 812, scale: "3.00")
        case "iPhone14,5":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP13", deviceName: "iPhone 13", width: 390, height: 844, scale: "3.00")
        case "iPhone14,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP13Pro", deviceName: "iPhone 13 Pro", width: 390, height: 844, scale: "3.00")
        case "iPhone14,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP13ProMax", deviceName: "iPhone 13 Pro Max", width: 428, height: 926, scale: "3.00")
        case "iPhone14,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPSE3", deviceName: "iPhone SE", width: 375, height: 667, scale: "2.00")
        // iPhone 14 series
        case "iPhone14,7":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP14", deviceName: "iPhone 14", width: 390, height: 844, scale: "3.00")
        case "iPhone14,8":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP14Plus", deviceName: "iPhone 14 Plus", width: 428, height: 926, scale: "3.00")
        case "iPhone15,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP14Pro", deviceName: "iPhone 14 Pro", width: 393, height: 852, scale: "3.00")
        case "iPhone15,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP14ProMax", deviceName: "iPhone 14 Pro Max", width: 430, height: 932, scale: "3.00")
        // iPhone 15 series
        case "iPhone15,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP15", deviceName: "iPhone 15", width: 393, height: 852, scale: "3.00")
        case "iPhone15,5":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP15Plus", deviceName: "iPhone 15 Plus", width: 430, height: 932, scale: "3.00")
        case "iPhone16,1":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP15Pro", deviceName: "iPhone 15 Pro", width: 393, height: 852, scale: "3.00")
        case "iPhone16,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP15ProMax", deviceName: "iPhone 15 Pro Max", width: 430, height: 932, scale: "3.00")
        // iPhone 16 series
        case "iPhone17,1":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP16Pro", deviceName: "iPhone 16 Pro", width: 402, height: 874, scale: "3.00")
        case "iPhone17,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP16ProMax", deviceName: "iPhone 16 Pro Max", width: 440, height: 956, scale: "3.00")
        case "iPhone17,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP16", deviceName: "iPhone 16", width: 393, height: 852, scale: "3.00")
        case "iPhone17,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP16Plus", deviceName: "iPhone 16 Plus", width: 430, height: 932, scale: "3.00")
        case "iPhone17,5":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP16e", deviceName: "iPhone 16e", width: 390, height: 844, scale: "3.00")
        // iPhone 17 & iPhone Air series
        case "iPhone18,1":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP17Pro", deviceName: "iPhone 17 Pro", width: 402, height: 874, scale: "3.00")
        case "iPhone18,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP17ProMax", deviceName: "iPhone 17 Pro Max", width: 440, height: 956, scale: "3.00")
        case "iPhone18,3":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP17", deviceName: "iPhone 17", width: 402, height: 874, scale: "3.00")
        case "iPhone18,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iP17Air", deviceName: "iPhone Air", width: 420, height: 912, scale: "3.00")
        // iPad mini / Air / Pro
        case "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadMini", deviceName: "iPad mini", width: 744, height: 1133, scale: "2.00")
        case "iPad13,1", "iPad13,2", "iPad13,16", "iPad13,17", "iPad14,8", "iPad14,9", "iPad15,3", "iPad15,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadAir", deviceName: "iPad Air", width: 820, height: 1180, scale: "2.00")
        case "iPad14,10", "iPad14,11", "iPad15,5", "iPad15,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadAir", deviceName: "iPad Air", width: 1024, height: 1366, scale: "2.00")
        case "iPad16,3", "iPad16,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadPro", deviceName: "iPad Pro", width: 834, height: 1210, scale: "2.00")
        case "iPad16,5", "iPad16,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadPro", deviceName: "iPad Pro", width: 1032, height: 1376, scale: "2.00")
        case "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7", "iPad14,3", "iPad14,4":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadPro", deviceName: "iPad Pro", width: 834, height: 1194, scale: "2.00")
        case "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11", "iPad14,5", "iPad14,6":
            return HardwareSpec(hardwareModel: trimmed, shortModel: "iPadPro", deviceName: "iPad Pro", width: 1024, height: 1366, scale: "2.00")
        default:
            if trimmed.hasPrefix("iPad") {
                let cleanShort = trimmed.replacingOccurrences(of: ",", with: "_")
                return HardwareSpec(hardwareModel: trimmed, shortModel: cleanShort, deviceName: "iPad", width: 834, height: 1194, scale: "2.00")
            }
            if trimmed.hasPrefix("iPhone") {
                let cleanShort = trimmed
                    .replacingOccurrences(of: "iPhone", with: "iP")
                    .replacingOccurrences(of: ",", with: "_")
                return HardwareSpec(hardwareModel: trimmed, shortModel: cleanShort, deviceName: "iPhone", width: 402, height: 874, scale: "3.00")
            }
            if isPadFallback || trimmed.hasPrefix("Mac") || trimmed == "arm64" || trimmed == "x86_64" {
                return HardwareSpec(hardwareModel: "iPad16,3", shortModel: "iPadPro", deviceName: "iPad Pro", width: 834, height: 1210, scale: "2.00")
            }
            return HardwareSpec(hardwareModel: "iPhone17,1", shortModel: "iP16Pro", deviceName: "iPhone 16 Pro", width: 402, height: 874, scale: "3.00")
        }
    }

    private static func readSysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let str = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : str
    }

    private static func currentOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Resolves and persists the authentic per-device identity for the host iPhone/iPad/Simulator/Mac Catalyst installation.
    public static func currentDevice(
        store: ZolaDeviceIdentityStore = .shared,
        rawMachineOverride: String? = nil,
        osVersionOverride: String? = nil,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> ZolaDeviceIdentity {
        let rawMachine: String
        let isPadIdiom: Bool
        if let rawMachineOverride, !rawMachineOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawMachine = rawMachineOverride
            isPadIdiom = rawMachineOverride.lowercased().hasPrefix("ipad")
        } else {
            #if targetEnvironment(macCatalyst) || os(macOS)
            rawMachine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPad16,3"
            isPadIdiom = true
            #elseif targetEnvironment(simulator)
            rawMachine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
                ?? readSysctlString("hw.machine")
                ?? "iPhone17,1"
            isPadIdiom = rawMachine.lowercased().hasPrefix("ipad")
            #else
            rawMachine = readSysctlString("hw.machine") ?? "iPhone17,1"
            isPadIdiom = rawMachine.lowercased().hasPrefix("ipad")
            #endif
        }

        var spec = resolveHardwareSpec(rawMachine: rawMachine, isPadFallback: isPadIdiom)
        var detectedOSVersion = osVersionOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if detectedOSVersion.isEmpty {
            detectedOSVersion = currentOSVersionString()
        }
        var liveVendorId: String? = nil

        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if rawMachineOverride == nil, OperationQueue.current === OperationQueue.main {
            MainActor.assumeIsolated {
                if osVersionOverride == nil {
                    let sysVer = UIDevice.current.systemVersion.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sysVer.isEmpty {
                        detectedOSVersion = sysVer
                    }
                }
                if let vid = UIDevice.current.identifierForVendor?.uuidString.uppercased(), !vid.isEmpty {
                    liveVendorId = vid
                }
                let bounds = UIScreen.main.bounds
                let minSide = Int(min(bounds.width, bounds.height).rounded())
                let maxSide = Int(max(bounds.width, bounds.height).rounded())
                if minSide >= 320 && maxSide >= 480 {
                    spec = HardwareSpec(
                        hardwareModel: spec.hardwareModel,
                        shortModel: spec.shortModel,
                        deviceName: spec.deviceName,
                        width: minSide,
                        height: maxSide,
                        scale: String(format: "%.2f", UIScreen.main.scale)
                    )
                }
            }
        }
        #endif

        let existing = store.load()
        let idfa = (existing?.idfa.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString.uppercased()
        let vendorId = (existing?.vendorId.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? liveVendorId
            ?? UUID().uuidString.uppercased()

        let freshPlatform = ZolaCrypto.platformString(
            shortModel: spec.shortModel,
            osVersion: detectedOSVersion,
            jailbroken: false
        )

        let zcid: String
        let zcidTimestampMs: Int64
        let platformModel: String
        let sameHardware = (existing?.hardwareModel == nil || existing?.hardwareModel == spec.hardwareModel)

        if let existing,
           sameHardware,
           existing.zcid.hasPrefix("1_"),
           ZolaCrypto.extractZCIDIdentity(zcid: existing.zcid).imei == idfa {
            zcid = existing.zcid
            zcidTimestampMs = existing.zcidTimestampMs
            platformModel = ZolaCrypto.extractZCIDIdentity(zcid: existing.zcid).platform
        } else {
            let generated = (try? ZolaCrypto.generateZCID(
                idfa: idfa,
                platform: freshPlatform,
                timestampMs: nowMs
            )) ?? Self.defaultProfile.zcid
            zcid = generated
            zcidTimestampMs = nowMs
            platformModel = freshPlatform
        }

        let validStoredDevId: String
        let storedExp = existing?.deviceIdentifierExpiresAtMs
        if let existing,
           sameHardware,
           let devId = existing.deviceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !devId.isEmpty,
           (storedExp == nil || storedExp! <= 0 || storedExp! > nowMs + 60_000) {
            validStoredDevId = devId
        } else {
            validStoredDevId = ""
        }

        let updatedRecord = ZolaStoredDeviceRecord(
            idfa: idfa,
            vendorId: vendorId,
            zcid: zcid,
            zcidTimestampMs: zcidTimestampMs,
            hardwareModel: spec.hardwareModel,
            platformModel: platformModel,
            zdkSdkId: sameHardware ? existing?.zdkSdkId : nil,
            deviceIdentifier: validStoredDevId.isEmpty ? nil : validStoredDevId,
            deviceIdentifierExpiresAtMs: validStoredDevId.isEmpty ? nil : storedExp
        )
        if existing != updatedRecord {
            store.save(updatedRecord)
        }

        return ZolaDeviceIdentity(
            idfa: idfa,
            zcid: zcid,
            deviceIdentifier: validStoredDevId,
            model: platformModel,
            deviceName: spec.deviceName,
            width: spec.width,
            height: spec.height,
            vendorId: vendorId,
            hardwareModel: spec.hardwareModel,
            scale: spec.scale
        )
    }
}

public struct ZolaLoginConfig: Sendable {
    public var apiKey: String
    public var apiSecret: String
    public var baseURL: String
    public var passwordKeyPrefix: String
    public var clientType: Int
    public var clientVersion: Int
    public var zdkBaseURL: String
    public var enableZDKMintingOnCustomTransport: Bool

    public init(
        apiKey: String = ZolaConstants.defaultApiKey,
        apiSecret: String = ZolaConstants.defaultApiSecret,
        baseURL: String = ZolaConstants.defaultRegisterHost,
        passwordKeyPrefix: String = "2c55197a0a52c30a16def06d5681b7b3",
        clientType: Int = ZolaConstants.clientTypeIOS,
        clientVersion: Int = ZolaConstants.clientVersionIOS,
        zdkBaseURL: String = "https://centralized.zaloapp.com",
        enableZDKMintingOnCustomTransport: Bool = false
    ) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.baseURL = baseURL
        self.passwordKeyPrefix = passwordKeyPrefix
        self.clientType = clientType
        self.clientVersion = clientVersion
        self.zdkBaseURL = zdkBaseURL
        self.enableZDKMintingOnCustomTransport = enableZDKMintingOnCustomTransport
    }
}

public struct ZolaLoginResult: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userId: Int64
    public let token: String
    public let sessionKey: String
    public let zcid: String
    public let cryptKey: Data
    public let displayName: String
    public let avatarUrl: String
    public let sendToMeId: Int64
    /// WPA service hosts assigned by Zalo (`zpw_service_map_v3`), service key -> base URL.
    public let serviceHosts: [String: String]
    /// `SocketEntity` endpoints from `data.socketServers` (socket channel `2001`).
    public let socketServers: [ZolaSocketServer]
    /// `EncryptProtocolVer2` key material from `data.keySet` (`keySetId`/`keySetValue`).
    public let keySetId: String?
    public let keySetValue: String?
    /// `AuthenV3Aes` ids (`aesPublicId`/`aesPrivateId`, valid when `>= 1`).
    public let aesPublicId: Int64?
    public let aesPrivateId: Int64?
    /// Normalized E.164 phone (`+84...`) used during login (paired with `token` for `/api/helper/getKeySet?`). Secret — never log.
    public let loginPhone: String?

    public init(
        userId: Int64,
        token: String,
        sessionKey: String,
        zcid: String,
        cryptKey: Data = Data(),
        displayName: String = "",
        avatarUrl: String = "",
        sendToMeId: Int64 = 0,
        serviceHosts: [String: String] = [:],
        socketServers: [ZolaSocketServer] = [],
        keySetId: String? = nil,
        keySetValue: String? = nil,
        aesPublicId: Int64? = nil,
        aesPrivateId: Int64? = nil,
        loginPhone: String? = nil
    ) {
        self.userId = userId
        self.token = token
        self.sessionKey = sessionKey
        self.zcid = zcid
        self.cryptKey = cryptKey
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.sendToMeId = sendToMeId
        self.serviceHosts = serviceHosts
        self.socketServers = socketServers
        self.keySetId = keySetId
        self.keySetValue = keySetValue
        self.aesPublicId = aesPublicId
        self.aesPrivateId = aesPrivateId
        let trimmedPhone = loginPhone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.loginPhone = trimmedPhone.isEmpty ? nil : trimmedPhone
    }

    public var hasValidKeySet: Bool {
        guard let ksId = keySetId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ksId.isEmpty,
              ksId != "0",
              ksId.utf8.count <= 255,
              let ksVal = keySetValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decoded = Data(base64Encoded: ksVal),
              decoded.count == 32
        else {
            return false
        }
        return true
    }

    public var description: String {
        let skFp = sessionKey.isEmpty ? "none" : ZolaCrypto.sha256Hex8(Data(sessionKey.utf8))
        let ckFp = cryptKey.isEmpty ? "none" : ZolaCrypto.sha256Hex8(cryptKey)
        return "ZolaLoginResult(userId=\(userId), sk_sha256_8='\(skFp)', ck_sha256_8='\(ckFp)', socketServers=\(socketServers.count))"
    }

    public var debugDescription: String { description }
}

/// Supported verification methods when a login challenge or new-device check occurs.
public enum ZolaVerificationMethod: String, Sendable, Equatable, Codable {
    case callOrSms
    case recentDevice

    public var zotpOption: Int {
        switch self {
        case .callOrSms:
            return 0
        case .recentDevice:
            return 1
        }
    }
}

public struct ZolaLoginChallenge: Sendable, Equatable {
    public let fields: [String]
    public let sessionToken: String?
    public let verificationToken: String?
    public let pwdToken: String?
    public let activationToken: String?
    public let activationType: Int?
    public let method: ZolaVerificationMethod?
    public let isForgotPassword: Bool
    public let errorCode: Int?
    public let errorMessage: String?
    public let otpLength: Int?
    public let smsGateway: String?
    public let smsContentHint: String?
    public let smsFormat: String?
    public let timeoutSeconds: Int?
    public let title: String?

    public init(
        fields: [String],
        sessionToken: String? = nil,
        verificationToken: String? = nil,
        pwdToken: String? = nil,
        activationToken: String? = nil,
        activationType: Int? = nil,
        otpLength: Int? = nil,
        smsGateway: String? = nil,
        smsContentHint: String? = nil,
        smsFormat: String? = nil,
        timeoutSeconds: Int? = nil,
        title: String? = nil,
        method: ZolaVerificationMethod? = nil,
        isForgotPassword: Bool = false,
        errorCode: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.fields = fields
        self.sessionToken = sessionToken
        self.verificationToken = verificationToken
        self.pwdToken = pwdToken
        self.activationToken = activationToken
        self.activationType = activationType
        self.method = method
        self.isForgotPassword = isForgotPassword
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.otpLength = otpLength
        self.smsGateway = smsGateway
        self.smsContentHint = smsContentHint
        self.smsFormat = smsFormat
        self.timeoutSeconds = timeoutSeconds
        self.title = title
    }

    public var requiresSmsGateway: Bool {
        let gw = smsGateway?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hint = smsContentHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fmt = smsFormat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !gw.isEmpty && (!hint.isEmpty || !fmt.isEmpty)
    }

    public var smsKeyword: String {
        let fmt = smsFormat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fmt.isEmpty { return fmt }
        let hint = smsContentHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !hint.isEmpty && hint.count <= 24 && !hint.contains("\n") {
            return hint
        }
        return "ZALO"
    }

    public var smsComposeURL: URL? {
        let gw = smsGateway?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !gw.isEmpty else { return nil }
        let bodyKeyword = smsKeyword
        if bodyKeyword.isEmpty {
            return URL(string: "sms:\(gw)")
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        let encoded = bodyKeyword.addingPercentEncoding(withAllowedCharacters: allowed) ?? bodyKeyword
        return URL(string: "sms:\(gw)&body=\(encoded)")
    }
}

/// Result of requesting an OTP/activation code via SMS/Call or a recently logged-in device.
public struct ZolaVerificationRequestResult: Sendable, Equatable {
    public let sent: Bool
    public let challenge: ZolaLoginChallenge
    public let errorCode: Int?
    public let errorMessage: String?
    public let deliveryMessage: String
    public let secureVerification: ZolaSecureVerification?

    public init(
        sent: Bool,
        challenge: ZolaLoginChallenge,
        errorCode: Int? = nil,
        errorMessage: String? = nil,
        deliveryMessage: String,
        secureVerification: ZolaSecureVerification? = nil
    ) {
        self.sent = sent
        self.challenge = challenge
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.deliveryMessage = deliveryMessage
        self.secureVerification = secureVerification
    }
}

/// Outcome of a password login attempt.
public enum ZolaLoginOutcome: Sendable, Equatable {
    case success(ZolaLoginResult)
    /// Zalo requires additional verification (OTP / recent device / call).
    case challenge(fields: [String], errorCode: Int?, errorMessage: String?)
    /// Server requires the H5 `VerificationCenter` page (`error_code = 2048`, `_processH5QuestionRequiredWith:completion:`).
    case secureVerification(ZolaSecureVerification)
    /// Server rejected the attempt (e.g. 2026 Invalid client, wrong password).
    case rejected(errorCode: Int?, errorMessage: String?, rawPreview: String)
}

/// H5 security check issued with `error_code = 2048`: `data.{secureUrl, sessionToken, pwd_token}`.
/// Zalo iOS loads `secureUrl` in `VerificationCenterViewController` (0x1023503d4) and waits for the page to report back.
public struct ZolaSecureVerification: Sendable, Equatable, Identifiable {
    public let secureUrl: String
    public let sessionToken: String?
    public let pwdToken: String?
    public let errorCode: Int

    public var id: String { secureUrl }

    public init(secureUrl: String, sessionToken: String? = nil, pwdToken: String? = nil, errorCode: Int = 2048) {
        self.secureUrl = secureUrl
        self.sessionToken = sessionToken
        self.pwdToken = pwdToken
        self.errorCode = errorCode
    }

    /// Cookies the page expects, from `makeThirdPartyCookiesFromAuthenticationInfo:` (0x100e99038):
    /// `zacc_session` carries `sessionToken`, `zlink3rd` carries `secureUrl`, both on the URL host for 21 days.
    public func webCookies(now: Date = Date()) -> [HTTPCookie] {
        guard let sessionToken, !sessionToken.isEmpty, let host = URL(string: secureUrl)?.host else { return [] }
        let expires = now.addingTimeInterval(1_814_400)
        return [("zacc_session", sessionToken), ("zlink3rd", secureUrl)].compactMap { name, value in
            HTTPCookie(properties: [
                .domain: host,
                .path: "/",
                .name: name,
                .value: value,
                .expires: expires,
            ])
        }
    }
}

/// Result the H5 page posts through the `jsCall` bridge handler with action `action.open.account.verification`.
/// Native reads `options.error_code` and `options.data.{verificationToken, verificationType}` (0x102325030).
public struct ZolaSecureVerificationResult: Sendable, Equatable {
    public static let bridgeAction = "action.open.account.verification"

    public let errorCode: Int
    public let verificationToken: String
    public let verificationType: Int
    public let pwdToken: String?

    public init(errorCode: Int = 0, verificationToken: String, verificationType: Int, pwdToken: String? = nil) {
        self.errorCode = errorCode
        self.verificationToken = verificationToken
        self.verificationType = verificationType
        self.pwdToken = pwdToken
    }

    /// Parses a bridge message. Nested values may arrive as JSON strings depending on how the page serializes them.
    public static func parse(bridgeMessage: [String: Any]) -> ZolaSecureVerificationResult? {
        let options = dictionary(bridgeMessage["options"]) ?? dictionary(bridgeMessage["data"]) ?? bridgeMessage
        let data = dictionary(options["data"]) ?? options
        guard options["error_code"] != nil || data["verificationToken"] != nil else { return nil }
        return ZolaSecureVerificationResult(
            errorCode: options["error_code"].map { ZolaJSON.int($0) } ?? 0,
            verificationToken: ZolaJSON.string(data["verificationToken"]).trimmingCharacters(in: .whitespacesAndNewlines),
            verificationType: data["verificationType"].map { ZolaJSON.int($0) } ?? 0,
            pwdToken: ZolaJSON.firstNonEmptyString(data["pwdToken"], data["pwd_token"]).nilIfEmpty
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let text = value as? String, let raw = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Int64 {
    var clampedToInt: Int { Int(clamping: self) }
}

/// Mobile authentication client handling client verification (`verifyClientInfo`), password authentication (`activeAccountByPassword` / `activePasswordWithQuestion`), OTP activation (`getActivationCode` / `activeAccountByActivationCode`), account verification (`verifyAccount`), and session hydration (`doLogin`).
public actor ZolaLoginClient {
    public static let otpChallengeErrorCodes: Set<Int> = [2012, 2021, 2034, 2037]
    public static let verificationRequiredErrorCodes: Set<Int> = [2012, 2021, 2034, 2036, 2037, 2048]
    public static let expiredVerificationCodeMessage = "Mã xác minh đã hết hạn hoặc đã được thay bằng mã mới. Hãy bấm \"Gửi lại mã\" rồi nhập mã mới nhất."
    public static let wrongVerificationCodeMessage = "Mã xác minh không đúng. Vui lòng kiểm tra và thử lại."
    public static let securityQuestionRequiredMessage = "Tài khoản yêu cầu trả lời câu hỏi bảo mật trên ứng dụng Zalo chính thức."
    public static let securityWebCheckRequiredMessage = "Zalo yêu cầu xác minh bảo mật trực tiếp trên ứng dụng Zalo chính thức trước khi đăng nhập."
    public static let secureVerificationFailedMessage = "Xác minh bảo mật chưa hoàn tất. Vui lòng thử lại."
    public static let reactivationRequiredMessage = "Vì lý do bảo mật, Zalo cần xác minh lại số điện thoại này. Vui lòng chọn phương thức nhận mã bên dưới."
    public static let sessionKeysMissingMessage = "Chưa lấy được khoá phiên từ Zalo. Vui lòng đăng nhập lại."
    public static let otpQuotaExceededMessage = "Đã vượt quá số lần nhận mã xác minh trong ngày. Vui lòng thử lại sau."

    private static let zdkSdkVersion = "4.3.0730"
    private static let zdkAppId = "0"
    private static let zdkBundleId = "vn.com.vng.zingalo"
    private static let zdkAppVersion = "261002"
    private static let zdkSecretKey = "@#centralize#@"

    private let config: ZolaLoginConfig
    private let identity: ZolaDeviceIdentity
    private let identityStore: ZolaDeviceIdentityStore?
    private let urlSession: URLSession
    private let customTransport: ZolaNetworkTransport?
    private var resolvedDeviceIdentifier: String
    private var lastChallenge: ZolaLoginChallenge?
    private var diagnosticLines: [String] = []

    public init(
        config: ZolaLoginConfig = .init(),
        identity: ZolaDeviceIdentity? = nil,
        identityStore: ZolaDeviceIdentityStore? = nil,
        transport: ZolaNetworkTransport? = nil
    ) {
        self.config = config
        if let identity {
            self.identity = identity
            self.identityStore = identityStore
            self.resolvedDeviceIdentifier = identity.deviceIdentifier
        } else {
            let resolvedStore = identityStore ?? .shared
            let current = ZolaDeviceIdentity.currentDevice(store: resolvedStore)
            self.identity = current
            self.identityStore = resolvedStore
            self.resolvedDeviceIdentifier = current.deviceIdentifier
        }
        self.customTransport = transport
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.httpAdditionalHeaders = [:]
        self.urlSession = URLSession(configuration: cfg)
    }

    /// Recent auth responses for support: endpoint, HTTP status, error code and `data` key names only, never values.
    public func diagnostics() -> [String] {
        diagnosticLines
    }

    private func recordDiagnostic(path: String, status: Int, obj: [String: Any]?) {
        var line = "\(Int64(Date().timeIntervalSince1970)) \(path) http=\(status)"
        if let ec = obj?["error_code"] {
            line += " ec=\(ZolaJSON.int(ec))"
        }
        if let data = obj?["data"] as? [String: Any] {
            line += " keys=\(data.keys.sorted().joined(separator: ","))"
            let secureUrl = ZolaJSON.firstNonEmptyString(data["secureUrl"], data["secure_url"])
            if let host = URL(string: secureUrl)?.host {
                line += " host=\(host)"
            }
        } else if let raw = obj?["data"] {
            line += " dataType=\(type(of: raw))"
        }
        diagnosticLines.append(line)
        if diagnosticLines.count > 30 {
            diagnosticLines.removeFirst(diagnosticLines.count - 30)
        }
    }

    public func latestChallenge() -> ZolaLoginChallenge? {
        lastChallenge
    }

    public func currentIdentity() -> ZolaDeviceIdentity {
        var copy = identity
        copy.deviceIdentifier = resolvedDeviceIdentifier
        return copy
    }

    // MARK: - ZDK `2001.*` Device Identifier Minting (`ZDKDeviceTracker` `0x104affd70` / `0x104b03f00`)

    /// Ensures a genuine `2001.*` `device_identifier` is minted and cached via `centralized.zaloapp.com`
    /// (`/sdk/mobile/ios` → `/id/mobile/ios`) matching `ZDKDeviceTracker` in Zalo iOS 261002.
    public func ensureDeviceIdentifier() async -> String {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var expiredPreviousSid: String? = nil
        if !resolvedDeviceIdentifier.isEmpty {
            if let record = identityStore?.load(),
               let exp = record.deviceIdentifierExpiresAtMs,
               exp > 0,
               exp <= nowMs + 60_000 {
                // Token in store has expired; clear immediately so network errors never return an expired token.
                expiredPreviousSid = resolvedDeviceIdentifier
                resolvedDeviceIdentifier = ""
                persistDeviceMetadata(zdkSdkId: nil, deviceIdentifier: nil, expiresAtMs: nil, clearDeviceIdentifier: true)
            } else {
                return resolvedDeviceIdentifier
            }
        }

        if let record = identityStore?.load(),
           let storedDevId = record.deviceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedDevId.isEmpty {
            if let exp = record.deviceIdentifierExpiresAtMs, exp > 0, exp <= nowMs + 60_000 {
                expiredPreviousSid = storedDevId
                persistDeviceMetadata(zdkSdkId: nil, deviceIdentifier: nil, expiresAtMs: nil, clearDeviceIdentifier: true)
            } else {
                resolvedDeviceIdentifier = storedDevId
                return storedDevId
            }
        }

        guard customTransport == nil || config.enableZDKMintingOnCustomTransport else {
            return resolvedDeviceIdentifier
        }

        let base = config.zdkBaseURL.hasSuffix("/") ? String(config.zdkBaseURL.dropLast()) : config.zdkBaseURL
        let storedRecord = identityStore?.load()
        var sdkId = storedRecord?.zdkSdkId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hadCachedSdkId = !sdkId.isEmpty
        let existingSid = (storedRecord?.deviceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? expiredPreviousSid
            ?? ""

        let platformParts = identity.model.components(separatedBy: "_@")
        let osv = (platformParts.count >= 2 ? platformParts[1] : ZolaConstants.defaultIOSVersion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hwModel = identity.hardwareModel.isEmpty ? "iPhone17,1" : identity.hardwareModel
        let screenSize = "\(identity.width)x\(identity.height)"
        let deviceDict: [String: Any] = [
            "dId": identity.vendorId,
            "mod": hwModel,
        ]
        guard let deviceJsonData = try? JSONSerialization.data(withJSONObject: deviceDict, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return resolvedDeviceIdentifier
        }
        let deviceJson = String(decoding: deviceJsonData, as: UTF8.self)
        let ua = ZolaCrypto.userAgent(forZCID: identity.zcid, scale: identity.scale)

        func registerZDKSdk() async -> String {
            guard let sdkURL = URL(string: "\(base)/sdk/mobile/ios") else { return "" }
            let sdkBody = [
                "pl=ios",
                "appId=\(Self.formEncode(Self.zdkAppId))",
                "sdkv=\(Self.formEncode(Self.zdkSdkVersion))",
                "osv=\(Self.formEncode(osv))",
                "model=\(Self.formEncode(hwModel))",
                "screenSize=\(Self.formEncode(screenSize))",
                "device=\(Self.formEncode(deviceJson))",
            ].joined(separator: "&")
            var sdkReq = URLRequest(url: sdkURL)
            sdkReq.httpMethod = "POST"
            sdkReq.httpBody = Data(sdkBody.utf8)
            sdkReq.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            sdkReq.setValue("*/*", forHTTPHeaderField: "Accept")
            sdkReq.setValue(ua, forHTTPHeaderField: "User-Agent")

            guard let sdkObj = await executeZDKJSONRequest(sdkReq) else { return "" }
            let sdkData = sdkObj["data"] as? [String: Any]
            let fetchedSdkId = ZolaJSON.firstNonEmptyString(sdkData?["sdkId"], sdkObj["sdkId"])
            if !fetchedSdkId.isEmpty {
                persistDeviceMetadata(zdkSdkId: fetchedSdkId, deviceIdentifier: nil, expiresAtMs: nil)
            }
            return fetchedSdkId
        }

        enum MintOutcome {
            case minted
            case serverRejected
            case networkError
        }

        func mintDeviceId(using activeSdkId: String) async -> MintOutcome {
            guard !activeSdkId.isEmpty, let idURL = URL(string: "\(base)/id/mobile/ios") else {
                return .networkError
            }
            let isPad = hwModel.lowercased().hasPrefix("ipad")
            let tzOffsetHours = TimeZone.current.secondsFromGMT() / 3600
            let tzStr = tzOffsetHours >= 0 ? "+\(tzOffsetHours)" : "\(tzOffsetHours)"
            let dataDict: [String: Any] = [
                "adId": identity.idfa,
                "av": Self.zdkAppVersion,
                "bId": Self.zdkBundleId,
                "dId": identity.vendorId,
                "dIdType": "advertiserId",
                "dev_type": isPad ? "tablet" : "mobile",
                "dpi": identity.scale,
                "lang": "vi",
                "lat": 0,
                "lng": 0,
                "mnft": "Apple",
                "mod": hwModel,
                "osv": osv,
                "sId": existingSid,
                "ss": screenSize,
                "tz": tzStr,
            ]
            guard let dataJsonBytes = try? JSONSerialization.data(withJSONObject: dataDict, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return .networkError
            }
            let dataJson = String(decoding: dataJsonBytes, as: UTF8.self)
            let tsStr = String(Int64(Date().timeIntervalSince1970 * 1000))
            let sigParams: [String: String] = [
                "pl": "ios",
                "appId": Self.zdkAppId,
                "device": deviceJson,
                "data": dataJson,
                "viewer": "",
                "ts": tsStr,
                "sdkId": activeSdkId,
            ]
            let sig = ZolaCrypto.makeSignature(params: sigParams, apiSecret: Self.zdkSecretKey)
            let idBody = [
                "pl=ios",
                "appId=\(Self.formEncode(Self.zdkAppId))",
                "device=\(Self.formEncode(deviceJson))",
                "data=\(Self.formEncode(dataJson))",
                "viewer=",
                "ts=\(Self.formEncode(tsStr))",
                "sig=\(Self.formEncode(sig))",
                "sdkId=\(Self.formEncode(activeSdkId))",
            ].joined(separator: "&")

            var idReq = URLRequest(url: idURL)
            idReq.httpMethod = "POST"
            idReq.httpBody = Data(sdkBodyOrIdBody(idBody).utf8)
            idReq.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            idReq.setValue("*/*", forHTTPHeaderField: "Accept")
            idReq.setValue(ua, forHTTPHeaderField: "User-Agent")

            guard let idObj = await executeZDKJSONRequest(idReq) else { return .networkError }
            let idData = idObj["data"] as? [String: Any]
            let mintedDevId = ZolaJSON.firstNonEmptyString(idData?["deviceId"], idData?["device_id"], idObj["deviceId"])
            guard !mintedDevId.isEmpty else { return .serverRejected }
            let rawExp = ZolaJSON.int64(idData?["expire"] ?? idData?["expires"] ?? idObj["expire"])
            let expiresAtMs: Int64? = rawExp > 0 ? (rawExp < 10_000_000_000 ? rawExp * 1000 : rawExp) : nil
            resolvedDeviceIdentifier = mintedDevId
            persistDeviceMetadata(zdkSdkId: activeSdkId, deviceIdentifier: mintedDevId, expiresAtMs: expiresAtMs)
            return .minted
        }

        func sdkBodyOrIdBody(_ s: String) -> String { s }

        if sdkId.isEmpty {
            sdkId = await registerZDKSdk()
        }
        guard !sdkId.isEmpty else {
            return resolvedDeviceIdentifier
        }
        let outcome = await mintDeviceId(using: sdkId)
        if outcome == .minted {
            return resolvedDeviceIdentifier
        }
        // Only clear a cached `sdkId` when `/id/mobile/ios` actually rejected it (not on transient network drops).
        if hadCachedSdkId && outcome == .serverRejected {
            persistDeviceMetadata(zdkSdkId: nil, deviceIdentifier: nil, expiresAtMs: nil, clearZdkSdkId: true)
            let refreshedSdkId = await registerZDKSdk()
            if !refreshedSdkId.isEmpty {
                _ = await mintDeviceId(using: refreshedSdkId)
            }
        }
        return resolvedDeviceIdentifier
    }

    private func executeZDKJSONRequest(_ req: URLRequest) async -> [String: Any]? {
        do {
            let raw: Data
            if let customTransport {
                (_, raw) = try await customTransport.execute(req)
            } else {
                (raw, _) = try await urlSession.data(for: req)
            }
            let body = ZolaRequestBuilder.gunzipDecompress(raw) ?? raw
            return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func persistDeviceMetadata(
        zdkSdkId: String?,
        deviceIdentifier: String?,
        expiresAtMs: Int64?,
        clearDeviceIdentifier: Bool = false,
        clearZdkSdkId: Bool = false
    ) {
        guard let identityStore else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var rec = identityStore.load() ?? ZolaStoredDeviceRecord(
            idfa: identity.idfa,
            vendorId: identity.vendorId,
            zcid: identity.zcid,
            zcidTimestampMs: nowMs,
            hardwareModel: identity.hardwareModel,
            platformModel: identity.model
        )
        if clearZdkSdkId {
            rec.zdkSdkId = nil
        } else if let zdkSdkId, !zdkSdkId.isEmpty {
            rec.zdkSdkId = zdkSdkId
        }
        if clearDeviceIdentifier {
            rec.deviceIdentifier = nil
            rec.deviceIdentifierExpiresAtMs = nil
        } else {
            if let deviceIdentifier, !deviceIdentifier.isEmpty {
                rec.deviceIdentifier = deviceIdentifier
            }
            if let expiresAtMs, expiresAtMs > 0 {
                rec.deviceIdentifierExpiresAtMs = expiresAtMs
            }
        }
        identityStore.save(rec)
    }

    // MARK: - Public API

    /// Full login: normalise phone → precheck (or reuse sessionToken) → password login.
    public func login(
        phone rawPhone: String,
        password: String,
        existingSessionToken: String? = nil,
        sourceSwitch: Int = 0
    ) async throws -> ZolaLoginOutcome {
        let phone = try Self.normalizePhone(rawPhone)
        guard !password.isEmpty else { throw ZolaError.invalidArgument("Password must not be empty") }

        let token: String
        let devid: String
        if let existing = existingSessionToken, !existing.isEmpty {
            token = existing
            devid = await ensureDeviceIdentifier()
        } else {
            let pre = try await precheck(phone: phone, sourceSwitch: sourceSwitch)
            guard let minted = pre.sessionToken, !minted.isEmpty else {
                if let secure = pre.secureVerification {
                    return .secureVerification(secure)
                }
                return .rejected(
                    errorCode: pre.errorCode,
                    errorMessage: pre.errorMessage,
                    rawPreview: String(pre.rawPreview.prefix(400))
                )
            }
            token = minted
            devid = pre.deviceIdentifier ?? resolvedDeviceIdentifier
        }
        return try await passwordLogin(
            phone: phone,
            password: password,
            sessionToken: token,
            deviceIdentifier: devid,
            sourceSwitch: sourceSwitch
        )
    }

    public struct PrecheckResult: Sendable {
        public let httpStatus: Int
        public let sessionToken: String?
        public let deviceIdentifier: String?
        public let errorCode: Int?
        public let errorMessage: String?
        public let rawPreview: String
        public var secureVerification: ZolaSecureVerification? = nil
    }

    /// Native reports this device's real storage in `log_disk` (0x101385398).
    private nonisolated static func diskUsageLog() -> [String: Int] {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let megabytes: (FileAttributeKey) -> Int = { key in
            ((attributes?[key] as? NSNumber)?.int64Value ?? 0).quotientAndRemainder(dividingBy: 1_048_576).quotient.clampedToInt
        }
        return ["free_MB": megabytes(.systemFreeSize), "total_MB": megabytes(.systemSize)]
    }

    /// Builds the standard client verification parameter dictionary required by `POST /api/register/verifyClientInfo`.
    public nonisolated func makePrecheckInnerPayload(
        phone: String,
        nowMs: Int64,
        sourceSwitch: Int = 0,
        captchaValue: String = "",
        captchaToken: String = "",
        deviceIdentifierOverride: String? = nil
    ) -> [String: Any] {
        [
            "type": config.clientType,
            "client_type": config.clientType,
            "client_version": config.clientVersion,
            "distributor": "iAPP",
            "width": identity.width,
            "height": identity.height,
            "heap": 314,
            "time_zone": "+07:00",
            "language": "vi",
            "user_language": "vi",
            "iso_country_code": "VN",
            "local_time": "\(nowMs).000000",
            "network": 1,
            "operator": "",
            "imei": identity.idfa,
            "advertising_id": identity.idfa,
            "jailbroken": "0",
            "model": identity.model,
            "device_name": identity.deviceName,
            "zcid": identity.zcid,
            "device_identifier": deviceIdentifierOverride ?? identity.deviceIdentifier,
            "phone_num": phone,
            "captcha_value": captchaValue,
            "captcha_token": captchaToken,
            "source_action": sourceSwitch > 0 ? 1 : 0,
            "source_switch": sourceSwitch,
            "src_type": 1,
            "fresh_install": 1,
            "api_key": config.apiKey,
            "v": "3.0",
            "error_code_fallback": "1",
            "call_id": String(nowMs),
            "encryptParams": true,
        ]
    }

    /// Step 1: POST /api/register/verifyClientInfo (no password).
    /// When the server responds with `error_code = 2060` (`Required captcha`), automatically resolves
    /// the slide-captcha challenge (`zmcaptcha.zaloapp.com`) and re-invokes `verifyClientInfo` with `captcha_token`
    /// so that a verified `zk000.*` `sessionToken` is issued.
    public func precheck(phone rawPhone: String, sourceSwitch: Int = 0) async throws -> PrecheckResult {
        let phone = try Self.normalizePhone(rawPhone)
        let activeDevId = await ensureDeviceIdentifier()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let inner = makePrecheckInnerPayload(
            phone: phone,
            nowMs: now,
            sourceSwitch: sourceSwitch,
            deviceIdentifierOverride: activeDevId
        )
        var (status, obj, text) = try await postForm(path: "/api/register/verifyClientInfo", inner: inner)

        let initialEc = (obj?["error_code"]).map { ZolaJSON.int($0) }
        let initialData = obj?["data"] as? [String: Any]
        let secureUrl = ZolaJSON.string(initialData?["secureUrl"] ?? initialData?["secure_url"])
        // Only the slide captcha is solved here: `2036` / `2048` carry their own flows.
        if initialEc != 2036, initialEc != 2048, (initialEc == 2060 || !secureUrl.isEmpty), customTransport == nil {
            let captchaSession = Self.extractCaptchaSession(from: initialData, secureUrl: secureUrl)
            if !captchaSession.isEmpty,
               let verifiedCaptchaToken = await resolveSlideCaptcha(session: captchaSession, secureUrl: secureUrl) {
                let retryNow = Int64(Date().timeIntervalSince1970 * 1000)
                let retryInner = makePrecheckInnerPayload(
                    phone: phone,
                    nowMs: retryNow,
                    sourceSwitch: sourceSwitch,
                    captchaValue: "",
                    captchaToken: verifiedCaptchaToken,
                    deviceIdentifierOverride: activeDevId
                )
                (status, obj, text) = try await postForm(path: "/api/register/verifyClientInfo", inner: retryInner)
            }
        }

        let finalEc = (obj?["error_code"]).map { ZolaJSON.int($0) }
        let blob = (obj.flatMap { try? JSONSerialization.data(withJSONObject: $0) }).map { String(decoding: $0, as: UTF8.self) } ?? text
        let searchable = blob + "\n" + text
        // Never treat an unverified 2060 captcha session ID ("Ubyy...") as a valid login sessionToken.
        // `data.sessionToken` of a `2048` response belongs to the H5 page, not to the password step.
        let token = (finalEc == 2060 || finalEc == 2048) ? nil : Self.extractPrecheckSessionToken(from: obj, searchable: searchable)
        if let serverDevId = Self.firstMatch(in: searchable, pattern: "2001\\.[0-9A-Za-z._+/-]+"),
           !serverDevId.isEmpty {
            resolvedDeviceIdentifier = serverDevId
            persistDeviceMetadata(zdkSdkId: nil, deviceIdentifier: serverDevId, expiresAtMs: nil)
        }
        let devid = resolvedDeviceIdentifier
        let rawDump = obj.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? text
        let rawPrecheckError = (obj?["error_message"]).map { ZolaJSON.string($0) }
        let localizedPrecheckError: String?
        if let finalEc, finalEc != 0 {
            if finalEc == 2003 {
                localizedPrecheckError = "Phiên kiểm tra đã hết hạn. Vui lòng thử lại."
            } else {
                localizedPrecheckError = Self.localizedAuthErrorMessage(code: finalEc, rawMessage: rawPrecheckError) ?? rawPrecheckError
            }
        } else {
            localizedPrecheckError = rawPrecheckError
        }
        return PrecheckResult(
            httpStatus: status,
            sessionToken: token,
            deviceIdentifier: devid,
            errorCode: finalEc,
            errorMessage: localizedPrecheckError,
            rawPreview: rawDump,
            secureVerification: finalEc == 2048 ? Self.secureVerification(from: obj?["data"] as? [String: Any]) : nil
        )
    }

    /// Step 2: Password login via `/api/register/activePasswordWithQuestion` with automatic fallback to `/api/register/activeAccountByPassword`.
    public func passwordLogin(
        phone rawPhone: String,
        password: String,
        sessionToken: String,
        deviceIdentifier: String,
        sourceSwitch: Int = 0
    ) async throws -> ZolaLoginOutcome {
        let phone = try Self.normalizePhone(rawPhone)
        let activeDevId = deviceIdentifier.isEmpty ? await ensureDeviceIdentifier() : deviceIdentifier
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var ckeysetBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<4 { ckeysetBytes[i] = UInt8.random(in: 0...255) }
        let ckeyset = Data(ckeysetBytes).base64EncodedString()
        let encryptedPassword = try encPassword(password, phone: phone)

        let baseInner: [String: Any] = [
            "source_switch": sourceSwitch,
            "session_token": sessionToken,
            "client_version": config.clientVersion,
            "client_type": config.clientType,
            "local_time": "\(now).000000",
            "inc_p": "1",
            "advertising_id": identity.idfa,
            "distributor": "iAPP",
            "zcid": identity.zcid,
            "call_id": String(now),
            "network": 1,
            "operator": "",
            "type": config.clientType,
            "activation_type": "1",
            "ckeyset": ckeyset,
            "jailbroken": "0",
            "encryptParams": true,
            "source_action": sourceSwitch > 0 ? 1 : 0,
            "device_identifier": activeDevId,
            "height": identity.height,
            "log_disk": Self.diskUsageLog(),
            "model": identity.model,
            "checkActiveCode": 1,
            "captcha_value": "",
            "captcha_token": "",
            "user_language": "vi",
            "iso_country_code": "VN",
            "time_zone": "+07:00",
            "protover": 1,
            "phone_num": phone,
            "api_key": config.apiKey,
            "fresh_install": 1,
            "v": "3.0",
            "error_code_fallback": "1",
            "language": "vi",
            "heap": 314,
            "imei": identity.idfa,
            "password": encryptedPassword,
            "width": identity.width,
            "device_name": identity.deviceName,
        ]

        // Primary password login endpoint (`/api/register/activePasswordWithQuestion`)
        var primaryInner = baseInner
        primaryInner["question_type"] = ""
        primaryInner["answer_type"] = ""
        primaryInner["answer_value"] = ""
        let (_, primaryObj, primaryText) = try await postForm(path: "/api/register/activePasswordWithQuestion", inner: primaryInner)
        let primaryOutcome = parseLoginResponse(obj: primaryObj, text: primaryText, sessionToken: sessionToken)
        switch primaryOutcome {
        case .success:
            return await enrichWithDoLoginIfNeeded(outcome: primaryOutcome, phone: phone, sessionToken: nil, deviceIdentifier: activeDevId)
        case .challenge, .secureVerification:
            return primaryOutcome
        case let .rejected(ec, _, _):
            // Only attempt fallback if the token was invalid (2003) or endpoint was not accepted
            guard ec == 2003 || ec == nil else {
                return primaryOutcome
            }
        }

        // Mint a fresh single-use session_token before calling the fallback endpoint
        let fallbackPre = try? await precheck(phone: phone, sourceSwitch: sourceSwitch)
        if let secure = fallbackPre?.secureVerification {
            return .secureVerification(secure)
        }
        guard let fallbackToken = fallbackPre?.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallbackToken.isEmpty else {
            return primaryOutcome
        }
        var fallbackInner = baseInner
        fallbackInner["session_token"] = fallbackToken
        fallbackInner["device_identifier"] = fallbackPre?.deviceIdentifier ?? activeDevId
        fallbackInner["activation_type"] = "1"
        let (_, obj, text) = try await postForm(path: "/api/register/activeAccountByPassword", inner: fallbackInner)
        let outcome = parseLoginResponse(obj: obj, text: text, sessionToken: fallbackToken)
        return await enrichWithDoLoginIfNeeded(outcome: outcome, phone: phone, sessionToken: nil, deviceIdentifier: fallbackPre?.deviceIdentifier ?? activeDevId)
    }

    /// Requests an OTP or device verification code via `/api/register/getActivationCode`
    /// for either `.callOrSms` (`zotp_opt = 0`) or `.recentDevice` (`zotp_opt = 1`).
    public func requestVerificationCode(
        phone rawPhone: String,
        method: ZolaVerificationMethod,
        existingChallenge: ZolaLoginChallenge? = nil,
        existingSessionToken: String? = nil,
        sourceSwitch: Int = 0
    ) async throws -> ZolaVerificationRequestResult {
        let phone = try Self.normalizePhone(rawPhone)
        let priorChallenge = existingChallenge ?? lastChallenge
        _ = existingSessionToken // Retained for public signature compatibility; never reuse a consumed/stale session_token.

        // Always mint a fresh single-use session_token from verifyClientInfo before calling getActivationCode,
        // because any previous session_token was already consumed or is unverified.
        let pre = try await precheck(phone: phone, sourceSwitch: sourceSwitch)
        let sessionToken = pre.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if sessionToken.isEmpty {
            let preMsg = Self.localizedAuthErrorMessage(code: pre.errorCode, rawMessage: pre.errorMessage)
                ?? "Chưa thể khởi tạo phiên nhận mã xác minh. Vui lòng thử lại."
            let preSecure = pre.secureVerification
            let failedChallenge = ZolaLoginChallenge(
                fields: priorChallenge?.fields ?? ["otp"],
                sessionToken: nil,
                verificationToken: priorChallenge?.verificationToken,
                pwdToken: priorChallenge?.pwdToken,
                activationToken: priorChallenge?.activationToken,
                activationType: priorChallenge?.activationType ?? (method == .recentDevice ? 6 : 1),
                otpLength: priorChallenge?.otpLength ?? 6,
                smsGateway: priorChallenge?.smsGateway,
                smsContentHint: priorChallenge?.smsContentHint,
                smsFormat: priorChallenge?.smsFormat,
                timeoutSeconds: priorChallenge?.timeoutSeconds,
                title: priorChallenge?.title,
                method: method,
                isForgotPassword: priorChallenge?.isForgotPassword ?? false,
                errorCode: pre.errorCode,
                errorMessage: pre.errorMessage
            )
            lastChallenge = failedChallenge
            return ZolaVerificationRequestResult(
                sent: false,
                challenge: failedChallenge,
                errorCode: pre.errorCode,
                errorMessage: pre.errorMessage,
                deliveryMessage: preMsg,
                secureVerification: preSecure
            )
        }

        let initialForgotPass = priorChallenge?.isForgotPassword ?? false
        let (obj, _, usedForgotPass, _) = try await performGetActivationCode(
            phone: phone,
            sessionToken: sessionToken,
            method: method,
            isForgotPassword: initialForgotPass,
            sourceSwitch: sourceSwitch
        )

        let ec = (obj?["error_code"]).map { ZolaJSON.int($0) }
        let em = (obj?["error_message"]).map { ZolaJSON.string($0) }
        let dataDict = obj?["data"] as? [String: Any]
        let zotpDict = dataDict?["zotp"] as? [String: Any]

        // Strictly extract only explicit activation tokens (`activationToken` / `activation_token`),
        // never confusing single-use `session_token` with the OTP submit token.
        let freshActivationToken = [
            dataDict?["activationToken"] as? String,
            dataDict?["activation_token"] as? String,
            zotpDict?["activationToken"] as? String,
            zotpDict?["activation_token"] as? String,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let activationToken: String?
        if let freshActivationToken {
            activationToken = freshActivationToken
        } else if ec == 2003 {
            activationToken = nil
        } else if let ec, ec != 0 {
            // Rate-limit / cooldown (`2006`, `2012`, `2021`, `2052`) keeps any previously issued valid activation token.
            activationToken = priorChallenge?.activationToken
        } else {
            activationToken = nil
        }

        let verifToken = [
            dataDict?["verificationToken"] as? String,
            dataDict?["verify_token"] as? String,
            zotpDict?["verificationToken"] as? String,
            zotpDict?["verify_token"] as? String,
            ec == 2003 ? nil : priorChallenge?.verificationToken,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let pwdTok = (dataDict?["pwd_token"] as? String) ?? priorChallenge?.pwdToken
        let actType = (dataDict?["activation_type"] ?? dataDict?["activationType"] ?? zotpDict?["activation_type"] ?? zotpDict?["activationType"]).map { ZolaJSON.int($0) }
            ?? priorChallenge?.activationType
            ?? (method == .recentDevice ? 6 : 1)
        let rawOtpLen = (dataDict?["activationNumber"] ?? dataDict?["activation_number"] ?? zotpDict?["activationNumber"] ?? zotpDict?["activation_number"]).map { ZolaJSON.int($0) }
        let otpLength = (rawOtpLen != nil && rawOtpLen! > 0) ? rawOtpLen! : (priorChallenge?.otpLength ?? 6)

        let freshSmsGateway = [
            ZolaJSON.string(dataDict?["sms_gateway"]),
            ZolaJSON.string(dataDict?["smsGateway"]),
            ZolaJSON.string(zotpDict?["sms_gateway"]),
            ZolaJSON.string(zotpDict?["smsGateway"]),
        ]
            .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let smsGateway = freshSmsGateway ?? ((ec == 2012 || ec == 2021) ? priorChallenge?.smsGateway : nil)

        let smsContentHint = [
            ZolaJSON.string(dataDict?["sms_content_hint"]),
            ZolaJSON.string(dataDict?["smsContentHint"]),
            ZolaJSON.string(zotpDict?["sms_content_hint"]),
            ZolaJSON.string(zotpDict?["smsContentHint"]),
            smsGateway != nil ? priorChallenge?.smsContentHint : nil,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let smsFormat = [
            ZolaJSON.string(dataDict?["sms_format"]),
            ZolaJSON.string(dataDict?["smsFormat"]),
            ZolaJSON.string(zotpDict?["sms_format"]),
            ZolaJSON.string(zotpDict?["smsFormat"]),
            smsGateway != nil ? priorChallenge?.smsFormat : nil,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let timeoutSeconds = (dataDict?["timeout"] ?? zotpDict?["timeout"]).map { ZolaJSON.int($0) } ?? priorChallenge?.timeoutSeconds
        let title = ((dataDict?["title"] ?? zotpDict?["title"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? priorChallenge?.title

        // Note: `sessionToken` (`otpRequestToken`) is single-use and was just consumed by `getActivationCode`.
        let updatedChallenge = ZolaLoginChallenge(
            fields: priorChallenge?.fields ?? ["otp"],
            sessionToken: nil,
            verificationToken: verifToken,
            pwdToken: pwdTok,
            activationToken: activationToken,
            activationType: actType,
            otpLength: otpLength,
            smsGateway: smsGateway,
            smsContentHint: smsContentHint,
            smsFormat: smsFormat,
            timeoutSeconds: timeoutSeconds,
            title: title,
            method: method,
            isForgotPassword: usedForgotPass,
            errorCode: ec,
            errorMessage: em
        )
        lastChallenge = updatedChallenge

        let isSmsGatewayChallenge = (ec == 2012 || ec == 2021)
            || ((ec == nil || ec == 0) && updatedChallenge.requiresSmsGateway)
        let isSuccess = (freshActivationToken != nil && (ec == nil || ec == 0)) || isSmsGatewayChallenge
        let deliveryMsg: String
        if isSmsGatewayChallenge {
            let gw = smsGateway ?? "8066"
            let keyword = updatedChallenge.smsKeyword
            if let hint = smsContentHint, hint.count > 24 {
                deliveryMsg = hint
            } else {
                let serverHint = (em?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                if let serverHint {
                    deliveryMsg = "\(serverHint)\nBấm nút \"Soạn tin nhắn SMS\" bên dưới để gửi cú pháp \"\(keyword)\" tới \(gw), sau đó nhập mã xác minh \(otpLength) chữ số nhận được."
                } else {
                    deliveryMsg = "Đã vượt giới hạn gửi mã tự động. Vui lòng bấm nút \"Soạn tin nhắn SMS\" bên dưới để gửi \"\(keyword)\" tới \(gw) nhận mã, rồi nhập \(otpLength) chữ số vào ô bên dưới."
                }
            }
        } else if isSuccess {
            switch method {
            case .callOrSms:
                deliveryMsg = "Đã gửi yêu cầu mã xác minh qua tin nhắn hoặc cuộc gọi đến số \(phone). Vui lòng nhập \(otpLength) chữ số bên dưới."
            case .recentDevice:
                deliveryMsg = "Đã gửi mã xác minh đến thiết bị Zalo đăng nhập gần đây. Vui lòng kiểm tra thông báo trên thiết bị đó và nhập \(otpLength) chữ số."
            }
        } else {
            deliveryMsg = Self.localizedAuthErrorMessage(code: ec, rawMessage: em)
                ?? "Chưa thể gửi mã xác minh tự động. Vui lòng thử lại hoặc chọn phương thức khác."
        }

        return ZolaVerificationRequestResult(
            sent: isSuccess,
            challenge: updatedChallenge,
            errorCode: ec,
            errorMessage: em,
            deliveryMessage: deliveryMsg,
            secureVerification: ec == 2048 ? Self.secureVerification(from: dataDict) : nil
        )
    }

    private func performGetActivationCode(
        phone: String,
        sessionToken: String,
        method: ZolaVerificationMethod,
        isForgotPassword: Bool,
        sourceSwitch: Int
    ) async throws -> ([String: Any]?, String, Bool, String) {
        let activeDevId = await ensureDeviceIdentifier()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var inner = makePrecheckInnerPayload(
            phone: phone,
            nowMs: now,
            sourceSwitch: sourceSwitch,
            deviceIdentifierOverride: activeDevId
        )
        inner.removeValue(forKey: "captcha_value")
        inner.removeValue(forKey: "captcha_token")
        inner["session_token"] = sessionToken
        inner["forget_password"] = isForgotPassword ? "1" : "0"
        inner["renew_account"] = "0"
        inner["zotp_opt"] = method.zotpOption

        var (_, obj, text) = try await postForm(path: "/api/register/getActivationCode", inner: inner)
        var currentToken = sessionToken
        var ec = (obj?["error_code"]).map { ZolaJSON.int($0) }

        let hasActivationPayload: ([String: Any]?) -> Bool = { payload in
            guard let d = payload?["data"] as? [String: Any] else { return false }
            let z = d["zotp"] as? [String: Any]
            let tok = ZolaJSON.firstNonEmptyString(
                d["activationToken"],
                d["activation_token"],
                z?["activationToken"],
                z?["activation_token"]
            )
            let gw = ZolaJSON.firstNonEmptyString(
                d["sms_gateway"],
                d["smsGateway"],
                z?["sms_gateway"],
                z?["smsGateway"]
            )
            return !tok.isEmpty || !gw.isEmpty
        }

        if ec == 0 || ec == 2012 || ec == 2021 || hasActivationPayload(obj) {
            return (obj, text, isForgotPassword, currentToken)
        }

        // If the server reports 2003 (Invalid token), mint a fresh session_token and retry once
        if ec == 2003,
           let pre = try? await precheck(phone: phone, sourceSwitch: sourceSwitch),
           let fresh = pre.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fresh.isEmpty,
           fresh != currentToken {
            currentToken = fresh
            let retryNow = Int64(Date().timeIntervalSince1970 * 1000)
            var retryInner = makePrecheckInnerPayload(
                phone: phone,
                nowMs: retryNow,
                sourceSwitch: sourceSwitch,
                deviceIdentifierOverride: pre.deviceIdentifier ?? activeDevId
            )
            retryInner.removeValue(forKey: "captcha_value")
            retryInner.removeValue(forKey: "captcha_token")
            retryInner["session_token"] = currentToken
            retryInner["forget_password"] = isForgotPassword ? "1" : "0"
            retryInner["renew_account"] = "0"
            retryInner["zotp_opt"] = method.zotpOption
            (_, obj, text) = try await postForm(path: "/api/register/getActivationCode", inner: retryInner)
            ec = (obj?["error_code"]).map { ZolaJSON.int($0) }
            if ec == 0 || ec == 2012 || ec == 2021 || hasActivationPayload(obj) {
                return (obj, text, isForgotPassword, currentToken)
            }
        }

        return (obj, text, isForgotPassword, currentToken)
    }

    private func clearExpiredChallengeTokens() {
        guard let current = lastChallenge else { return }
        lastChallenge = ZolaLoginChallenge(
            fields: current.fields,
            sessionToken: nil,
            verificationToken: nil,
            pwdToken: current.pwdToken,
            activationToken: nil,
            activationType: current.activationType,
            otpLength: current.otpLength,
            smsGateway: current.smsGateway,
            smsContentHint: current.smsContentHint,
            smsFormat: current.smsFormat,
            timeoutSeconds: current.timeoutSeconds,
            title: current.title,
            method: current.method,
            isForgotPassword: current.isForgotPassword,
            errorCode: 2003,
            errorMessage: Self.expiredVerificationCodeMessage
        )
    }

    /// Step 3: Submits the 6-digit verification code via `/api/register/activeAccountByActivationCode` and `/api/register/verifyAccount`.
    public func submitVerificationCode(
        phone rawPhone: String,
        password: String,
        code rawCode: String,
        challenge: ZolaLoginChallenge? = nil,
        existingSessionToken: String? = nil,
        sourceSwitch: Int = 0
    ) async throws -> ZolaLoginOutcome {
        let phone = try Self.normalizePhone(rawPhone)
        let trimmedCode = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw ZolaError.invalidArgument("Vui lòng nhập mã xác minh gồm 6 chữ số.")
        }

        let activeChallenge = challenge ?? lastChallenge
        if let challenge {
            lastChallenge = challenge
        }
        let actToken = activeChallenge?.activationToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialVerifToken = activeChallenge?.verificationToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var pwdTok = activeChallenge?.pwdToken

        // Step 3A: When an OTP/device `activationToken` is present, verify the 6-digit code via `activeAccountByActivationCode`.
        if !actToken.isEmpty {
            let activeDevId = await ensureDeviceIdentifier()
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var ckeysetBytes = [UInt8](repeating: 0, count: 8)
            for i in 0..<4 { ckeysetBytes[i] = UInt8.random(in: 0...255) }
            let ckeyset = Data(ckeysetBytes).base64EncodedString()

            var actInner = makePrecheckInnerPayload(
                phone: phone,
                nowMs: now,
                sourceSwitch: sourceSwitch,
                deviceIdentifierOverride: activeDevId
            )
            actInner.removeValue(forKey: "captcha_value")
            actInner.removeValue(forKey: "captcha_token")
            actInner["activation_value"] = trimmedCode
            actInner["activation_type"] = activeChallenge?.activationType ?? (activeChallenge?.method == .recentDevice ? 6 : 1)
            actInner["activation_token"] = actToken
            actInner["forget_password"] = (activeChallenge?.isForgotPassword ?? false) ? "1" : "0"
            actInner["renew_account"] = "0"
            actInner["displayname"] = ""
            actInner["ckeyset"] = ckeyset
            actInner["protover"] = 1
            actInner["log_disk"] = Self.diskUsageLog()
            actInner["fresh_install"] = 1

            let (_, actObj, actText) = try await postForm(path: "/api/register/activeAccountByActivationCode", inner: actInner)
            let actOutcome = parseLoginResponse(obj: actObj, text: actText, sessionToken: nil)
            if case .success = actOutcome {
                return await enrichWithDoLoginIfNeeded(
                    outcome: actOutcome,
                    phone: phone,
                    sessionToken: nil,
                    deviceIdentifier: activeDevId
                )
            }
            if case .secureVerification = actOutcome {
                // The server accepted this code, so it cannot be submitted a second time (`2002`).
                clearExpiredChallengeTokens()
                return actOutcome
            }

            let actEc = (actObj?["error_code"]).map { ZolaJSON.int($0) }
            if let actEc, actEc != 0 {
                let preview = String(actText.prefix(400))
                switch actEc {
                case 2002:
                    return .rejected(errorCode: actEc, errorMessage: Self.wrongVerificationCodeMessage, rawPreview: preview)
                case 2003:
                    clearExpiredChallengeTokens()
                    return .rejected(errorCode: actEc, errorMessage: Self.expiredVerificationCodeMessage, rawPreview: preview)
                default:
                    if let localized = Self.localizedAuthErrorMessage(code: actEc, rawMessage: (actObj?["error_message"]).map { ZolaJSON.string($0) }) {
                        return .rejected(errorCode: actEc, errorMessage: localized, rawPreview: preview)
                    }
                    return actOutcome
                }
            }

            let actData = actObj?["data"] as? [String: Any]
            let actZotp = actData?["zotp"] as? [String: Any]
            let explicitVerifToken = ZolaJSON.firstNonEmptyString(
                actData?["verificationToken"],
                actData?["verify_token"],
                actZotp?["verificationToken"],
                actZotp?["verify_token"]
            )
            let explicitFollowUpSessionToken = ZolaJSON.firstNonEmptyString(
                actData?["session_token"],
                actData?["sessionToken"],
                actZotp?["session_token"],
                actZotp?["sessionToken"]
            )
            let newPwd = ZolaJSON.firstNonEmptyString(actData?["pwd_token"], actData?["pwdToken"])
            if !newPwd.isEmpty {
                pwdTok = newPwd
            }

            let verifTokenToUse = !explicitVerifToken.isEmpty ? explicitVerifToken : initialVerifToken
            if !verifTokenToUse.isEmpty {
                return try await verifyAccount(
                    phone: phone,
                    password: password,
                    verificationToken: verifTokenToUse,
                    pwdToken: pwdTok,
                    activationCode: trimmedCode,
                    sessionToken: nil,
                    sourceSwitch: sourceSwitch,
                    activationType: activeChallenge?.activationType
                )
            }

            if !explicitFollowUpSessionToken.isEmpty, explicitFollowUpSessionToken != actToken {
                return try await passwordLogin(
                    phone: phone,
                    password: password,
                    sessionToken: explicitFollowUpSessionToken,
                    deviceIdentifier: activeDevId,
                    sourceSwitch: sourceSwitch
                )
            }

            // Never fall through to `/api/register/verifyAccount` without a genuine `verificationToken`.
            clearExpiredChallengeTokens()
            return .rejected(
                errorCode: 2003,
                errorMessage: Self.expiredVerificationCodeMessage,
                rawPreview: String(actText.prefix(400))
            )
        }

        // Step 3B: Direct `verifyAccount` path only when a genuine `verificationToken` is present.
        guard !initialVerifToken.isEmpty else {
            clearExpiredChallengeTokens()
            return .rejected(
                errorCode: 2003,
                errorMessage: Self.expiredVerificationCodeMessage,
                rawPreview: ""
            )
        }

        return try await verifyAccount(
            phone: phone,
            password: password,
            verificationToken: initialVerifToken,
            pwdToken: pwdTok,
            activationCode: trimmedCode,
            sessionToken: nil,
            sourceSwitch: sourceSwitch,
            activationType: activeChallenge?.activationType
        )
    }

    /// Step 3B: POST /api/register/verifyAccount (account verification step).
    public func verifyAccount(
        phone rawPhone: String,
        password: String,
        verificationToken: String,
        pwdToken: String? = nil,
        activationCode: String = "",
        sessionToken: String? = nil,
        sourceSwitch: Int = 0,
        activationType: Int? = nil
    ) async throws -> ZolaLoginOutcome {
        let phone = try Self.normalizePhone(rawPhone)
        let activeDevId = await ensureDeviceIdentifier()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var ckeysetBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<4 { ckeysetBytes[i] = UInt8.random(in: 0...255) }
        let ckeyset = Data(ckeysetBytes).base64EncodedString()

        var inner = makePrecheckInnerPayload(
            phone: phone,
            nowMs: now,
            sourceSwitch: sourceSwitch,
            deviceIdentifierOverride: activeDevId
        )
        inner.removeValue(forKey: "captcha_value")
        inner.removeValue(forKey: "captcha_token")
        inner["activation_type"] = String(activationType ?? 1)
        inner["ckeyset"] = ckeyset
        inner["protover"] = 1
        inner["inc_p"] = "1"
        inner["checkActiveCode"] = 1
        inner["log_disk"] = Self.diskUsageLog()
        inner["verificationToken"] = verificationToken
        inner["pwd_token"] = pwdToken ?? ""
        if !activationCode.isEmpty {
            inner["code"] = activationCode
        }
        // The OTP path has no password: `LoginOTPScreenIntent` passes nil and the request uses `encodeIfPresent` (0x1054eaee8).
        if !password.isEmpty {
            inner["password"] = try encPassword(password, phone: phone)
        }
        if verificationToken.isEmpty, let sessionToken, !sessionToken.isEmpty {
            inner["session_token"] = sessionToken
        }

        let (_, obj, text) = try await postForm(path: "/api/register/verifyAccount", inner: inner)
        let ec = (obj?["error_code"]).map { ZolaJSON.int($0) }
        if ec == 2002 {
            return .rejected(errorCode: 2002, errorMessage: Self.wrongVerificationCodeMessage, rawPreview: String(text.prefix(400)))
        }
        if ec == 2003 {
            clearExpiredChallengeTokens()
            return .rejected(errorCode: 2003, errorMessage: Self.expiredVerificationCodeMessage, rawPreview: String(text.prefix(400)))
        }
        let outcome = parseLoginResponse(obj: obj, text: text, sessionToken: sessionToken)
        return await enrichWithDoLoginIfNeeded(outcome: outcome, phone: phone, sessionToken: sessionToken, deviceIdentifier: activeDevId)
    }

    /// Finishes the H5 `VerificationCenter` flow the way `verificationCenterViewController:fallbackObject:` (0x102325030) does:
    /// `verificationType = 1` continues with `verifyAccount`, `verificationType = 2` asks for re-activation by OTP.
    public func completeSecureVerification(
        phone rawPhone: String,
        password: String,
        verification: ZolaSecureVerification,
        result: ZolaSecureVerificationResult,
        sourceSwitch: Int = 0
    ) async throws -> ZolaLoginOutcome {
        let failure = ZolaLoginOutcome.rejected(
            errorCode: result.errorCode == 0 ? nil : result.errorCode,
            errorMessage: Self.localizedAuthErrorMessage(code: result.errorCode, rawMessage: nil) ?? Self.secureVerificationFailedMessage,
            rawPreview: ""
        )
        let pwdToken = result.pwdToken ?? verification.pwdToken
        // Native branches on `verificationType` alone, `error_code` only matters when the page sent no usable type.
        switch result.verificationType {
        case 1:
            guard !result.verificationToken.isEmpty else { return failure }
            return try await verifyAccount(
                phone: rawPhone,
                password: password,
                verificationToken: result.verificationToken,
                pwdToken: pwdToken,
                sessionToken: nil,
                sourceSwitch: sourceSwitch,
                activationType: password.isEmpty ? lastChallenge?.activationType : nil
            )
        case 2:
            let challenge = ZolaLoginChallenge(
                fields: ["verification_required"],
                sessionToken: nil,
                verificationToken: result.verificationToken.isEmpty ? nil : result.verificationToken,
                pwdToken: pwdToken,
                activationToken: nil,
                activationType: nil,
                otpLength: 6,
                smsGateway: nil,
                smsContentHint: nil,
                smsFormat: nil,
                timeoutSeconds: nil,
                title: nil,
                method: nil,
                isForgotPassword: false,
                errorCode: nil,
                errorMessage: nil
            )
            lastChallenge = challenge
            return .challenge(fields: challenge.fields, errorCode: nil, errorMessage: Self.reactivationRequiredMessage)
        default:
            return failure
        }
    }

    private static func secureVerification(from data: [String: Any]?) -> ZolaSecureVerification? {
        let secureUrl = ZolaJSON.firstNonEmptyString(data?["secureUrl"], data?["secure_url"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: secureUrl), url.scheme?.lowercased() == "https" else { return nil }
        return ZolaSecureVerification(
            secureUrl: secureUrl,
            sessionToken: ZolaJSON.firstNonEmptyString(data?["sessionToken"], data?["session_token"]).nilIfEmpty,
            pwdToken: ZolaJSON.firstNonEmptyString(data?["pwd_token"], data?["pwdToken"]).nilIfEmpty
        )
    }

    /// Post-authentication session hydration via `POST /api/login/doLogin`
    /// so standalone devices obtain `CrypKey`, `keySet`, `socketServers`, `send2me_id`, and profile metadata
    /// whenever `activePasswordWithQuestion` or `verifyAccount` returns an access `token` with incomplete socket/crypto keys.
    private func enrichWithDoLoginIfNeeded(
        outcome: ZolaLoginOutcome,
        phone: String,
        sessionToken: String?,
        deviceIdentifier: String
    ) async -> ZolaLoginOutcome {
        guard case let .success(initial) = outcome else {
            return outcome
        }
        let initialWithPhone = ZolaLoginResult(
            userId: initial.userId,
            token: initial.token,
            sessionKey: initial.sessionKey,
            zcid: initial.zcid,
            cryptKey: initial.cryptKey,
            displayName: initial.displayName,
            avatarUrl: initial.avatarUrl,
            sendToMeId: initial.sendToMeId,
            serviceHosts: initial.serviceHosts,
            socketServers: initial.socketServers,
            keySetId: initial.keySetId,
            keySetValue: initial.keySetValue,
            aesPublicId: initial.aesPublicId,
            aesPrivateId: initial.aesPrivateId,
            loginPhone: initial.loginPhone ?? phone
        )
        let needsDoLogin = initial.cryptKey.isEmpty || !initial.hasValidKeySet || initial.socketServers.isEmpty
        guard needsDoLogin,
              !initial.token.isEmpty,
              let encTok = try? encPassword(initial.token, phone: phone)
        else {
            return .success(initialWithPhone)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var ckeysetBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<4 { ckeysetBytes[i] = UInt8.random(in: 0...255) }
        let ckeyset = Data(ckeysetBytes).base64EncodedString()

        var inner = makePrecheckInnerPayload(
            phone: phone,
            nowMs: now,
            deviceIdentifierOverride: deviceIdentifier.isEmpty ? resolvedDeviceIdentifier : deviceIdentifier
        )
        inner["ckeyset"] = ckeyset
        inner["protover"] = 1
        inner["inc_p"] = "1"
        inner["log_disk"] = Self.diskUsageLog()
        inner["token"] = encTok
        if let sessionToken, !sessionToken.isEmpty {
            inner["session_token"] = sessionToken
        }

        var doLoginResponse = try? await postForm(path: "/api/login/doLogin", inner: inner)
        if doLoginResponse == nil {
            doLoginResponse = try? await postForm(path: "/api/login/doLogin", inner: inner)
        }
        // Without `CrypKey` the session cannot encrypt messages, so reporting success would only fail later.
        let incomplete = ZolaLoginOutcome.rejected(errorCode: nil, errorMessage: Self.sessionKeysMissingMessage, rawPreview: "")
        guard let (_, obj, text) = doLoginResponse else {
            return initial.cryptKey.isEmpty ? incomplete : .success(initialWithPhone)
        }
        let enriched = parseLoginResponse(obj: obj, text: text, sessionToken: sessionToken)
        if case let .success(updated) = enriched {
            return .success(ZolaLoginResult(
                userId: updated.userId != 0 ? updated.userId : initial.userId,
                token: updated.token.isEmpty ? initial.token : updated.token,
                sessionKey: updated.sessionKey.isEmpty ? initial.sessionKey : updated.sessionKey,
                zcid: updated.zcid,
                cryptKey: updated.cryptKey.isEmpty ? initial.cryptKey : updated.cryptKey,
                displayName: updated.displayName.isEmpty ? initial.displayName : updated.displayName,
                avatarUrl: updated.avatarUrl.isEmpty ? initial.avatarUrl : updated.avatarUrl,
                sendToMeId: updated.sendToMeId != 0 ? updated.sendToMeId : initial.sendToMeId,
                serviceHosts: updated.serviceHosts.isEmpty ? initial.serviceHosts : updated.serviceHosts,
                socketServers: updated.socketServers.isEmpty ? initial.socketServers : updated.socketServers,
                keySetId: updated.keySetId ?? initial.keySetId,
                keySetValue: updated.keySetValue ?? initial.keySetValue,
                aesPublicId: updated.aesPublicId ?? initial.aesPublicId,
                aesPrivateId: updated.aesPrivateId ?? initial.aesPrivateId,
                loginPhone: updated.loginPhone ?? initial.loginPhone ?? phone
            ))
        }
        return initial.cryptKey.isEmpty ? incomplete : .success(initialWithPhone)
    }

    internal static func localizedAuthErrorMessage(code: Int?, rawMessage: String?) -> String? {
        switch code {
        case 2002:
            return wrongVerificationCodeMessage
        case 2003:
            return expiredVerificationCodeMessage
        case 2036:
            return securityQuestionRequiredMessage
        case 2048:
            return securityWebCheckRequiredMessage
        case 2052:
            return otpQuotaExceededMessage
        default:
            let trimmed = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty,
                  trimmed.lowercased() != "successful",
                  trimmed.lowercased() != "successful." else {
                return nil
            }
            if let code {
                return "\(trimmed) (mã \(code))"
            }
            return trimmed
        }
    }

    internal func parseLoginResponse(
        obj: [String: Any]?,
        text: String,
        sessionToken: String?
    ) -> ZolaLoginOutcome {
        let ec = (obj?["error_code"]).map { ZolaJSON.int($0) }
        let em = (obj?["error_message"]).map { ZolaJSON.string($0) }
        let data = obj?["data"] as? [String: Any]

        if (ec == nil || ec == 0),
           let data,
           let sk = (data["session_key"] as? String), !sk.isEmpty,
           data["user_id"] != nil {
            lastChallenge = nil
            let ckRaw = ZolaJSON.string(
                data["CrypKey"] ?? data["crypt_key"] ?? data["cryptKey"] ?? data["crypt_key_b64"]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let decodedCk: Data
            if !ckRaw.isEmpty, let b64 = Data(base64Encoded: ckRaw), b64.count == 16 {
                decodedCk = b64
            } else if ckRaw.utf8.count == 16 {
                decodedCk = Data(ckRaw.utf8)
            } else {
                decodedCk = Data()
            }

            let profileDict = data["profile"] as? [String: Any]
            let simpleInfoDict = data["simpleInfo"] as? [String: Any]
            let dName = [
                profileDict?["dpn"],
                profileDict?["display_name"],
                profileDict?["displayName"],
                simpleInfoDict?["dname"],
                simpleInfoDict?["displayName"],
                data["user_name"],
                data["display_name"],
                data["displayName"],
            ]
                .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""

            let avt = [
                profileDict?["avt"],
                profileDict?["avatar"],
                simpleInfoDict?["avatar_url"],
                simpleInfoDict?["avt"],
                data["avatar"],
                data["avt"],
            ]
                .compactMap { ZolaJSON.string($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""

            let send2me = ZolaJSON.int64(
                data["send2me_id"] ?? data["send_to_me_id"] ?? data["sendToMeId"] ?? profileDict?["send2me_id"]
            )
            let hosts = ZolaSession.serviceHosts(
                fromServiceMap: data["zpw_service_map_v3"] ?? data["zpw_service_map_new"] ?? data["zpw_service_map"]
            )

            // Socket channel `2001` material (`context-login-response` @ `0x1039d4c14`/`0x1039d4f9c`):
            // `data.keySet.{keySetId,keySetValue}` + `data.socketServers[]` + `aesPublicId`/`aesPrivateId`.
            // [chưa verify — cần runtime] whether `aesPublicId`/`aesPrivateId` ship inside `keySet` or at `data` level.
            let keySetDict = data["keySet"] as? [String: Any]
            let keySetId = ZolaJSON.string(keySetDict?["keySetId"] ?? data["keySetId"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let keySetValue = ZolaJSON.string(keySetDict?["keySetValue"] ?? data["keySetValue"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let aesPub = ZolaJSON.int64(keySetDict?["aesPublicId"] ?? data["aesPublicId"] ?? data["aes_public_id"])
            let aesPriv = ZolaJSON.int64(keySetDict?["aesPrivateId"] ?? data["aesPrivateId"] ?? data["aes_private_id"])
            var servers: [ZolaSocketServer] = []
            if let arr = (data["socketServers"] ?? data["socket_servers"]) as? [Any] {
                for item in arr {
                    guard let dict = item as? [String: Any] else { continue }
                    let srv = ZolaSocketServer.fromServerDict(dict)
                    if !srv.hostName.isEmpty { servers.append(srv) }
                }
            }

            return .success(ZolaLoginResult(
                userId: ZolaJSON.int64(data["user_id"]),
                token: ZolaJSON.string(data["token"]),
                sessionKey: sk,
                zcid: identity.zcid,
                cryptKey: decodedCk,
                displayName: dName,
                avatarUrl: avt,
                sendToMeId: send2me,
                serviceHosts: hosts,
                socketServers: servers,
                keySetId: (!keySetId.isEmpty && keySetId != "0") ? keySetId : nil,
                keySetValue: keySetValue.isEmpty ? nil : keySetValue,
                aesPublicId: aesPub >= 1 ? aesPub : nil,
                aesPrivateId: aesPriv >= 1 ? aesPriv : nil
            ))
        }

        let zotpDict = data?["zotp"] as? [String: Any]
        let otpChallengeKeys = [
            "verificationToken",
            "verify_token",
            "otp",
            "pwd_token",
            "verify_methods",
            "activation_token",
            "activationToken",
            "zotp",
        ]
        let present = data.map { dict in otpChallengeKeys.filter { dict[$0] != nil } } ?? []

        // `2048` carries `pwd_token`, so it must be routed before the OTP key check below.
        if ec == 2048 {
            if let secure = Self.secureVerification(from: data) {
                return .secureVerification(secure)
            }
            return .rejected(errorCode: ec, errorMessage: Self.securityWebCheckRequiredMessage, rawPreview: String(text.prefix(400)))
        }

        // Security question (`2036`) and daily OTP quota (`2052`)
        // must surface explicit guidance instead of entering an unrecoverable OTP loop when no OTP challenge was issued.
        if present.isEmpty, let ec, (ec == 2036 || ec == 2052) {
            let msg = Self.localizedAuthErrorMessage(code: ec, rawMessage: em) ?? em
            return .rejected(errorCode: ec, errorMessage: msg, rawPreview: String(text.prefix(400)))
        }

        let verifToken = [
            data?["verificationToken"] as? String,
            data?["verify_token"] as? String,
            zotpDict?["verificationToken"] as? String,
            zotpDict?["verify_token"] as? String,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let pwdTok = data?["pwd_token"] as? String
        let actToken = [
            data?["activation_token"] as? String,
            data?["activationToken"] as? String,
            zotpDict?["activation_token"] as? String,
            zotpDict?["activationToken"] as? String,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let actType = (data?["activation_type"] ?? data?["activationType"] ?? zotpDict?["activation_type"] ?? zotpDict?["activationType"]).map { ZolaJSON.int($0) }
        let isOtpChallengeCode = ec.map { Self.otpChallengeErrorCodes.contains($0) } ?? false

        if !present.isEmpty || isOtpChallengeCode {
            let fields = present.isEmpty ? ["verification_required"] : present
            // Only keep a session_token if the server response explicitly issued a new one in `data`.
            // The input `sessionToken` was already consumed by the password login POST request.
            let freshSessionTokenFromResponse = [
                data?["session_token"] as? String,
                data?["sessionToken"] as? String,
                data?["request_session_key"] as? String,
                data?["requestSessionKey"] as? String,
            ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != sessionToken }
            let smsGateway = [
                ZolaJSON.string(data?["sms_gateway"]),
                ZolaJSON.string(data?["smsGateway"]),
                ZolaJSON.string(zotpDict?["sms_gateway"]),
                ZolaJSON.string(zotpDict?["smsGateway"]),
            ]
                .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let smsContentHint = [
                ZolaJSON.string(data?["sms_content_hint"]),
                ZolaJSON.string(data?["smsContentHint"]),
                ZolaJSON.string(zotpDict?["sms_content_hint"]),
                ZolaJSON.string(zotpDict?["smsContentHint"]),
            ]
                .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let smsFormat = [
                ZolaJSON.string(data?["sms_format"]),
                ZolaJSON.string(data?["smsFormat"]),
                ZolaJSON.string(zotpDict?["sms_format"]),
                ZolaJSON.string(zotpDict?["smsFormat"]),
            ]
                .compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let rawOtpLen = (data?["activationNumber"] ?? data?["activation_number"] ?? zotpDict?["activationNumber"] ?? zotpDict?["activation_number"]).map { ZolaJSON.int($0) }
            let otpLength = (rawOtpLen != nil && rawOtpLen! > 0) ? rawOtpLen! : 6
            let timeoutSeconds = (data?["timeout"] ?? zotpDict?["timeout"]).map { ZolaJSON.int($0) }
            let title = ((data?["title"] ?? zotpDict?["title"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let challenge = ZolaLoginChallenge(
                fields: fields,
                sessionToken: freshSessionTokenFromResponse,
                verificationToken: verifToken,
                pwdToken: pwdTok,
                activationToken: actToken,
                activationType: actType,
                otpLength: otpLength,
                smsGateway: smsGateway,
                smsContentHint: smsContentHint,
                smsFormat: smsFormat,
                timeoutSeconds: timeoutSeconds,
                title: title,
                method: nil,
                isForgotPassword: false,
                errorCode: ec,
                errorMessage: em
            )
            lastChallenge = challenge
            return .challenge(fields: fields, errorCode: ec, errorMessage: em)
        }

        if ec == 2002 {
            return .rejected(errorCode: 2002, errorMessage: Self.wrongVerificationCodeMessage, rawPreview: String(text.prefix(400)))
        }
        if ec == 2003 {
            return .rejected(errorCode: 2003, errorMessage: Self.expiredVerificationCodeMessage, rawPreview: String(text.prefix(400)))
        }
        return .rejected(errorCode: ec, errorMessage: em, rawPreview: String(text.prefix(400)))
    }

    /// Build a `ZolaSession` from a successful login result (includes `CrypKey` and `send2me_id` when returned by server).
    public func makeSession(from result: ZolaLoginResult) throws -> ZolaSession {
        try ZolaSession(
            uid: result.userId,
            sessionKey: result.sessionKey,
            cryptKey: result.cryptKey,
            zcid: result.zcid,
            zcidIsNative: true,
            apiKey: config.apiKey,
            apiSecret: config.apiSecret,
            sendToMeId: result.sendToMeId,
            serviceHosts: result.serviceHosts.isEmpty ? nil : result.serviceHosts,
            socketServers: result.socketServers.isEmpty ? nil : result.socketServers,
            keySetId: result.keySetId,
            keySetValue: result.keySetValue,
            aesPublicId: result.aesPublicId,
            aesPrivateId: result.aesPrivateId,
            accessToken: result.token.isEmpty ? nil : result.token,
            loginPhone: result.loginPhone
        )
    }

    // MARK: - Transport

    private static func unwrapZotpPayload(_ rawValue: Any?, zcid: String) -> [String: Any]? {
        if let dict = rawValue as? [String: Any] {
            return dict
        }
        guard let str = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else {
            return nil
        }
        if str.hasPrefix("{"),
           let jsonData = str.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] {
            return dict
        }
        if str.count > 16, Self.isHex(str) {
            return (try? ZolaCrypto.decryptZCIDPrefixECB(str, zcid: zcid))
                ?? (try? ZolaCrypto.decryptZCIDParams(str, zcid: zcid))
        }
        return nil
    }

    private func postForm(path: String, inner: [String: Any]) async throws -> (Int, [String: Any]?, String) {
        let dataHex = try encData(inner)
        var outer: [String: String] = ["api_key": config.apiKey, "data": dataHex, "encryptParams": "1"]
        outer["sig"] = ZolaCrypto.makeSignature(params: outer, apiSecret: config.apiSecret)
        let body = outer.keys.sorted()
            .map { "\($0)=\(Self.formEncode(outer[$0] ?? ""))" }
            .joined(separator: "&")

        guard let url = URL(string: config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) + path : config.baseURL + path) else {
            throw ZolaError.invalidArgument("Bad login URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.stripZcidPrefix(identity.zcid), forHTTPHeaderField: "zcid")
        req.setValue("v2", forHTTPHeaderField: "v")
        req.setValue("0", forHTTPHeaderField: "retry")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let raw: Data
        let status: Int
        if let customTransport {
            (status, raw) = try await customTransport.execute(req)
        } else {
            let (respData, resp) = try await urlSession.data(for: req)
            raw = respData
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        let text = String(decoding: raw, as: UTF8.self)

        guard var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            recordDiagnostic(path: path, status: status, obj: nil)
            return (status, nil, text)
        }
        // Unwrap encrypted "data" field (hex string) if present, or normalize plain JSON "data" dict.
        if let dataHexResp = obj["data"] as? String,
           dataHexResp.count > 32,
           Self.isHex(dataHexResp),
           var clear = try? ZolaCrypto.decryptZCIDParams(dataHexResp, zcid: identity.zcid) {
            if let idHex = clear["identifier"] as? String,
               idHex.count > 16,
               Self.isHex(idHex),
               let simpleInfo = try? ZolaCrypto.decryptZCIDPrefixECB(idHex, zcid: identity.zcid) {
                clear["simpleInfo"] = simpleInfo
            }
            if let zotpDict = Self.unwrapZotpPayload(clear["zotp"], zcid: identity.zcid) {
                clear["zotp"] = zotpDict
            }
            obj["data"] = clear
        } else if var plainData = obj["data"] as? [String: Any],
                  let zotpDict = Self.unwrapZotpPayload(plainData["zotp"], zcid: identity.zcid) {
            plainData["zotp"] = zotpDict
            obj["data"] = plainData
        }
        // Unwrap top-level "zotp" field (hex string / JSON string / dict) if present and attach to data["zotp"].
        if let topZotp = Self.unwrapZotpPayload(obj["zotp"], zcid: identity.zcid) {
            var dataDict = (obj["data"] as? [String: Any]) ?? [:]
            dataDict["zotp"] = topZotp
            obj["data"] = dataDict
        }
        recordDiagnostic(path: path, status: status, obj: obj)
        return (status, obj, text)
    }

    // MARK: - Crypto (mirrors zalo_login.py)

    /// AES-256-CBC(param_key(zcid), IV=0, PKCS7) of compact JSON, hex LOWERCASE (matches server-proven Python).
    private func encData(_ inner: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: inner, options: [.withoutEscapingSlashes])
        let ct = try ZolaCrypto.aesCBC(json, key: try ZolaCrypto.paramKey(zcid: identity.zcid), iv: ZolaCrypto.zeroIV16, decrypt: false, pkcs7Padding: true)
        return ZolaCrypto.hex(ct, uppercase: false)
    }

    /// md5(prefix + phone.lower()) → hex[5..<21] as AES-128 key → AES-128-CBC(IV=0, PKCS7) → hex UPPERCASE.
    public static func encryptPhoneBoundValue(
        _ value: String,
        phone: String,
        prefix: String = "2c55197a0a52c30a16def06d5681b7b3"
    ) throws -> String {
        let digest = ZolaCrypto.md5Hex(prefix + phone.lowercased())
        let keyStart = digest.index(digest.startIndex, offsetBy: 5)
        let keyEnd = digest.index(digest.startIndex, offsetBy: 21)
        let key = Data(String(digest[keyStart..<keyEnd]).utf8)  // 16 ASCII bytes → AES-128
        let ct = try ZolaCrypto.aesCBC(Data(value.utf8), key: key, iv: ZolaCrypto.zeroIV16, decrypt: false, pkcs7Padding: true)
        return ZolaCrypto.hex(ct, uppercase: true)
    }

    private func encPassword(_ value: String, phone: String) throws -> String {
        try Self.encryptPhoneBoundValue(value, phone: phone, prefix: config.passwordKeyPrefix)
    }

    // MARK: - Helpers

    static func normalizePhone(_ raw: String) throws -> String {
        let compact = raw.filter { !" ()-".contains($0) }
        let nat: String
        if compact.hasPrefix("+84") { nat = String(compact.dropFirst(3)) }
        else if compact.hasPrefix("84") { nat = String(compact.dropFirst(2)) }
        else if compact.hasPrefix("0") { nat = String(compact.dropFirst(1)) }
        else { nat = compact }
        guard nat.count == 9, nat.allSatisfy({ $0.isNumber }) else {
            throw ZolaError.invalidArgument("Cần số di động VN (09.., 84.., +84..)")
        }
        return "+84" + nat
    }

    private static func stripZcidPrefix(_ zcid: String) -> String {
        zcid.hasPrefix("1_") ? String(zcid.dropFirst(2)) : zcid
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit }
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func extractPrecheckSessionToken(from obj: [String: Any]?, searchable: String) -> String? {
        let dataDict = obj?["data"] as? [String: Any]
        let zotpDict = dataDict?["zotp"] as? [String: Any]
        let candidates: [String?] = [
            dataDict?["session_token"] as? String,
            dataDict?["sessionToken"] as? String,
            dataDict?["request_session_key"] as? String,
            dataDict?["requestSessionKey"] as? String,
            dataDict?["token"] as? String,
            zotpDict?["session_token"] as? String,
            zotpDict?["sessionToken"] as? String,
            firstMatch(in: searchable, pattern: "zk[0-9A-Za-z_-]*\\.[0-9A-Za-z._-]+"),
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Slide Captcha Verification (`zmcaptcha.zaloapp.com`)

    private static func extractCaptchaSession(from dataDict: [String: Any]?, secureUrl: String) -> String {
        let direct = ZolaJSON.string(dataDict?["sessionToken"] ?? dataDict?["session_token"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }
        if let comps = URLComponents(string: secureUrl),
           let q = comps.queryItems?.first(where: { $0.name == "session" })?.value,
           !q.isEmpty {
            return q
        }
        return ""
    }

    /// Resolves the `zmcaptcha.zaloapp.com` slide-captcha challenge for a `2060` verification session
    /// and returns `captchaToken` (`"zcc_2_2...."`).
    private func resolveSlideCaptcha(session: String, secureUrl: String) async -> String? {
        let baseHost: String
        if let parsed = URL(string: secureUrl), let scheme = parsed.scheme, let host = parsed.host {
            baseHost = "\(scheme)://\(host)"
        } else {
            baseHost = "https://zmcaptcha.zaloapp.com"
        }
        let encodedSession = Self.formEncode(session)
        guard let genURL = URL(string: "\(baseHost)/api/slide-captcha-gen?session=\(encodedSession)&lang=vi"),
              let verifyURL = URL(string: "\(baseHost)/api/slide-captcha-verify?session=\(encodedSession)&lang=vi") else {
            return nil
        }

        for _ in 0..<3 {
            var genReq = URLRequest(url: genURL)
            genReq.httpMethod = "GET"
            genReq.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            genReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            genReq.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
            if !secureUrl.isEmpty {
                genReq.setValue(secureUrl, forHTTPHeaderField: "Referer")
            }

            guard let (genData, genResp) = try? await urlSession.data(for: genReq),
                  let genObj = (try? JSONSerialization.jsonObject(with: genData)) as? [String: Any],
                  ZolaJSON.int(genObj["error_code"]) == 0,
                  let data = genObj["data"] as? [String: Any] else {
                continue
            }

            let top = ZolaJSON.int(data["top"])
            let bgStr = ZolaJSON.string(data["bg"])
            let sliceStr = ZolaJSON.string(data["slice"])
            guard let leftOffset = Self.solveSlideCaptchaLeftOffset(bgDataURL: bgStr, sliceDataURL: sliceStr, top: top) else {
                continue
            }

            let stopTime = Int64(Date().timeIntervalSince1970 * 1000)
            let startTime = stopTime - Int64.random(in: 580...840)
            let postBody = "left=\(leftOffset)&startTime=\(startTime)&stopTime=\(stopTime)"

            var verReq = URLRequest(url: verifyURL)
            verReq.httpMethod = "POST"
            verReq.httpBody = Data(postBody.utf8)
            verReq.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            verReq.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
            verReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            verReq.setValue(ZolaConstants.userAgentUXHttp, forHTTPHeaderField: "User-Agent")
            if !secureUrl.isEmpty {
                verReq.setValue(secureUrl, forHTTPHeaderField: "Referer")
            }
            if let httpResp = genResp as? HTTPURLResponse,
               let setCookie = httpResp.value(forHTTPHeaderField: "Set-Cookie"),
               let cookiePair = setCookie.split(separator: ";").first {
                verReq.setValue(String(cookiePair), forHTTPHeaderField: "Cookie")
            }

            guard let (verData, _) = try? await urlSession.data(for: verReq),
                  let verObj = (try? JSONSerialization.jsonObject(with: verData)) as? [String: Any],
                  ZolaJSON.int(verObj["error_code"]) == 0,
                  let verDataDict = verObj["data"] as? [String: Any] else {
                continue
            }

            let capTok = ZolaJSON.string(verDataDict["captchaToken"] ?? verDataDict["captcha_token"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !capTok.isEmpty {
                return capTok
            }
        }
        return nil
    }

    /// Computes the horizontal pixel offset (`left`) for a slide-captcha puzzle cutout
    /// by matching the alpha silhouette boundary of `sliceDataURL` against 2D edge gradients in `bgDataURL` at `y = top`.
    public static func solveSlideCaptchaLeftOffset(bgDataURL: String, sliceDataURL: String, top: Int) -> Int? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let bgData = decodeDataURL(bgDataURL),
              let slData = decodeDataURL(sliceDataURL),
              let bg = decodeRGBA(bgData),
              let sl = decodeRGBA(slData),
              bg.w > sl.w + 20,
              sl.w >= 16, sl.h >= 16 else {
            return nil
        }

        var borderPts: [(x: Int, y: Int)] = []
        borderPts.reserveCapacity(300)
        for y in 1..<(sl.h - 1) {
            for x in 1..<(sl.w - 1) {
                let a = Int(sl.bytes[(y * sl.w + x) * 4 + 3])
                if a > 128 {
                    let aL = Int(sl.bytes[(y * sl.w + (x - 1)) * 4 + 3])
                    let aR = Int(sl.bytes[(y * sl.w + (x + 1)) * 4 + 3])
                    let aU = Int(sl.bytes[((y - 1) * sl.w + x) * 4 + 3])
                    let aD = Int(sl.bytes[((y + 1) * sl.w + x) * 4 + 3])
                    if aL < 64 || aR < 64 || aU < 64 || aD < 64 {
                        borderPts.append((x, y))
                    }
                }
            }
        }
        guard !borderPts.isEmpty else { return nil }

        var bestLeft = 0
        var bestScore = -1.0
        let maxLeft = bg.w - sl.w - 5
        guard maxLeft >= 15 else { return nil }

        for left in 15...maxLeft {
            var score = 0.0
            for pt in borderPts {
                let bx = left + pt.x
                let by = top + pt.y
                guard by >= 2 && by < bg.h - 2 && bx >= 2 && bx < bg.w - 2 else { continue }
                let idx = (by * bg.w + bx) * 4
                let idxOutX = (by * bg.w + (bx - 2)) * 4
                let idxOutY = ((by - 2) * bg.w + bx) * 4
                let r = Double(bg.bytes[idx])
                let g = Double(bg.bytes[idx + 1])
                let b = Double(bg.bytes[idx + 2])
                let gx = abs(r - Double(bg.bytes[idxOutX]))
                       + abs(g - Double(bg.bytes[idxOutX + 1]))
                       + abs(b - Double(bg.bytes[idxOutX + 2]))
                let gy = abs(r - Double(bg.bytes[idxOutY]))
                       + abs(g - Double(bg.bytes[idxOutY + 1]))
                       + abs(b - Double(bg.bytes[idxOutY + 2]))
                score += gx + gy
            }
            if score > bestScore {
                bestScore = score
                bestLeft = left
            }
        }
        return bestScore > 0 ? bestLeft : nil
        #else
        return nil
        #endif
    }

    private static func decodeDataURL(_ str: String) -> Data? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let commaIdx = trimmed.firstIndex(of: ",") {
            let b64 = String(trimmed[trimmed.index(after: commaIdx)...])
            return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        }
        return Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters)
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    private static func decodeRGBA(_ data: Data) -> (w: Int, h: Int, bytes: [UInt8])? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let w = cg.width
        let h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }
    #endif
}
