import XCTest
@testable import Notch

@MainActor
final class CodexSessionTests: XCTestCase {
    private func store(sharedPID: Bool = false) -> AgentSessionStore {
        AgentSessionStore(resolveAncestor: { _, _ in sharedPID ? getpid() : nil }, processes: { _ in [] })
    }

    private func send(_ name: String, to store: AgentSessionStore, id: String = "thread-a",
                      turn: String = "turn-a", provider: AgentProvider = .codex,
                      fields: [String: Any] = [:], replaying: Bool = false) {
        var event: [String: Any] = ["session_id": id, "hook_event_name": name,
                                   "cwd": "/tmp/notch-project", "turn_id": turn]
        event.merge(fields) { _, new in new }
        store.apply(event, at: Date(), hookParent: getpid(), provider: provider, replaying: replaying)
    }

    func testCodexLifecycleAndPermissionClearing() throws {
        let store = store()
        var alerts: [AgentSession.State] = []
        store.onAttention = { alerts.append($0.state) }
        send("SessionStart", to: store, fields: ["source": "startup", "model": "test-model"])
        XCTAssertEqual(store.sessions.first?.state, .idle)
        send("UserPromptSubmit", to: store, fields: ["prompt": "Fix the build"])
        XCTAssertEqual(store.sessions.first?.state, .thinking)
        send("PreToolUse", to: store, fields: ["tool_name": "Bash", "tool_input": ["command": "swift build"]])
        XCTAssertEqual(store.sessions.first?.activity, "Bash · swift build")
        send("PermissionRequest", to: store, fields: ["tool_name": "Bash"])
        XCTAssertEqual(store.sessions.first?.waitingReason, .permission)
        send("PostToolUse", to: store)
        XCTAssertNil(store.sessions.first?.attention)
        XCTAssertNil(store.sessions.first?.waitingReason)
        send("Stop", to: store, fields: ["last_assistant_message": "Build fixed"])
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(session.state, .done)
        XCTAssertEqual(session.lastReply, "Build fixed")
        XCTAssertEqual(session.model, "test-model")
        XCTAssertNotNil(session.turnEndedAt)
        XCTAssertEqual(alerts, [.waiting, .done])
        send("SessionEnd", to: store)
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testMultipleCodexThreadsCanShareProcessAndProviderIDsCannotCollide() {
        let store = store(sharedPID: true)
        send("UserPromptSubmit", to: store)
        send("UserPromptSubmit", to: store, id: "thread-b")
        send("UserPromptSubmit", to: store, provider: .claude)
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertEqual(Set(store.sessions.map(\.id)).count, 3)
        XCTAssertEqual(Set(store.sessions.compactMap(\.pid)), [getpid()])
        send("SessionEnd", to: store)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.sessions.contains { $0.provider == .claude })
    }

    func testClaudeStillReplacesSessionWhenProcessIsReused() {
        let store = store(sharedPID: true)
        send("SessionStart", to: store, provider: .claude)
        send("SessionStart", to: store, id: "replacement", provider: .claude)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.sessionID, "replacement")
    }

    func testInterruptAndLateToolEventsDoNotTriggerCompletionOrRestartSpinner() {
        let store = store()
        var alerts = 0
        store.onAttention = { _ in alerts += 1 }
        send("UserPromptSubmit", to: store)
        send("Interrupt", to: store)
        send("PostToolUse", to: store)
        send("Stop", to: store)
        XCTAssertFalse(store.anyActive)
        XCTAssertEqual(store.sessions.first?.lastReply, "Interrupted")
        XCTAssertEqual(alerts, 0)
        send("UserPromptSubmit", to: store, turn: "turn-b")
        send("Stop", to: store, turn: "turn-a")
        XCTAssertTrue(store.anyActive)
        XCTAssertNil(store.sessions.first?.interruptedAt)
    }

    func testReplayIsSilentAndUnknownEventsDoNotCreateGhosts() {
        let store = store()
        var alerts = 0
        store.onAttention = { _ in alerts += 1 }
        send("UserPromptSubmit", to: store, replaying: true)
        send("Stop", to: store, replaying: true)
        send("NotAnEvent", to: store, id: "ghost")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(alerts, 0)
    }

    func testQuestionsCompactionAndSubagents() {
        let store = store()
        send("UserPromptSubmit", to: store)
        send("PreToolUse", to: store, fields: ["tool_name": "request_user_input",
            "tool_input": ["questions": [["question": "Which branch?"]]]])
        XCTAssertEqual(store.sessions.first?.state, .waiting)
        XCTAssertEqual(store.sessions.first?.attention, "Which branch?")
        XCTAssertEqual(store.sessions.first?.waitingReason, .question)
        send("PostToolUse", to: store)
        send("SubagentStart", to: store)
        send("SubagentStop", to: store)
        send("SubagentStop", to: store)
        XCTAssertEqual(store.sessions.first?.subagentCount, 0)
        send("PreCompact", to: store)
        send("SessionStart", to: store, fields: ["source": "compact"])
        XCTAssertEqual(store.sessions.first?.state, .compacting)
        send("PostCompact", to: store)
        XCTAssertEqual(store.sessions.first?.state, .thinking)
    }

    func testCodexToolDescriptionsAndExecutableMatching() {
        XCTAssertEqual(AgentSessionStore.describeTool(name: "apply_patch", input: ["command":
            "*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-old\n+new\n*** End Patch"]), "Edit · App.swift")
        XCTAssertTrue(Proc.isAgentExecutable("/Applications/Codex.app/Contents/Resources/codex", provider: .codex))
        XCTAssertTrue(Proc.isAgentExecutable("/opt/homebrew/bin/codex-aarch64-apple-darwin", provider: .codex))
        XCTAssertFalse(Proc.isAgentExecutable("/tmp/codex-hook.sh", provider: .codex))
        XCTAssertFalse(Proc.isAgentExecutable("/usr/local/bin/claude", provider: .codex))
    }
}

final class CodexHooksTests: XCTestCase {
    private func fixture() throws -> CodexHooks {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CodexHooks(settingsURL: directory.appendingPathComponent("hooks.json"),
                          supportDirectory: directory.appendingPathComponent("Zain's $files/Notch"))
    }

    func testInstallIsIdempotentAndUninstallPreservesOtherHooks() throws {
        let hooks = try fixture()
        let original: [String: Any] = ["description": "mine", "extra": 7, "hooks": [
            "Stop": [["matcher": "*", "hooks": [["type": "command", "command": "echo keep-me"]]]],
            "FutureEvent": [["hooks": [["type": "command", "command": "echo future"]]]],
            "SessionStart": []]]
        try JSONSerialization.data(withJSONObject: original).write(to: hooks.settingsURL)
        try hooks.setEnabled(true)
        XCTAssertTrue(hooks.isInstalled)
        let once = try Data(contentsOf: hooks.settingsURL)
        try hooks.setEnabled(true)
        XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), once)
        try hooks.setEnabled(false)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks.settingsURL)) as? [String: Any])
        // An originally empty event may disappear when its only installed group is removed.
        var expected = original
        var events = expected["hooks"] as! [String: Any]
        events.removeValue(forKey: "SessionStart")
        expected["hooks"] = events
        XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: expected))
        XCTAssertFalse(hooks.isInstalled)
    }

    func testInvalidConfigurationIsNeverOverwritten() throws {
        let hooks = try fixture()
        for invalid in ["{broken", "[]", #"{"hooks":{"Stop":"invalid"}}"#,
                        #"{"hooks":{"Stop":[{"hooks":"invalid"}]}}"#] {
            let bytes = Data(invalid.utf8)
            try bytes.write(to: hooks.settingsURL)
            XCTAssertThrowsError(try hooks.setEnabled(true))
            XCTAssertThrowsError(try hooks.setEnabled(false))
            XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), bytes)
        }
    }

    func testOptOutWithoutOurHooksDoesNotRewriteUserFile() throws {
        let hooks = try fixture()
        let bytes = Data("{  \"description\": \"untouched\", \"hooks\": {\"Stop\": []} }\n".utf8)
        try bytes.write(to: hooks.settingsURL)
        try hooks.setEnabled(false)
        XCTAssertEqual(try Data(contentsOf: hooks.settingsURL), bytes)
    }

    func testGeneratedHookWorksWithQuotedPathsAndProducesNoDecisions() throws {
        let hooks = try fixture()
        try hooks.setEnabled(true)
        let payload = #"{"session_id":"test","cwd":"/tmp","hook_event_name":"Stop","last_assistant_message":"done"}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", CodexHooks.shellQuote(hooks.scriptURL.path)]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let line = try Data(contentsOf: hooks.spoolURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual((object["event"] as? [String: Any])?["session_id"] as? String, "test")
        XCTAssertNotNil(object["pid"])
        XCTAssertNotNil(object["ts"])
    }
}

@MainActor
final class SessionSpoolTests: XCTestCase {
    func testPartialMalformedAndMultipleLines() {
        let spool = SessionEventSpool(url: URL(fileURLWithPath: "/unused"))
        var seen: [String] = []
        var replays: [Bool] = []
        spool.onEvent = { event, _, _, replaying in
            seen.append(event["session_id"] as! String)
            replays.append(replaying)
        }
        spool.ingest(Data("broken\n{\"event\":{\"session_id\":\"one".utf8), replaying: true)
        XCTAssertTrue(seen.isEmpty)
        spool.ingest(Data("\"}}\n{\"event\":{\"session_id\":\"two\"}}\n".utf8), replaying: true)
        XCTAssertEqual(seen, ["one", "two"])
        XCTAssertEqual(replays, [true, true])
    }
}
