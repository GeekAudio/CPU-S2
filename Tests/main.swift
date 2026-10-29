import Foundation
import Darwin

// Keep these regressions independent of the app and its CPU sampling loops.
// The linked C stubs abort if a test accidentally attempts to measure or burn CPU.
var checks = 0
var failures: [String] = []

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { failures.append(message) }
}

func expectEqual(_ actual: Double, _ expected: Double, _ message: String) {
    expect(actual.isFinite && abs(actual - expected) < 0.000_001,
           "\(message): expected \(expected), got \(actual)")
}

func sample(_ frequency: Double, util: Double = 25, temp: Double = 55,
            power: Double = 12) -> Sample {
    var row = Sample()
    row.freq = frequency
    row.util = util
    row.temp = temp
    row.power = power
    return row
}

func statistics(_ frequencies: [Double], ceiling: Int = 4500) -> PhaseResult {
    var result = PhaseResult()
    Engine.fillStats(&result, samples: frequencies.map { sample($0) }, ceilingMhz: ceiling)
    return result
}

// These expected values come from conventional median and nearest-rank P90,
// rather than duplicating the implementation's indexing expressions.
let pair = statistics([1000, 2000])
expectEqual(pair.median, 1500, "even-sized median interpolates the two center values")
expectEqual(statistics([3000, 1000, 2000]).median, 2000, "median is independent of input order")
expectEqual(statistics(Array(stride(from: 1000.0, through: 10000.0, by: 1000.0)), ceiling: 10000).p90,
            9000, "nearest-rank P90 uses the ninth observation out of ten")
let singleton = statistics([2500])
expectEqual(singleton.minF, 2500, "one observation minimum")
expectEqual(singleton.median, 2500, "one observation median")
expectEqual(singleton.p90, 2500, "one observation P90")
expectEqual(singleton.maxF, 2500, "one observation maximum")
expect(!singleton.failed && singleton.samples == 1, "one valid observation is a valid result")

let invalid = [Double.nan, Double.infinity, -Double.infinity, 0, 199, 6301]
let cleaned = Engine.cleanSamples((invalid + [200, 4400, 4800]).map { sample($0) }, ceilingMhz: 4500)
expect(cleaned.map(\.freq).sorted() == [200, 4400, 4800], "invalid and nonfinite frequencies are removed")
expect(statistics(invalid).failed, "all-invalid frequency input produces insufficient data")
expect(statistics([]).failed && statistics([]).samples == 0, "empty input produces insufficient data")
let mixed = statistics([Double.nan, 4400, Double.infinity, 4800])
expect(mixed.samples == 2, "valid sample count excludes all nonfinite values")
expectEqual(mixed.median, 4600, "nonfinite frequencies do not contaminate the median")
expect(mixed.rawSamples.count == 4 && mixed.droppedSamples == 2,
       "results retain raw observations and explicit rejection counts")
expect(mixed.dropReasons.values.reduce(0, +) == 2, "rejection reasons account for every discarded observation")
var reused = pair
Engine.fillStats(&reused, samples: [], ceilingMhz: 4500)
expect(reused.failed && reused.samples == 0 && reused.median == 0 && reused.maxF == 0,
       "reusing a result for an empty capture clears previous successful statistics")

var telemetryResult = PhaseResult()
Engine.fillStats(&telemetryResult,
                 samples: [sample(4000, util: .nan, temp: .infinity, power: .nan),
                           sample(4200, util: 50, temp: 60, power: 20)],
                 ceilingMhz: 4500)
expect(telemetryResult.utilAvg.isFinite && telemetryResult.tempMax.isFinite && telemetryResult.powerMax.isFinite,
       "missing or nonfinite optional telemetry never contaminates summary values")
expectEqual(telemetryResult.tempMax, 60, "nonfinite temperature cannot become a maximum")
expectEqual(telemetryResult.powerMax, 20, "nonfinite power cannot become a maximum")

let phases: [[Double]] = [[4400, 4800], [200, 200, 3050], [Double.nan, 4500, Double.infinity, 6301]]
let tiers = Engine.buildTiers(phases, floorMhz: 800, ceilingMhz: 4500)
for phase in phases.indices {
    let result = statistics(phases[phase])
    let chartCount = tiers.reduce(0) { $0 + $1.counts[phase] }
    expect(chartCount == result.samples,
           "phase \(phase) chart count \(chartCount) equals its \(result.samples) accepted observations")
}
expect(tiers.reduce(0) { $0 + $1.total } == 6, "tier totals retain accepted readings outside the nominal range")
expect(tiers.allSatisfy { $0.total == $0.counts.reduce(0, +) }, "each tier total equals its phase counts")
expect(tiers.contains { $0.freq == 4800 && $0.total == 1 }, "observed 4800 MHz receives a visible tier")

func loadedResult(_ frequencies: [Double]) -> PhaseResult {
    var result = statistics(frequencies)
    result.key = "single"
    result.seconds = 6
    return result
}
expect(Engine.verdict(results: [loadedResult(Array(repeating: 3200, count: 9) + [4000])],
                      baseMhz: 3200, isAppleSilicon: false) == .notObserved,
       "one high-frequency spike cannot establish a turbo observation")
expect(Engine.verdict(results: [loadedResult(Array(repeating: 3200, count: 7) + [4000, 4100, 4200])],
                      baseMhz: 3200, isAppleSilicon: false) == .observed,
       "repeated elevated samples can establish an observation")
expect(Engine.verdict(results: [loadedResult(Array(repeating: 4000, count: 9))],
                      baseMhz: 3200, isAppleSilicon: false) == .insufficient,
       "a short capture reports insufficient data")
expect(Engine.verdict(results: [loadedResult([4000])],
                      baseMhz: .nan, isAppleSilicon: false) == .insufficient,
       "an invalid reference frequency cannot produce a verdict")
expect(Engine.verdict(results: [], baseMhz: 3200, isAppleSilicon: true) == .notApplicable,
       "Intel turbo verdict does not apply to Apple Silicon")

let fixtures = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/Fixtures"
let csv = Engine.parseCSV(fixtures + "/powerlog-quoted.csv")
expect(csv.count == 3, "CSV keeps valid frequencies with empty telemetry and drops nonfinite frequencies")
if csv.count == 3 {
    expect(csv.map(\.freq) == [4400, 4800, 4500], "quoted commas and escaped quotes preserve frequency columns")
    expectEqual(csv[0].temp, 0, "empty temperature is represented as missing")
    expectEqual(csv[0].power, 32.5, "empty temperature does not shift the power column")
    expectEqual(csv[1].temp, 61.25, "temperature after a quoted field remains aligned")
    expectEqual(csv[1].power, 0, "empty power does not discard valid frequency")
    expect(csv[2].util.isFinite && csv[2].temp.isFinite && csv[2].power.isFinite,
           "CSV sanitizes nonfinite optional telemetry")
}
expect(Engine.parseCSV(fixtures + "/does-not-exist.csv").isEmpty, "missing CSV returns no observations")
expect(Engine.csvFields("a,,c,\n") == [["a", "", "c", ""]], "CSV preserves interior and trailing empty fields")
expect(Engine.csvFields("\"a, b\",\"say \"\"hello\"\"\"\n") == [["a, b", "say \"hello\""]],
       "CSV decodes quoted commas and doubled quote escapes")
expect(Engine.csvFields("\"two\nlines\",last\n") == [["two\nlines", "last"]],
       "quoted newlines stay inside their original field")
expect(Engine.csvFields("good,row\n\"unterminated,row").count == 1,
       "an unterminated quoted record is discarded")

// CSV's first header may contain a UTF-8 BOM, and PowerLog commonly writes CRLF.
let bomURL = FileManager.default.temporaryDirectory.appendingPathComponent("cpus2-csv-\(UUID().uuidString).csv")
do {
    defer { try? FileManager.default.removeItem(at: bomURL) }
    try "\u{FEFF}\"CPU Frequency_0(MHz)\",\"Package Temperature_0(C)\"\r\n\"3200\",\"\"\r\n"
        .write(to: bomURL, atomically: true, encoding: .utf8)
    let rows = Engine.parseCSV(bomURL.path)
    expect(rows.count == 1 && rows.first?.freq == 3200, "UTF-8 BOM and CRLF do not hide the frequency header")
} catch {
    failures.append("could not create temporary BOM/CRLF CSV fixture: \(error)")
}

// Short sleeping processes validate lifecycle ownership with no CPU workload.
func sleeper(ignoreTermination: Bool = false) throws -> Process {
    let process = Process()
    let ready = Pipe()
    process.executableURL = URL(fileURLWithPath: ignoreTermination ? "/bin/sh" : "/bin/sleep")
    // The shell execs sleep, leaving only one owned PID; the byte confirms SIGTERM is ignored.
    process.arguments = ignoreTermination ? ["-c", "trap '' TERM; printf .; exec /bin/sleep 10"] : ["10"]
    process.standardOutput = ignoreTermination ? ready : FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    if ignoreTermination {
        expect(ready.fileHandleForReading.readData(ofLength: 1) == Data([46]),
               "forced-timeout fixture installed its SIGTERM handler")
    }
    return process
}

func cleanUp(_ process: Process) {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

do {
    let session = Engine.Session()
    expect(!session.isCancelled, "fresh session is active")
    let process = try sleeper()
    defer { cleanUp(process) }
    expect(session.register(process), "active session owns an existing process")
    let started = ProcessInfo.processInfo.systemUptime
    session.cancel()
    session.cancel()
    expect(session.isCancelled, "cancel is persistent and idempotent")
    _ = session.waitForExit(process, timeout: 2)
    expect(!process.isRunning, "cancelling the session reaps its process")
    expect(ProcessInfo.processInfo.systemUptime - started < 3, "cancel has a bounded completion time")
    session.unregister(process)
} catch {
    failures.append("cancellation process setup failed: \(error)")
}

do {
    let session = Engine.Session()
    let process = try sleeper(ignoreTermination: true)
    defer { cleanUp(process) }
    expect(session.register(process), "timeout test process is registered")
    let started = ProcessInfo.processInfo.systemUptime
    expect(!session.waitForExit(process, timeout: 0.1), "a wait timeout reports failure")
    expect(!process.isRunning, "a wait timeout terminates and reaps its process")
    expect(ProcessInfo.processInfo.systemUptime - started < 3, "timeout cleanup is bounded")
    session.unregister(process)
} catch {
    failures.append("timeout process setup failed: \(error)")
}

do {
    let session = Engine.Session()
    session.cancel()
    let process = try sleeper()
    defer { cleanUp(process) }
    expect(!session.register(process), "cancelled session refuses a newly supplied process")
    _ = session.waitForExit(process, timeout: 2)
    expect(!process.isRunning, "a rejected process is terminated rather than orphaned")
} catch {
    failures.append("late-registration process setup failed: \(error)")
}

do {
    let session = Engine.Session()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["0.02"]
    let launched = try session.launch(process)
    expect(launched, "session can atomically launch and own a process")
    defer { cleanUp(process) }
    expect(session.waitForExit(process, timeout: 2), "normal process completion reports success")
    expect(process.terminationStatus == 0, "normal completion preserves the exit status")
} catch {
    failures.append("atomic-launch process setup failed: \(error)")
}

do {
    let session = Engine.Session()
    session.cancel()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["10"]
    let launched = try session.launch(process)
    expect(!launched, "a cancelled session cannot launch a later process")
    expect(!process.isRunning, "rejected atomic launch never starts the child")
    var progressCallbacks = 0
    let result = Engine.runDetailed(sampler: .builtin, session: session) { _ in progressCallbacks += 1 }
    expect(result.cancelled && result.phases.isEmpty && progressCallbacks == 0,
           "an already-cancelled capture returns without starting a phase or touching the CPU probe")
} catch {
    failures.append("cancelled-launch process setup failed: \(error)")
}

if failures.isEmpty {
    print("PASS: \(checks) parser/statistics/process lifecycle checks; no CPU probes were executed")
} else {
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(failures.count) failure(s) across \(checks) checks\n", stderr)
    exit(1)
}
