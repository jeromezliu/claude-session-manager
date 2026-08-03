import Foundation
import AppKit
import Security

/// Fetches the **real** list of models the account can use from the Anthropic
/// Models API (`GET /v1/models`), which returns concrete ids and human display
/// names — so the picker shows "Claude Opus 4.8", not the `opus (latest)` alias.
///
/// Auth, in order: `ANTHROPIC_API_KEY` if the user has one, otherwise the
/// subscription OAuth access token the CLI already stores in
/// `~/.claude/.credentials.json`. The token is only ever read, never written:
/// refreshing it here could rotate the CLI's own token out from under it, so if
/// the stored token is stale the fetch just fails and the picker falls back to
/// concrete ids seen in the user's sessions.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    struct Model: Identifiable, Hashable {
        let id: String          // e.g. "claude-opus-4-8"
        let display: String     // e.g. "Claude Opus 4.8"
    }

    @Published private(set) var models: [Model] = []
    @Published private(set) var lastError: String?
    private var started = false

    /// Fetch once per launch; call freely from `.onAppear`.
    func loadIfNeeded() {
        guard !started else { return }
        started = true
        Task { await fetch() }
    }

    func fetch() async {
        do {
            models = try await Self.fetchModels()
            lastError = models.isEmpty ? "No models returned" : nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Networking

    private enum Err: LocalizedError {
        case noAuth, http(Int)
        var errorDescription: String? {
            switch self {
            case .noAuth: return "No Anthropic credentials found"
            case .http(let c): return "Models API returned HTTP \(c)"
            }
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Row]
        struct Row: Decodable { let id: String; let display_name: String? }
    }

    /// Runs off the main actor; pure networking + parsing.
    nonisolated static func fetchModels() async throws -> [Model] {
        guard let headers = authHeaders() else { throw Err.noAuth }
        var comps = URLComponents(string: "https://api.anthropic.com/v1/models")!
        comps.queryItems = [URLQueryItem(name: "limit", value: "100")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw Err.http(code) }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        // API returns newest first; keep that order.
        return decoded.data.map {
            Model(id: $0.id, display: $0.display_name ?? ModelCatalog.label(for: $0.id))
        }
    }

    /// Either an API-key header or an OAuth bearer header, or nil if neither.
    nonisolated static func authHeaders() -> [String: String]? {
        let version = "2023-06-01"
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return ["x-api-key": key, "anthropic-version": version]
        }
        if let token = oauthAccessToken() {
            return ["Authorization": "Bearer \(token)",
                    "anthropic-beta": "oauth-2025-04-20",
                    "anthropic-version": version]
        }
        return nil
    }

    /// The subscription OAuth access token from the CLI's credential store.
    /// Linux keeps it in `~/.claude/.credentials.json`; macOS keeps it in the
    /// Keychain (service "Claude Code-credentials"). Try the file first, then
    /// the Keychain. The blob is the same JSON either way.
    nonisolated static func oauthAccessToken() -> String? {
        if let token = tokenFromBlob(credentialsFileData()) { return token }
        if let token = tokenFromBlob(keychainCredentialData()) { return token }
        return nil
    }

    private nonisolated static func credentialsFileData() -> Data? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    /// Reads the generic-password blob the Claude CLI stores in the login
    /// Keychain. Because this app is signed differently from the CLI, macOS
    /// shows a one-time access prompt; "Always Allow" makes it silent after.
    private nonisolated static func keychainCredentialData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private nonisolated static func tokenFromBlob(_ data: Data?) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - Diagnostic (env-gated; prints model NAMES only, never the token)

    /// If `CSM_LIST_MODELS=<path>` is set, fetch the real list, write it to that
    /// path as JSON, and quit — lets the build be verified without the GUI.
    static func runDiagnosticIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CSM_LIST_MODELS"], !path.isEmpty
        else { return }
        Task { @MainActor in
            var out: [String: Any] = [:]
            do {
                let models = try await fetchModels()
                out["ok"] = true
                out["auth"] = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil
                    ? "api-key" : "oauth"
                out["models"] = models.map { ["id": $0.id, "display": $0.display] }
            } catch {
                out["ok"] = false
                out["error"] = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: path))
            NSApplication.shared.terminate(nil)
        }
    }
}
