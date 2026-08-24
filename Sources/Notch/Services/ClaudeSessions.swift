import AppKit
import Combine
import Darwin

// MARK: - Model

/// One live Claude Code session, as reconstructed from hook events.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable {
        /// Waiting for the user to type a prompt.
        case idle
        /// Model is generating (between prompt/tool-result and the next tool call or stop).
        case thinking
        /// A tool is executing.
        case tool
        /// Blocked on the user: permission prompt, question, MCP elicitation.
        case waiting
        /// Context compaction in progress.
        case compacting
        /// Turn finished; user hasn't responded yet.
        case done
        /// Turn ended on an API error.
        case failed
    }

    let id: String                       // Claude's session_id
    var pid: pid_t?                      // the `claude` process, once resolved
    var tty: String?                     // e.g. "ttys001" — for terminal window lookup
    var cwd: String
    var transcriptPath: String?
    var model: String?
    var state: State = .idle
    var branch: String?
    /// Human-readable current activity: "Bash · ./build.sh run", "Edit · Tabs.swift"…
    var activity: String?
    var lastPrompt: String?
    var lastReply: String?
    /// Why it needs you (permission prompt text, question, error). Cleared when the user acts.
    var attention: String?
    var subagentCount = 0
    var turnStartedAt: Date?
    var lastEventAt: Date
    var startedAt: Date

    var projectName: String { (cwd as NSString).lastPathComponent }
    var needsAttention: Bool { state == .waiting || state == .failed }
    var isBusy: Bool { state == .thinking || state == .tool || state == .compacting }
}

// MARK: - Store

/// Tails the hook spool file, folds events into `sessions`, and drops sessions
/// whose `claude` process has exited. Also knows how to bring a session's
/// terminal window to the front.
@MainActor
final class ClaudeSessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hooksInstalled = false

    /// Fired when a session flips into a state that deserves a nudge
    /// (needs permission / finished / failed). UI decides how loud to be.
    var onAttention: ((ClaudeSession) -> Void)?

    private var byID: [String: ClaudeSession] = [:]
    private var fd: Int32 = -1
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var livenessTimer: Timer?
    private var pendingBuffer = Data()

    private static let spoolTruncateBytes: UInt64 = 4_000_000

    /// Sessions sorted for display: needs-you first, then busiest/most recent.
    var ordered: [ClaudeSession] {
        sessions.sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.lastEventAt > b.lastEventAt
        }
    }
    var attentionCount: Int { sessions.filter(\.needsAttention).count }

    // MARK: Lifecycle

    func start() {
        hooksInstalled = ClaudeHooks.isInstalled
        ClaudeHooks.ensureScript()
        replayAndTruncate()
        openSpool()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reapDead() }
        }
    }

    func setHooksEnabled(_ enabled: Bool) {
        if enabled { ClaudeHooks.install() } else { ClaudeHooks.uninstall() }
        hooksInstalled = ClaudeHooks.isInstalled
    }

    // MARK: Spool tailing

    /// On launch: fold everything that accumulated while we were away, then
    /// truncate so the file can't grow forever. Dead sessions get reaped right
    /// after, so a stale spool doesn't resurrect ghosts.
    private func replayAndTruncate() {
        let url = ClaudeHooks.spoolURL
        if let data = try? Data(contentsOf: url) {
            ingest(data)
        }
        try? Data().write(to: url)
        offset = 0
        reapDead()
    }

    private func openSpool() {
        source?.cancel(); source = nil
        fd = open(ClaudeHooks.spoolURL.path, O_EVTONLY)
        guard fd >= 0 else { notchLog("claude-sessions: spool open failed"); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                // Someone removed the spool — recreate and re-arm.
                ClaudeHooks.ensureScript()
                self.offset = 0
                self.openSpool()
                return
            }
            self.readNew()
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
        readNew()
    }

    private func readNew() {
        guard let fh = try? FileHandle(forReadingFrom: ClaudeHooks.spoolURL) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0 }            // truncated underneath us
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return }
        offset = size
        ingest(data)
        if size > Self.spoolTruncateBytes {
            try? Data().write(to: ClaudeHooks.spoolURL)
            offset = 0
        }
    }

    private func ingest(_ data: Data) {
        pendingBuffer.append(data)
        // Lines are complete once a newline lands; keep any partial tail.
        while let nl = pendingBuffer.firstIndex(of: 0x0A) {
            let line = pendingBuffer.subdata(in: pendingBuffer.startIndex..<nl)
            pendingBuffer.removeSubrange(pendingBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let event = obj["event"] as? [String: Any]
            else { continue }
            let ts = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let hookPID = (obj["pid"] as? Int).map { pid_t($0) }
            apply(event, at: ts, hookParent: hookPID)
        }
    }

    // MARK: Event folding

    private func apply(_ e: [String: Any], at ts: Date, hookParent: pid_t?) {
        guard let id = e["session_id"] as? String,
              let name = e["hook_event_name"] as? String else { return }
        let cwd = e["cwd"] as? String ?? ""

        if name == "SessionEnd" {
            let reason = e["session_end_reason"] as? String ?? ""
            // `clear`/`resume` end the transcript but the process lives on and
            // will fire a fresh SessionStart with a new id. Drop this one.
            byID.removeValue(forKey: id)
            notchLog("claude-sessions: end \(id.prefix(8)) (\(reason))")
            publish()
            return
        }

        var s = byID[id] ?? ClaudeSession(id: id, cwd: cwd, lastEventAt: ts, startedAt: ts)
        s.lastEventAt = ts
        if !cwd.isEmpty { s.cwd = cwd }
        if let t = e["transcript_path"] as? String { s.transcriptPath = t }
        if s.pid == nil, let hp = hookParent, let claude = Proc.findClaudeAncestor(of: hp) {
            s.pid = claude
            s.tty = Proc.tty(of: claude)
        }
        if s.branch == nil || name == "SessionStart" || name == "CwdChanged" {
            s.branch = Git.branch(at: s.cwd)
        }

        let previous = s.state
        switch name {
        case "SessionStart":
            s.model = e["model"] as? String ?? s.model
            let reason = e["session_start_reason"] as? String ?? ""
            // A compaction restart keeps the turn running; everything else is a fresh idle.
            if reason != "compact" { s.state = .idle; s.activity = nil; s.attention = nil }
        case "UserPromptSubmit":
            s.state = .thinking
            s.turnStartedAt = ts
            s.attention = nil
            s.activity = nil
            s.lastReply = nil
            s.subagentCount = 0
            s.lastPrompt = Self.snippet(e["prompt"] as? String)
        case "PreToolUse":
            s.state = .tool
            s.attention = nil
            s.activity = Self.describeTool(name: e["tool_name"] as? String,
                                           input: e["tool_input"] as? [String: Any])
        case "PostToolUse", "PostToolUseFailure":
            s.state = .thinking
            if name == "PostToolUseFailure", let err = e["tool_error"] as? String {
                s.activity = "⚠︎ \(Self.snippet(err, max: 60) ?? "tool failed")"
            } else {
                s.activity = nil
            }
        case "PermissionRequest":
            s.state = .waiting
            s.attention = "Permission: " + (Self.describeTool(name: e["tool_name"] as? String,
                                                               input: e["tool_input"] as? [String: Any]) ?? "tool")
        case "Notification":
            let type = e["notification_type"] as? String ?? ""
            let msg = e["notification_message"] as? String ?? e["notification_title"] as? String
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                s.state = .waiting
                s.attention = Self.snippet(msg, max: 90) ?? "Needs your input"
            case "idle_prompt":
                // Claude has been sitting at the prompt for a while — it's done, not blocked.
                if s.state == .done || s.state == .idle { s.state = .done }
            default: break
            }
        case "Stop":
            s.state = .done
            s.activity = nil
            s.lastReply = Self.snippet(e["last_assistant_message"] as? String, max: 140)
        case "StopFailure":
            s.state = .failed
            s.activity = nil
            let type = e["error_type"] as? String ?? "error"
            s.attention = Self.snippet(e["error_message"] as? String, max: 90) ?? type
        case "SubagentStart":
            s.subagentCount += 1
        case "SubagentStop":
            s.subagentCount = max(0, s.subagentCount - 1)
        case "PreCompact":
            s.state = .compacting
            s.activity = "Compacting context…"
        case "PostCompact":
            s.state = .thinking
            s.activity = nil
        default:
            break
        }

        byID[id] = s
        notchLog("claude-sessions: \(name) \(s.projectName) id=\(id.prefix(8)) pid=\(s.pid.map(String.init) ?? "?") tty=\(s.tty ?? "?") state=\(s.state) \(s.activity ?? s.attention ?? "")")
        publish()
        if s.state != previous, s.state == .waiting || s.state == .done || s.state == .failed {
            onAttention?(s)
        }
    }

    private func publish() {
        let list = Array(byID.values)
        if list != sessions { sessions = list }
    }

    /// Drop sessions whose process is gone. Sessions we never managed to pin to
    /// a pid expire after an hour of silence instead.
    private func reapDead() {
        let now = Date()
        var changed = false
        for (id, s) in byID {
            let dead: Bool
            if let pid = s.pid {
                dead = !Proc.isAlive(pid)
            } else {
                dead = now.timeIntervalSince(s.lastEventAt) > 3600
            }
            if dead { byID.removeValue(forKey: id); changed = true }
        }
        if changed { publish() }
    }

    // MARK: Formatting

    static func snippet(_ text: String?, max: Int = 80) -> String? {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > max { t = String(t.prefix(max - 1)) + "…" }
        return t
    }

    static func describeTool(name: String?, input: [String: Any]?) -> String? {
        guard let name else { return nil }
        let base = { (path: String) in (path as NSString).lastPathComponent }
        switch name {
        case "Bash":
            let cmd = (input?["command"] as? String)?.components(separatedBy: "\n").first ?? ""
            return "Bash · " + (snippet(cmd, max: 60) ?? "")
        case "Read", "Edit", "Write", "NotebookEdit", "MultiEdit":
            if let p = input?["file_path"] as? String ?? input?["notebook_path"] as? String {
                return "\(name) · \(base(p))"
            }
            return name
        case "Grep", "Glob":
            if let p = input?["pattern"] as? String { return "\(name) · \(snippet(p, max: 40) ?? "")" }
            return name
        case "Agent", "Task":
            if let d = input?["description"] as? String { return "Agent · \(snippet(d, max: 50) ?? "")" }
            return "Agent"
        case "WebFetch", "WebSearch":
            if let q = input?["url"] as? String ?? input?["query"] as? String {
                return "\(name) · \(snippet(q, max: 50) ?? "")"
            }
            return name
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return "MCP · " + parts.dropFirst().joined(separator: " ")
            }
            return name
        }
    }

    // MARK: Focus

    /// Bring the terminal window hosting this session to the front. Supported
    /// hosts: Terminal.app (tab matched by tty) and VS Code (activate, then
    /// raise the window whose title mentions the project folder). Anything
    /// else just gets its app activated.
    func focus(_ session: ClaudeSession) {
        guard let pid = session.pid,
              let host = Proc.hostApplication(of: pid) else { return }
        let bundle = host.bundleIdentifier ?? ""
        let ttyPath = session.tty.map { "/dev/\($0)" }
        notchLog("claude-sessions: focus \(session.projectName) host=\(bundle) tty=\(ttyPath ?? "-")")

        if bundle == "com.apple.Terminal", let ttyPath {
            let hit = AppleScript.run("""
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(ttyPath)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
                return false
                """) == "true"
            if hit { return }
        }
        host.activate()
        if bundle == "com.microsoft.VSCode" {
            AXWindows.raiseWindow(ofPID: host.processIdentifier, titleContaining: session.projectName)
        }
    }
}

// MARK: - Process helpers

/// sysctl-based process inspection: no spawning, works for any pid we can see.
enum Proc {
    struct Info {
        let pid: pid_t
        let ppid: pid_t
        let comm: String
        let tdev: dev_t
    }

    static func info(_ pid: pid_t) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let comm = withUnsafePointer(to: &kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return Info(pid: pid, ppid: kp.kp_eproc.e_ppid, comm: comm, tdev: kp.kp_eproc.e_tdev)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Executable path via libproc (empty when unavailable).
    static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh"]

    /// Walk up from the hook process (its `$PPID` — usually claude itself) to
    /// the `claude` process that spawned it.
    /// Can't match on `p_comm`: the native CLI sets it to its version string
    /// ("2.1.241"), so match the executable name (claude / node for the npm
    /// install) and otherwise take the first non-shell ancestor — the hook is
    /// spawned either directly by claude or through one `sh -c`.
    static func findClaudeAncestor(of pid: pid_t) -> pid_t? {
        var cur = pid
        for _ in 0..<8 {
            guard let i = info(cur), i.pid > 1 else { return nil }
            let full = path(i.pid)
            let exe = (full as NSString).lastPathComponent
            // Native install lives at ~/.local/share/claude/versions/<ver>.
            if exe == "claude" || exe == "node" || full.localizedCaseInsensitiveContains("/claude/") { return i.pid }
            if !shells.contains(exe), !shells.contains(i.comm) { return i.pid }
            cur = i.ppid
        }
        return nil
    }

    static func tty(of pid: pid_t) -> String? {
        guard let i = info(pid), i.tdev != dev_t(bitPattern: UInt32.max), i.tdev != 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 64)
        guard devname_r(i.tdev, S_IFCHR, &buf, Int32(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    /// Nearest ancestor that is a regular GUI app (Terminal.app, VS Code).
    static func hostApplication(of pid: pid_t) -> NSRunningApplication? {
        var cur = pid
        for _ in 0..<16 {
            guard let i = info(cur), i.pid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: i.pid),
               app.activationPolicy == .regular {
                return app
            }
            cur = i.ppid
        }
        return nil
    }
}

// MARK: - Git

enum Git {
    /// Current branch by reading `.git/HEAD` directly (handles worktrees'
    /// `gitdir:` pointer files). No subprocess.
    static func branch(at path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var gitDir: URL?
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    gitDir = dotGit
                } else if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    let p = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                }
            }
            if let gitDir,
               let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return String(h.prefix(7))          // detached
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

// MARK: - AppleScript / AX

enum AppleScript {
    /// Runs a script and returns its string result (nil on error).
    @discardableResult
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error { notchLog("applescript: \(error)"); return nil }
        return result.stringValue ?? (result.booleanValue ? "true" : "false")
    }
}

enum AXWindows {
    /// Raise the first window of `pid` whose title contains `needle`.
    /// Silently does nothing without Accessibility permission.
    static func raiseWindow(ofPID pid: pid_t, titleContaining needle: String) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
                  let title = t as? String, title.localizedCaseInsensitiveContains(needle) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }
}
