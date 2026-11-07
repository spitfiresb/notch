import XCTest
@testable import Notch

final class ClaudeHooksTests: XCTestCase {
    func fixture() throws -> ClaudeHooks {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ClaudeHooks(settingsURL: directory.appendingPathComponent("settings.json"),
                           directory: directory.appendingPathComponent("It's $safe/Notch"))
    }

    func testMalformedAndUnreadableSettingsArePreserved() throws {
        let hooks = try fixture()
        for value in ["{broken", "[]", #"{"hooks":false}"#, #"{"hooks":{"Stop":"invalid"}}"#,
                      #"{"hooks":{"Stop":[{"hooks":false}]}}"#] {
            let bytes = Data(value.utf8)
            try bytes.write(to: hooks.settingsURL)
            XCTAssertThrowsError(try hooks.setEnabled(true))
            XCTAssertThrowsError(try hooks.setEnabled(false))
            XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), bytes)
        }
        try FileManager.default.removeItem(at: hooks.settingsURL)
        try FileManager.default.createDirectory(at: hooks.settingsURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try hooks.setEnabled(true))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: hooks.settingsURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testInstallBackupIdempotenceAndExactUninstall() throws {
        let hooks = try fixture()
        let original: [String: Any] = ["permissions": ["allow": ["Read"]], "hooks": [
            "Stop": [["hooks": [["type": "command", "command": "echo Notch/claude-hook.sh"]]]],
            "FutureEvent": [["hooks": [["type": "command", "command": "echo keep"]]]]]]
        let bytes = try JSONSerialization.data(withJSONObject: original)
        try bytes.write(to: hooks.settingsURL)
        try hooks.setEnabled(true)
        XCTAssertTrue(hooks.isInstalled)
        let once = try Data(contentsOf: hooks.settingsURL)
        try hooks.setEnabled(true)
        XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), once)
        let backups = try FileManager.default.contentsOfDirectory(at: hooks.directory.appendingPathComponent("settings-backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
        try hooks.setEnabled(false)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks.settingsURL)) as? [String: Any])
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: original))
    }

    func testExplicitHookOptOutAndMissingFileCleanupAreNoOps() throws {
        let hooks = try fixture()
        try hooks.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.settingsURL.path))
        let bytes = Data(#"{ "disableAllHooks": true, "permissions": {"allow": ["Read"]} }"#.utf8)
        try bytes.write(to: hooks.settingsURL)
        try hooks.setEnabled(true)
        XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), bytes)
    }

    func testHookScriptHandlesSpecialPathsAndEmitsNoDecisions() throws {
        let hooks = try fixture()
        try hooks.setEnabled(true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hooks.scriptURL.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"session_id":"one","hook_event_name":"Stop"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks.spoolURL)) as? [String: Any])
        XCTAssertEqual((event["event"] as? [String: Any])?["session_id"] as? String, "one")
    }
}

final class ClaudeTranscriptTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ type: String, content: Any, stop: String? = nil, time: String = "2026-09-27T10:00:00.500Z") -> [String: Any] {
        var message: [String: Any] = ["content": content]
        message["stop_reason"] = stop
        return ["type": type, "sessionId": "one", "timestamp": time, "cwd": "/tmp/project", "message": message]
    }

    private func line(_ record: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: record); data.append(10); return data
    }

    func testTranscriptLifecycleAndMetadataFiltering() {
        let parser = ClaudeTranscriptParser(sessionID: "one", cwd: "/tmp/project")
        XCTAssertEqual(parser.translate(record("user", content: "hello")).first?.payload["hook_event_name"] as? String, "UserPromptSubmit")
        XCTAssertEqual(parser.translate(record("assistant", content: [["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]])).first?.payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(parser.translate(record("user", content: [["type": "tool_result", "content": "ok"]])).first?.payload["hook_event_name"] as? String, "PostToolUse")
        XCTAssertEqual(parser.translate(record("assistant", content: [["type": "text", "text": "done"]], stop: "end_turn")).first?.payload["last_assistant_message"] as? String, "done")
        XCTAssertEqual(parser.translate(record("user", content: "[Request interrupted by user]")).first?.payload["hook_event_name"] as? String, "Interrupt")
        var meta = record("user", content: "not a prompt"); meta["isMeta"] = true
        XCTAssertTrue(parser.translate(meta).isEmpty)
        meta["isMeta"] = false; meta["isSidechain"] = true
        XCTAssertTrue(parser.translate(meta).isEmpty)
        meta["isSidechain"] = false; meta["sessionId"] = "another"
        XCTAssertTrue(parser.translate(meta).isEmpty)
        XCTAssertTrue(parser.translate(["type": "new-future-record"]).isEmpty)
    }

    func testReaderReplayPartialLinesReplacementAndTemporaryMissingFile() throws {
        let url = try directory().appendingPathComponent("one.jsonl")
        try line(record("user", content: "hello")).write(to: url)
        let reader = ClaudeTranscriptReader(identity: .init(sessionID: "one", path: url.path, pid: 101, cwd: "/tmp/project"))
        XCTAssertTrue(try XCTUnwrap(reader.readNew().first).replaying)
        XCTAssertTrue(reader.readNew().isEmpty)
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        let completed = try line(record("assistant", content: "done", stop: "end_turn"))
        try file.write(contentsOf: Data("broken\n".utf8) + completed.dropLast())
        XCTAssertTrue(reader.readNew().isEmpty)
        try file.write(contentsOf: Data([10])); try file.close()
        let events = reader.readNew()
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(try XCTUnwrap(events.first).replaying)
        let replacement = try line(record("user", content: "a new prompt considerably longer than the original content"))
        try replacement.write(to: url, options: .atomic)
        XCTAssertEqual(reader.readNew().first?.payload["hook_event_name"] as? String, "UserPromptSubmit")
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(reader.readNew().isEmpty)
        try completed.write(to: url)
        XCTAssertEqual(reader.readNew().first?.payload["hook_event_name"] as? String, "Stop")
    }

    func testMonitorRetainsReaderDuringDiscoveryFailureAndRemovesExitedProcess() throws {
        let url = try directory().appendingPathComponent("one.jsonl")
        try line(record("user", content: "hello")).write(to: url)
        let identity = ClaudeSessionMonitor.Identity(sessionID: "one", path: url.path, pid: 101, cwd: "/tmp/project")
        var live = true, readable = true
        let monitor = ClaudeSessionMonitor(processes: { live ? [(101, "/tmp/project")] : [] }, discover: { _, _ in readable ? [identity] : [] })
        XCTAssertTrue(monitor.scan().contains { $0.payload["hook_event_name"] as? String == "UserPromptSubmit" })
        readable = false
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
        try file.write(contentsOf: line(record("assistant", content: "done", stop: "end_turn")))
        try file.close()
        XCTAssertTrue(monitor.scan().contains { $0.payload["hook_event_name"] as? String == "Stop" })
        live = false
        XCTAssertEqual(monitor.scan().first?.payload["hook_event_name"] as? String, "SessionEnd")
    }

    func testLargeTranscriptReplaysLatestStateWithoutUnboundedHistory() throws {
        let url = try directory().appendingPathComponent("one.jsonl")
        var data = Data(repeating: 32, count: 3 * 1024 * 1024); data.append(10)
        data.append(try line(record("assistant", content: "done", stop: "end_turn")))
        try data.write(to: url)
        let reader = ClaudeTranscriptReader(identity: .init(sessionID: "one", path: url.path, pid: 101, cwd: "/tmp/project"))
        let events = reader.readNew()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload["hook_event_name"] as? String, "Stop")
        XCTAssertTrue(events.allSatisfy(\.replaying))
    }
}

@MainActor
final class SessionRecoveryTests: XCTestCase {
    func testBrokenSettingsDoNotBlockSpoolAndAutomaticallyRecover() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hooks = ClaudeHooks(settingsURL: directory.appendingPathComponent("settings.json"), directory: directory)
        XCTAssertTrue(hooks.ensureScript())
        let invalid = Data("{invalid".utf8)
        try invalid.write(to: hooks.settingsURL)
        let object: [String: Any] = ["ts": Date().timeIntervalSince1970, "pid": Int(getpid()), "event": [
            "session_id": "one", "cwd": "/tmp/project", "hook_event_name": "UserPromptSubmit", "prompt": "hello"]]
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10)
        try bytes.write(to: hooks.spoolURL)
        let store = AgentSessionStore(resolveAncestor: { _, _ in getpid() }, processes: { _ in [] }, claudeHooks: hooks)
        defer { store.shutdown() }
        store.setHooksEnabled(true)
        XCTAssertTrue(store.anyActive, "Existing events must work even when hook installation cannot write settings")
        XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), invalid)
        XCTAssertNotNil(store.integrationErrors[.claude])
        try Data("{}".utf8).write(to: hooks.settingsURL)
        store.updateClaudeHooks(enabled: true) // the same operation scheduled by the retry timer
        XCTAssertTrue(hooks.isInstalled)
        XCTAssertNil(store.integrationErrors[.claude])
        store.setHooksEnabled(false)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testFallbackCannotUndoPermissionWaitOrDuplicateCompletion() {
        let store = AgentSessionStore(resolveAncestor: { _, _ in getpid() }, processes: { _ in [] })
        var alerts = 0
        store.onAttention = { _ in alerts += 1 }
        let stamp = Date(timeIntervalSince1970: 100)
        store.apply(["session_id": "one", "hook_event_name": "PermissionRequest"], at: stamp, hookParent: getpid())
        store.applyClaudeTranscript(.init(payload: ["session_id": "one", "hook_event_name": "PreToolUse"],
                                          date: stamp.addingTimeInterval(0.5), pid: getpid(), replaying: false))
        XCTAssertEqual(store.sessions.first?.state, .waiting)
        store.applyClaudeTranscript(.init(payload: ["session_id": "one", "hook_event_name": "Stop", "last_assistant_message": "done"],
                                          date: stamp.addingTimeInterval(2), pid: getpid(), replaying: false))
        store.apply(["session_id": "one", "hook_event_name": "Stop"], at: stamp.addingTimeInterval(2), hookParent: getpid())
        XCTAssertEqual(store.sessions.first?.lastReply, "done")
        XCTAssertEqual(alerts, 2, "One permission alert and one completion only")
        store.apply(["session_id": "one", "hook_event_name": "PreToolUse"], at: stamp, hookParent: getpid())
        XCTAssertFalse(store.anyActive, "Delayed hooks must not revive an older turn")
    }

    func testUndetectableProcessIsVisibleAndReplacedByRealSessionForBothProviders() {
        for provider in AgentProvider.allCases {
            let store = AgentSessionStore(resolveAncestor: { _, _ in getpid() }, processes: { _ in [] })
            store.apply(["session_id": "process:\(getpid())", "hook_event_name": "SessionObserved", "cwd": "/tmp/project"],
                        at: Date(), hookParent: getpid(), provider: provider)
            XCTAssertEqual(store.activeSessions.first?.state, .unknown)
            store.apply(["session_id": "real", "hook_event_name": "UserPromptSubmit", "cwd": "/tmp/project"],
                        at: Date(), hookParent: getpid(), provider: provider)
            XCTAssertEqual(store.sessions.count, 1)
            XCTAssertEqual(store.sessions.first?.sessionID, "real")
            XCTAssertEqual(store.sessions.first?.state, .thinking)
        }
    }
}

extension ClaudeTranscriptTests {
    func testExactDescriptorDiscoveryKeepsSameFolderSessionsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects/project")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let file = projects.appendingPathComponent(id + ".jsonl")
        try Data().write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        let identities = ClaudeSessionMonitor.openTranscripts(pid: getpid(), cwd: "/tmp/project")
        XCTAssertTrue(identities.contains { $0.sessionID == id })
        try handle.close()
        XCTAssertFalse(ClaudeSessionMonitor.openTranscripts(pid: getpid(), cwd: "/tmp/project").contains { $0.sessionID == id })
        XCTAssertFalse(Proc.arguments(getpid()).isEmpty, "Native argv inspection should return arguments, never environment values")
    }
}

extension SessionRecoveryTests {
    func testClaudeQuestionAndExplicitToolInterrupt() {
        let store = AgentSessionStore(resolveAncestor: { _, _ in getpid() }, processes: { _ in [] })
        var alerts = 0
        store.onAttention = { _ in alerts += 1 }
        store.apply(["session_id": "one", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                     "tool_input": ["questions": [["question": "Which branch?"]]]], at: Date(), hookParent: getpid())
        XCTAssertEqual(store.sessions.first?.state, .waiting)
        XCTAssertEqual(store.sessions.first?.waitingReason, .question)
        XCTAssertEqual(store.sessions.first?.attention, "Which branch?")
        store.apply(["session_id": "one", "hook_event_name": "PostToolUseFailure", "is_interrupt": true],
                    at: Date(), hookParent: getpid())
        XCTAssertFalse(store.anyActive)
        XCTAssertEqual(store.sessions.first?.lastReply, "Interrupted")
        XCTAssertEqual(alerts, 1, "An explicit interrupt should not create a completion notification")
    }
}
