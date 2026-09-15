import Foundation
import Security

/// Stockage de la clé API OpenAI dans le trousseau (jamais dans le code).
/// Si le trousseau refuse (build simulateur non signé, entitlements absents), repli sur UserDefaults
/// avec `lastError` renseigné pour l'afficher dans les réglages.
enum KeychainStore {
    private static let service = "com.k2r59.WatchCoach"
    static let apiKeyAccount = "openai_api_key"
    private static let fallbackPrefix = "keychain.fallback."

    /// Dernier code d'erreur Security rencontré (0 = aucun).
    static var lastError: OSStatus = 0

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        return UserDefaults.standard.string(forKey: fallbackPrefix + account)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return delete(account) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        lastError = status
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
            return true
        }
        // Repli : le trousseau n'est pas disponible (typiquement simulateur sans signature).
        UserDefaults.standard.set(trimmed, forKey: fallbackPrefix + account)
        return true
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + account)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "code \(status)"
    }
}
