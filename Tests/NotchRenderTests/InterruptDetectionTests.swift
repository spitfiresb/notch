import XCTest
@testable import Notch

/// `ClaudeSessionStore.transcriptEndsWithInterrupt` against the transcript
/// shapes Claude Code actually writes around a Ctrl-C.
final class InterruptDetectionTests: XCTestCase {
    private static let interrupt = #"{"type":"user","interruptedMessageId":"m1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    private static let toolInterruptNoID = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
    private static let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]}}"#
    private static let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private static let prompt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"try again"}]}}"#
    private static let snapshot = #"{"type":"file-history-snapshot","snapshot":{"timestamp":"2026-08-29T00:00:00Z"}}"#
    private static let system = #"{"type":"system","subtype":"turn_duration","durationMs":1200}"#
    private static let lastPrompt = #"{"type":"last-prompt","lastPrompt":"hi"}"#

    private func check(_ lines: [String]) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let text = lines.joined(separator: "\n") + "\n"
        try! text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = (try! FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).uint64Value
        return ClaudeSessionStore.transcriptEndsWithInterrupt(path: url.path, size: size)
    }

    func testInterruptAsLastLine() {
        XCTAssertTrue(check([Self.prompt, Self.assistant, Self.interrupt]))
    }

    func testInterruptFollowedByMetadataRecords() {
        XCTAssertTrue(check([Self.prompt, Self.assistant, Self.interrupt, Self.snapshot]))
        XCTAssertTrue(check([Self.prompt, Self.assistant, Self.interrupt, Self.system, Self.snapshot]))
        XCTAssertTrue(check([Self.prompt, Self.assistant, Self.interrupt, Self.lastPrompt]))
    }

    func testToolInterruptWithoutIDField() {
        XCTAssertTrue(check([Self.prompt, Self.assistant, Self.toolInterruptNoID, Self.system]))
    }

    func testNotInterrupted() {
        XCTAssertFalse(check([Self.prompt, Self.assistant]), "assistant is last")
        XCTAssertFalse(check([Self.prompt, Self.assistant, Self.toolResult]), "mid-turn tool result")
        XCTAssertFalse(check([Self.prompt, Self.assistant, Self.interrupt, Self.snapshot, Self.prompt]),
                       "a new prompt after the interrupt")
        XCTAssertFalse(check([Self.prompt, Self.assistant, Self.toolResult, Self.snapshot]), "metadata after tool result")
    }
}
