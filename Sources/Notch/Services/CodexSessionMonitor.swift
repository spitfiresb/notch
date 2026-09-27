import Foundation
import Darwin

/// Read-only discovery: use the rollout files actually held open by a Codex process.
/// This avoids guessing by cwd, scanning historical chats, or modifying Codex's trust/config.
final class CodexSessionMonitor {
    struct Event {
        let payload: [String: Any]
        let date: Date
        let pid: pid_t
        let replaying: Bool
    }

    private let queue = DispatchQueue(label: "Notch.CodexSessions", qos: .utility)
    private let processes: () -> [(pid: pid_t, cwd: String)]
    private let openPaths: (pid_t) -> [String]?

    init(processes: @escaping () -> [(pid: pid_t, cwd: String)] = { Proc.agentProcesses(provider: .codex) },
         openPaths: @escaping (pid_t) -> [String]? = Proc.codexRolloutPaths) {
        self.processes = processes
        self.openPaths = openPaths
    }

    private var readers: [String: CodexRolloutReader] = [:] // worker queue only
    private var polling = false // main thread only
    private var generation = 0
    var onEvents: (([Event]) -> Void)?

    func poll() {
        guard !polling else { return }
        polling = true
        let generation = generation
        queue.async { [weak self] in
            guard let self else { return }
            let events = self.scan()
            DispatchQueue.main.async {
                self.polling = false
                guard self.generation == generation else { return }
                self.onEvents?(events)
            }
        }
    }

    func stop() {
        generation += 1
        queue.async { self.readers.removeAll() }
    }

    func scan() -> [Event] {
        var events: [Event] = []
        var found = Set<String>()
        for process in processes() {
            guard let paths = openPaths(process.pid) else {
                // Permission/transient inspection failure is not evidence of session exit.
                found.formUnion(readers.filter { $0.value.pid == process.pid }.map(\.key))
                continue
            }
            var candidates: [(String, CodexRolloutReader)] = []
            for path in paths {
                let reader = readers[path].flatMap { $0.pid == process.pid ? $0 : nil }
                    ?? CodexRolloutReader(path: path, pid: process.pid)
                guard let reader else { continue }
                candidates.append((path, reader))
            }
            // A CLI can retain the previous rollout's fd after /new or /resume.
            // The most recently written root CLI rollout owns the terminal now.
            let cli = candidates.filter { $0.1.source == "cli" }
                .max { $0.1.modifiedAt < $1.1.modifiedAt }?.0
            for (path, reader) in candidates where reader.source != "cli" || path == cli {
                found.insert(path)
                readers[path] = reader
                events.append(contentsOf: reader.readNew())
            }
        }
        for (path, reader) in readers where !found.contains(path) {
            events.append(Event(payload: ["session_id": reader.parser.sessionID,
                                         "hook_event_name": "SessionEnd"],
                                date: Date(), pid: reader.pid, replaying: true))
        }
        readers = readers.filter { found.contains($0.key) }
        return events
    }
}

/// Stateful translation of local rollout records into the shared session lifecycle.
/// Unknown record types are ignored, so new Codex metadata cannot create ghost activity.
struct CodexRolloutParser {
    let sessionID: String
    var cwd: String
    var model: String?
    var turnID: String?
    private let fractional = ISO8601DateFormatter()
    private let seconds = ISO8601DateFormatter()

    init(sessionID: String, cwd: String) {
        self.sessionID = sessionID
        self.cwd = cwd
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    mutating func translate(_ record: [String: Any]) -> (payload: [String: Any], date: Date)? {
        guard let kind = record["type"] as? String,
              let p = record["payload"] as? [String: Any] else { return nil }
        let stamp = record["timestamp"] as? String ?? ""
        let date = fractional.date(from: stamp) ?? seconds.date(from: stamp) ?? Date()
        var fields: [String: Any] = [:]
        let name: String
        switch kind {
        case "session_meta": name = "SessionStart"
        case "turn_context":
            cwd = p["cwd"] as? String ?? cwd
            model = p["model"] as? String ?? model
            turnID = p["turn_id"] as? String ?? turnID
            name = "CodexContext"
        case "event_msg":
            switch p["type"] as? String {
            case "task_started", "turn_started":
                turnID = p["turn_id"] as? String
                name = "UserPromptSubmit"
            case "task_complete", "turn_complete":
                name = "Stop"
                fields["last_assistant_message"] = p["last_agent_message"]
            case "turn_aborted": name = "Interrupt"
            case "user_message":
                name = "CodexPrompt"
                fields["prompt"] = p["message"]
            default: return nil
            }
            // Preserve the record's turn id so late completion cannot stop a new turn.
            fields["turn_id"] = p["turn_id"]
        case "response_item":
            switch p["type"] as? String {
            case "function_call", "custom_tool_call":
                name = "PreToolUse"
                fields["tool_name"] = p["name"]
                let raw = p["arguments"] as? String ?? p["input"] as? String ?? ""
                fields["tool_input"] = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
                    ?? ["command": raw]
            case "function_call_output", "custom_tool_call_output": name = "PostToolUse"
            case "message" where p["role"] as? String == "user":
                name = "CodexPrompt"
                let content = p["content"] as? [[String: Any]] ?? []
                fields["prompt"] = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            default: return nil
            }
        default: return nil
        }
        fields["hook_event_name"] = name
        fields["session_id"] = sessionID
        fields["cwd"] = cwd
        fields["model"] = model
        if fields["turn_id"] == nil { fields["turn_id"] = turnID }
        return (fields, date)
    }
}

final class CodexRolloutReader {
    let path: String
    let pid: pid_t
    let source: String
    var parser: CodexRolloutParser
    private var offset: UInt64 = 0
    private var pending = Data()
    private var firstRead = true
    private var droppingLine = false
    private let window: UInt64 = 2 * 1024 * 1024

    var modifiedAt: Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }

    init?(path: String, pid: pid_t) {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        // Metadata is the first line; bound the read even for corrupt/unsupported files.
        guard let head = try? file.read(upToCount: 1024 * 1024),
              let newline = head.firstIndex(of: 10),
              let record = try? JSONSerialization.jsonObject(with: head.prefix(upTo: newline)) as? [String: Any],
              record["type"] as? String == "session_meta",
              let metadata = record["payload"] as? [String: Any],
              let id = metadata["id"] as? String ?? metadata["session_id"] as? String,
              !id.isEmpty,
              let source = metadata["source"] as? String,
              ["cli", "vscode", "exec", "app-server"].contains(source) else { return nil }
        self.path = path
        self.pid = pid
        self.source = source
        self.parser = CodexRolloutParser(sessionID: id, cwd: metadata["cwd"] as? String ?? "")
    }

    func readNew() -> [CodexSessionMonitor.Event] {
        guard let file = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        if size < offset {
            offset = 0; pending.removeAll(); firstRead = true; droppingLine = false
            parser = CodexRolloutParser(sessionID: parser.sessionID, cwd: parser.cwd)
        }
        let replaying = firstRead
        var events: [CodexSessionMonitor.Event] = []
        if firstRead {
            events.append(.init(payload: ["session_id": parser.sessionID, "cwd": parser.cwd,
                                          "hook_event_name": "SessionStart", "transcript_path": path],
                                date: Date(), pid: pid, replaying: true))
            if size > window { offset = size - window; droppingLine = true }
        }
        try? file.seek(toOffset: offset)
        var budget = Int(window)
        while budget > 0, let data = try? file.read(upToCount: min(64 * 1024, budget)), !data.isEmpty {
            offset += UInt64(data.count)
            budget -= data.count
            events.append(contentsOf: ingest(data, replaying: replaying))
        }
        firstRead = false
        return events
    }

    func ingest(_ data: Data, replaying: Bool) -> [CodexSessionMonitor.Event] {
        pending.append(data)
        var events: [CodexSessionMonitor.Event] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            if !droppingLine,
               let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let event = parser.translate(record) {
                events.append(.init(payload: event.payload, date: event.date, pid: pid, replaying: replaying))
            }
            droppingLine = false
            pending.removeSubrange(pending.startIndex...newline)
        }
        // Large image/tool payloads are irrelevant to lifecycle and must not grow RAM unbounded.
        if pending.count > Int(window) { pending.removeAll(); droppingLine = true }
        return events
    }
}

extension Proc {
    /// Native libproc inspection: no lsof subprocess, shell setup, or fixed CODEX_HOME.
    static func codexRolloutPaths(_ pid: pid_t) -> [String]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let count = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return nil }
        var paths = Set<String>()
        for fd in fds.prefix(Int(count) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { paths.insert(path) }
        }
        return paths.sorted()
    }
}
