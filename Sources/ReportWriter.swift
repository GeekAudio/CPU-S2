import Foundation

struct DeviceSnapshot {
    var model: String
    var processor: String
    var system: String
    var physicalCores: Int
    var logicalThreads: Int
    var baseMHz: Double
    var ceilingMHz: Int
    var isAppleSilicon: Bool
    var isTranslated: Bool
    var coreInfo: CPUCoreInfo? = nil

    static func read() -> DeviceSnapshot {
        let arm = Engine.isAppleSilicon
        let translated = Engine.sysctlInt("sysctl.proc_translated") == 1
        let processor = Engine.sysctl("machdep.cpu.brand_string") ?? (arm ? "Apple Silicon" : "未知处理器")
        let cores = CPUCoreInfo.read()
        return DeviceSnapshot(model: Engine.sysctl("hw.model") ?? "未知机型",
                              processor: processor,
                              system: systemDescription(),
                              physicalCores: cores.physicalCores,
                              logicalThreads: cores.logicalThreads,
                              baseMHz: Double(Engine.sysctlInt("hw.cpufrequency") ?? 0) / 1e6,
                              ceilingMHz: (Engine.sysctlInt("machdep.xcpm.hard_plimit_max_100mhz_ratio") ?? 0) * 100,
                              isAppleSilicon: arm, isTranslated: translated, coreInfo: cores)
    }

    private static func systemDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let build = Engine.sysctl("kern.osversion")
        let name = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return build.map { name + " (\($0))" } ?? name
    }

    var brief: String {
        "\(coreInfo?.summary ?? coreSummary) · 标称基频 \(frequencyText(baseMHz))" + (isTranslated ? " · Rosetta" : "")
    }
    var coreSummary: String {
        let cores = physicalCores > 0 ? "\(physicalCores) 核" : "核心不可用"
        let threads = logicalThreads > 0 ? "\(logicalThreads) 线程" : "线程不可用"
        return "\(cores) / \(threads)"
    }
    var description: String {
        "\(processor)\n\(model) · \(system)\n\(brief) · XCPM 限值 \(frequencyText(Double(ceilingMHz)))"
    }
}

func frequencyText(_ MHz: Double) -> String {
    MHz.isFinite && MHz > 0 ? String(format: "%.2f GHz", MHz / 1000) : "不可用"
}

func dateText(_ date: Date, compact: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = compact ? "yyyyMMdd-HHmmss" : "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

/// A completed run and its hardware context form one immutable export snapshot.
/// Live UI progress, tab selection and settings never become part of its report.
struct DetectionReport {
    let run: Engine.RunResult
    let device: DeviceSnapshot

    var verdict: Engine.Verdict { Engine.verdict(results: run.phases, baseMhz: device.baseMHz, isAppleSilicon: device.isAppleSilicon) }
    var peak: Double { run.phases.filter { !$0.failed }.map { $0.maxF }.filter { $0.isFinite }.max() ?? 0 }
    var validCount: Int { run.phases.reduce(0) { $0 + $1.samples } }
    var droppedCount: Int { run.phases.reduce(0) { $0 + $1.droppedSamples } }
    var highestTemperature: Double? { run.phases.map { $0.tempMax }.filter { $0.isFinite && $0 > 0 }.max() }
    var tiers: [Engine.Tier] { Engine.buildTiers(run.freqsPerPhase, floorMhz: 0, ceilingMhz: 0) }
}

enum ReportWriter {
    static func text(_ report: DetectionReport) -> String {
        var lines = ["CPU-S2 v\(kAppVersion)", report.device.description,
                     "检测时间：\(dateText(report.run.startedAt)) → \(dateText(report.run.finishedAt))",
                     "结论：\(Engine.verdictDescription(report.verdict))",
                     "峰值 \(frequencyText(report.peak)) · 有效 \(report.validCount) · 剔除 \(report.droppedCount)",
                     "探针为未经绝对标定的估算；本轮未观察到高频，不代表硬件不支持睿频。", ""]
        for phase in report.run.phases {
            lines.append("\(phase.label) | \(phase.source)")
            lines.append("中位 \(frequencyText(phase.median)) · P90 \(frequencyText(phase.p90)) · 峰值 \(frequencyText(phase.maxF))")
            lines.append(String(format: "系统利用率 %.1f%% · 有效 %d · 剔除 %d", phase.utilAvg, phase.samples, phase.droppedSamples))
            if phase.tempMax.isFinite && phase.tempMax > 0 { lines.append(String(format: "最高已读温度 %.1f °C", phase.tempMax)) }
            if !phase.warning.isEmpty { lines.append("提示：\(phase.warning)") }
            if !phase.dropReasons.isEmpty {
                lines.append("剔除原因：" + phase.dropReasons.keys.sorted().map { "\($0) \(phase.dropReasons[$0]!)" }.joined(separator: "；"))
            }
            lines.append(phase.uncertainty)
            lines.append("")
        }
        lines.append("中位数取中间值（偶数取两项均值）；P90 为 nearest-rank；100 MHz 为统计分箱，不是硬件 P-state 枚举。")
        return lines.joined(separator: "\n")
    }

    static func csv(_ report: DetectionReport) -> String {
        func cell(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func number(_ value: Double) -> String { value.isFinite ? String(value) : "" }
        var rows = ["phase,source,timestamp,elapsed_seconds,duration_seconds,frequency_mhz,system_util_percent,temp_c,power_w,accepted,rejection_reason,temperature_source,auxiliary_source"]
        for phase in report.run.phases {
            for sample in phase.rawSamples {
                let rejection = Engine.rejectionReason(sample, ceilingMhz: phase.validationCeilingMhz)
                rows.append([cell(phase.label), cell(sample.source), cell(sample.timestamp.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
                             number(sample.elapsed), number(sample.duration), number(sample.freq), number(sample.util),
                             sample.temp > 0 ? number(sample.temp) : "", sample.power > 0 ? number(sample.power) : "",
                             rejection == nil ? "true" : "false", cell(rejection ?? ""), cell(sample.temperatureSource), cell(sample.auxiliarySource)].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func json(_ report: DetectionReport) throws -> Data {
        func finite(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
        let phases: [[String: Any]] = report.run.phases.map { phase in
            ["key": phase.key, "label": phase.label, "source": phase.source, "uncertainty": phase.uncertainty, "warning": phase.warning,
             "validSamples": phase.samples, "droppedSamples": phase.droppedSamples, "dropReasons": phase.dropReasons,
             "validationCeilingMHz": phase.validationCeilingMhz,
             "medianMHz": finite(phase.median), "p90MHz": finite(phase.p90), "peakMHz": finite(phase.maxF),
             "durationSeconds": finite(phase.seconds), "warmupSeconds": finite(phase.warmupSeconds),
             "systemUtilPercent": finite(phase.utilAvg), "temperatureC": phase.tempMax > 0 ? finite(phase.tempMax) : NSNull(),
             "rawSamples": phase.rawSamples.map { sample -> [String: Any] in
                let rejection = Engine.rejectionReason(sample, ceilingMhz: phase.validationCeilingMhz)
                return ["timestamp": sample.timestamp.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                        "elapsedSeconds": finite(sample.elapsed), "durationSeconds": finite(sample.duration), "source": sample.source,
                        "frequencyMHz": finite(sample.freq), "systemUtilPercent": finite(sample.util),
                        "temperatureC": sample.temp > 0 ? finite(sample.temp) : NSNull(), "powerW": sample.power > 0 ? finite(sample.power) : NSNull(),
                        "temperatureSource": sample.temperatureSource, "auxiliarySource": sample.auxiliarySource,
                        "accepted": rejection == nil, "rejectionReason": rejection as Any? ?? NSNull()]
             }]
        }
        let object: [String: Any] = ["app": "CPU-S2", "version": kAppVersion, "device": ["processor": report.device.processor, "model": report.device.model,
                                       "system": report.device.system, "physicalCores": report.device.physicalCores, "logicalThreads": report.device.logicalThreads,
                                       "baseMHz": finite(report.device.baseMHz), "ceilingMHz": report.device.ceilingMHz,
                                       "appleSilicon": report.device.isAppleSilicon, "translated": report.device.isTranslated],
                                   "startedAt": ISO8601DateFormatter().string(from: report.run.startedAt),
                                   "finishedAt": ISO8601DateFormatter().string(from: report.run.finishedAt),
                                   "verdict": report.verdict.rawValue, "summary": text(report), "phases": phases,
                                   "bins": report.tiers.map { ["frequencyMHz": $0.freq, "counts": $0.counts, "total": $0.total] }]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
