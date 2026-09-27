import XCTest
@testable import Notch

final class CodexRolloutTests: XCTestCase {
    private func fixture(source: Any = "cli", id: String = "thread-one") throws -> (URL, CodexRolloutReader) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-test.jsonl")
        let meta: [String: Any] = ["type": "session_meta", "payload": [
            "id": id, "cwd": "/tmp/project", "source": source]]
        var data = try JSONSerialization.data(withJSONObject: meta)
        data.append(10)
        try data.write(to: url)
        return (url, try XCTUnwrap(CodexRolloutReader(path: url.path, pid: getpid())))
    }

    private func record(_ kind: String, _ payload: [String: Any]) -> [String: Any] {
        ["timestamp": "2026-09-27T10:00:00.000Z", "type": kind, "payload": payload]
    }

    @MainActor
    func testRealRolloutShapesDriveLifecycleAndSilentReplay() throws {
        var parser = CodexRolloutParser(sessionID: "one", cwd: "/tmp/project")
        let store = AgentSessionStore(resolveAncestor: { _, _ in getpid() }, processes: { _ in [] })
        var alerts = 0
        store.onAttention = { _ in alerts += 1 }
        func send(_ kind: String, _ payload: [String: Any], replaying: Bool = false) throws {
            let event = try XCTUnwrap(parser.translate(record(kind, payload)))
            store.apply(event.payload, at: event.date, hookParent: getpid(), provider: .codex, replaying: replaying)
        }
        try send("event_msg", ["type": "task_started", "turn_id": "first"], replaying: true)
        try send("event_msg", ["type": "task_complete", "turn_id": "first", "last_agent_message": "Old reply"], replaying: true)
        XCTAssertEqual(alerts, 0)
        try send("event_msg", ["type": "task_started", "turn_id": "second"])
        try send("turn_context", ["turn_id": "second", "model": "example", "cwd": "/tmp/project"])
        try send("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix this"]]])
        try send("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"swift build\"}"])
        XCTAssertEqual(store.sessions.first?.activity, "Bash · swift build")
        XCTAssertEqual(store.sessions.first?.lastPrompt, "Fix this")
        XCTAssertEqual(store.sessions.first?.model, "example")
        try send("response_item", ["type": "function_call_output", "output": "ok"])
        XCTAssertEqual(store.sessions.first?.state, .thinking)
        try send("event_msg", ["type": "task_complete", "turn_id": "first"])
        XCTAssertTrue(store.anyActive, "Late completion must not end a newer turn")
        try send("event_msg", ["type": "turn_aborted", "turn_id": "second"])
        try send("response_item", ["type": "custom_tool_call_output", "output": "late"])
        XCTAssertFalse(store.anyActive)
        XCTAssertEqual(alerts, 0, "Interrupt must not display a completion toast")
        try send("event_msg", ["type": "task_started", "turn_id": "third"])
        try send("event_msg", ["type": "task_complete", "turn_id": "third", "last_agent_message": "Finished"])
        XCTAssertEqual(store.sessions.first?.lastReply, "Finished")
        XCTAssertEqual(alerts, 1)
        XCTAssertNil(parser.translate(record("event_msg", ["type": "token_count"])))
    }

    func testTailReadsOnlyNewCompleteLinesAndRecoversAfterMalformedLine() throws {
        let (url, reader) = try fixture()
        XCTAssertTrue(reader.readNew().allSatisfy(\.replaying))
        XCTAssertTrue(reader.readNew().isEmpty)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("broken\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"".utf8))
        XCTAssertTrue(reader.readNew().isEmpty)
        try file.write(contentsOf: Data(",\"turn_id\":\"new\"}}\n".utf8))
        let events = reader.readNew()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload["hook_event_name"] as? String, "UserPromptSubmit")
        XCTAssertFalse(try XCTUnwrap(events.first?.replaying))
        XCTAssertTrue(reader.readNew().isEmpty)
    }

    func testLargeHistoryIsBoundedAndReplayDoesNotSkipLatestState() throws {
        let (url, reader) = try fixture()
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data(repeating: 32, count: 3 * 1024 * 1024))
        try file.write(contentsOf: Data("\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"last\"}}\n".utf8))
        let events = reader.readNew()
        XCTAssertEqual(events.last?.payload["hook_event_name"] as? String, "Stop")
        XCTAssertTrue(events.allSatisfy(\.replaying))
        XCTAssertTrue(reader.readNew().isEmpty)
    }

    func testDiscoversExactOpenFileAndIgnoresClosedHistory() throws {
        let (url, _) = try fixture()
        let file = try FileHandle(forReadingFrom: url)
        let paths = try XCTUnwrap(Proc.codexRolloutPaths(getpid())).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertTrue(paths.contains(url.resolvingSymlinksInPath().path), "expected \(url.resolvingSymlinksInPath().path); got \(paths)")
        try file.close()
        XCTAssertFalse(try XCTUnwrap(Proc.codexRolloutPaths(getpid())).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.contains(url.resolvingSymlinksInPath().path))
    }

    func testDiscoverySeparatesSameFolderSessionsAndRemovesExitedProcess() throws {
        let (one, _) = try fixture(id: "one")
        let (two, _) = try fixture(id: "two")
        var processes: [(pid: pid_t, cwd: String)] = [(101, "/tmp/project"), (102, "/tmp/project")]
        let monitor = CodexSessionMonitor(processes: { processes }, openPaths: { pid in
            [pid == 101 ? one.path : two.path]
        })
        let events = monitor.scan()
        XCTAssertEqual(Set(events.compactMap { $0.payload["session_id"] as? String }), ["one", "two"])
        XCTAssertEqual(Set(events.map(\.pid)), [101, 102])
        XCTAssertTrue(events.allSatisfy(\.replaying))
        XCTAssertTrue(monitor.scan().isEmpty)
        processes.removeFirst()
        let ended = monitor.scan()
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(ended.first?.payload["hook_event_name"] as? String, "SessionEnd")
        XCTAssertEqual(ended.first?.payload["session_id"] as? String, "one")
    }

    func testResumeSelectsCurrentRolloutAndInspectionFailurePreservesIt() throws {
        let (old, _) = try fixture(id: "old")
        let (current, _) = try fixture(id: "current")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        var paths: [String]? = [old.path, current.path]
        let monitor = CodexSessionMonitor(processes: { [(101, "/tmp/project")] }, openPaths: { _ in paths })
        let events = monitor.scan()
        XCTAssertEqual(Set(events.compactMap { $0.payload["session_id"] as? String }), ["current"])
        paths = nil
        XCTAssertTrue(monitor.scan().isEmpty, "A transient inspection failure must not remove a live session")
        paths = [old.path]
        let resumed = monitor.scan()
        XCTAssertTrue(resumed.contains { $0.payload["session_id"] as? String == "old" && $0.payload["hook_event_name"] as? String == "SessionStart" })
        XCTAssertTrue(resumed.contains { $0.payload["session_id"] as? String == "current" && $0.payload["hook_event_name"] as? String == "SessionEnd" })
    }

    func testSubagentMetadataIsExcluded() throws {
        let (url, _) = try fixture()
        let meta: [String: Any] = ["type": "session_meta", "payload": [
            "id": "child", "cwd": "/tmp/project", "source": ["subagent": ["thread_spawn": [:]]]]]
        var data = try JSONSerialization.data(withJSONObject: meta); data.append(10)
        try data.write(to: url)
        XCTAssertNil(CodexRolloutReader(path: url.path, pid: getpid()))
    }
}
