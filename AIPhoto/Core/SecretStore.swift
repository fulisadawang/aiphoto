import Foundation
import Security

/// API 密钥存在本机 `~/Library/Application Support/AIPhoto/secrets.json`（只有当前用户可读写），不放钥匙串。
/// 本机临时签名每次更新签名都会变，钥匙串每次更新后都弹「始终允许」，拒绝了就像密钥丢了（用户 2026-10-21 决定改存本地）。
/// 旧版本存在钥匙串里的密钥，第一次用到时搬过来并从钥匙串删除（最后弹一次授权框）
enum SecretStore {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPhoto/secrets.json")
    }

    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let lock = NSLock()

    /// 只看本地文件和旧版本留下的标记，不碰钥匙串（不会弹授权框）
    static func isSaved(account: String) -> Bool {
        let stored = (try? read()[account]).map { !$0.isEmpty } ?? false
        return stored || UserDefaults.standard.bool(forKey: legacyFlag(account))
    }

    /// 只有存过密钥才读；放到后台读：旧密钥搬家时可能弹钥匙串授权框，不能卡住界面
    static func loadIfSaved(account: String) async throws -> String? {
        guard isSaved(account: account) else { return nil }
        return try await Task.detached { try load(account: account) }.value
    }

    static func load(account: String) throws -> String? {
        if let value = try read()[account] { return value }
        return try migrateFromKeychain(account: account)
    }

    static func save(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try readUnlocked()
        secrets[account] = value
        try writeUnlocked(secrets)
        // 新密钥已在本地文件里，不再去钥匙串找旧的
        UserDefaults.standard.set(false, forKey: legacyFlag(account))
    }

    static func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var secrets = try readUnlocked()
        secrets[account] = nil
        try writeUnlocked(secrets)
    }

    // MARK: - 文件

    private static func read() throws -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return try readUnlocked()
    }

    private static func readUnlocked() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL))
        } catch {
            throw StoreError(message: "读取本地密钥文件失败：\(error.localizedDescription)")
        }
    }

    /// 先写同目录的临时文件（权限 600）再替换，任何时刻都不会出现别人可读的密钥文件
    private static func writeUnlocked(_ secrets: [String: String]) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".secrets-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(secrets)
        guard manager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError(message: "写入本地密钥文件失败")
        }
        if manager.fileExists(atPath: fileURL.path) {
            _ = try manager.replaceItemAt(fileURL, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: fileURL)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - 旧版本钥匙串

    private static let legacyService = "com.nieyutan.aiphoto"

    private static func legacyFlag(_ account: String) -> String { "keychainSaved.\(account)" }

    /// 旧版本保存过才去钥匙串取；取到后写进本地文件并从钥匙串删除，以后不再碰钥匙串
    private static func migrateFromKeychain(account: String) throws -> String? {
        guard UserDefaults.standard.bool(forKey: legacyFlag(account)) else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: legacyService, kSecAttrAccount: account,
        ]
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound {
            UserDefaults.standard.set(false, forKey: legacyFlag(account))
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            throw StoreError(message: "读取旧版本保存在钥匙串里的密钥失败：\(reason)。可以在设置里重新填一次密钥。")
        }
        let value = String(decoding: data, as: UTF8.self)
        try save(value, account: account)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: legacyFlag(account))
        return value
    }
}
