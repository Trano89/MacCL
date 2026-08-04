import Foundation
import Security

/// SSH passwords, stored in the macOS Keychain and nowhere else.
///
/// They never reach UserDefaults, the conversation files, or the log: `SSHHost`
/// deliberately has no password property, and the value is read back only at the
/// moment a connection is made — handed to ssh's own askpass helper through the
/// environment rather than argv, because argv is world-readable via `ps` while
/// a process's environment is not.
enum SSHKeychain {
    private static let service = "com.trano89.maccl.ssh"

    /// Store (or replace) the password for a host. Returns false if the Keychain
    /// refused — the caller must then tell the user rather than pretend it saved.
    @discardableResult
    static func save(password: String, hostId: String) -> Bool {
        guard !hostId.isEmpty, let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
        ]
        // Update in place when it already exists; SecItemAdd would return
        // errSecDuplicateItem and silently keep the stale password.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            AppLog.warn("ssh", "keychain update failed (OSStatus \(updateStatus))")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insert[kSecAttrLabel as String] = "MacCL — SSH"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            AppLog.warn("ssh", "keychain add failed (OSStatus \(addStatus))")
        }
        return addStatus == errSecSuccess
    }

    /// Read a host's password back. nil when none is stored (or access denied).
    static func load(hostId: String) -> String? {
        guard !hostId.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                AppLog.warn("ssh", "keychain read failed (OSStatus \(status))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// True when a password exists, without pulling the secret into memory.
    static func hasPassword(hostId: String) -> Bool {
        guard !hostId.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(hostId: String) {
        guard !hostId.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLog.warn("ssh", "keychain delete failed (OSStatus \(status))")
        }
    }
}
