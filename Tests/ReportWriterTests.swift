import Foundation
import Darwin

// The app and UI are deliberately absent from this executable. ProbeStubs.c
// aborts if a regression accidentally enters a hardware sampling or load path.
@main
enum ReportWriterTests {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }

    static func sample(_ frequency: Double, index: Int) -> Sample {
        var row = Sample()
        row.freq = frequency
        row.timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        row.elapsed = Double(index) / 10
        row.duration = 0.05
        row.util = 25
        row.temp = 55
        row.power = 12
        row.source = "来源, \"引号\"\n第二行"
        row.temperatureSource = "温度, \"SMC\""
        row.auxiliarySource = "辅助\n来源"
        return row
    }

    static func phase(_ key: String, label: String, frequencies: [Double], ceiling: Int) -> PhaseResult {
        var result = PhaseResult()
        result.key = key
        result.label = label
        result.seconds = 6
        result.warmupSeconds = 1.2
        result.source = "内建探针估算"
        result.uncertainty = "未经绝对标定"
        var rows = frequencies.enumerated().map { sample($0.element, index: $0.offset) }
        if key == "light" {
            // Invalid frequency and valid frequency with missing optional readings
            // must remain distinguishable in the raw-data export.
            for index in [2, 5] {
                rows[index].elapsed = .nan
                rows[index].duration = .infinity
                rows[index].util = -.infinity
                rows[index].temp = .infinity
                rows[index].power = .nan
                rows[index].timestamp = nil
            }
        }
        Engine.fillStats(&result, samples: rows, ceilingMhz: ceiling)
        return result
    }

    static func allKeys(_ object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.flatMap { [$0] + allKeys(dictionary[$0]!) }
        }
        if let array = object as? [Any] { return array.flatMap(allKeys) }
        return []
    }

    static func main() {
        do { try runChecks() }
        catch { failures.append("unexpected report serialization error: \(error)") }

        if failures.isEmpty {
            print("PASS: \(checks) report snapshot/CSV/JSON checks; no CPU probes were executed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) report checks\n", stderr)
            exit(1)
        }
    }

    static func runChecks() throws {
        let phases = [
            phase("light", label: "轻载, \"探测\"\n阶段", frequencies: [2400, 3600, .nan, .infinity, -.infinity, 3400], ceiling: 2500),
            phase("single", label: "单线程", frequencies: [3600, 6400], ceiling: 4500),
            phase("allcore", label: "多线程", frequencies: [6400, 11900, 12001], ceiling: 0)
        ]
        var liveDevice = DeviceSnapshot(model: "SnapshotMac,1", processor: "Captured CPU", system: "Captured system",
                                        physicalCores: 12, logicalThreads: 20, baseMHz: 2400, ceilingMHz: 2500,
                                        isAppleSilicon: false, isTranslated: false,
                                        coreInfo: CPUCoreInfo.resolve(processor: "Intel Core i7-12700K", vendor: "GenuineIntel",
                                                                      isAppleSilicon: false, isTranslated: false,
                                                                      currentPhysicalCores: 8, maximumPhysicalCores: 12,
                                                                      currentLogicalThreads: 20, maximumLogicalThreads: 20))
        var liveRun = Engine.RunResult(phases: phases, freqsPerPhase: phases.map { $0.validSamples.map(\.freq) },
                                       sampler: .builtin, cancelled: false,
                                       startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       finishedAt: Date(timeIntervalSince1970: 1_700_000_030))
        let saved = DetectionReport(run: liveRun, device: liveDevice)
        let capturedCoreReference = liveDevice.coreInfo?.referenceURL
        let text = ReportWriter.text(saved)
        let csv = ReportWriter.csv(saved)
        let jsonData = try ReportWriter.json(saved)

        // Simulate a later capture and refreshed settings/device data while a
        // completed result is still displayed. Value semantics preserve the
        // historical snapshot used by all three export formats.
        liveDevice.processor = "Later CPU"
        liveDevice.model = "LaterMac,2"
        liveDevice.baseMHz = .infinity
        liveDevice.coreInfo = nil
        liveRun.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        liveRun.finishedAt = liveRun.startedAt
        liveRun.cancelled = true
        liveRun.phases[0].label = "新检测进行中"
        liveRun.phases[0].rawSamples.removeAll()
        liveRun.freqsPerPhase = []
        let nextCapture = DetectionReport(run: liveRun, device: liveDevice)
        expect(ReportWriter.text(nextCapture) != text, "fixture represents a distinct later capture")
        expect(ReportWriter.text(saved) == text, "later capture/settings changes cannot alter saved text")
        expect(ReportWriter.csv(saved) == csv, "later capture/settings changes cannot alter saved CSV")
        let savedJSONAfterCapture = try ReportWriter.json(saved)
        expect(savedJSONAfterCapture == jsonData, "later capture/settings changes cannot alter saved JSON")
        expect(text.contains("Captured CPU") && !text.contains("Later CPU") && !text.contains("新检测进行中"),
               "historical text retains only the captured hardware and run state")
        expect(text.contains("标称 8 大核 + 4 小核") && text.contains("12 核 / 20 线程"),
               "historical text retains the captured P/E specification and system thread count")
        expect(saved.validCount == 5 && saved.droppedCount == 6, "fixture has five accepted and six rejected observations")

        let parsed = try JSONSerialization.jsonObject(with: jsonData)
        guard let json = parsed as? [String: Any], let jsonPhases = json["phases"] as? [[String: Any]],
              let bins = json["bins"] as? [[String: Any]], let device = json["device"] as? [String: Any] else {
            failures.append("JSON schema is missing device/phases/bins")
            return
        }
        expect(jsonPhases.count == 3, "JSON contains all three phases")
        expect(json["summary"] as? String == text, "JSON summary equals the standalone text export")
        expect(device["model"] as? String == "SnapshotMac,1", "JSON uses captured hardware")
        let coreTopology = device["coreTopology"] as? [String: Any]
        expect((coreTopology?["performanceCores"] as? NSNumber)?.intValue == 8 &&
               (coreTopology?["efficiencyCores"] as? NSNumber)?.intValue == 4,
               "JSON exports the captured P/E specification")
        expect(coreTopology?["source"] as? String == "intelSpecification" &&
               coreTopology?["referenceURL"] as? String == capturedCoreReference,
               "JSON preserves the source and Intel reference in the immutable snapshot")
        expect((device["physicalCores"] as? NSNumber)?.intValue == 12 &&
               (device["logicalThreads"] as? NSNumber)?.intValue == 20,
               "JSON reports system hardware totals independently of the P/E specification")
        expect(Set(json.keys) == Set(["app", "version", "device", "startedAt", "finishedAt", "verdict", "summary", "phases", "bins"]),
               "top-level JSON contains only the detection report schema")

        let expectedHeader = ["phase", "source", "timestamp", "elapsed_seconds", "duration_seconds", "frequency_mhz",
                              "system_util_percent", "temp_c", "power_w", "accepted", "rejection_reason", "temperature_source", "auxiliary_source"]
        let records = Engine.csvFields(csv)
        expect(records.first == expectedHeader, "CSV has the exact 13-column detection schema")
        expect(records.count == 12 && records.allSatisfy { $0.count == 13 },
               "CSV quoting preserves all eleven raw records and exactly 13 fields each")
        guard records.count == 12, records.allSatisfy({ $0.count == 13 }), jsonPhases.count == 3 else { return }
        expect(records[1][0] == phases[0].label, "CSV round-trips a phase label containing comma, quotes and newline")
        expect(records[1][1] == phases[0].rawSamples[0].source, "CSV round-trips source punctuation and embedded newline")
        expect(records[1][11] == "温度, \"SMC\"" && records[1][12] == "辅助\n来源",
               "CSV optional-source fields remain aligned after quote escaping")

        var csvCursor = 1
        let ceilings = [2500, 4500, 0]
        let expectedAccepted = [[true, false, false, false, false, true], [true, false], [true, true, false]]
        var acceptedByPhase = [0, 0, 0]
        for phaseIndex in phases.indices {
            let jsonPhase = jsonPhases[phaseIndex]
            expect((jsonPhase["validationCeilingMHz"] as? NSNumber)?.intValue == ceilings[phaseIndex],
                   "phase \(phaseIndex) exports its own validation ceiling")
            guard let rows = jsonPhase["rawSamples"] as? [[String: Any]], rows.count == expectedAccepted[phaseIndex].count else {
                failures.append("phase \(phaseIndex) JSON raw record count changed")
                continue
            }
            for rowIndex in rows.indices {
                let accepted = expectedAccepted[phaseIndex][rowIndex]
                let jsonRow = rows[rowIndex]
                let csvRow = records[csvCursor]
                csvCursor += 1
                expect(jsonRow["accepted"] as? Bool == accepted && csvRow[9] == (accepted ? "true" : "false"),
                       "phase \(phaseIndex) row \(rowIndex) uses the same acceptance rule in CSV and JSON")
                expect(csvRow[10] == (jsonRow["rejectionReason"] as? String ?? ""),
                       "phase \(phaseIndex) row \(rowIndex) preserves its rejection reason in both formats")
                if accepted { acceptedByPhase[phaseIndex] += 1 }
                if phaseIndex == 0 && (2...4).contains(rowIndex) {
                    expect(jsonRow["frequencyMHz"] is NSNull && csvRow[5].isEmpty,
                           "NaN and both infinities serialize as JSON null and empty CSV frequency")
                    expect(!(csvRow[10].isEmpty), "nonfinite frequency has an explicit rejection reason")
                }
                if phaseIndex == 0 && [2, 5].contains(rowIndex) {
                    for key in ["timestamp", "elapsedSeconds", "durationSeconds", "systemUtilPercent", "temperatureC", "powerW"] {
                        expect(jsonRow[key] is NSNull, "nonfinite or missing \(key) serializes as JSON null")
                    }
                    expect([2, 3, 4, 6, 7, 8].allSatisfy { csvRow[$0].isEmpty },
                           "nonfinite optional readings produce empty CSV fields without shifting columns")
                }
            }
            expect((jsonPhase["validSamples"] as? NSNumber)?.intValue == acceptedByPhase[phaseIndex],
                   "phase \(phaseIndex) summary count agrees with exported accepted rows")
        }
        expect(acceptedByPhase == [2, 1, 2], "stage-specific ceilings accept 3600/6400 MHz only in their applicable phases")

        // Independent expected bins make omitted/recounted accepted observations
        // visible, including values above a device's nominal ceiling.
        let expectedBins = [2400: [1, 0, 0], 3400: [1, 0, 0], 3600: [0, 1, 0], 6400: [0, 0, 1], 11900: [0, 0, 1]]
        var observedBins: [Int: [Int]] = [:]
        var binnedByPhase = [0, 0, 0]
        for bin in bins {
            guard let frequency = (bin["frequencyMHz"] as? NSNumber)?.intValue,
                  let counts = bin["counts"] as? [Int], counts.count == 3,
                  let total = (bin["total"] as? NSNumber)?.intValue else {
                failures.append("JSON bin schema is invalid")
                continue
            }
            expect(total == counts.reduce(0, +), "\(frequency) MHz bin total equals its stage counts")
            for phaseIndex in 0..<3 { binnedByPhase[phaseIndex] += counts[phaseIndex] }
            if total > 0 { observedBins[frequency] = counts }
        }
        expect(observedBins == expectedBins, "JSON bins contain exactly the independently expected accepted observations")
        expect(binnedByPhase == acceptedByPhase, "JSON bins and CSV accepted-record totals agree for every phase")

        let removedMarkers = ["official", "telemetry", "powermetrics", "activeresidency", "idleresidency", "metricname"]
        expect(!allKeys(json).contains { key in removedMarkers.contains { key.lowercased().contains($0) } },
               "JSON has no official import or hardware-telemetry schema fields")
        expect(![text, csv, String(decoding: jsonData, as: UTF8.self)].contains { output in
            ["官方", "遥测", "powermetrics"].contains { output.lowercased().contains($0) }
        }, "all report formats omit removed official import/telemetry content")

        var missingReference = saved.device
        missingReference.baseMHz = .nan
        let noReference = DetectionReport(run: saved.run, device: missingReference)
        let noReferenceJSON = try JSONSerialization.jsonObject(with: ReportWriter.json(noReference)) as? [String: Any]
        let noReferenceDevice = noReferenceJSON?["device"] as? [String: Any]
        expect(noReferenceDevice?["baseMHz"] is NSNull, "a nonfinite captured reference frequency serializes as null")
    }
}
