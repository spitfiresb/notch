import Foundation

/// Installs / removes the Claude Code hook entries that let Notch observe live
/// sessions. Claude Code runs a shell command on each lifecycle event and feeds
/// it JSON on stdin; our command is a tiny script that wraps that JSON with a
/// timestamp + parent pid and appends it to a spool file that
/// `ClaudeSessionStore` tails. A file (not a socket) so events buffer while
/// Notch isn't running and the store can rebuild state on launch.
enum ClaudeHooks {

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
    static var scriptURL: URL { supportDirectory.appendingPathComponent("claude-hook.sh") }
    static var spoolURL: URL { supportDirectory.appendingPathComponent("claude-events.jsonl") }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// Substring that identifies our hook entries inside settings.json, so the
    /// uninstaller only ever touches what we added.
    private static let marker = "Notch/claude-hook.sh"

    // MARK: Script

    private static var script: String {
        """
        #!/bin/bash
        # Installed by Notch.app — forwards Claude Code hook events to the notch.
        # Reads the hook JSON from stdin and appends one line to the spool file.
        # Safe to delete; Notch re-creates it. Never blocks or fails a session.
        SPOOL="\(spoolURL.path)"
        payload=$(cat | tr -d '\\n')
        [ -z "$payload" ] && exit 0
        printf '{"ts":%s,"pid":%s,"event":%s}\\n' "$(date +%s)" "$PPID" "$payload" >> "$SPOOL" 2>/dev/null
        exit 0

        """
    }

    @discardableResult
    static func ensureScript() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let current = try? String(contentsOf: scriptURL, encoding: .utf8)
            if current != script {
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            if !fm.fileExists(atPath: spoolURL.path) {
                fm.createFile(atPath: spoolURL.path, contents: nil)
            }
            return true
        } catch {
            notchLog("claude-hooks: script write failed: \(error)")
            return false
        }
    }

    // MARK: settings.json

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    private static func writeSettings(_ obj: [String: Any]) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            notchLog("claude-hooks: settings write failed: \(error)")
            return false
        }
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(marker) == true
    }

    /// The exact entry `install()` writes. Quoted: the path has a space
    /// (Application Support) and Claude runs the command through a shell.
    private static var hookEntry: [String: Any] {
        ["type": "command", "command": "\"\(scriptURL.path)\"", "timeout": 5, "async": true]
    }

    /// Ours *and* up to date — an older-shaped entry counts as not installed so
    /// launch re-runs `install()` and refreshes it.
    private static func isCurrent(_ hook: [String: Any]) -> Bool {
        isOurs(hook)
            && hook["command"] as? String == hookEntry["command"] as? String
            && hook["async"] as? Bool == true
    }

    /// True when every event we care about already routes to our script.
    static var isInstalled: Bool {
        guard let hooks = readSettings()["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: isCurrent)
            }
        }
    }

    /// Adds one matcher-less group per event pointing at our script. Existing
    /// user hooks are preserved untouched; re-running is idempotent.
    @discardableResult
    static func install() -> Bool {
        guard ensureScript() else { return false }
        var settings = readSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let ourHook = hookEntry
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Drop any stale copies (older script path / options) then add fresh.
            groups = groups.compactMap { g in
                var g = g
                let kept = ((g["hooks"] as? [[String: Any]]) ?? []).filter { !isOurs($0) }
                if kept.isEmpty, (g["hooks"] as? [[String: Any]])?.isEmpty == false { return nil }
                g["hooks"] = kept
                return g
            }
            groups.append(["hooks": [ourHook]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        let ok = writeSettings(settings)
        notchLog("claude-hooks: install \(ok ? "ok" : "FAILED")")
        return ok
    }

    /// Removes only our entries; leaves everything else in settings.json alone.
    @discardableResult
    static func uninstall() -> Bool {
        var settings = readSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return true }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { g in
                var g = g
                let kept = ((g["hooks"] as? [[String: Any]]) ?? []).filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                g["hooks"] = kept
                return g
            }
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        let ok = writeSettings(settings)
        notchLog("claude-hooks: uninstall \(ok ? "ok" : "FAILED")")
        return ok
    }
}
