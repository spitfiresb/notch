import Foundation

/// Codex's documented lifecycle hooks, kept separate from config.toml and `notify`.
/// Hook trust remains owned by Codex; installation never changes its trust records.
struct CodexHooks {
    static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Interrupt",
        "PreToolUse", "PostToolUse", "PermissionRequest",
        "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
    ]

    static var current: CodexHooks {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let codexHome = configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return CodexHooks(settingsURL: codexHome.appendingPathComponent("hooks.json"),
                          supportDirectory: ClaudeHooks.supportDirectory)
    }

    let settingsURL: URL
    let supportDirectory: URL
    var scriptURL: URL { supportDirectory.appendingPathComponent("codex-hook.sh") }
    var spoolURL: URL { supportDirectory.appendingPathComponent("codex-events.jsonl") }

    /// Single-quote paths as shell literals, including homes containing quotes or `$`.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    var script: String {
        """
        #!/bin/bash
        # Installed by Notch.app. Observes events locally; emits no hook decisions.
        umask 077
        payload=$(/bin/cat | /usr/bin/tr -d '\\n')
        [ -z "$payload" ] && exit 0
        printf '{"ts":%s,"pid":%s,"event":%s}\\n' "$(/bin/date +%s)" "$PPID" "$payload" >> \(Self.shellQuote(spoolURL.path)) 2>/dev/null
        exit 0

        """
    }

    func ensureScript() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        if !fm.fileExists(atPath: spoolURL.path) {
            guard fm.createFile(atPath: spoolURL.path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private func entry(for event: String) -> [String: Any] {
        // A tiny synchronous append preserves lifecycle order. No subprocess lingers,
        // no output steers the model; the timeout also bounds a failed filesystem.
        ["type": "command", "command": Self.shellQuote(scriptURL.path),
         "timeout": event == "Interrupt" ? 1 : 2]
    }

    private func isOurs(_ hook: [String: Any]) -> Bool {
        hook["type"] as? String == "command"
            && hook["command"] as? String == Self.shellQuote(scriptURL.path)
    }

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        // Refuse malformed configuration instead of silently discarding user hooks.
        if let hooks = object["hooks"] {
            guard let events = hooks as? [String: Any], events.values.allSatisfy({ value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.allSatisfy { $0["hooks"] is [[String: Any]] }
            }) else { throw CocoaError(.propertyListReadCorrupt) }
        }
        return object
    }

    var isInstalled: Bool {
        guard let object = try? readSettings(), let hooks = object["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                group["matcher"] == nil && (group["hooks"] as? [[String: Any]] ?? []).contains {
                    NSDictionary(dictionary: $0).isEqual(to: entry(for: event))
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        var object = try readSettings()
        let original = object
        if enabled { try ensureScript() }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            let groups = hooks[event] as? [[String: Any]] ?? []
            if groups.isEmpty { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let kept = handlers.filter { !isOurs($0) }
                guard kept.count != handlers.count else { return group }
                guard !kept.isEmpty else { return nil }
                var result = group
                result["hooks"] = kept
                return result
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = cleaned }
        }
        if enabled {
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [entry(for: event)]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { object.removeValue(forKey: "hooks") }
        else { object["hooks"] = hooks }
        if NSDictionary(dictionary: original).isEqual(to: object) { return }
        if !enabled && !FileManager.default.fileExists(atPath: settingsURL.path) { return }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }
}
