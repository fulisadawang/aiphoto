import Foundation
import Security

/// API 密钥只存在本机钥匙串，不写入任何文件
enum KeychainStore {
    private static let service = "com.nieyutan.aiphoto"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "钥匙串操作失败：\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")"
        }
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// 是否在本 App 里保存过密钥。记在 UserDefaults，判断时不碰钥匙串：
    /// 每次重新编译签名都会变，读钥匙串会弹系统授权框，Magpie 这类不需要密钥的服务不该触发它
    static func isSaved(account: String) -> Bool {
        UserDefaults.standard.bool(forKey: savedFlag(account))
    }

    /// 只在保存过密钥时才读钥匙串，并且放到后台读：授权框弹出期间不卡住界面
    static func loadIfSaved(account: String) async throws -> String? {
        guard isSaved(account: account) else { return nil }
        return try await Task.detached { try load(account: account) }.value
    }

    private static func savedFlag(_ account: String) -> String { "keychainSaved.\(account)" }

    static func load(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, account: String) throws {
        try delete(account: account)
        var item = query(account)
        item[kSecValueData] = Data(value.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        UserDefaults.standard.set(true, forKey: savedFlag(account))
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        UserDefaults.standard.set(false, forKey: savedFlag(account))
    }
}
