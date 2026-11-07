import Foundation
import Darwin

/// Independent of hook installation: discovers live processes and follows their local transcripts.
/// Hooks supply permission/subagent detail; transcripts recover missed starts, turns and completions.
final class ClaudeSessionMonitor {
    struct Identity: Equatable {
        let sessionID: String
        let path: String
        let pid: pid_t
        let cwd: String
    }
    struct Event {
        let payload: [String: Any]
        let date: Date
        let pid: pid_t
        let replaying: Bool
    }

    private let queue = DispatchQueue(label: "Notch.ClaudeSessions", qos: .utility)
    private let processes: () -> [(pid: pid_t, cwd: String)]
    private let discover: (pid_t, String) -> [Identity]
    private var hints: [pid_t: Identity] = [:] // worker queue only
    private var readers: [pid_t: ClaudeTranscriptReader] = [:]
    private var polling = false // main thread only
    private var generation = 0
    var onEvents: (([Event]) -> Void)?

    init(processes: @escaping () -> [(pid: pid_t, cwd: String)] = { Proc.agentProcesses(provider: .claude) },
         discover: @escaping (pid_t, String) -> [Identity] = ClaudeSessionMonitor.openTranscripts) {
        self.processes = processes
        self.discover = discover
    }

    func observe(_ identity: Identity) {
        queue.async { self.hints[identity.pid] = identity }
    }

    func poll() {
        guard !polling else { return }
        polling = true
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            let events = self.scan()
            DispatchQueue.main.async {
                self.polling = false
                guard self.generation == token else { return }
                self.onEvents?(events)
            }
        }
    }

    func stop() {
        generation += 1
        queue.async { self.readers.removeAll(); self.hints.removeAll() }
    }

    func scan() -> [Event] {
        let live = processes()
        let livePIDs = Set(live.map(\.pid))
        var events: [Event] = []
        for process in live {
            events.append(Event(payload: ["session_id": "process:\(process.pid)", "cwd": process.cwd,
                                          "hook_event_name": "SessionObserved"], date: Date(), pid: process.pid, replaying: true))
            let candidates = discover(process.pid, process.cwd)
            let exact = candidates.max { Self.modified($0.path) < Self.modified($1.path) }
            let hint = hints[process.pid]
            // Hooks identify the exact session even when the transcript isn't held open.
            let identity: Identity?
            if let exact, let hint {
                identity = Self.modified(exact.path) > Self.modified(hint.path) ? exact : hint
            } else { identity = exact ?? hint }
            if let identity, readers[process.pid]?.identity != identity {
                readers[process.pid] = ClaudeTranscriptReader(identity: identity)
            }
            // A temporarily unreadable file is retried on the next poll, without losing its offset.
            events.append(contentsOf: readers[process.pid]?.readNew() ?? [])
        }
        for (pid, reader) in readers where !livePIDs.contains(pid) {
            events.append(Event(payload: ["session_id": reader.identity.sessionID,
                                          "hook_event_name": "SessionEnd"],
                                date: Date(), pid: pid, replaying: true))
        }
        readers = readers.filter { livePIDs.contains($0.key) }
        hints = hints.filter { livePIDs.contains($0.key) }
        return events
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? .distantPast
    }

    /// Exact fd/session-id matches only: never assign the newest historical chat to a terminal
    /// merely because two sessions have the same working directory.
    static func openTranscripts(pid: pid_t, cwd: String) -> [Identity] {
        let paths = Proc.openFilePaths(pid) ?? []
        var identities: [Identity] = []
        var hints = Set<String>()
        var roots = Set<String>()
        roots.insert(ClaudeHooks.current.settingsURL.deletingLastPathComponent().path)
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if path.contains("/projects/"), url.pathExtension == "jsonl", !path.contains("/subagents/") {
                identities.append(.init(sessionID: id, path: path, pid: pid, cwd: cwd))
            } else if url.deletingLastPathComponent().lastPathComponent == "debug", url.pathExtension == "txt" {
                hints.insert(id)
                roots.insert(url.deletingLastPathComponent().deletingLastPathComponent().path)
            }
        }
        let args = Proc.arguments(pid)
        for index in args.indices where ["--session-id", "--resume", "-r"].contains(args[index]) {
            if index + 1 < args.count, UUID(uuidString: args[index + 1]) != nil { hints.insert(args[index + 1]) }
        }
        guard !hints.isEmpty else { return identities }
        for root in roots {
            let projects = URL(fileURLWithPath: root).appendingPathComponent("projects")
            // Only exact UUID filenames in direct project directories; no chat-history parsing.
            for directory in (try? FileManager.default.contentsOfDirectory(at: projects,
                                                    includingPropertiesForKeys: nil)) ?? [] {
                for id in hints {
                    let path = directory.appendingPathComponent(id + ".jsonl").path
                    if FileManager.default.fileExists(atPath: path) {
                        identities.append(.init(sessionID: id, path: path, pid: pid, cwd: cwd))
                    }
                }
            }
        }
        return identities
    }
}

/// Bounded incremental reads, silent initial replay and inode tracking for replaced files.
final class ClaudeTranscriptReader {
    let identity: ClaudeSessionMonitor.Identity
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var pending = Data()
    private var droppingLine = false
    private var firstRead = true
    private let window = 2 * 1024 * 1024
    private var parser: ClaudeTranscriptParser

    init(identity: ClaudeSessionMonitor.Identity) {
        self.identity = identity
        parser = ClaudeTranscriptParser(sessionID: identity.sessionID, cwd: identity.cwd)
    }

    func readNew() -> [ClaudeSessionMonitor.Event] {
        guard let handle = FileHandle(forReadingAtPath: identity.path) else { return [] }
        defer { try? handle.close() }
        var stat = Darwin.stat()
        guard fstat(handle.fileDescriptor, &stat) == 0, stat.st_size >= 0 else { return [] }
        let size = UInt64(stat.st_size), currentInode = UInt64(stat.st_ino)
        if inode != currentInode || size < offset {
            offset = 0; pending.removeAll(); firstRead = true; droppingLine = false
            parser = ClaudeTranscriptParser(sessionID: identity.sessionID, cwd: identity.cwd)
        }
        inode = currentInode
        let replaying = firstRead
        if firstRead && size > UInt64(window) { offset = size - UInt64(window); droppingLine = true }
        guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
        var budget = window
        var events: [ClaudeSessionMonitor.Event] = []
        while budget > 0, let data = try? handle.read(upToCount: min(64 * 1024, budget)), !data.isEmpty {
            offset += UInt64(data.count); budget -= data.count; pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                if !droppingLine, let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    for event in parser.translate(record) {
                        var payload = event.payload
                        payload["transcript_path"] = identity.path
                        events.append(.init(payload: payload, date: event.date, pid: identity.pid, replaying: replaying))
                    }
                }
                pending.removeSubrange(pending.startIndex...newline)
                droppingLine = false
            }
            if pending.count > window { pending.removeAll(); droppingLine = true }
        }
        firstRead = false
        return events
    }
}

struct ClaudeTranscriptParser {
    let sessionID: String
    var cwd: String
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let seconds = ISO8601DateFormatter()

    func translate(_ record: [String: Any]) -> [(payload: [String: Any], date: Date)] {
        guard record["isSidechain"] as? Bool != true,
              let id = record["sessionId"] as? String ?? record["session_id"] as? String, id == sessionID,
              let stamp = record["timestamp"] as? String,
              let date = fractional.date(from: stamp) ?? seconds.date(from: stamp) else { return [] }
        let message = record["message"] as? [String: Any] ?? [:]
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = message["content"] as? String
            ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        func event(_ name: String, _ fields: [String: Any] = [:]) -> (payload: [String: Any], date: Date) {
            var payload = fields
            payload["session_id"] = sessionID
            payload["hook_event_name"] = name
            payload["cwd"] = record["cwd"] as? String ?? cwd
            payload["model"] = message["model"]
            return (payload, date)
        }
        switch record["type"] as? String {
        case "user":
            if record["interruptedMessageId"] != nil || text.hasPrefix("[Request interrupted") {
                return [event("Interrupt")]
            }
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return [event("PostToolUse")] }
            guard record["isMeta"] as? Bool != true, !text.isEmpty else { return [] }
            return [event("UserPromptSubmit", ["prompt": text])]
        case "assistant":
            if record["isApiErrorMessage"] as? Bool == true {
                return [event("StopFailure", ["error_message": text])]
            }
            let tools = blocks.filter { $0["type"] as? String == "tool_use" }
            if !tools.isEmpty {
                return tools.map { event("PreToolUse", ["tool_name": $0["name"] ?? "Tool", "tool_input": $0["input"] ?? [:]]) }
            }
            if ["end_turn", "stop_sequence"].contains(message["stop_reason"] as? String ?? "") {
                return [event("Stop", ["last_assistant_message": text])]
            }
            return [event("ClaudeActivity")]
        case "system":
            if record["subtype"] as? String == "turn_duration" { return [event("Stop")] }
            return []
        default: return []
        }
    }
}
