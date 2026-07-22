import Foundation
import Security

/// Stores remote-host SSH passwords in the user's login Keychain, one generic
/// password item per host (account == `RemoteHost.id`). The password therefore
/// never touches the on-disk host config JSON.
///
/// Reads are cached in memory for the lifetime of the process: each Keychain
/// read of another app's-signature item can trigger the macOS ACL prompt, and
/// this app re-authenticates on every periodic sync — without the cache an
/// ad-hoc-signed build would prompt the user every 60 seconds.
enum SSHKeychain {
    private static let service = "com.jerome.claudesessionmanager.ssh"

    /// hostID → password; a stored `nil` means "known absent (or access
    /// denied)" so a missing item doesn't re-prompt on every sync either.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: String?] = [:]
    }
    private static let cache = Cache()

    private static func baseQuery(for hostID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: hostID]
    }

    static func setPassword(_ password: String, for hostID: String) {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(for: hostID) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(for: hostID)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
        cache.lock.lock()
        cache.values[hostID] = password
        cache.lock.unlock()
    }

    static func password(for hostID: String) -> String? {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.values[hostID] { return cached }

        var query = baseQuery(for: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let password: String?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            password = String(data: data, encoding: .utf8)
        } else {
            password = nil
        }
        cache.values[hostID] = password
        return password
    }

    static func deletePassword(for hostID: String) {
        SecItemDelete(baseQuery(for: hostID) as CFDictionary)
        cache.lock.lock()
        cache.values[hostID] = String?.none
        cache.lock.unlock()
    }
}
