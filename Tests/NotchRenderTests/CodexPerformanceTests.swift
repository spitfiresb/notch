import XCTest
import Darwin
@testable import Notch

/// Opt-in component benchmark. Never starts AgentSessionStore or reads personal rollouts.
final class CodexPerformanceTests: XCTestCase {
    private struct Sample: Codable {
        let wallMS: Double
        let cpuMS: Double
        let residentMiB: Double
    }

    private struct Result: Codable {
        let name: String
        let sessions: Int
        let bytesAppendedPerScan: Int
        let eventsPerScan: Int?
        let samples: [Sample]
        let residentBeforeMiB: Double
        let residentAfterMiB: Double
        var wallP50MS: Double { percentile(samples.map(\.wallMS), 0.5) }
        var wallP95MS: Double { percentile(samples.map(\.wallMS), 0.95) }
        var wallMaxMS: Double { samples.map(\.wallMS).max() ?? 0 }
        var meanCPUMS: Double { samples.map(\.cpuMS).reduce(0, +) / Double(samples.count) }
        // A projection for one invocation per second, NOT sampled app CPU usage.
        var projectedOneCorePercentAt1Hz: Double { meanCPUMS / 10 }
        var sampledResidentMaxMiB: Double { samples.map(\.residentMiB).max() ?? 0 }
    }

    private final class Fixture {
        let directory: URL
        let paths: [String]
        let writers: [FileHandle]

        init(count: Int) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-codex-bench-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var paths: [String] = []
            var writers: [FileHandle] = []
            do {
                for index in 0..<count {
                    let url = directory.appendingPathComponent("rollout-\(index).jsonl")
                    let metadata: [String: Any] = ["type": "session_meta", "payload": [
                        "id": "benchmark-\(index)", "cwd": "/synthetic/project", "source": "cli"]]
                    try CodexPerformanceTests.line(metadata).write(to: url)
                    let writer = try FileHandle(forWritingTo: url)
                    try writer.seekToEnd()
                    writers.append(writer)
                    paths.append(url.path)
                }
            } catch {
                writers.forEach { try? $0.close() }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            self.paths = paths
            self.writers = writers
        }

        deinit {
            writers.forEach { try? $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }

        func append(_ data: Data) throws {
            for writer in writers { try writer.write(contentsOf: data) }
        }

        func monitor() -> CodexSessionMonitor {
            let paths = paths
            // Synthetic identities isolate parsing from machine-dependent process discovery.
            return CodexSessionMonitor(processes: {
                paths.indices.map { (pid: pid_t($0 + 100_000), cwd: "/synthetic/project") }
            }, openPaths: { pid in [paths[Int(pid) - 100_000]] })
        }
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func turn(outputBytes: Int) throws -> Data {
        let records: [(String, [String: Any])] = [
            ("event_msg", ["type": "task_started", "turn_id": "benchmark-turn"]),
            ("response_item", ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"true\"}"]),
            ("response_item", ["type": "function_call_output", "output": String(repeating: "x", count: outputBytes)]),
            ("event_msg", ["type": "task_complete", "turn_id": "benchmark-turn", "last_agent_message": "done"])
        ]
        return try records.reduce(into: Data()) { data, record in
            data.append(try Self.line(["timestamp": "2026-09-27T12:00:00.000Z", "type": record.0, "payload": record.1]))
        }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func residentMiB() throws -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Double(info.pti_resident_size) / 1_048_576
    }

    private func measure(name: String, sessions: Int, iterations: Int, bytes: Int = 0,
                         expectedEvents: Int? = nil, prepare: () throws -> Void = {},
                         operation: () throws -> Int) throws -> Result {
        // Fixture writes, assertions, RSS sampling and report encoding are outside the timed region.
        var samples: [Sample] = []
        let before = try residentMiB()
        for index in 0..<(iterations + 3) {
            try prepare()
            let measurement: (Double, Double, Int) = try autoreleasepool {
                let cpu = cpuSeconds()
                let start = DispatchTime.now().uptimeNanoseconds
                let count = try operation()
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                return (elapsed, (cpuSeconds() - cpu) * 1000, count)
            }
            if let expectedEvents { XCTAssertEqual(measurement.2, expectedEvents, name) }
            if index >= 3 {
                samples.append(Sample(wallMS: measurement.0, cpuMS: measurement.1,
                                      residentMiB: try residentMiB()))
            }
        }
        return Result(name: name, sessions: sessions, bytesAppendedPerScan: bytes,
                      eventsPerScan: expectedEvents, samples: samples,
                      residentBeforeMiB: before, residentAfterMiB: try residentMiB())
    }

    func testCodexMonitoringBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOTCH_CODEX_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with scripts/benchmark-codex.sh")
        }
        #if DEBUG
        throw XCTSkip("Use an optimized release build for performance measurements")
        #endif
        let iterations = Int(environment["NOTCH_BENCHMARK_SAMPLES"] ?? "30") ?? 30
        guard (5...1000).contains(iterations) else {
            XCTFail("NOTCH_BENCHMARK_SAMPLES must be between 5 and 1000")
            return
        }
        var results: [Result] = []
        var discoveredCount = 0
        results.append(try measure(name: "native-process-discovery", sessions: 0, iterations: iterations) {
            let processes = Proc.agentProcesses(provider: .codex)
            discoveredCount = processes.count
            return processes.count // Deliberately do not open these processes' rollouts.
        })
        do {
            let fixture = try Fixture(count: 20)
            results.append(try measure(name: "native-fd-discovery-20-open-files", sessions: 20,
                                       iterations: iterations, expectedEvents: 20) {
                let found = Set(try XCTUnwrap(Proc.codexRolloutPaths(getpid())).map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                })
                return fixture.paths.filter { found.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }.count
            })
        }
        for count in [0, 1, 5, 20] {
            let fixture = try Fixture(count: count)
            let monitor = fixture.monitor()
            _ = monitor.scan()
            results.append(try measure(name: "idle-\(count)", sessions: count, iterations: iterations,
                                       expectedEvents: 0) { monitor.scan().count })
        }
        for (name, count, outputBytes) in [("active-1", 1, 4096), ("active-5", 5, 4096),
                                          ("active-20", 20, 4096), ("heavy-5", 5, 256 * 1024)] {
            let fixture = try Fixture(count: count)
            let monitor = fixture.monitor()
            _ = monitor.scan()
            let data = try turn(outputBytes: outputBytes)
            results.append(try measure(name: name, sessions: count, iterations: iterations,
                                       bytes: data.count * count, expectedEvents: count * 4,
                                       prepare: { try fixture.append(data) }) { monitor.scan().count })
            XCTAssertTrue(monitor.scan().isEmpty, "No duplicate events after consuming appended bytes")
        }
        do {
            let fixture = try Fixture(count: 1)
            let data = try turn(outputBytes: 4096)
            for _ in 0..<(16 * 1024 * 1024 / data.count + 1) { try fixture.append(data) }
            var monitor = fixture.monitor()
            results.append(try measure(name: "initial-replay-16MiB-history", sessions: 1,
                                       iterations: min(iterations, 10), prepare: { monitor = fixture.monitor() }) {
                let events = monitor.scan()
                XCTAssertTrue(events.allSatisfy(\.replaying))
                XCTAssertEqual(events.last?.payload["hook_event_name"] as? String, "Stop")
                return events.count
            })
        }
        // A backlog must take several bounded reads, yet deliver every lifecycle event exactly once.
        var backlogScans = 0
        var backlogBytes = 0
        do {
            let fixture = try Fixture(count: 1)
            let monitor = fixture.monitor()
            _ = monitor.scan()
            let data = try turn(outputBytes: 256 * 1024)
            let turns = 8 * 1024 * 1024 / data.count + 1
            for _ in 0..<turns { try fixture.append(data) }
            backlogBytes = turns * data.count
            var counts: [String: Int] = [:]
            repeat {
                let events = monitor.scan()
                for event in events { counts[event.payload["hook_event_name"] as? String ?? "", default: 0] += 1 }
                backlogScans += 1
            } while counts["Stop", default: 0] < turns && backlogScans < 20
            for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
                XCTAssertEqual(counts[name], turns, "Backlog lost or duplicated \(name)")
            }
            XCTAssertEqual(backlogScans, Int(ceil(Double(backlogBytes) / Double(2 * 1024 * 1024))))
            XCTAssertTrue(monitor.scan().isEmpty)
        }

        let summary: [[String: Any]] = results.map { result in
            ["name": result.name, "wallP50MS": result.wallP50MS, "wallP95MS": result.wallP95MS,
             "wallMaxMS": result.wallMaxMS, "meanCPUMS": result.meanCPUMS,
             "projectedOneCorePercentAt1Hz": result.projectedOneCorePercentAt1Hz,
             "sampledResidentMaxMiB": result.sampledResidentMaxMiB]
        }
        let encoded = try JSONEncoder().encode(results)
        let report: [String: Any] = [
            "schemaVersion": 1, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "logicalCPUs": ProcessInfo.processInfo.processorCount,
            "physicalMemoryGiB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            "buildConfiguration": "release", "samplesPerScenario": iterations, "warmups": 3,
            "liveCodexProcessesAtLastDiscovery": discoveredCount,
            "backlog": ["bytes": backlogBytes, "scansToDrain": backlogScans],
            "summary": summary, "results": try JSONSerialization.jsonObject(with: encoded)
        ]
        let output = environment["NOTCH_BENCHMARK_OUTPUT"] ?? ".build/benchmarks/codex.json"
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        print("\nCodex component benchmark (release; three warmups; timings in ms)")
        print("scenario | wall p50 | wall p95 | CPU mean | projected core % at 1 Hz")
        for result in results {
            print(String(format: "%@ | %.3f | %.3f | %.3f | %.3f", result.name,
                         result.wallP50MS, result.wallP95MS, result.meanCPUMS, result.projectedOneCorePercentAt1Hz))
        }
        print("Backlog: \(backlogBytes) bytes drained in \(backlogScans) scans")
        print("JSON report: \(url.path)")
    }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
}
