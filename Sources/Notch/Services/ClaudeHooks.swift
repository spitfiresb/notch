import Foundation

/// Installs / removes the Claude Code hook entries that let Notch observe live
/// sessions. Claude Code runs a shell command on each lifecycle event and feeds
/// it JSON on stdin; our command is a tiny script that wraps that JSON with a
/// timestamp + parent pid and appends it to a spool file that
/// `AgentSessionStore` tails. A file (not a socket) so events buffer while
/// Notch isn't running and the store can rebuild state on launch.
struct ClaudeHooks {

    /// Every event we subscribe to. Anything else Claude Code emits is ignored.
    static let events = [
        "SessionStart", "SessionEnd",
        "UserPromptSubmit", "Stop", "StopFailure",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification",
        "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact",
        "CwdChanged",
    ]

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notch", isDirectory: true)
    }
    static var current: ClaudeHooks {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return ClaudeHooks(settingsURL: root.appendingPathComponent("settings.json"),
                           directory: supportDirectory)
    }
    let settingsURL: URL
    let directory: URL
    var scriptURL: URL { directory.appendingPathComponent("claude-hook.sh") }
    var spoolURL: URL { directory.appendingPathComponent("claude-events.jsonl") }

    // MARK: Script

    var script: String {
        """
        #!/bin/bash
        # Installed by Notch.app — forwards Claude Code hook events to the notch.
        # Reads the hook JSON from stdin and appends one line to the spool file.
        # Safe to delete; Notch re-creates it. Never blocks or fails a session.
        umask 077
        payload=$(/bin/cat | /usr/bin/tr -d '\\n')
        [ -z "$payload" ] && exit 0
        printf '{"ts":%s,"pid":%s,"event":%s}\\n' "$(/bin/date +%s)" "$PPID" "$payload" >> \(CodexHooks.shellQuote(spoolURL.path)) 2>/dev/null
        exit 0

        """
    }

    @discardableResult
    func ensureScript() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = try? String(contentsOf: scriptURL, encoding: .utf8)
            if current != script {
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            if !fm.fileExists(atPath: spoolURL.path) {
                guard fm.createFile(atPath: spoolURL.path, contents: nil,
                                    attributes: [.posixPermissions: 0o600]) else { return false }
            }
            return true
        } catch {
            notchLog("claude-hooks: script write failed: \(error)")
            return false
        }
    }

    // MARK: settings.json

    private func readSettings() throws -> (object: [String: Any], bytes: Data?) {
        let bytes: Data
        do { bytes = try Data(contentsOf: settingsURL) }
        catch CocoaError.fileReadNoSuchFile { return ([:], nil) }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if let value = object["hooks"] {
            guard let hooks = value as? [String: Any], hooks.values.allSatisfy({ value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.allSatisfy { $0["hooks"] is [[String: Any]] }
            }) else { throw CocoaError(.propertyListReadCorrupt) }
        }
        return (object, bytes)
    }

    private func isOurs(_ hook: [String: Any]) -> Bool {
        guard hook["type"] as? String == "command", let command = hook["command"] as? String else { return false }
        // Exact matching also recognizes our previous double-quoted command.
        return command == CodexHooks.shellQuote(scriptURL.path) || command == "\"\(scriptURL.path)\""
    }

    private var hookEntry: [String: Any] {
        // A bounded synchronous append keeps lifecycle events in order. No decisions/output.
        ["type": "command", "command": CodexHooks.shellQuote(scriptURL.path), "timeout": 2]
    }

    var isInstalled: Bool {
        guard let settings = try? readSettings(),
              let hooks = settings.object["hooks"] as? [String: Any] else { return false }
        return Self.events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                group["matcher"] == nil && (group["hooks"] as? [[String: Any]] ?? []).contains {
                    NSDictionary(dictionary: $0).isEqual(to: hookEntry)
                }
            }
        }
    }

    /// Preserve invalid/unreadable files byte for byte. Monitoring runs independently.
    /// Save the original bytes before a change and abandon a stale read if another writer edited it.
    func setEnabled(_ enabled: Bool) throws {
        let original = try readSettings()
        var settings = original.object
        if enabled {
            guard ensureScript() else { throw CocoaError(.fileWriteUnknown) }
            // Respect the user's explicit hook policy; transcript monitoring still works.
            if settings["disableAllHooks"] as? Bool == true { return }
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Array(hooks.keys) {
            let groups = hooks[event] as? [[String: Any]] ?? []
            guard !groups.isEmpty else { continue }
            let cleaned = groups.compactMap { group -> [String: Any]? in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                let kept = handlers.filter { !isOurs($0) }
                guard kept.count != handlers.count else { return group }
                guard !kept.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = cleaned }
        }
        if enabled {
            for event in Self.events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [hookEntry]])
                hooks[event] = groups
            }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        guard !NSDictionary(dictionary: original.object).isEqual(to: settings) else { return }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let bytes = original.bytes {
            let backups = directory.appendingPathComponent("settings-backups")
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let backup = backups.appendingPathComponent("claude-\(UUID().uuidString).json")
            try bytes.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard try readSettings().bytes == original.bytes else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }
}
