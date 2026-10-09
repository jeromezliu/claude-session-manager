import Foundation
import Combine
import IOKit.pwr_mgt
import Darwin

/// A network interface the host can be reached on.
struct NetworkInterface: Identifiable, Hashable {
    var id: String { name }
    let name: String          // BSD name, e.g. en0, utun3
    let addresses: [String]   // IPv4 first
    var kind: String {
        if name.hasPrefix("en") { return "Wi-Fi / Ethernet" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return "VPN" }
        if name.hasPrefix("bridge") { return "Bridge" }
        return "Network"
    }

    /// Up, non-loopback interfaces with an address (skips AWDL & friends).
    static func current() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: [String]] = [:]
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard let addr = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  !["awdl", "llw", "anpi", "ap", "gif", "stf"].contains(where: name.hasPrefix) else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("fe80") { continue }   // link-local v6: not useful to type
            byName[name, default: []].append(ip)
        }
        return byName.map { name, ips in
            NetworkInterface(name: name, addresses: ips.sorted { !$0.contains(":") && $1.contains(":") })
        }.sorted { $0.name < $1.name }
    }
}

/// Append-only record of what remote devices did (JSON lines).
struct AuditLog {
    struct Entry: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        let device: String?
        let action: String
        let detail: String
    }

    let url: URL

    func append(device: String?, action: String, detail: String) {
        let entry = Entry(at: Date(), device: device, action: action, detail: detail)
        guard var line = try? JSONEncoder.remote.encode(entry) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func recent(_ n: Int) -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).compactMap {
            try? JSONDecoder.remote.decode(Entry.self, from: Data($0.utf8))
        }.reversed()
    }
}

/// Everything about remote access the UI toggles: on/off, network vs this
/// Mac only, which interfaces, keep-awake — persisted, applied to the server.
@MainActor
final class RemoteAccessController: ObservableObject {
    enum Scope: String, CaseIterable { case thisMac, network }

    @Published var enabled: Bool { didSet { save(); apply() } }
    @Published var scope: Scope { didSet { save(); restart() } }
    /// Interface names allowed in `.network` scope; empty = all.
    @Published var interfaces: Set<String> { didSet { save(); server.allowedInterfaces = interfaces.isEmpty ? nil : interfaces } }
    @Published var keepAwake: Bool { didSet { save(); updatePower() } }
    @Published private(set) var tlsError: String?
    @Published private(set) var recentAudit: [AuditLog.Entry] = []

    let server: RemoteServer
    let port: UInt16
    private let defaults = UserDefaults.standard
    private let audit = AuditLog(url: AppPaths.support.appendingPathComponent("remote-audit.log"))
    private var powerAssertion: IOPMAssertionID = 0
    private var runningSink: AnyCancellable?
    private(set) var tls: TLSIdentity?

    init(server: RemoteServer, port: UInt16 = 8473) {
        self.server = server
        self.port = port
        enabled = defaults.bool(forKey: "remoteAccessEnabled")
        scope = Scope(rawValue: defaults.string(forKey: "remoteAccessScope") ?? "") ?? .thisMac
        interfaces = Set((defaults.string(forKey: "remoteAccessInterfaces") ?? "").split(separator: ",").map(String.init))
        keepAwake = defaults.object(forKey: "remoteAccessKeepAwake") as? Bool ?? true
        server.allowedInterfaces = interfaces.isEmpty ? nil : interfaces
        server.onAudit = { [weak self] device, action, detail in
            self?.audit.append(device: device, action: action, detail: detail)
            self?.recentAudit = self?.audit.recent(20) ?? []
        }
        recentAudit = audit.recent(20)
        // The listener comes up asynchronously; hold the power assertion
        // exactly while it's actually running.
        runningSink = server.$isRunning.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updatePower() }
        }
    }

    /// Start or stop the server to match the settings.
    func apply() {
        if enabled {
            guard !server.isRunning else { return updatePower() }
            do {
                if tls == nil { tls = try TLSIdentity.loadOrCreate() }
                tlsError = nil
                server.tls = tls
                server.exposeOnNetwork = scope == .network
                try server.start(port: port)
                server.audit(nil, "remote access on", scope == .network ? "network" : "this Mac only")
            } catch {
                tlsError = error.localizedDescription
            }
        } else if server.isRunning {
            server.stop()
            server.audit(nil, "remote access off")
        }
        updatePower()
    }

    /// Kill switch: off now, and stays off.
    func turnOff() { enabled = false }

    func revoke(_ device: PairedDevice) {
        server.devices.revoke(device.id)
        server.disconnect(deviceID: device.id)
        server.audit(device.name, "revoked")
    }

    /// What the pairing QR code encodes: where to connect, which certificate
    /// to pin, and the one-time code.
    func pairingURL(code: String) -> String? {
        guard let tls else { return nil }
        let hosts = scope == .network
            ? NetworkInterface.current().filter { interfaces.isEmpty || interfaces.contains($0.name) }
                .flatMap(\.addresses).filter { !$0.contains(":") }
            : ["127.0.0.1"]
        var c = URLComponents()
        c.scheme = "csm"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "v", value: String(RemoteProtocol.version)),
                        URLQueryItem(name: "hosts", value: hosts.joined(separator: ",")),
                        URLQueryItem(name: "port", value: String(server.port ?? port)),
                        URLQueryItem(name: "fp", value: tls.fingerprint),
                        URLQueryItem(name: "code", value: code)]
        return c.string
    }

    private func restart() {
        guard enabled else { return }
        server.stop()
        apply()
    }

    private func save() {
        defaults.set(enabled, forKey: "remoteAccessEnabled")
        defaults.set(scope.rawValue, forKey: "remoteAccessScope")
        defaults.set(interfaces.sorted().joined(separator: ","), forKey: "remoteAccessInterfaces")
        defaults.set(keepAwake, forKey: "remoteAccessKeepAwake")
    }

    /// Keep the Mac from idle-sleeping while remote access is on (the display
    /// may still sleep). Released as soon as it's off.
    private func updatePower() {
        let want = enabled && keepAwake && server.isRunning
        if want, powerAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Claude Session Manager remote access" as CFString, &powerAssertion)
        } else if !want, powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }
}
