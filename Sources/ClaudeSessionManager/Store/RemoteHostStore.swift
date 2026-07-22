import Foundation

/// Manages configured remote (SSH) hosts: persists the host list, mirrors
/// each host's projects folder into a local cache via `rsync` so the rest
/// of the app (SessionParser, SummaryCache, TranscriptView) can treat a
/// remote session exactly like a local one, and offers a connection test.
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

    func localCacheDir(for host: RemoteHost) -> URL {
        Self.cacheRoot.appendingPathComponent(host.alias, isDirectory: true)
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

    func addHost(alias: String, displayName: String, remoteRoot: String) {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { errorMessage = "Enter a host alias."; return }
        guard !hosts.contains(where: { $0.alias == alias }) else {
            errorMessage = "A host named “\(alias)” already exists."
            return
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = RemoteHost(alias: alias, displayName: name.isEmpty ? alias : name,
                               remoteRoot: root.isEmpty ? "~/.claude/projects" : root)
        hosts.append(host)
        save()
        Task { await sync(host) }
    }

    func updateHost(_ host: RemoteHost) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i] = host
        save()
        if host.enabled { Task { await sync(host) } }
    }

    func removeHost(_ host: RemoteHost) {
        hosts.removeAll { $0.id == host.id }
        syncStatus[host.id] = nil
        save()
        try? FileManager.default.removeItem(at: localCacheDir(for: host))
    }

    // MARK: - Connection test

    func testConnection(_ host: RemoteHost) async -> Result<Void, Error> {
        do {
            let out = try await RemoteShell.sshRun(alias: host.alias, remoteCommand: "echo ok", timeout: 10)
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

        let remoteSpec = "\(host.alias):\(host.remoteRoot)/"
        do {
            let out = try await RemoteShell.run(
                "/usr/bin/rsync",
                ["-az", "--delete", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10",
                 remoteSpec, dest.path + "/"],
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
        let remoteSpec = "\(host.alias):\(host.remoteRoot)/\(encodedFolder)/"
        _ = try? await RemoteShell.run(
            "/usr/bin/rsync",
            ["-az", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", remoteSpec, dest.path + "/"],
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
