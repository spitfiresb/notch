import Foundation

enum AppInfo {
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "development") (\(info["CFBundleVersion"] as? String ?? "local"))"
    }
    static let releasesURL = URL(string: "https://github.com/spitfiresb/notch/releases")!
    static let issuesURL = URL(string: "https://github.com/spitfiresb/notch/issues/new")!
    static let privacyURL = URL(string: "https://github.com/spitfiresb/notch/blob/main/PRIVACY.md")!

    // Deliberately excludes usernames, paths, prompts, session IDs, tokens and logs.
    static var diagnostics: String {
        "Notch \(versionDescription)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nArchitecture: \(architecture)"
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64 (development build)"
        #endif
    }
}
