import Foundation
import Security
import CryptoKit

/// The host's TLS identity: a self-signed P-256 certificate made on first
/// use. Clients pin its SHA-256 fingerprint (delivered in the pairing QR code
/// and shown as a short security code on both screens), so no CA is involved.
///
/// Stored as a PKCS#12 file (0600) in the app's support folder; its password
/// lives in the Keychain. Imported into memory only, so using it never
/// touches or prompts for the Keychain's certificate store.
struct TLSIdentity {
    let identity: SecIdentity
    /// DER bytes of the certificate.
    let certificate: Data

    /// Hex SHA-256 of the certificate — what clients pin.
    var fingerprint: String { Self.fingerprint(of: certificate) }

    /// Six digits both screens show during pairing.
    var securityCode: String { Self.securityCode(forFingerprint: fingerprint) }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func securityCode(forFingerprint fp: String) -> String {
        PairingSecurity.code(forFingerprint: fp)
    }

    enum TLSError: LocalizedError {
        case generation(String), importFailed(OSStatus), noIdentity
        var errorDescription: String? {
            switch self {
            case .generation(let m): return "Couldn't create the TLS certificate: \(m)"
            case .importFailed(let s): return "Couldn't load the TLS certificate (\(s))."
            case .noIdentity: return "The TLS certificate file has no identity."
            }
        }
    }

    static let defaultKeychainAccount = "csm-tls-identity"

    /// Load the identity, creating it on first use. Tests pass their own
    /// folder and Keychain account so they never touch the app's identity.
    static func loadOrCreate(in dir: URL = AppPaths.support.appendingPathComponent("tls", isDirectory: true),
                             keychainAccount: String = defaultKeychainAccount) throws -> TLSIdentity {
        let p12 = dir.appendingPathComponent("identity.p12")
        if let data = try? Data(contentsOf: p12), let password = SSHKeychain.password(for: keychainAccount),
           let loaded = try? load(p12: data, password: password) {
            return loaded
        }
        let password = DeviceStore.randomToken()
        let data = try generate(password: password, scratch: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: p12, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        SSHKeychain.setPassword(password, for: keychainAccount)
        return try load(p12: data, password: password)
    }

    static func load(p12 data: Data, password: String) throws -> TLSIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15.0, iOS 18.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw TLSError.importFailed(status) }
        guard let first = (items as? [[String: Any]])?.first,
              let ref = first[kSecImportItemIdentity as String] else { throw TLSError.noIdentity }
        let identity = ref as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw TLSError.noIdentity }
        return TLSIdentity(identity: identity, certificate: SecCertificateCopyData(cert) as Data)
    }

    /// Self-signed P-256 certificate + key as PKCS#12, via the system's LibreSSL.
    private static func generate(password: String, scratch: URL) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("csm-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = tmp.appendingPathComponent("key.pem").path
        let cert = tmp.appendingPathComponent("cert.pem").path
        let out = tmp.appendingPathComponent("id.p12").path
        let name = Host.current().localizedName ?? "Mac"
        // The key must be SEC1 ("EC PRIVATE KEY", from `ecparam`): a PKCS#8 EC
        // key (`req -newkey ec`) makes SecPKCS12Import's memory-only path
        // throw on macOS 26+ (verified: SEC1 and RSA import, PKCS#8 crashes).
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        try openssl(["req", "-new", "-x509", "-key", key, "-days", "3650",
                     "-subj", "/CN=Claude Session Manager (\(name))", "-out", cert])
        // The password goes through the environment, never the command line
        // (which any local process can read with `ps`).
        try openssl(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", out, "-passout", "env:CSM_P12_PASS"],
                    env: ["CSM_P12_PASS": password])
        return try Data(contentsOf: URL(fileURLWithPath: out))
    }

    private static func openssl(_ args: [String], env: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice   // never wait for a prompt
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw TLSError.generation(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
