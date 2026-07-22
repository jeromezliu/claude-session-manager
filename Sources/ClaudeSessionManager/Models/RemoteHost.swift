import Foundation

/// A remote/cloud-shell host reachable over SSH, identified by an
/// `~/.ssh/config` `Host` alias. All auth (user, port, identity file) is
/// expected to already live in ssh config — the app stores nothing but the
/// alias, a friendly label, and which remote folder to scan.
struct RemoteHost: Identifiable, Hashable, Codable, Sendable {
    var id: String { alias }

    /// Matches a `Host` entry in ~/.ssh/config (or a plain user@hostname).
    var alias: String
    var displayName: String
    /// Remote folder to scan for `.jsonl` sessions, mirroring `rootPath` locally.
    var remoteRoot: String = "~/.claude/projects"
    var enabled: Bool = true
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
