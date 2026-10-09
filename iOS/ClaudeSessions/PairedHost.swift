import Foundation
import Security

/// A Mac this device is paired with. The device token lives in the Keychain;
/// everything else (where to connect, which certificate to trust) is here.
struct PairedHost: Codable, Identifiable, Equatable {
    var id: String { deviceID }
    let deviceID: String
    var name: String
    /// Addresses to try, in order (LAN, VPN, …).
    var addresses: [String]
    var port: Int
    /// SHA-256 of the host certificate — the only one this app accepts.
    let fingerprint: String

    var securityCode: String { PairingSecurity.code(forFingerprint: fingerprint) }
}

/// A scanned / pasted `csm://pair?v=1&hosts=…&port=…&fp=…&code=…` link.
struct PairingLink: Equatable {
    let addresses: [String]
    let port: Int
    let fingerprint: String
    let code: String

    init?(_ string: String) {
        guard let c = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "csm", c.host == "pair" else { return nil }
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
        guard let hosts = q["hosts"], let port = q["port"].flatMap(Int.init), let fp = q["fp"], fp.count == 64,
              let code = q["code"], !code.isEmpty else { return nil }
        addresses = hosts.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return nil }
        self.port = port
        fingerprint = fp.lowercased()
        self.code = code
    }
}

/// Paired hosts (UserDefaults) and their tokens (Keychain).
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [PairedHost] = []
    private let key = "pairedHosts"
    private static let service = "com.jerome.claudesessionmanager.remote.token"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([PairedHost].self, from: data) {
            hosts = list
        }
    }

    var current: PairedHost? { hosts.first }

    func add(_ host: PairedHost, token: String) {
        hosts.removeAll { $0.fingerprint == host.fingerprint }   // re-pairing the same Mac
        hosts.insert(host, at: 0)
        save()
        Self.setToken(token, for: host.deviceID)
    }

    func remove(_ host: PairedHost) {
        hosts.removeAll { $0.deviceID == host.deviceID }
        save()
        Self.deleteToken(for: host.deviceID)
    }

    func token(for host: PairedHost) -> String? { Self.token(for: host.deviceID) }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: key)
    }

    // MARK: Keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func setToken(_ token: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func token(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken(for account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
