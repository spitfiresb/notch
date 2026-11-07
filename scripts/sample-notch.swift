// Compile/run through sample-notch.sh. Read-only sampling of an existing process.
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if args.contains("--help") {
    print("sample-notch.sh --pid PID --scenario LABEL --seconds 60 --output report.json --claude-disabled [--interval 1]")
    print("Manually arrange the scenario first. --claude-disabled attests Claude monitoring is off; this tool changes no settings.")
    exit(0)
}
guard let rawPID = option("--pid"), let pid = Int32(rawPID), pid > 1,
      let scenario = option("--scenario"), !scenario.isEmpty,
      let output = option("--output") else { fail("Use --help for required arguments") }
guard args.contains("--claude-disabled") else { fail("Disable Claude in the test app, then attest with --claude-disabled") }
let seconds = Double(option("--seconds") ?? "60") ?? 0
let interval = Double(option("--interval") ?? "1") ?? 0
guard (1...3600).contains(seconds), (0.05...10).contains(interval), interval <= seconds else {
    fail("seconds must be 1...3600; interval 0.05...10 and no longer than duration")
}
var pathBuffer = [CChar](repeating: 0, count: 4096)
guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { fail("Cannot inspect PID") }
let path = String(cString: pathBuffer)
guard URL(fileURLWithPath: path).lastPathComponent == "Notch" || args.contains("--allow-any-process") else {
    fail("PID is not a Notch executable; use a Notch PID")
}
func identity() -> String? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
}
guard let initialIdentity = identity() else { fail("Cannot read process identity") }
func sample() -> (time: UInt64, cpu: UInt64, data: [String: Any])? {
    guard identity() == initialIdentity else { return nil }
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: max(1, Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32))
    let used = descriptors.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    let time = DispatchTime.now().uptimeNanoseconds
    return (time, info.pti_total_user + info.pti_total_system,
            ["residentMiB": Double(info.pti_resident_size) / 1_048_576,
             "virtualMiB": Double(info.pti_virtual_size) / 1_048_576,
             "threads": info.pti_threadnum, "openFDs": used > 0 ? Int(used) / MemoryLayout<proc_fdinfo>.stride : -1,
             "pageins": info.pti_pageins, "faults": info.pti_faults, "contextSwitches": info.pti_csw])
}
guard let first = sample() else { fail("Initial process sample failed") }
var previous = first
var rows: [[String: Any]] = []
var status = "completed"
while Double(DispatchTime.now().uptimeNanoseconds - first.time) / 1e9 < seconds {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - first.time) / 1e9
    Thread.sleep(forTimeInterval: min(interval, max(0, seconds - elapsed)))
    guard let current = sample() else { status = "process-exited-or-inspection-failed"; break }
    var data = current.data
    data["elapsedSeconds"] = Double(current.time - first.time) / 1e9
    data["oneCoreCPUPercent"] = Double(current.cpu - previous.cpu) / Double(current.time - previous.time) * 100
    rows.append(data)
    previous = current
}
let elapsed = Double(previous.time - first.time) / 1e9
let report: [String: Any] = ["schemaVersion": 1, "scenario": scenario, "status": status,
    "timestamp": ISO8601DateFormatter().string(from: Date()), "pid": pid, "executable": path,
    "processIdentity": initialIdentity, "claudeDisabledAttested": true,
    "requestedSeconds": seconds, "observedSeconds": elapsed, "intervalSeconds": interval,
    "meanOneCoreCPUPercent": elapsed > 0 ? Double(previous.cpu - first.cpu) / (elapsed * 1e9) * 100 : 0,
    "initialResources": first.data, "samples": rows,
    "limitations": "Scenario and Claude toggle are operator-attested, not verified. No GPU/FPS, energy, network/disk I/O, or child-process CPU measurement."]
do {
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    print("\(scenario): \(status), \(rows.count) samples, report \(url.path)")
} catch { fail(String(describing: error)) }
if status != "completed" { exit(2) }
