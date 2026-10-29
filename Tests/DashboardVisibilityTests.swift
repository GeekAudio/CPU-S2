import AppKit
import Darwin

// Presentation regressions only. Explicit fixtures and aborting ProbeStubs.c
// keep this executable out of hardware sampling and CPU load paths.
@main
enum DashboardVisibilityTests {
    static var checks = 0
    static var failures: [String] = []

    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func visible(_ view: NSView) -> Bool { !view.isHiddenOrHasHiddenAncestor }

    static let processor = "Intel(R) Core(TM) i9-13900K CPU @ 3.00GHz · 完整处理器名称以及较长的系统报告内容"
    static let coreInfo = CPUCoreInfo.resolve(processor: processor, vendor: "GenuineIntel",
                                              isAppleSilicon: false, isTranslated: false,
                                              currentPhysicalCores: 24, maximumPhysicalCores: 24,
                                              currentLogicalThreads: 32, maximumLogicalThreads: 32)
    static let device = DeviceSnapshot(model: "MacPro7,1", processor: processor,
                                       system: "macOS 26.1.0 (25B5023a)", physicalCores: 24,
                                       logicalThreads: 32, baseMHz: 3000, ceilingMHz: 5800,
                                       isAppleSilicon: false, isTranslated: false, coreInfo: coreInfo)

    static func phase(_ index: Int, frequencies: [Double], temperature: Double = 58) -> PhaseResult {
        var value = PhaseResult()
        value.key = ["light", "single", "allcore"][index]
        value.label = ["轻载探测", "单线程计算", "多线程计算"][index]
        value.coreProbe = true
        value.source = "内建探针估算（测试固定数据）"
        value.uncertainty = "界面回归固定数据，不执行检测。"
        value.seconds = 8
        let samples = frequencies.map { frequency -> Sample in
            var sample = Sample()
            sample.freq = frequency
            sample.util = 42
            sample.temp = temperature
            return sample
        }
        Engine.fillStats(&value, samples: samples, ceilingMhz: 0)
        return value
    }

    static func report(_ frequencies: [[Double]], temperature: Double = 58) -> DetectionReport {
        let phases = frequencies.enumerated().map { phase($0.offset, frequencies: $0.element, temperature: temperature) }
        return DetectionReport(run: Engine.RunResult(phases: phases,
                                                     freqsPerPhase: phases.map { $0.validSamples.map(\.freq) },
                                                     sampler: .builtin, cancelled: false,
                                                     startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                     finishedAt: Date(timeIntervalSince1970: 1_700_000_030)),
                               device: device)
    }

    static func resultControlsHidden(_ view: DashboardView, context: String) {
        for (name, control) in [("navigation", view.navigation as NSView),
                                ("copy", view.copyButton), ("export", view.exportButton),
                                ("headline", view.headline), ("date", view.dateLabel),
                                ("histogram", view.histogram), ("status", view.status),
                                ("peak", view.peakTile), ("temperature", view.temperatureTile),
                                ("samples", view.samplesTile), ("phase table", view.phaseTable),
                                ("tier table", view.tierTable)] {
            expect(!visible(control), "\(context): \(name) must stay hidden")
        }
        for (index, card) in view.phaseCards.enumerated() {
            expect(!visible(card), "\(context): phase card \(index) must stay hidden")
        }
    }

    static func deviceFields(_ view: DashboardView) {
        let labels = descendants(view).compactMap { $0 as? NSTextField }
        let expected = ["机型标识符", "处理器", "系统版本与构建号", "核心 / 线程", "标称基频", "XCPM 上限",
                        device.model, processor, device.system, "标称 8 大核 + 16 小核\n24 核 / 32 线程", "3.00 GHz", "5.80 GHz"]
        for text in expected {
            expect(labels.contains { visible($0) && $0.stringValue == text }, "visible complete hardware field: \(text)")
        }
        if let cpu = labels.first(where: { $0.stringValue == processor }) {
            expect(cpu.lineBreakMode == .byWordWrapping, "long processor name wraps rather than truncates")
            expect(cpu.maximumNumberOfLines == 0, "long processor name permits all lines")
            expect(cpu.isSelectable, "processor name can be copied in full")
        }
        if let topology = labels.first(where: { $0.stringValue == device.coreInfo?.display }) {
            expect(topology.isSelectable, "full two-line Intel topology remains selectable")
            expect(topology.lineBreakMode == .byWordWrapping && topology.maximumNumberOfLines == 0,
                   "two-line topology does not truncate on the narrow layout")
            expect(topology.toolTip?.contains("型号规格") == true && topology.toolTip?.contains("intel.com") == true,
                   "the visible specification shows its source and enabled-core caveat on hover")
        } else {
            expect(false, "full Intel core topology remains visible")
        }
    }

    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let view = DashboardView(device: device, sources: [.builtin])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 960),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        runChecks(view)
        window.contentView = nil
        window.close()
        if failures.isEmpty {
            print("PASS: \(checks) dashboard visibility/hardware field checks; no CPU probes were executed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("\(failures.count) failure(s) across \(checks) dashboard checks\n", stderr)
            exit(1)
        }
    }

    static func runChecks(_ view: DashboardView) {
        let complete = report([[1800, 2200, 2800], [4400, 4500, 4600], [3900, 4000, 4100]])
        let progress = descendants(view).compactMap { $0 as? NSProgressIndicator }.first!

        view.render(nil)
        resultControlsHidden(view, context: "initial")
        expect(!visible(progress), "initial progress must stay hidden")
        expect(visible(view.runButton) && view.runButton.title == "开始检测", "initial start button")
        deviceFields(view)
        view.selectPage(1)
        resultControlsHidden(view, context: "empty detail selection")

        view.beginRun(hasHistory: false)
        view.showProgress(Engine.Progress(phaseIndex: 1, phaseLabel: "单线程计算", completedFraction: 0.4,
                                         elapsed: 2, duration: 8, warmup: false, message: ""), hasHistory: false)
        resultControlsHidden(view, context: "first running")
        expect(visible(progress), "running progress is visible")
        expect(visible(view.runButton) && view.runButton.title == "停止检测", "running stop button")
        view.selectPage(1)
        resultControlsHidden(view, context: "running detail selection")
        deviceFields(view)

        view.render(complete)
        view.selectPage(0)
        expect(visible(view.navigation), "completed navigation restored")
        expect(visible(view.copyButton) && view.copyButton.isEnabled, "completed copy restored")
        expect(visible(view.exportButton) && view.exportButton.isEnabled, "completed export restored")
        expect(visible(view.histogram) && !view.histogram.freqs.isEmpty, "completed histogram restored")
        expect(visible(view.peakTile) && visible(view.samplesTile), "completed metrics restored")
        expect(view.phaseCards.allSatisfy(visible), "completed phase cards restored")
        expect(!visible(progress), "completed progress hidden")
        view.selectPage(1)
        expect(visible(view.phaseTable) && visible(view.tierTable), "completed details may be opened")

        view.beginRun(hasHistory: true)
        resultControlsHidden(view, context: "retest with old report")
        expect(visible(progress), "retest progress visible")
        view.selectPage(1)
        resultControlsHidden(view, context: "retest detail selection")
        view.render(complete, stopped: true)
        view.selectPage(0)
        expect(visible(view.histogram), "cancelled retest restores old complete report")
        expect(visible(view.history) && view.history.stringValue.contains("上次完整结果"), "cancelled retest marks old report")
        expect(visible(view.copyButton) && visible(view.exportButton), "cancelled retest restores report operations")

        let partial = report([[1800, 2200], [], [3900, 4100]])
        view.stagePicker.selectedSegment = 1
        view.render(partial)
        view.selectPage(0)
        expect(visible(view.phaseCards[0]) && visible(view.phaseCards[2]), "valid partial stages appear")
        expect(!visible(view.phaseCards[1]), "failed partial stage does not appear as a waiting card")
        expect(!view.stagePicker.isEnabled(forSegment: 1), "failed stage chart choice disabled")
        expect(view.stagePicker.selectedSegment == 0, "chart selects first stage with data")
        expect(visible(view.histogram) && !view.histogram.freqs.isEmpty, "partial report chart contains valid data")

        view.render(report([[], [], []], temperature: 0))
        view.selectPage(0)
        expect(view.phaseCards.allSatisfy { !visible($0) }, "all failed report hides stage cards")
        expect(!visible(view.histogram), "all failed report hides empty histogram")
        expect(!visible(view.peakTile) && !visible(view.samplesTile) && !visible(view.temperatureTile), "all failed report hides empty KPIs")
        expect(!view.navigation.isEnabled(forSegment: 1), "all failed report disables details")
        view.selectPage(1)
        expect(!visible(view.phaseTable) && !visible(view.tierTable), "all failed report cannot expose empty details")

        view.render(complete)
        view.selectPage(0)
        expect(view.phaseCards.allSatisfy(visible) && visible(view.histogram), "completed report restores data after all failed")
        expect(visible(view.temperatureTile), "available temperature restores its metric")
        view.render(report([[1900], [4500], [4000]], temperature: 0))
        expect(!visible(view.temperatureTile), "missing optional temperature has no empty metric")

        view.beginRun(hasHistory: false)
        view.showStopping()
        expect(!view.runButton.isEnabled, "stopping cannot trigger another run")
        view.render(nil, stopped: true)
        resultControlsHidden(view, context: "cancelled first run")
        expect(!visible(progress), "cancelled first run has no running progress bar")
        expect(visible(view.runButton) && view.runButton.isEnabled && view.runButton.title == "开始检测", "cancelled first run restores start")
        expect(view.histogram.freqs.isEmpty, "cancelled first run clears stale chart data")
        view.selectPage(1)
        resultControlsHidden(view, context: "cancelled first run detail selection")
        deviceFields(view)
    }
}
