import Foundation
import Security

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    #if os(iOS)
    // The keyboard has its own bundle ID, so the app and the keyboard share items through the App Group.
    private static let service = "app.openspell"
    private static let accessGroup: String? = SharedStorage.appGroup
    #else
    private static let service = Bundle.main.bundleIdentifier ?? "app.openspell"
    private static let accessGroup: String? = nil
    #endif

    static func get(_ account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { base[kSecAttrAccessGroup as String] = accessGroup }
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
