import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - 全局常量

let kAppName = "CPU-S2"
let kAppVersion = "2.5.0"
let kResolutionMs = 100            // 采样间隔（毫秒）
let kLoadWarmup = 1.2              // 加压后先等这么久再开始计数
let kPowerLog = "/Applications/Intel Power Gadget/PowerLog"
let kPrefHideIPGWarning = "cpus2.hideIPGWarning"

// C 探针（见 Probe.c）
@_silgen_name("cpus2_measure_mhz")
func cpus2_measure_mhz(_ ms: Double) -> Double

@_silgen_name("cpus2_burn")
func cpus2_burn(_ ms: Double)

// SMC 温度（VirtualSMC/SMCProcessor，免 root；读不到返回 0）
@_silgen_name("cpus2_cpu_temp")
func cpus2_cpu_temp() -> Double

// MARK: - 数据模型

struct Sample {
    var freq: Double = 0        // MHz; zero means unavailable
    var util: Double = 0        // %
    var temp: Double = 0        // °C; zero means unavailable
    var power: Double = 0       // W; zero means unavailable
    var hwMin: Double = 0
    var timestamp: Date? = nil  // wall-clock anchor + monotonic elapsed
    var elapsed: Double = 0    // midpoint, seconds from this phase's sampling window
    var duration: Double = 0   // actual probe wall time, seconds
    var source: String = "内建探针估算"
    var temperatureSource: String = ""
    var auxiliarySource: String = ""
}

struct PhaseResult {
    var key: String = ""
    var label: String = ""
    var threads: Int = 0
    var seconds: Double = 0     // actual sampling-window duration, excludes warmup
    var samples: Int = 0
    var aux: Bool = false
    var coreProbe: Bool = false
    var minF: Double = 0
    var median: Double = 0
    var p90: Double = 0         // nearest-rank: sorted[ceil(0.9 * n) - 1]
    var maxF: Double = 0
    var utilAvg: Double = 0
    var tempMax: Double = 0
    var powerMax: Double = 0
    var failed: Bool = false
    var rawSamples: [Sample] = []
    var validSamples: [Sample] = []
    var validationCeilingMhz: Int = 0
    var droppedSamples: Int = 0
    var dropReasons: [String: Int] = [:]
    var source: String = ""
    var uncertainty: String = ""
    var warmupSeconds: Double = 0
    var warning: String = ""
}

// MARK: - 引擎

enum Engine {

    enum Sampler: String {
        case powerLog
        case builtin
    }

    struct Tier {
        var freq: Int                  // 档位中心频率（MHz）
        var counts: [Int] = [0, 0, 0]  // 轻载 / 单线程 / 多线程
        var total: Int = 0
    }

    // MARK: sysctl

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: 系统报告的 CPU 电源限制（不是实时频率）
    //
    // IOPMCopyCPUPowerStatus 是 IOKit 公开 API（IOPMLib.h），返回：
    //   CPU_Speed_Limit / CPU_Scheduler_Limit  (0–100)  —— 系统给 CPU 的频率上限百分比
    //   CPU_Available_CPUs
    // 它描述系统报告的限制，不提供实际频率，也不足以验证计时探针的绝对精度。

    static func cpuSpeedLimit() -> Int? {
        var unmanaged: Unmanaged<CFDictionary>?
        let r = IOPMCopyCPUPowerStatus(&unmanaged)
        guard r == kIOReturnSuccess, let cf = unmanaged?.takeRetainedValue() else { return nil }
        let dict = cf as NSDictionary
        if let v = dict["CPU_Speed_Limit"] as? Int { return v }
        if let n = dict["CPU_Speed_Limit"] as? NSNumber { return n.intValue }
        return nil
    }

    // MARK: 会话与进程生命周期

    /// One session owns every child it starts. Cancelling an old session cannot kill a new run.
    final class Session {
        private let lock = NSLock()
        private var cancelled = false
        private var processes: [ObjectIdentifier: Process] = [:]
        let startedAt = Date()

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        @discardableResult
        func launch(_ process: Process) throws -> Bool {
            // Serialize launch with cancel so a process cannot escape after cancellation.
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            try process.run()
            processes[ObjectIdentifier(process)] = process
            return true
        }

        @discardableResult
        func register(_ process: Process) -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            processes[ObjectIdentifier(process)] = process
            lock.unlock()
            return true
        }

        func unregister(_ process: Process) {
            lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let children = Array(processes.values)
            processes.removeAll()
            lock.unlock()
            // Send to the complete set immediately; never block the UI waiting per child.
            for child in children where child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
        }

        func stop(_ process: Process) {
            if process.isRunning { process.terminate() }
            let deadline = Engine.monotonicNow() + 0.15
            while process.isRunning && Engine.monotonicNow() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let killDeadline = Engine.monotonicNow() + 0.25
            while process.isRunning && Engine.monotonicNow() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            unregister(process)
        }

        /// Returns false on cancellation or timeout, and always stops a timed-out child.
        func waitForExit(_ process: Process, timeout: Double) -> Bool {
            let deadline = Engine.monotonicNow() + max(0, timeout.isFinite ? timeout : 0)
            while process.isRunning && !isCancelled && Engine.monotonicNow() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let success = !process.isRunning && !isCancelled
            if !success { stop(process) } else { unregister(process) }
            return success
        }
    }

    struct Progress {
        var phaseIndex: Int
        var phaseLabel: String
        var completedFraction: Double
        var elapsed: Double
        var duration: Double
        var warmup: Bool
        var message: String
    }

    struct RunResult {
        var phases: [PhaseResult]
        var freqsPerPhase: [[Double]]
        var sampler: Sampler
        var cancelled: Bool
        var startedAt: Date
        var finishedAt: Date
    }

    static var isAppleSilicon: Bool { sysctlInt("hw.optional.arm64") == 1 }

    static func monotonicNow() -> Double { ProcessInfo.processInfo.systemUptime }

    @discardableResult
    static func pause(_ seconds: Double, session: Session) -> Bool {
        let deadline = monotonicNow() + max(0, seconds)
        while !session.isCancelled && monotonicNow() < deadline {
            Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - monotonicNow())))
        }
        return !session.isCancelled
    }

    static func detectSampler() -> Sampler {
        if !isAppleSilicon && FileManager.default.isExecutableFile(atPath: kPowerLog) { return .powerLog }
        return .builtin
    }

    static func samplerName(_ s: Sampler) -> String {
        switch s {
        case .powerLog: return "Intel PowerLog / 单线程探针估算"
        case .builtin: return "内建探针估算（未标定）"
        }
    }

    static func note(_ s: String) {
        FileHandle.standardError.write(("cpus2: " + s + "\n").data(using: .utf8)!)
    }

    // MARK: CPU 占用率

    final class CPUUsageSampler {
        private var lastTicks: [UInt32]?
        func read() -> Double {
            var info = host_cpu_load_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
            let kr = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
                p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, q, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return 0 }
            let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
            defer { lastTicks = ticks }
            guard let previous = lastTicks else { return 0 }
            let deltas = zip(ticks, previous).map { Double($0 &- $1) }
            let total = deltas.reduce(0, +)
            return total > 0 ? min(100, max(0, (total - deltas[2]) / total * 100)) : 0
        }
    }

    // MARK: 负载

    final class LoadManager {
        /// Kept for legacy application shutdown. New runs use their own Session.
        static let shared = LoadManager()
        private static let registryLock = NSLock()
        private static var activeSessions: [ObjectIdentifier: Session] = [:]
        private let session: Session
        private var children: [Process] = []

        init(session: Session = Session()) { self.session = session }

        static func track(_ session: Session) {
            registryLock.lock(); activeSessions[ObjectIdentifier(session)] = session; registryLock.unlock()
        }
        static func untrack(_ session: Session) {
            registryLock.lock(); activeSessions.removeValue(forKey: ObjectIdentifier(session)); registryLock.unlock()
        }

        @discardableResult
        func spawn(_ n: Int) -> Bool {
            guard n > 0 else { return true }
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/yes") else {
                note("找不到 /usr/bin/yes，无法建立多线程负载")
                return false
            }
            for _ in 0..<n {
                guard !session.isCancelled else { return false }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
                process.arguments = ["-n", "10", "/usr/bin/yes"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    guard try session.launch(process) else { return false }
                    children.append(process)
                } catch {
                    note("负载进程启动失败：\(error.localizedDescription)")
                    return false
                }
            }
            return true
        }

        func stop() {
            // Stop all workers together before reaping, keeping shutdown bounded.
            for child in children where child.isRunning { kill(child.processIdentifier, SIGKILL) }
            for child in children { _ = session.waitForExit(child, timeout: 0.2) }
            children.removeAll()
        }

        func killAll() {
            Self.registryLock.lock()
            let sessions = Array(Self.activeSessions.values)
            Self.activeSessions.removeAll()
            Self.registryLock.unlock()
            for active in sessions { active.cancel() }
            session.cancel()
            stop()
        }
    }

    // MARK: 采样

    private struct Capture {
        var rows: [Sample]
        var sampler: Sampler
        var elapsed: Double
        var warmup: Double
        var warning: String = ""
    }

    private static func warmup(seconds: Double, threads: Int, session: Session,
                               progress: ((Double, Bool) -> Void)?) -> Double {
        let started = monotonicNow()
        while !session.isCancelled && monotonicNow() - started < seconds {
            if threads > 0 { _ = cpus2_measure_mhz(100) }
            else { _ = pause(min(0.05, seconds - (monotonicNow() - started)), session: session) }
            progress?(monotonicNow() - started, true)
        }
        return monotonicNow() - started
    }

    /// The probe itself is the single-thread workload. Multithread uses N-1 workers + probe.
    /// Light probing is 4ms every 200ms (~2% nominal probe duty); it is not passive idle telemetry.
    private static func captureBuiltin(seconds: Double, threads: Int, session: Session,
                                       progress: ((Double, Bool) -> Void)? = nil) -> Capture {
        let manager = LoadManager(session: session)
        let logical = max(1, sysctlInt("hw.logicalcpu") ?? 1)
        let workers = max(0, min(threads, logical) - 1)
        let loadOK = manager.spawn(workers)
        defer { manager.stop() }
        let prepared = warmup(seconds: threads > 0 ? kLoadWarmup : 0.5,
                              threads: threads, session: session, progress: progress)
        let usage = CPUUsageSampler()
        _ = usage.read()
        let start = monotonicNow()
        let wallStart = Date()
        var rows: [Sample] = []
        let interval = threads > 0 ? Double(kResolutionMs) / 1000 : 0.2
        while !session.isCancelled && monotonicNow() - start < seconds {
            let before = monotonicNow()
            let remaining = max(0.001, seconds - (before - start))
            let frequency = cpus2_measure_mhz(min(threads > 0 ? 100 : 4, remaining * 1000))
            let after = monotonicNow()
            var sample = Sample()
            sample.freq = frequency
            sample.elapsed = (before + after) / 2 - start
            sample.duration = after - before
            sample.timestamp = wallStart.addingTimeInterval(sample.elapsed)
            sample.util = usage.read()
            sample.temp = validTemperature(cpus2_cpu_temp())
            sample.temperatureSource = sample.temp > 0 ? "SMC（采样期间读取）" : ""
            rows.append(sample)
            progress?(monotonicNow() - start, false)
            if threads == 0 {
                _ = pause(max(0, interval - (monotonicNow() - before)), session: session)
            }
        }
        return Capture(rows: rows, sampler: .builtin, elapsed: monotonicNow() - start,
                       warmup: prepared, warning: loadOK ? "" : "多线程负载未完全建立，本阶段不可用于负载比较")
    }

    static func sampleBuiltin(seconds: Double, threads: Int) -> [Sample] {
        let session = Session()
        LoadManager.track(session); defer { LoadManager.untrack(session) }
        return captureBuiltin(seconds: seconds, threads: threads, session: session).rows
    }

    private static func capturePowerLog(seconds: Double, threads: Int, probeFreq: Bool,
                                        session: Session, progress: ((Double, Bool) -> Void)? = nil) -> Capture {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpus2-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let manager = LoadManager(session: session)
        let logical = max(1, sysctlInt("hw.logicalcpu") ?? 1)
        let loadOK = manager.spawn(max(0, min(threads, logical) - 1))
        defer { manager.stop() }
        let prepared = warmup(seconds: threads > 0 ? kLoadWarmup : 0.5,
                              threads: threads, session: session, progress: progress)
        guard !session.isCancelled else {
            return Capture(rows: [], sampler: .powerLog, elapsed: 0, warmup: prepared)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kPowerLog)
        process.arguments = ["-duration", "\(max(1, Int(ceil(seconds))))", "-file", tmp.path,
                             "-resolution", "\(kResolutionMs)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let start = monotonicNow()
        let wallStart = Date()
        do {
            guard try session.launch(process) else {
                return Capture(rows: [], sampler: .powerLog, elapsed: 0, warmup: prepared)
            }
        } catch {
            note("PowerLog 启动失败：\(error.localizedDescription)")
            return Capture(rows: [], sampler: .powerLog, elapsed: 0, warmup: prepared,
                           warning: "PowerLog 无法启动")
        }
        defer { if process.isRunning { session.stop(process) } else { session.unregister(process) } }
        let usage = CPUUsageSampler()
        _ = usage.read()
        var probes: [Sample] = []
        while !session.isCancelled && monotonicNow() - start < seconds {
            let before = monotonicNow()
            var sample = Sample()
            sample.freq = cpus2_measure_mhz(min(threads > 0 ? 100 : 4, max(1, (seconds - (before - start)) * 1000)))
            let after = monotonicNow()
            sample.elapsed = (before + after) / 2 - start
            sample.duration = after - before
            sample.timestamp = wallStart.addingTimeInterval(sample.elapsed)
            sample.util = usage.read()
            sample.temp = validTemperature(cpus2_cpu_temp())
            sample.temperatureSource = sample.temp > 0 ? "SMC（采样期间读取）" : ""
            probes.append(sample)
            progress?(monotonicNow() - start, false)
            if threads == 0 { _ = pause(max(0, 0.2 - (monotonicNow() - before)), session: session) }
        }
        let elapsed = monotonicNow() - start
        let completed = session.waitForExit(process, timeout: 2.0)
        guard !session.isCancelled else { return Capture(rows: [], sampler: .powerLog, elapsed: elapsed, warmup: prepared) }
        var hardware = parseCSV(tmp.path)
        hardware = hardware.filter { $0.elapsed >= 0 && $0.elapsed <= elapsed + Double(kResolutionMs) / 1000 }
        for index in hardware.indices {
            hardware[index].timestamp = wallStart.addingTimeInterval(hardware[index].elapsed)
            if hardware[index].temp <= 0,
               let nearest = nearestSample(to: hardware[index].elapsed, in: probes, tolerance: 0.25), nearest.temp > 0 {
                hardware[index].temp = nearest.temp
                hardware[index].temperatureSource = nearest.temperatureSource
            }
        }
        let ceiling = (sysctlInt("machdep.xcpm.hard_plimit_max_100mhz_ratio") ?? 0) * 100
        let hasHardware = !cleanSamples(hardware, ceilingMhz: ceiling).isEmpty
        // Reuse the concurrently acquired probes instead of applying a second complete load test.
        if !hasHardware {
            return Capture(rows: probes, sampler: .builtin, elapsed: elapsed, warmup: prepared,
                           warning: "PowerLog 无有效辅助读数，使用本阶段同时采集的探针估算" +
                            (loadOK ? "" : "；多线程负载未完全建立，本阶段不可用于负载比较"))
        }
        var rows = hardware
        if probeFreq {
            rows = probes.map { probe in
                var sample = probe
                // Align individual points by elapsed time. Never copy a whole-run average/peak to each point.
                if let aux = nearestSample(to: probe.elapsed, in: hardware, tolerance: 0.25) {
                    sample.util = aux.util
                    sample.power = aux.power
                    sample.hwMin = aux.hwMin
                    if aux.temp > 0 {
                        sample.temp = aux.temp
                        sample.temperatureSource = aux.temperatureSource
                    }
                    sample.auxiliarySource = "Intel PowerLog（邻近时间点）"
                }
                return sample
            }
        }
        var warnings: [String] = []
        if !completed { warnings.append("PowerLog 超时，已终止；仅保留文件内已写入数据") }
        if !loadOK { warnings.append("多线程负载未完全建立，本阶段不可用于负载比较") }
        return Capture(rows: rows, sampler: .powerLog,
                       elapsed: elapsed, warmup: prepared, warning: warnings.joined(separator: "；"))
    }

    static func samplePowerLog(seconds: Double, threads: Int, probeFreq: Bool) -> [Sample] {
        let session = Session()
        LoadManager.track(session); defer { LoadManager.untrack(session) }
        return capturePowerLog(seconds: seconds, threads: threads, probeFreq: probeFreq, session: session).rows
    }

    private static func nearestSample(to elapsed: Double, in rows: [Sample], tolerance: Double) -> Sample? {
        guard let sample = rows.min(by: { abs($0.elapsed - elapsed) < abs($1.elapsed - elapsed) }),
              abs(sample.elapsed - elapsed) <= tolerance else { return nil }
        return sample
    }

    private static func validTemperature(_ value: Double) -> Double {
        value.isFinite && value > 0 && value < 150 ? value : 0
    }

    static func currentTemp() -> Double { validTemperature(cpus2_cpu_temp()) }

    // MARK: CSV（保留空列、引号内逗号、双引号转义和 CRLF）

    static func csvFields(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted && next < text.endIndex && text[next] == "\"" {
                    field.append("\""); index = text.index(after: next); continue
                }
                quoted.toggle()
            } else if character == "," && !quoted {
                row.append(field.trimmingCharacters(in: .whitespaces)); field = ""
            } else if (character == "\n" || character == "\r" || character == "\r\n") && !quoted {
                row.append(field.trimmingCharacters(in: .whitespaces)); field = ""
                if row.contains(where: { !$0.isEmpty }) { records.append(row) }
                row = []
            } else { field.append(character) }
            index = next
        }
        // An unterminated quoted record is malformed, rather than an extra valid data row.
        if !quoted && (!field.isEmpty || !row.isEmpty) {
            row.append(field.trimmingCharacters(in: .whitespaces)); records.append(row)
        }
        return records
    }

    static func parseCSV(_ path: String) -> [Sample] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let records = csvFields(text.replacingOccurrences(of: "\u{feff}", with: ""))
        guard let headerIndex = records.firstIndex(where: { $0.contains("CPU Frequency_0(MHz)") }) else { return [] }
        let header = records[headerIndex]
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        let frequency = column("CPU Frequency_0(MHz)")
        let utilization = column("CPU Utilization(%)")
        let temperature = column("Package Temperature_0(C)")
        let power = column("Processor Power_0(Watt)")
        let minimum = column("CPU Min Frequency_0(MHz)")
        let elapsed = header.firstIndex(where: { $0.lowercased().contains("elapsed time") })
        func number(_ row: [String], _ index: Int?) -> Double? {
            guard let index = index, index < row.count, let value = Double(row[index]), value.isFinite else { return nil }
            return value
        }
        var rows: [Sample] = []
        for (offset, record) in records.dropFirst(headerIndex + 1).enumerated() {
            guard let value = number(record, frequency), value > 0 else { continue }
            var sample = Sample()
            sample.freq = value
            sample.util = min(100, max(0, number(record, utilization) ?? 0))
            sample.temp = validTemperature(number(record, temperature) ?? 0)
            sample.power = max(0, number(record, power) ?? 0)
            sample.hwMin = max(0, number(record, minimum) ?? 0)
            sample.elapsed = number(record, elapsed) ?? Double(offset) * Double(kResolutionMs) / 1000
            sample.duration = Double(kResolutionMs) / 1000
            sample.source = "Intel PowerLog（封装平均频率）"
            sample.temperatureSource = sample.temp > 0 ? "Intel PowerLog" : ""
            sample.auxiliarySource = "Intel PowerLog"
            rows.append(sample)
        }
        return rows
    }

    private static func capture(sampler: Sampler, seconds: Double, threads: Int, probeFreq: Bool,
                                session: Session, progress: ((Double, Bool) -> Void)? = nil) -> Capture {
        if sampler == .powerLog && !isAppleSilicon {
            let captured = capturePowerLog(seconds: seconds, threads: threads, probeFreq: probeFreq,
                                           session: session, progress: progress)
            if !captured.rows.isEmpty || session.isCancelled { return captured }
            note("PowerLog 无有效数据，回退内建探针估算")
            var fallback = captureBuiltin(seconds: seconds, threads: threads, session: session, progress: progress)
            fallback.warning = "PowerLog 无有效数据，本阶段已重新使用内建探针估算"
            return fallback
        }
        return captureBuiltin(seconds: seconds, threads: threads, session: session, progress: progress)
    }

    static func takeSamples(sampler: Sampler, seconds: Double, threads: Int,
                            probeFreq: Bool) -> ([Sample], Sampler) {
        let session = Session()
        LoadManager.track(session); defer { LoadManager.untrack(session) }
        let captured = capture(sampler: sampler, seconds: seconds, threads: threads,
                               probeFreq: probeFreq, session: session)
        return (captured.rows, captured.sampler)
    }

    // MARK: 一致的清洗与统计

    /// Ceiling is a plausibility guard, not a clamp: values above the nominal max can remain valid.
    /// Without an Intel ceiling, use a broad sanity range rather than inventing a 4.5GHz maximum.
    static func rejectionReason(_ sample: Sample, ceilingMhz: Int) -> String? {
        if !sample.freq.isFinite { return "频率非有限数" }
        if sample.freq < 200 { return "频率低于200MHz" }
        let upper = ceilingMhz > 0 ? min(12000, Double(ceilingMhz) * 1.4) : 12000
        if sample.freq > upper { return "频率超出合理范围" }
        return nil
    }

    static func cleanSamples(_ samples: [Sample], ceilingMhz: Int) -> [Sample] {
        samples.filter { rejectionReason($0, ceilingMhz: ceilingMhz) == nil }.map { sample in
            var cleaned = sample
            cleaned.util = sample.util.isFinite ? min(100, max(0, sample.util)) : 0
            cleaned.temp = validTemperature(sample.temp)
            cleaned.power = sample.power.isFinite ? max(0, sample.power) : 0
            cleaned.hwMin = sample.hwMin.isFinite ? max(0, sample.hwMin) : 0
            return cleaned
        }
    }

    static func fillStats(_ result: inout PhaseResult, samples: [Sample], ceilingMhz: Int) {
        result.rawSamples = samples
        result.validationCeilingMhz = ceilingMhz
        result.dropReasons = [:]
        for sample in samples {
            if let reason = rejectionReason(sample, ceilingMhz: ceilingMhz) { result.dropReasons[reason, default: 0] += 1 }
        }
        let clean = cleanSamples(samples, ceilingMhz: ceilingMhz)
        result.validSamples = clean
        result.samples = clean.count
        result.droppedSamples = samples.count - clean.count
        result.failed = clean.isEmpty
        result.minF = 0; result.maxF = 0; result.median = 0; result.p90 = 0
        result.utilAvg = 0; result.tempMax = 0; result.powerMax = 0
        guard !clean.isEmpty else { return }
        let frequencies = clean.map { $0.freq }.sorted()
        let count = frequencies.count
        result.minF = frequencies[0]
        result.maxF = frequencies[count - 1]
        result.median = count.isMultiple(of: 2) ? (frequencies[count / 2 - 1] + frequencies[count / 2]) / 2 : frequencies[count / 2]
        result.p90 = frequencies[max(0, Int(ceil(Double(count) * 0.9)) - 1)]
        result.utilAvg = clean.map { $0.util }.reduce(0, +) / Double(count)
        result.tempMax = clean.map { $0.temp }.max() ?? 0
        result.powerMax = clean.map { $0.power }.max() ?? 0
    }

    // MARK: 实测分箱（每个有效点都进入一个100MHz箱）

    static func buildTiers(_ perPhase: [[Double]], floorMhz: Int, ceilingMhz: Int) -> [Tier] {
        var bins: [Int: Tier] = [:]
        for (phase, frequencies) in perPhase.enumerated() where phase < 3 {
            let clean = cleanSamples(frequencies.map { Sample(freq: $0) }, ceilingMhz: ceilingMhz)
            for sample in clean {
                let center = Int((sample.freq / 100).rounded()) * 100
                var tier = bins[center] ?? Tier(freq: center)
                tier.counts[phase] += 1
                tier.total += 1
                bins[center] = tier
            }
        }
        guard let lowest = bins.keys.min(), let highest = bins.keys.max() else { return [] }
        // Keep empty intermediate bins so histogram positions remain proportional to MHz.
        return stride(from: lowest, through: highest, by: 100).map { bins[$0] ?? Tier(freq: $0) }
    }

    // MARK: 判定

    enum Verdict: String {
        case observed, notObserved, insufficient, notApplicable
    }

    /// A repeated elevated measurement is required; one peak can never determine the verdict.
    /// The guard band is a decision rule, not a calibrated confidence interval.
    static func verdict(results: [PhaseResult], baseMhz: Double,
                        isAppleSilicon: Bool = Engine.isAppleSilicon) -> Verdict {
        guard !isAppleSilicon else { return .notApplicable }
        guard baseMhz.isFinite && baseMhz > 0 else { return .insufficient }
        let loaded = results.filter { $0.key == "single" || $0.key == "allcore" }
        let valid = loaded.filter { !$0.failed && $0.samples >= 10 && $0.seconds >= 1 && !$0.warning.contains("负载未完全建立") }
        guard !valid.isEmpty else { return .insufficient }
        let threshold = baseMhz + max(100, baseMhz * 0.05)
        for phase in valid {
            // Hardware can establish a measured observation; uncalibrated probes only suggest it.
            let points = cleanSamples(phase.rawSamples, ceilingMhz: phase.validationCeilingMhz)
            let elevated = points.filter { $0.freq > threshold }.count
            if elevated >= max(3, Int(ceil(Double(points.count) * 0.1))) && phase.p90 > threshold { return .observed }
        }
        return valid.count == loaded.count && !loaded.isEmpty ? .notObserved : .insufficient
    }

    static func verdictDescription(_ verdict: Verdict, estimated: Bool = true) -> String {
        switch verdict {
        case .observed: return estimated ? "估算读数持续高于标称基频" : "已观察到高于基频的频率"
        case .notObserved: return "本次未观察到稳定高于基频的频率"
        case .insufficient: return "数据不足，无法判定"
        case .notApplicable: return "Apple Silicon：分别观察计算负载变化，Intel 睿频判定不适用"
        }
    }

    // MARK: 跑三档

    struct PhaseSpec {
        let key: String
        let label: String
        let threads: Int
        let seconds: Double
        let probeFreq: Bool
        var warmupSeconds: Double { threads > 0 ? kLoadWarmup : 0.5 }
    }

    static func specs() -> [PhaseSpec] {
        let logical = max(1, sysctlInt("hw.logicalcpu") ?? 1)
        return [
            PhaseSpec(key: "idle", label: "轻载探测", threads: 0, seconds: 8, probeFreq: false),
            PhaseSpec(key: "single", label: "单线程计算", threads: 1, seconds: 6, probeFreq: true),
            PhaseSpec(key: "allcore", label: "多线程计算", threads: logical, seconds: 12, probeFreq: false),
        ]
    }

    static func runDetailed(sampler: Sampler, session: Session,
                            progress: @escaping (Progress) -> Void) -> RunResult {
        let startedAt = Date()
        LoadManager.track(session)
        defer { LoadManager.untrack(session) }
        let ceiling = (sysctlInt("machdep.xcpm.hard_plimit_max_100mhz_ratio") ?? 0) * 100
        var results: [PhaseResult] = []
        var freqs: [[Double]] = []
        var effective = sampler
        let phases = specs()
        let totalDuration = phases.reduce(0) { $0 + $1.seconds + $1.warmupSeconds }
        var completed: Double = 0
        for (index, spec) in phases.enumerated() {
            guard !session.isCancelled else { break }
            let update: (Double, Bool) -> Void = { elapsed, warming in
                let phaseElapsed = warming ? elapsed : spec.warmupSeconds + elapsed
                let bounded = min(spec.seconds + spec.warmupSeconds, phaseElapsed)
                progress(Progress(phaseIndex: index, phaseLabel: spec.label,
                                  completedFraction: min(1, (completed + bounded) / totalDuration),
                                  elapsed: elapsed, duration: warming ? spec.warmupSeconds : spec.seconds,
                                  warmup: warming,
                                  message: warming ? "\(spec.label) · 预热中…" : "\(spec.label) · 采样中…"))
            }
            update(0, true)
            let captured = capture(sampler: sampler, seconds: spec.seconds, threads: spec.threads,
                                   probeFreq: spec.probeFreq, session: session, progress: update)
            guard !session.isCancelled else { break }
            if captured.sampler == .builtin { effective = .builtin }
            var result = PhaseResult()
            result.key = spec.key; result.label = spec.label; result.threads = spec.threads
            result.seconds = captured.elapsed; result.warmupSeconds = captured.warmup
            result.coreProbe = spec.probeFreq || captured.sampler == .builtin
            result.aux = spec.probeFreq && captured.sampler == .powerLog
            result.source = result.coreProbe ? "内建探针估算（未标定）" : "Intel PowerLog（封装平均频率）"
            result.uncertainty = result.coreProbe ? "指令链计时估算，受抢占、迁核及微架构影响；未标定，不承诺固定误差" : "Intel PowerLog 封装平均频率；与单个活跃核心的频率口径不同"
            if isAppleSilicon { result.uncertainty += "；未区分 P/E 核和簇，不用于 Intel 睿频判定" }
            result.warning = captured.warning
            fillStats(&result, samples: captured.rows, ceilingMhz: ceiling)
            let clean = cleanSamples(captured.rows, ceilingMhz: ceiling)
            note("\(spec.label)：原始 \(captured.rows.count) 条 → 有效 \(result.samples) 条，中位 \(Int(result.median)) MHz，峰值 \(Int(result.maxF)) MHz")
            results.append(result)
            freqs.append(clean.map { $0.freq })
            completed += spec.seconds + spec.warmupSeconds
        }
        return RunResult(phases: results, freqsPerPhase: freqs, sampler: effective,
                         cancelled: session.isCancelled, startedAt: startedAt, finishedAt: Date())
    }

    /// Backwards-compatible entry point. Prefer runDetailed + an explicit Session in the UI.
    static func run(sampler: Sampler, session: Session = Session(),
                    progress: @escaping (Int, String) -> Void) -> ([PhaseResult], [[Double]], Sampler) {
        let result = runDetailed(sampler: sampler, session: session) { update in
            progress(update.phaseIndex, update.message)
        }
        return (result.phases, result.freqsPerPhase, result.sampler)
    }
}
