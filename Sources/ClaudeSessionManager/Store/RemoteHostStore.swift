import Foundation

/// Manages configured remote (SSH) hosts: persists the host list (passwords go
/// to the Keychain, not the JSON), mirrors each host's projects folder into a
/// local cache via `rsync` so the rest of the app (SessionParser, SummaryCache,
/// TranscriptView) can treat a remote session exactly like a local one, and
/// offers a connection test.
@MainActor
final class RemoteHostStore: ObservableObject {
    @Published var hosts: [RemoteHost] = []
    @Published var syncStatus: [String: HostSyncStatus] = [:]
    @Published var errorMessage: String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    private static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeSessionManager/remote-hosts.json")
    }

    private static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeSessionManager/RemoteCache", isDirectory: true)
    }

    init() {
        load()
        startPeriodicSync()
    }

    func host(withID id: String) -> RemoteHost? {
        hosts.first { $0.id == id }
    }

    func localCacheDir(for host: RemoteHost) -> URL {
        Self.cacheRoot.appendingPathComponent(host.id, isDirectory: true)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let decoded = try? Self.decoder.decode([RemoteHost].self, from: data) else { return }
        hosts = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(),
                                                      withIntermediateDirectories: true)
            let data = try Self.encoder.encode(hosts)
            try data.write(to: Self.configURL)
        } catch {
            errorMessage = "Couldn't save remote hosts: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    /// Add a fully-configured host. A non-nil `password` is stored in the
    /// Keychain under the host's id (only meaningful for `.password` auth).
    func addHost(_ host: RemoteHost, password: String?) {
        guard validate(host, ignoringID: nil) else { return }
        hosts.append(host)
        if host.authMethod == .password, let password, !password.isEmpty {
            SSHKeychain.setPassword(password, for: host.id)
        }
        save()
        errorMessage = nil
        Task { await sync(host) }
    }

    /// Update a host in place. `password == nil` leaves the stored password
    /// untouched (so an edit sheet can keep its password field blank).
    func updateHost(_ host: RemoteHost, password: String? = nil) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        guard validate(host, ignoringID: host.id) else { return }
        hosts[i] = host
        if let password, !password.isEmpty, host.authMethod == .password {
            SSHKeychain.setPassword(password, for: host.id)
        }
        if host.authMethod != .password {
            SSHKeychain.deletePassword(for: host.id)
        }
        save()
        errorMessage = nil
        if host.enabled { Task { await sync(host) } }
    }

    func removeHost(_ host: RemoteHost) {
        hosts.removeAll { $0.id == host.id }
        syncStatus[host.id] = nil
        SSHKeychain.deletePassword(for: host.id)
        save()
        try? FileManager.default.removeItem(at: localCacheDir(for: host))
    }

    private func validate(_ host: RemoteHost, ignoringID: String?) -> Bool {
        guard !host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a hostname or IP address."
            return false
        }
        guard (1...65535).contains(host.port) else {
            errorMessage = "Port must be between 1 and 65535."
            return false
        }
        if hosts.contains(where: { $0.id != ignoringID && $0.destination == host.destination && $0.port == host.port }) {
            errorMessage = "A host for \(host.endpoint) already exists."
            return false
        }
        return true
    }

    // MARK: - Connection test

    func testConnection(_ host: RemoteHost) async -> Result<Void, Error> {
        do {
            let out = try await RemoteShell.sshRun(host: host, remoteCommand: "echo ok", timeout: 15)
            if out.succeeded && out.stdout.contains("ok") { return .success(()) }
            let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(NSError(domain: "ClaudeSessionManager", code: 2,
                                     userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Connection failed." : msg]))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Sync

    /// Full mirror of one host's remote root into its local cache dir.
    func sync(_ host: RemoteHost) async {
        syncStatus[host.id, default: HostSyncStatus()].phase = .syncing
        let dest = localCacheDir(for: host)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let remoteSpec = "\(host.destination):\(host.remoteRoot)/"
        do {
            let out = try await RemoteShell.run(
                "/usr/bin/rsync",
                ["-az", "--delete", "-e", RemoteShell.rsyncRemoteShell(for: host),
                 remoteSpec, dest.path + "/"],
                environment: RemoteShell.environment(for: host),
                timeout: 120)
            if out.succeeded {
                syncStatus[host.id] = HostSyncStatus(phase: .idle, lastSyncedAt: Date())
            } else {
                let msg = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                syncStatus[host.id] = HostSyncStatus(phase: .failed(msg.isEmpty ? "rsync failed" : msg),
                                                      lastSyncedAt: syncStatus[host.id]?.lastSyncedAt)
            }
        } catch {
            syncStatus[host.id] = HostSyncStatus(phase: .failed(error.localizedDescription),
                                                  lastSyncedAt: syncStatus[host.id]?.lastSyncedAt)
        }
    }

    /// Scoped mirror of a single project subfolder — used while polling for a
    /// brand-new remote session's file, much cheaper than a full-tree sync.
    func syncProjectFolder(_ host: RemoteHost, _ encodedFolder: String) async {
        let dest = localCacheDir(for: host).appendingPathComponent(encodedFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let remoteSpec = "\(host.destination):\(host.remoteRoot)/\(encodedFolder)/"
        _ = try? await RemoteShell.run(
            "/usr/bin/rsync",
            ["-az", "-e", RemoteShell.rsyncRemoteShell(for: host), remoteSpec, dest.path + "/"],
            environment: RemoteShell.environment(for: host),
            timeout: 30)
    }

    func syncAll() async {
        for host in hosts where host.enabled {
            await sync(host)
        }
    }

    private func startPeriodicSync() {
        Task { [weak self] in
            while let self {
                await self.syncAll()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}
