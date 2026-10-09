import Foundation
import CryptoKit

/// A phone/tablet allowed to connect.
struct PairedDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    /// SHA-256 of the device token (the token itself is never stored).
    let tokenHash: String
    let pairedAt: Date
    var lastSeen: Date?
}

/// Paired devices and the one-time pairing code. Tokens are 256-bit random
/// values handed to the device once; only their hashes are kept, so the file
/// alone can't be used to connect. Revoking a device removes its hash.
@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [PairedDevice] = []
    /// The code currently shown on the Mac, if pairing is open.
    @Published private(set) var pairingCode: String?
    private(set) var pairingExpires: Date?
    private var failedAttempts = 0

    static let codeLifetime: TimeInterval = 5 * 60
    static let maxFailedAttempts = 5
    /// No 0/O, 1/I/L: the code is read off one screen and typed on another.
    private static let codeAlphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

    private let fileURL: URL

    init(fileURL: URL = AppPaths.support.appendingPathComponent("devices.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = list
        }
    }

    // MARK: Pairing

    /// Open pairing: a fresh 8-character code, valid for 5 minutes, single use.
    @discardableResult
    func beginPairing(now: Date = Date()) -> String {
        let code = String((0..<8).map { _ in Self.codeAlphabet.randomElement()! })
        pairingCode = code
        pairingExpires = now.addingTimeInterval(Self.codeLifetime)
        failedAttempts = 0
        return code
    }

    func cancelPairing() {
        pairingCode = nil
        pairingExpires = nil
    }

    /// Redeem the code: returns the new device and its token (to send once),
    /// or nil. Too many wrong guesses close pairing.
    func completePairing(code: String, deviceName: String, now: Date = Date()) -> (device: PairedDevice, token: String)? {
        guard let expected = pairingCode, let expires = pairingExpires, now < expires else {
            cancelPairing()
            return nil
        }
        let typed = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard Self.constantTimeEqual(typed, expected) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedAttempts { cancelPairing() }
            return nil
        }
        cancelPairing()
        let token = Self.randomToken()
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = PairedDevice(id: UUID().uuidString, name: name.isEmpty ? "Device" : String(name.prefix(60)),
                                  tokenHash: Self.hash(token), pairedAt: now, lastSeen: now)
        devices.append(device)
        save()
        return (device, token)
    }

    // MARK: Auth

    /// The device a token belongs to, if it's still paired.
    func authenticate(token: String, now: Date = Date()) -> PairedDevice? {
        let h = Self.hash(token)
        guard let i = devices.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, h) }) else { return nil }
        devices[i].lastSeen = now
        save()
        return devices[i]
    }

    func revoke(_ deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        save()
    }

    func rename(_ deviceID: String, to name: String) {
        guard let i = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[i].name = name
        save()
    }

    // MARK: Helpers

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
