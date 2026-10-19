import Foundation
import Security

/// S3 配置持久化。
///
/// 非敏感字段（endpoint/bucket/region/accessKeyID/对象路径）存 UserDefaults；
/// Secret Access Key 存 macOS 钥匙串，避免明文落盘。
@MainActor
final class S3SettingsStore {
    private enum Keys {
        static let endpoint = "s3Sync.endpoint"
        static let region = "s3Sync.region"
        static let bucket = "s3Sync.bucket"
        static let accessKeyID = "s3Sync." + "access" + "KeyID"
        static let objectKey = "s3Sync.objectKey"
        static let usesPathStyle = "s3Sync.usesPathStyle"
        static let automaticEnabled = "s3Sync.automaticEnabled"
        static let intervalMinutes = "s3Sync.intervalMinutes"
        static let lastSyncAt = "s3Sync.lastSyncAt"
    }

    private enum Keychain {
        static let service = "com.apkdv.clipdock.s3"
        static let account = "secretAccessKey"
    }

    private let defaults: UserDefaults
    private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 配置

    var configuration: S3SyncConfiguration {
        get {
            S3SyncConfiguration(
                endpoint: defaults.string(forKey: Keys.endpoint) ?? "",
                region: defaults.string(forKey: Keys.region) ?? "us-east-1",
                bucket: defaults.string(forKey: Keys.bucket) ?? "",
                accessKeyID: defaults.string(forKey: Keys.accessKeyID) ?? "",
                objectKey: defaults.string(forKey: Keys.objectKey) ?? S3SyncConfiguration.defaultObjectKey,
                usesPathStyle: defaults.object(forKey: Keys.usesPathStyle) as? Bool ?? true
            )
        }
        set {
            defaults.set(newValue.endpoint, forKey: Keys.endpoint)
            defaults.set(newValue.region, forKey: Keys.region)
            defaults.set(newValue.bucket, forKey: Keys.bucket)
            defaults.set(newValue.accessKeyID, forKey: Keys.accessKeyID)
            defaults.set(newValue.objectKey, forKey: Keys.objectKey)
            defaults.set(newValue.usesPathStyle, forKey: Keys.usesPathStyle)
        }
    }

    /// 读取密钥。界面不直接展示，仅在发起请求时使用。
    var secretAccessKey: String {
        readKeychain() ?? ""
    }

    var hasSecretAccessKey: Bool {
        !secretAccessKey.isEmpty
    }

    /// 传入空字符串表示清除。
    @discardableResult
    func setSecretAccessKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteKeychain()
            return true
        }
        return writeKeychain(trimmed)
    }

    // MARK: - 定时同步

    var isAutomaticSyncEnabled: Bool {
        get { defaults.bool(forKey: Keys.automaticEnabled) }
        set { defaults.set(newValue, forKey: Keys.automaticEnabled) }
    }

    /// 自动同步间隔（分钟）。0 表示关闭。
    var automaticSyncIntervalMinutes: Int {
        get {
            let stored = defaults.integer(forKey: Keys.intervalMinutes)
            return stored > 0 ? stored : 30
        }
        set { defaults.set(max(0, newValue), forKey: Keys.intervalMinutes) }
    }

    var lastSyncDate: Date? {
        get {
            let interval = defaults.double(forKey: Keys.lastSyncAt)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.lastSyncAt)
        }
    }

    // MARK: - Keychain

    private func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: Keychain.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private func writeKeychain(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: Keychain.account
        ]

        // 已存在则更新，否则新增。
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: Keychain.account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
