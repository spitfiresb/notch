import AppKit
import Combine
import Darwin

enum AgentProvider: String, CaseIterable {
    case claude, codex
    var label: String { self == .claude ? "Claude" : "Codex" }
}

// MARK: - Model

/// One live coding-agent session, as reconstructed from provider hook events.
struct AgentSession: Identifiable, Equatable {
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

    enum Host: Equatable {
        case terminal, vscode, codex, other
        var symbol: String {
            switch self {
            case .terminal: "terminal"
            case .vscode:   "chevron.left.forwardslash.chevron.right"
            case .codex:    "desktopcomputer"
            case .other:    "app.dashed"
            }
        }
        var label: String {
            switch self {
            case .terminal: "Terminal"
            case .vscode:   "VS Code"
            case .codex:    "Codex"
            case .other:    "Other"
            }
        }
    }

    let sessionID: String               // provider's session_id
    var provider: AgentProvider = .claude
    var id: String { provider.rawValue + ":" + sessionID }
    var turnID: String?
    var pid: pid_t?                      // owning agent process, once resolved
    var tty: String?                     // e.g. "ttys001" — for terminal window lookup
    var host: Host = .other
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
    enum WaitingReason: Equatable { case permission, question }
    /// What kind of input a `.waiting` session is blocked on.
    var waitingReason: WaitingReason?
    var subagentCount = 0
    var turnStartedAt: Date?
    var turnEndedAt: Date?
    /// When the turn was seen to be cut short by Ctrl-C (from the transcript,
    /// since no hook fires). Cleared by the next prompt.
    var interruptedAt: Date?
    var lastEventAt: Date
    var startedAt: Date

    var projectName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        return (cwd as NSString).lastPathComponent
    }
    /// Seconds the current (or last) turn has been running.
    func turnDuration(at now: Date = Date()) -> TimeInterval? {
        guard let start = turnStartedAt else { return nil }
        return (turnEndedAt ?? now).timeIntervalSince(start)
    }
    var needsAttention: Bool { state == .waiting || state == .failed }
    var isBusy: Bool { state == .thinking || state == .tool || state == .compacting }
    /// An unfinished turn, including one paused for user input.
    var isActive: Bool { isBusy || state == .waiting }

    /// Pin this session to its `claude` process and derive tty / host from it.
    mutating func attach(pid claude: pid_t) {
        pid = claude
        tty = Proc.tty(of: claude)
        switch Proc.hostApplication(of: claude)?.bundleIdentifier {
        case "com.apple.Terminal":   host = .terminal
        case "com.microsoft.VSCode": host = .vscode
        case "com.openai.codex", "com.openai.chat": host = .codex
        default:                     host = .other
        }
    }
}

// MARK: - Store

/// Tails the hook spool file, folds events into `sessions`, and drops sessions
/// whose agent process has exited. Also knows how to bring a session's
/// terminal window to the front.
@MainActor
final class AgentSessionStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var integrationErrors: [AgentProvider: String] = [:]
    var onAttention: ((AgentSession) -> Void)?

    private var byID: [String: AgentSession] = [:]
    private var spools: [AgentProvider: SessionEventSpool] = [:]
    private var enabledProviders = Set<AgentProvider>()
    private var codexMonitor: CodexSessionMonitor?
    private var livenessTimer: Timer?
    private var tick = 0
    private let network = NetworkActivityMonitor()
    private let resolveAncestor: (pid_t, AgentProvider) -> pid_t?
    private let processes: (AgentProvider) -> [(pid: pid_t, cwd: String)]

    init(resolveAncestor: @escaping (pid_t, AgentProvider) -> pid_t? = { Proc.findAgentAncestor(of: $0, provider: $1) },
         processes: @escaping (AgentProvider) -> [(pid: pid_t, cwd: String)] = { Proc.agentProcesses(provider: $0) }) {
        self.resolveAncestor = resolveAncestor
        self.processes = processes
    }

    /// Active sessions sorted for display: needs-you first, then most recent.
    var activeSessions: [AgentSession] {
        sessions.filter(\.isActive).sorted { a, b in
            if a.needsAttention != b.needsAttention { return a.needsAttention }
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.lastEventAt > b.lastEventAt
        }
    }
    /// A session is mid-task: working, or blocked on you to keep working.
    var anyActive: Bool { sessions.contains(where: \.isActive) }
    /// What the single collapsed-pill spinner should express: needs-you wins
    /// over plain busy.
    var headlineState: AgentSession.State {
        activeSessions.first?.state ?? .idle
    }

    var headlineProvider: AgentProvider {
        activeSessions.first?.provider ?? .claude
    }

    // MARK: Lifecycle

    func start(claudeEnabled: Bool, codexEnabled: Bool) {
        setHooksEnabled(claudeEnabled, provider: .claude)
        setHooksEnabled(codexEnabled, provider: .codex)
        livenessTimer?.invalidate()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for spool in self.spools.values { spool.readNew() }
                self.codexMonitor?.poll()
                self.tick += 1
                self.detectInterrupts()
                self.detectSilentInterrupts()
                if self.tick % 3 == 0 { self.reapDead() }
            }
        }
    }

    func shutdown() {
        livenessTimer?.invalidate()
        livenessTimer = nil
        spools.values.forEach { $0.stop() }
        spools.removeAll()
        codexMonitor?.stop()
        codexMonitor = nil
        network.watch([])
    }

    func setHooksEnabled(_ enabled: Bool, provider: AgentProvider = .claude) {
        // Stop observing immediately on opt-out, including already buffered events.
        if !enabled {
            enabledProviders.remove(provider)
            spools.removeValue(forKey: provider)?.stop()
            byID = byID.filter { $0.value.provider != provider }
            publish()
        }
        if provider == .codex {
            codexMonitor?.stop()
            codexMonitor = nil
            // Retire only our old hook definitions. Monitoring never depends on this cleanup.
            do {
                try CodexHooks.current.setEnabled(false)
                integrationErrors.removeValue(forKey: .codex)
            } catch {
                integrationErrors[.codex] = "Old Notch hooks could not be removed: \(error.localizedDescription)"
            }
            guard enabled else { return }
            enabledProviders.insert(.codex)
            let monitor = CodexSessionMonitor()
            monitor.onEvents = { [weak self] events in
                guard let self, self.enabledProviders.contains(.codex) else { return }
                for event in events {
                    self.apply(event.payload, at: event.date, hookParent: event.pid,
                               provider: .codex, replaying: event.replaying)
                }
            }
            codexMonitor = monitor
            monitor.poll()
            return
        }
        do {
            let ok = enabled ? ClaudeHooks.install() : ClaudeHooks.uninstall()
            guard ok else { throw CocoaError(.fileWriteUnknown) }
            let url = ClaudeHooks.spoolURL
            integrationErrors.removeValue(forKey: provider)
            guard enabled else { return }
            enabledProviders.insert(provider)
            if spools[provider] == nil {
                let spool = SessionEventSpool(url: url)
                spool.onEvent = { [weak self] event, date, pid, replaying in
                    guard let self, self.enabledProviders.contains(provider) else { return }
                    self.apply(event, at: date, hookParent: pid, provider: provider, replaying: replaying)
                }
                spools[provider] = spool
                spool.start()
                reapDead()
            }
        } catch {
            integrationErrors[provider] = "Could not update \(provider.label) hooks: \(error.localizedDescription)"
            notchLog("sessions: \(provider.rawValue) hook setup failed: \(error)")
        }
    }

    // MARK: Event folding

    func apply(_ e: [String: Any], at ts: Date, hookParent: pid_t?,
               provider: AgentProvider = .claude, replaying: Bool = false) {
        guard let sessionID = e["session_id"] as? String, !sessionID.isEmpty,
              let name = e["hook_event_name"] as? String else { return }
        guard (provider == .claude ? ClaudeHooks.events : CodexHooks.events + ["CodexContext", "CodexPrompt"]).contains(name) else { return }
        let id = provider.rawValue + ":" + sessionID
        let cwd = e["cwd"] as? String ?? ""

        if name == "SessionEnd" {
            let reason = e["session_end_reason"] as? String ?? ""
            // `clear`/`resume` end the transcript but the process lives on and
            // will fire a fresh SessionStart with a new id. Drop this one.
            byID.removeValue(forKey: id)
            notchLog("sessions: end \(id.prefix(8)) (\(reason))")
            publish()
            return
        }

        var s = byID[id] ?? AgentSession(sessionID: sessionID, provider: provider, cwd: cwd, lastEventAt: ts, startedAt: ts)
        if provider == .codex, let turn = e["turn_id"] as? String {
            if name != "UserPromptSubmit", let active = s.turnID, active != turn { return }
            if name != "UserPromptSubmit", s.turnID == turn,
               s.state == .done || s.state == .failed { return }
            s.turnID = turn
        }
        s.lastEventAt = ts
        if let model = e["model"] as? String { s.model = model }
        if !cwd.isEmpty {
            if s.cwd != cwd { s.branch = nil }
            s.cwd = cwd
        }
        if let t = e["transcript_path"] as? String { s.transcriptPath = t }
        // Pin to the claude process. Re-resolve every event so an early wrong
        // guess self-heals; when the hook's parent is already gone (replayed
        // events, or a short-lived `sh -c`), fall back to a live claude
        // process in this session's folder that no other session owns.
        if let hp = hookParent, let claude = resolveAncestor(hp, provider), claude != s.pid {
            s.attach(pid: claude)
        } else if s.pid == nil || !Proc.isAlive(s.pid!) {
            let claimed = Set(byID.values.filter { $0.id != id }.compactMap(\.pid))
            // Folder matching cannot identify a Codex thread in a shared app server.
            if provider == .claude, let p = processes(provider).first(where: { $0.cwd == s.cwd && !claimed.contains($0.pid) }) {
                s.attach(pid: p.pid)
            }
        }
        // Claude uses one process per session. A `/clear` or resume hands the same
        // process a new session id; the old entry is superseded, not a sibling.
        if provider == .claude, let p = s.pid {
            for (otherID, o) in byID where otherID != id && o.provider == provider && o.pid == p {
                byID.removeValue(forKey: otherID)
                notchLog("sessions: \(otherID.prefix(8)) superseded by \(id.prefix(8)) (pid \(p))")
            }
        }
        if s.branch == nil || name == "SessionStart" || name == "CwdChanged" {
            s.branch = Git.branch(at: s.cwd)
        }

        let previous = s.state
        switch name {
        case "SessionStart":
            s.model = e["model"] as? String ?? s.model
            let reason = e["session_start_reason"] as? String ?? e["source"] as? String ?? ""
            // A compaction restart keeps the turn running; everything else is a fresh idle.
            if reason != "compact" { s.state = .idle; s.activity = nil; s.attention = nil }
        case "CodexPrompt":
            s.lastPrompt = Self.snippet(e["prompt"] as? String)
        case "UserPromptSubmit":
            s.state = .thinking
            s.turnStartedAt = ts
            s.turnEndedAt = nil
            s.interruptedAt = nil
            s.attention = nil
            s.waitingReason = nil
            s.activity = nil
            s.lastReply = nil
            s.subagentCount = 0
            s.lastPrompt = Self.snippet(e["prompt"] as? String)
        case "PreToolUse":
            // A hook from the turn that was just interrupted can land after we
            // flipped the session to done; don't let it wake the spinner back
            // up. Only briefly, though: a later tool call means the turn is
            // genuinely still going (the interrupt call was wrong) and wins.
            if let t = s.interruptedAt, ts.timeIntervalSince(t) < Self.interruptHookGrace { break }
            s.interruptedAt = nil
            s.state = .tool
            s.attention = nil
            s.activity = Self.describeTool(name: e["tool_name"] as? String,
                                           input: e["tool_input"] as? [String: Any])
            if provider == .codex,
               ["request_user_input", "request_user_input_async"].contains(e["tool_name"] as? String ?? "") {
                s.state = .waiting
                s.waitingReason = .question
                let questions = (e["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]]
                s.attention = Self.snippet(questions?.first?["question"] as? String
                                          ?? questions?.first?["title"] as? String) ?? "Needs your input"
            }
        case "PostToolUse", "PostToolUseFailure":
            if let t = s.interruptedAt, ts.timeIntervalSince(t) < Self.interruptHookGrace { break }
            s.interruptedAt = nil
            s.state = .thinking
            s.attention = nil
            s.waitingReason = nil
            if name == "PostToolUseFailure", let err = e["tool_error"] as? String {
                s.activity = "⚠︎ \(Self.snippet(err, max: 60) ?? "tool failed")"
            } else {
                s.activity = nil
            }
        case "PermissionRequest":
            s.state = .waiting
            s.waitingReason = .permission
            s.attention = "Permission: " + (Self.describeTool(name: e["tool_name"] as? String,
                                                               input: e["tool_input"] as? [String: Any]) ?? "tool")
        case "Notification":
            let type = e["notification_type"] as? String ?? ""
            let msg = e["notification_message"] as? String ?? e["notification_title"] as? String
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                s.state = .waiting
                s.waitingReason = type == "permission_prompt" ? .permission : .question
                s.attention = Self.snippet(msg, max: 90) ?? "Needs your input"
            case "idle_prompt":
                // Claude has been sitting at the prompt for ~60 s — it's done, not
                // blocked. If we still had it as busy, the turn was cut short by
                // Ctrl-C before it produced any output: no hook fires for that and
                // nothing is written to the transcript, so this is the only signal
                // there is. Late, but it lands.
                if s.isBusy {
                    s.state = .done
                    s.activity = nil
                    s.turnEndedAt = ts
                    s.interruptedAt = ts
                    s.lastReply = "Interrupted"
                } else if s.state == .done || s.state == .idle {
                    s.state = .done
                }
            default: break
            }
        case "Interrupt":
            s.state = .done
            s.activity = nil
            s.attention = nil
            s.waitingReason = nil
            s.turnEndedAt = ts
            s.interruptedAt = ts
            s.lastReply = "Interrupted"
        case "Stop":
            s.attention = nil
            s.waitingReason = nil
            s.state = .done
            s.activity = nil
            s.turnEndedAt = ts
            s.lastReply = Self.snippet(e["last_assistant_message"] as? String, max: 140)
        case "StopFailure":
            s.state = .failed
            s.activity = nil
            s.turnEndedAt = ts
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
        notchLog("sessions: \(name) \(s.projectName) id=\(id.prefix(8)) pid=\(s.pid.map(String.init) ?? "?") tty=\(s.tty ?? "?") state=\(s.state) \(s.activity ?? s.attention ?? "")")
        publish()
        // No nudge for a turn the user cut short themselves.
        if !replaying, s.state != previous, s.interruptedAt == nil,
           s.state == .waiting || s.state == .done || s.state == .failed {
            onAttention?(s)
        }
    }

    private func publish() {
        let list = Array(byID.values)
        if list != sessions { sessions = list }
    }

    /// Ctrl-C mid-turn fires no hook at all, so an interrupted session would sit
    /// "busy" (spinner up) until the next prompt. Claude Code does record the
    /// interrupt in the transcript, so for busy sessions whose transcript has
    /// grown since we last looked, peek at its tail. Runs every second; a
    /// `stat` per busy session is all it costs when nothing has changed.
    private var transcriptSizes: [String: UInt64] = [:]

    /// How long after an interrupt call tool hooks from the old turn are ignored.
    private static let interruptHookGrace: TimeInterval = 3

    /// Ctrl-C while the model is still thinking — before it has produced any
    /// output — writes nothing to the transcript and fires no hook, so
    /// `detectInterrupts` can't see it. The wire can: a turn in flight is an
    /// open API stream delivering bytes every second, and aborting closes it.
    /// Sessions waiting on the model whose process has gone quiet for a few
    /// seconds have no turn any more. (Tool phases are exempt — a long `bash`
    /// is silent on the network by nature — and are covered by the transcript
    /// path, since a tool interrupt is recorded there.)
    private static let silenceWindow: TimeInterval = 6
    /// Below this many inbound bytes over `silenceWindow` counts as silence.
    /// Measured: a live stream never delivered less than 2.4 KB in any 6 s
    /// window (tokens or pings); an idle `claude` never more than 750 B (the
    /// odd keepalive). 4 s windows overlapped (940 B vs 740 B) and misfired.
    private static let silenceBytes: UInt64 = 1200
    /// Don't judge a session until its last hook event is this old — a fresh
    /// prompt or tool result takes a moment to turn into a request.
    private static let settleAfterEvent: TimeInterval = 5

    private func detectSilentInterrupts() {
        // Keep the counters running for every busy session (tool phases
        // included, so a session that flips tool -> thinking already has a
        // full window of history to judge); only sessions waiting on the
        // model are judged.
        network.watch(Set(byID.values.filter { $0.provider == .claude && $0.isBusy }.compactMap(\.pid)))
        let waiting = byID.values.filter { $0.provider == .claude && ($0.state == .thinking || $0.state == .compacting) && $0.pid != nil }
        let now = Date()
        var changed = false
        for s in waiting {
            guard let pid = s.pid, now.timeIntervalSince(s.lastEventAt) >= Self.settleAfterEvent,
                  let bytes = network.bytesIn(pid, over: Self.silenceWindow, now: now),
                  bytes < Self.silenceBytes else { continue }
            var u = s
            u.state = .done
            u.activity = nil
            u.turnEndedAt = now
            u.interruptedAt = now
            u.lastReply = "Interrupted"
            byID[s.id] = u
            changed = true
            notchLog("sessions: interrupted \(u.projectName) id=\(s.id.prefix(8)) — \(bytes) B in over \(Int(Self.silenceWindow)) s, no stream")
        }
        if changed { publish() }
    }

    private func detectInterrupts() {
        var changed = false
        let now = Date()
        for (id, s) in byID where s.provider == .claude && s.isBusy {
            guard let path = s.transcriptPath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  transcriptSizes[id] != size else { continue }
            transcriptSizes[id] = size
            guard Self.transcriptEndsWithInterrupt(path: path, size: size) else { continue }
            var u = s
            u.state = .done
            u.activity = nil
            u.turnEndedAt = now
            u.interruptedAt = now
            u.lastReply = "Interrupted"
            byID[id] = u
            changed = true
            notchLog("sessions: interrupted \(u.projectName) id=\(id.prefix(8))")
        }
        transcriptSizes = transcriptSizes.filter { byID[$0.key] != nil }
        // No `onAttention` here: the user interrupted it themselves, no toast needed.
        if changed { publish() }
    }

    /// True when the transcript's last *message* is the `[Request interrupted by
    /// user]` (or `… for tool use]`) user turn Claude Code appends on Ctrl-C.
    /// Claude Code usually writes a `file-history-snapshot`, `system`,
    /// `last-prompt` or `attachment` record right behind it — often within
    /// milliseconds — so the interrupt is rarely the literal last line; walk
    /// back past anything that isn't a user/assistant message. A new prompt
    /// typed afterwards is a plain user message, so it reads as not interrupted.
    nonisolated static func transcriptEndsWithInterrupt(path: String, size: UInt64) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let window: UInt64 = 64 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? h.readToEnd() else { return false }
        let text = String(decoding: data, as: UTF8.self)   // tolerant of a torn leading char
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "assistant": return false
            case "user":
                if obj["interruptedMessageId"] != nil { return true }
                let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
                return (content?["text"] as? String)?.hasPrefix("[Request interrupted") ?? false
            default: continue   // snapshot / system / last-prompt / attachment …
            }
        }
        return false
    }

    /// Drop sessions whose process is gone. Sessions we never managed to pin to
    /// a pid die once no claude process is running in their folder (after a
    /// short grace so a slow resolve doesn't flicker), or after an hour.
    private func reapDead() {
        let now = Date()
        var changed = false
        var live: [AgentProvider: [(pid: pid_t, cwd: String)]] = [:]
        for (id, s) in byID {
            let dead: Bool
            if let pid = s.pid {
                dead = !Proc.isAlive(pid)
            } else {
                let quiet = now.timeIntervalSince(s.lastEventAt)
                if live[s.provider] == nil { live[s.provider] = processes(s.provider) }
                let anyHere = live[s.provider]!.contains { $0.cwd == s.cwd }
                dead = quiet > 3600 || (quiet > 60 && !anyHere)
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
        case "Bash", "exec_command", "shell_command":
            let cmd = (input?["command"] as? String ?? input?["cmd"] as? String)?.components(separatedBy: "\n").first ?? ""
            return "Bash · " + (snippet(cmd, max: 60) ?? "")
        case "apply_patch":
            if let patch = input?["command"] as? String,
               let line = patch.components(separatedBy: "\n").first(where: {
                   $0.hasPrefix("*** Update File: ") || $0.hasPrefix("*** Add File: ") || $0.hasPrefix("*** Delete File: ")
               }), let colon = line.firstIndex(of: ":") {
                return "Edit · " + base(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return "Edit files"
        case "Read", "Edit", "Write", "NotebookEdit", "MultiEdit":
            if let p = input?["file_path"] as? String ?? input?["notebook_path"] as? String {
                return "\(name) · \(base(p))"
            }
            return name
        case "Grep", "Glob":
            if let p = input?["pattern"] as? String { return "\(name) · \(snippet(p, max: 40) ?? "")" }
            return name
        case "Agent", "Task", "spawn_agent":
            if let d = input?["description"] as? String ?? input?["message"] as? String { return "Agent · \(snippet(d, max: 50) ?? "")" }
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
    func focus(_ session: AgentSession) {
        guard let pid = session.pid,
              let host = Proc.hostApplication(of: pid) else { return }
        let bundle = host.bundleIdentifier ?? ""
        let ttyPath = session.tty.map { "/dev/\($0)" }
        notchLog("sessions: focus \(session.projectName) host=\(bundle) tty=\(ttyPath ?? "-")")

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

    /// Native CLI: `~/.local/share/claude/versions/<ver>` or a `claude` binary.
    /// (npm installs run under `node` and can't be told apart by path alone.)
    static func isClaudeExecutable(_ full: String) -> Bool {
        let exe = (full as NSString).lastPathComponent
        return exe == "claude" || full.contains("/claude/versions/")
    }

    /// Working directory via libproc (empty when unavailable).
    static func cwd(of pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Every running native `claude` process with its cwd. ~1 ms; call sparingly.
    static func agentProcesses(provider: AgentProvider) -> [(pid: pid_t, cwd: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [(pid: pid_t, cwd: String)] = []
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 && isAgentExecutable(path(pid), provider: provider) {
            out.append((pid, cwd(of: pid)))
        }
        return out
    }

    /// Walk up from the hook process (its `$PPID` — usually claude itself) to
    /// the `claude` process that spawned it.
    /// Can't match on `p_comm`: the native CLI sets it to its version string
    /// ("2.1.241"), so match the executable name (claude / node for the npm
    /// install) and otherwise take the first non-shell ancestor — the hook is
    /// spawned either directly by claude or through one `sh -c`.
    static func isAgentExecutable(_ full: String, provider: AgentProvider) -> Bool {
        if provider == .claude { return isClaudeExecutable(full) }
        let exe = (full as NSString).lastPathComponent
        return ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"].contains(exe)
    }

    static func findAgentAncestor(of pid: pid_t, provider: AgentProvider) -> pid_t? {
        if provider == .claude { return findClaudeAncestor(of: pid) }
        var current = pid
        for _ in 0..<16 {
            guard let i = info(current), i.pid > 1 else { return nil }
            if isAgentExecutable(path(i.pid), provider: provider) { return i.pid }
            current = i.ppid
        }
        return nil
    }

    static func findClaudeAncestor(of pid: pid_t) -> pid_t? {
        var cur = pid
        for _ in 0..<8 {
            guard let i = info(cur), i.pid > 1 else { return nil }
            let full = path(i.pid)
            let exe = (full as NSString).lastPathComponent
            // Native install lives at ~/.local/share/claude/versions/<ver>.
            if exe == "node" || isClaudeExecutable(full) { return i.pid }
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
