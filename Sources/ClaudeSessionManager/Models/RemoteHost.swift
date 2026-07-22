import Foundation

/// A remote/cloud-shell host reachable over SSH, configured entirely in-app:
/// hostname, port, username, and either a private key/certificate file or a
/// password. The password itself is never written to the config JSON — it
/// lives in the macOS Keychain, keyed by `id` (see `SSHKeychain`).
struct RemoteHost: Identifiable, Hashable, Codable, Sendable {
    enum AuthMethod: String, Codable, Sendable, CaseIterable {
        /// A private key / certificate file (or the user's default keys and
        /// ssh-agent when no file is set).
        case privateKey
        /// A password stored in the Keychain, supplied via ssh-askpass.
        case password

        var label: String {
            switch self {
            case .privateKey: return "Key / Certificate"
            case .password: return "Password"
            }
        }
    }

    /// Stable identifier — also the local mirror-cache folder name and the
    /// Keychain account for this host's password.
    var id: String = UUID().uuidString

    var displayName: String
    var hostname: String
    var port: Int = 22
    /// Empty means "let ssh pick the local username".
    var username: String
    var authMethod: AuthMethod = .privateKey
    /// Path to a private key / certificate file. Empty (with `.privateKey`)
    /// falls back to the user's default identities and ssh-agent.
    var identityFile: String = ""
    /// Remote folder to scan for `.jsonl` sessions, mirroring `rootPath` locally.
    var remoteRoot: String = "~/.claude/projects"
    /// Pre-filled working directory when starting a new session on this host.
    var defaultWorkingDirectory: String = ""
    var enabled: Bool = true

    /// `user@host` (or bare host when no username), for ssh/scp/rsync specs.
    var destination: String {
        username.isEmpty ? hostname : "\(username)@\(hostname)"
    }

    /// Human-readable endpoint for the UI: `user@host:port`.
    var endpoint: String {
        port == 22 ? destination : "\(destination):\(port)"
    }

    // MARK: - Codable (with migration from the old alias-based format)

    private enum CodingKeys: String, CodingKey {
        case id, displayName, hostname, port, username
        case authMethod, identityFile, remoteRoot, defaultWorkingDirectory, enabled
        case alias   // legacy: an ~/.ssh/config Host alias (read-only)
    }

    init(id: String = UUID().uuidString, displayName: String, hostname: String,
         port: Int = 22, username: String, authMethod: AuthMethod = .privateKey,
         identityFile: String = "", remoteRoot: String = "~/.claude/projects",
         defaultWorkingDirectory: String = "", enabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.remoteRoot = remoteRoot
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        remoteRoot = try c.decodeIfPresent(String.self, forKey: .remoteRoot) ?? "~/.claude/projects"
        defaultWorkingDirectory = try c.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true

        if let hostname = try c.decodeIfPresent(String.self, forKey: .hostname) {
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            self.hostname = hostname
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
            authMethod = try c.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .privateKey
            identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        } else if let alias = try c.decodeIfPresent(String.self, forKey: .alias) {
            // Legacy entry from the ~/.ssh/config-alias era. Keep `id == alias`
            // so the local mirror cache and trash metadata still resolve; the
            // alias is treated as a plain hostname (splitting a `user@` prefix
            // if present) and can be corrected in the UI afterwards.
            id = alias
            if let at = alias.firstIndex(of: "@") {
                username = String(alias[..<at])
                hostname = String(alias[alias.index(after: at)...])
            } else {
                username = ""
                hostname = alias
            }
            port = 22
            authMethod = .privateKey
            identityFile = ""
            if displayName.isEmpty { displayName = alias }
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "RemoteHost entry has neither 'hostname' nor legacy 'alias'."))
        }
        if displayName.isEmpty { displayName = hostname }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(authMethod, forKey: .authMethod)
        try c.encode(identityFile, forKey: .identityFile)
        try c.encode(remoteRoot, forKey: .remoteRoot)
        try c.encode(defaultWorkingDirectory, forKey: .defaultWorkingDirectory)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// Live sync state for one host, tracked separately from the persisted config.
struct HostSyncStatus: Sendable {
    enum Phase: Sendable, Equatable {
        case idle
        case syncing
        case failed(String)
    }
    var phase: Phase = .idle
    var lastSyncedAt: Date?
}
