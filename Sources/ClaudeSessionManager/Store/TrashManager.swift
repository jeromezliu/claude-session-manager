import Foundation

/// App-managed trash for deleted sessions. Files are moved into a dedicated
/// folder (not the system Trash) so the app can list, recover, and permanently
/// delete them. Each trashed `.jsonl` gets a `.meta` sidecar recording where it
/// came from.
enum TrashManager {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudeSessionManager/Trash", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Operations

    /// Move a session into the trash, writing a `.meta` sidecar. For a remote
    /// session, this also removes the original from the host over SSH — the
    /// file moved into Trash here is the already-mirrored local cache copy.
    static func trash(_ session: SessionSummary, remoteHostStore: RemoteHostStore? = nil) async throws {
        try ensureDirectory()
        let fm = FileManager.default

        var target = directory.appendingPathComponent(session.id).appendingPathExtension("jsonl")
        var counter = 1
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(session.id)-\(counter)").appendingPathExtension("jsonl")
            counter += 1
        }

        var remoteAlias: String?
        var remoteDisplayName: String?
        var remoteRoot: String?
        if let alias = session.remoteAlias, let hostStore = remoteHostStore,
           let host = await hostStore.hosts.first(where: { $0.alias == alias }) {
            let remotePath = "\(host.remoteRoot)/\(session.projectFolder)/\(session.id).jsonl"
            let out = try await RemoteShell.sshRun(alias: alias, remoteCommand: "rm \(RemoteShell.shellQuote(remotePath))")
            guard out.succeeded else {
                throw NSError(domain: "ClaudeSessionManager", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: out.stderr.isEmpty ? "Couldn't remove the remote file." : out.stderr])
            }
            remoteAlias = alias
            remoteDisplayName = host.displayName
            remoteRoot = host.remoteRoot
        }

        try fm.moveItem(at: session.fileURL, to: target)

        let meta = TrashMeta(originalPath: session.fileURL.path,
                             projectFolder: session.projectFolder,
                             title: session.title,
                             deletedAt: Date(),
                             remoteAlias: remoteAlias,
                             remoteDisplayName: remoteDisplayName,
                             remoteRoot: remoteRoot)
        let metaURL = target.appendingPathExtension("meta")
        try encoder.encode(meta).write(to: metaURL)
    }

    /// List everything currently in the trash, newest first.
    static func list() -> [TrashEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }

        var entries: [TrashEntry] = []
        for url in files where url.pathExtension == "jsonl" {
            let metaURL = url.appendingPathExtension("meta")
            let meta = (try? Data(contentsOf: metaURL)).flatMap { try? decoder.decode(TrashMeta.self, from: $0) }
            guard var summary = SessionParser.summary(for: url) else { continue }

            // Prefer the stored title/original path from the sidecar.
            if let meta {
                summary = summary.withTitle(meta.title.isEmpty ? summary.title : meta.title)
            }
            let originalPath = meta?.originalPath
                ?? SessionSummary.decodeFolder(summary.projectFolder) + "/" + url.lastPathComponent
            let deletedAt = meta?.deletedAt
                ?? ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
            if let alias = meta?.remoteAlias, let name = meta?.remoteDisplayName {
                summary = summary.withRemote(alias: alias, displayName: name)
            }

            entries.append(TrashEntry(summary: summary, trashedURL: url, metaURL: metaURL,
                                      originalPath: originalPath, deletedAt: deletedAt,
                                      remoteAlias: meta?.remoteAlias, remoteDisplayName: meta?.remoteDisplayName,
                                      remoteRoot: meta?.remoteRoot))
        }
        return entries.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Restore a trashed session to its original location. Returns the path it
    /// was restored to (may differ if the original name was taken). For a
    /// remote session, this re-uploads the file to the host over `scp` instead
    /// of moving it on the local filesystem.
    @discardableResult
    static func recover(_ entry: TrashEntry, remoteHostStore: RemoteHostStore? = nil) async throws -> URL {
        if let alias = entry.remoteAlias, let root = entry.remoteRoot, let hostStore = remoteHostStore,
           let host = await hostStore.hosts.first(where: { $0.alias == alias }) {
            let remotePath = "\(root)/\(entry.summary.projectFolder)/\(entry.summary.id).jsonl"
            let remoteDir = (remotePath as NSString).deletingLastPathComponent
            let mkdir = try await RemoteShell.sshRun(alias: alias, remoteCommand: "mkdir -p \(RemoteShell.shellQuote(remoteDir))")
            guard mkdir.succeeded else {
                throw NSError(domain: "ClaudeSessionManager", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: mkdir.stderr.isEmpty ? "Couldn't prepare the remote folder." : mkdir.stderr])
            }
            let scp = try await RemoteShell.run("/usr/bin/scp",
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", entry.trashedURL.path, "\(alias):\(remotePath)"])
            guard scp.succeeded else {
                throw NSError(domain: "ClaudeSessionManager", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: scp.stderr.isEmpty ? "Couldn't upload the session." : scp.stderr])
            }
            try? FileManager.default.removeItem(at: entry.trashedURL)
            try? FileManager.default.removeItem(at: entry.metaURL)
            await hostStore.syncProjectFolder(host, entry.summary.projectFolder)
            return URL(fileURLWithPath: remotePath)
        }

        let fm = FileManager.default
        let original = URL(fileURLWithPath: entry.originalPath)
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)

        var dest = original
        if fm.fileExists(atPath: dest.path) {
            let stem = original.deletingPathExtension().lastPathComponent
            let dir = original.deletingLastPathComponent()
            var counter = 1
            repeat {
                dest = dir.appendingPathComponent("\(stem)-recovered\(counter == 1 ? "" : "-\(counter)")")
                          .appendingPathExtension("jsonl")
                counter += 1
            } while fm.fileExists(atPath: dest.path)
        }

        try fm.moveItem(at: entry.trashedURL, to: dest)
        try? fm.removeItem(at: entry.metaURL)
        return dest
    }

    /// Permanently delete a single trashed session.
    static func purge(_ entry: TrashEntry) throws {
        let fm = FileManager.default
        try fm.removeItem(at: entry.trashedURL)
        try? fm.removeItem(at: entry.metaURL)
    }

    /// Permanently delete everything in the trash.
    static func empty() throws {
        for entry in list() { try? purge(entry) }
    }
}
