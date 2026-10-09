import Foundation

/// Version info stamped into Info.plist by build.sh.
enum AppInfo {
    /// e.g. "1.3.0" for a release, "1.3.0+2.fc9b2db" for a build past the
    /// v1.3.0 tag; "dev" when run outside an app bundle (`swift run`).
    static var version: String {
        let info = Bundle.main.infoDictionary
        return (info?["CSMFullVersion"] as? String)
            ?? (info?["CFBundleShortVersionString"] as? String)
            ?? "dev"
    }
}
