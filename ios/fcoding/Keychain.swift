import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the device token from pairing.
enum Keychain {
    private static let service = "com.brooklyn96.fcoding"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    /// Update in place; add only when there is no item yet. On any failure the old token
    /// stays exactly as it was (never delete-then-add).
    static func set(_ value: String, for account: String) -> Bool {
        let fields: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base(account) as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let add = base(account).merging(fields) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
