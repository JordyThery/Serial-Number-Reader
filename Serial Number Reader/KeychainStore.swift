import Foundation
import Security

/// Minimal Keychain wrapper for Jamf credentials (OAuth client secret or
/// account password). Secrets are never written to UserDefaults.
nonisolated enum KeychainStore {

    enum Account: String {
        case clientSecret
        case password = "jamfPassword"
    }

    private static let service = "be.jordythery.SerialNumberReader.jamf"

    private static func baseQuery(for account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    @discardableResult
    static func save(_ secret: String, account: Account) -> Bool {
        guard !secret.isEmpty else {
            delete(account: account)
            return true
        }
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(for: account)
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    static func load(account: Account) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: Account) {
        SecItemDelete(baseQuery(for: account) as CFDictionary)
    }
}
