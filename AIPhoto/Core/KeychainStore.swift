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
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
