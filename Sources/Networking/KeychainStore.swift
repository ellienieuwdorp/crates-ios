import Foundation
import Security

/// Tiny wrapper over the Keychain for the handful of secrets this app holds (today: just the
/// pairing bearer token). Talks to the `SecItem` API directly — no third-party dependency, per
/// the platform-first rule — storing one generic-password item per `account` under a shared
/// service. Items are `AfterFirstUnlockThisDeviceOnly`: readable by the background sync/download
/// tasks once the device has been unlocked after boot, and never synced off-device to iCloud.
///
/// Thread-safe: a stateless namespace of `static` functions over immutable inputs, and the
/// underlying `SecItem*` calls are themselves safe to invoke concurrently — so no lock is needed
/// and the type is trivially Swift-6 concurrency-clean.
enum KeychainStore {
    /// Shared service name; a new secret is just a new `account` under it.
    static let service = "co.crates.ios"

    /// The accounts (keys) this app stores.
    enum Account {
        /// The device access token from the pairing handshake.
        static let accessToken = "accessToken"
    }

    /// Store `value` for `account`, overwriting any existing item. Returns false on an unexpected
    /// `OSStatus` — callers treat that as "not persisted" (and, for migration, keep the old copy).
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Update in place when the item already exists; add it when it doesn't.
        let updated = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(match.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    /// The string stored for `account`, or nil if it is absent (or unreadable).
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Remove the item for `account`. Treats "already absent" as success (nothing to delete).
    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
