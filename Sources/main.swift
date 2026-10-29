import AppKit
import Foundation

/// Application lifecycle and detection sessions. Layout and report serialization are separate modules.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var dashboard: DashboardView!
    var session: Engine.Session?
    var lastReport: DetectionReport?
    var cancelling = false
    private var lastAnnouncedPhase = -1
    private var resultSize = NSSize(width: 800, height: 920)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        buildMenu()
        let device = DeviceSnapshot.read()
        let sources: [Engine.Sampler] = Engine.detectSampler() == .powerLog ? [.builtin, .powerLog] : [.builtin]
        dashboard = DashboardView(device: device, sources: sources)
        dashboard.onRun = { [weak self] in self?.toggleRun() }
        dashboard.onCopy = { [weak self] in self?.copyReport() }
        dashboard.onExport = { [weak self] in self?.exportReport() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 280),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CPU-S2"
        window.minSize = NSSize(width: 720, height: 200)
        window.isReleasedWhenClosed = false
        window.contentView = dashboard
        window.backgroundColor = DashboardColors.page(window.effectiveAppearance)
        window.center()
        if let screen = window.screen ?? NSScreen.main {
            var frame = window.frame
            frame.size.width = min(frame.width, screen.visibleFrame.width)
            frame.size.height = min(frame.height, screen.visibleFrame.height)
            frame.origin.x = min(max(frame.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.visibleFrame.minY), screen.visibleFrame.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        resizeWindow(forResults: false, animated: false)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--preview") { preview(); return }
        if CommandLine.arguments.contains("--selftest") {
            start()
            if let index = CommandLine.arguments.firstIndex(of: "--cancel-after"), index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]), seconds.isFinite, seconds > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + min(120, seconds)) { if self.session != nil { self.toggleRun() } }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { session?.cancel() }

    private func buildMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 CPU-S2", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 CPU-S2", action: #selector(quit), keyEquivalent: "q")
        application.submenu = appMenu
        main.addItem(application)
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "开始 / 停止检测", action: #selector(toggleRun), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "导出报告…", action: #selector(exportReport), keyEquivalent: "s")
        file.submenu = fileMenu
        main.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let copy = editMenu.addItem(withTitle: "复制检测摘要", action: #selector(copyReport), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyReport) || menuItem.action == #selector(exportReport) { return lastReport != nil }
        if menuItem.action == #selector(toggleRun) { return !cancelling }
        return true
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func about() {
        let alert = NSAlert()
        alert.messageText = "CPU-S2 v\(kAppVersion)"
        alert.informativeText = "本机 CPU 频率与负载检测。\n默认无需管理员权限，不修改 EFI 或系统文件。\n内建探针为未做绝对精度标定的估算。"
        alert.runModal()
    }

    @objc func toggleRun() {
        if let session = session {
            guard !cancelling else { return }
            cancelling = true
            dashboard.showStopping()
            session.cancel()
            announce("正在停止检测")
        } else { start() }
    }

    private func start() {
        guard session == nil else { return }
        let current = Engine.Session()
        let device = DeviceSnapshot.read()
        let source = dashboard.selectedSampler
        session = current
        cancelling = false
        lastAnnouncedPhase = -1
        if lastReport != nil, dashboard.hasData { resultSize = dashboard.bounds.size }
        dashboard.updateDevice(device)
        dashboard.beginRun(hasHistory: lastReport != nil)
        resizeWindow(forResults: false)
        announce("开始检测")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Engine.runDetailed(sampler: source, session: current) { update in
                DispatchQueue.main.async {
                    guard self.session === current, !self.cancelling else { return }
                    self.dashboard.showProgress(update, hasHistory: self.lastReport != nil)
                    if update.phaseIndex != self.lastAnnouncedPhase {
                        self.lastAnnouncedPhase = update.phaseIndex
                        self.announce(update.phaseLabel)
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.session === current else { return }
                self.session = nil
                self.cancelling = false
                if result.cancelled {
                    self.dashboard.render(self.lastReport, stopped: true)
                    self.dashboard.status.stringValue = self.lastReport == nil ? "已停止，本次未生成完整结果。" : "已停止，显示上次完整检测结果。"
                    self.announce("检测已停止")
                } else {
                    let report = DetectionReport(run: result, device: device)
                    self.lastReport = report
                    self.dashboard.render(report)
                    self.dashboard.status.stringValue = "频率为估算读数，适合观察变化；不承诺绝对精度。"
                    self.announce("检测完成")
                }
                self.resizeWindow(forResults: self.lastReport != nil)
                if CommandLine.arguments.contains("--selftest") { self.snapshots() }
            }
        }
    }

    private func resizeWindow(forResults: Bool, animated: Bool = true) {
        dashboard.layoutSubtreeIfNeeded()
        let full = forResults && dashboard.hasData
        let height = full ? resultSize.height : dashboard.compactHeight + (forResults ? 160 : 0)
        window.minSize = NSSize(width: 720, height: full ? 540 : 200)
        let previous = window.frame
        var next = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: dashboard.bounds.width, height: height))
        if let screen = window.screen ?? NSScreen.main {
            next.size.height = min(next.height, screen.visibleFrame.height)
            next.origin.x = min(max(previous.minX, screen.visibleFrame.minX), screen.visibleFrame.maxX - next.width)
            next.origin.y = min(max(previous.maxY - next.height, screen.visibleFrame.minY), screen.visibleFrame.maxY - next.height)
        } else { next.origin = NSPoint(x: previous.minX, y: previous.maxY - next.height) }
        window.setFrame(next, display: true, animate: animated)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: dashboard as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @objc func copyReport() {
        guard let report = lastReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportWriter.text(report), forType: .string)
        dashboard.status.stringValue = "已复制检测摘要。"
    }

    @objc func exportReport() {
        guard let report = lastReport else { return }
        let panel = NSSavePanel()
        panel.title = "导出检测报告"
        panel.nameFieldStringValue = "CPU-S2-\(dateText(report.run.finishedAt, compact: true)).txt"
        let format = NSPopUpButton()
        format.addItems(withTitles: ["文字摘要 (.txt)", "逐样本数据 (.csv)", "完整数据 (.json)"])
        panel.accessoryView = NSStackView(views: [NSTextField(labelWithString: "格式"), format])
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let selected = panel.url else { return }
            do {
                let ext = ["txt", "csv", "json"][format.indexOfSelectedItem]
                let url = selected.deletingPathExtension().appendingPathExtension(ext)
                if url != selected && FileManager.default.fileExists(atPath: url.path) {
                    throw NSError(domain: "CPU-S2", code: 1, userInfo: [NSLocalizedDescriptionKey: "同名文件已存在，请使用不同名称。"])
                }
                let data: Data
                switch format.indexOfSelectedItem {
                case 1: data = Data(ReportWriter.csv(report).utf8)
                case 2: data = try ReportWriter.json(report)
                default: data = Data(ReportWriter.text(report).utf8)
                }
                try data.write(to: url, options: .atomic)
                self.dashboard.status.stringValue = "已导出 \(url.lastPathComponent)"
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: self.window)
            }
        }
    }

    private func preview() {
        var frequencies: [[Double]] = [[1800, 2300, 3100, 4300], [4550, 4630, 4670, 4700, 4710], [4200, 4350, 4400, 4450, 4500]]
        if CommandLine.arguments.contains("--preview-invalid") { frequencies[0] += [.nan, .infinity, 100] }
        var phases: [PhaseResult] = []
        for (index, spec) in Engine.specs().enumerated() {
            var phase = PhaseResult()
            phase.key = spec.key; phase.label = spec.label; phase.coreProbe = true
            phase.source = "内建探针估算（示例）"; phase.uncertainty = "固定示例数据，不能用于判断本机频率。"
            phase.seconds = spec.seconds
            let rows = frequencies[index].map { Sample(freq: $0, util: index == 2 ? 92 : 8, temp: Double(42 + index * 15)) }
            Engine.fillStats(&phase, samples: rows, ceilingMhz: 0)
            phases.append(phase)
        }
        let run = Engine.RunResult(phases: phases, freqsPerPhase: phases.map { $0.validSamples.map { $0.freq } }, sampler: .builtin,
                                   cancelled: false, startedAt: Date().addingTimeInterval(-29), finishedAt: Date())
        lastReport = DetectionReport(run: run, device: DeviceSnapshot.read())
        dashboard.render(lastReport)
        resizeWindow(forResults: true, animated: false)
        dashboard.headline.stringValue = "界面预览 · 示例数据"
        dashboard.status.stringValue = "当前为固定示例，未执行检测。"
        if CommandLine.arguments.contains("--preview-small") { window.setContentSize(NSSize(width: 720, height: 640)) }
        if CommandLine.arguments.contains("--preview-empty") {
            lastReport = nil; dashboard.render(nil); resizeWindow(forResults: false, animated: false)
        }
        if CommandLine.arguments.contains("--preview-running") {
            lastReport = nil; dashboard.render(nil); dashboard.beginRun(hasHistory: false)
            dashboard.showProgress(Engine.Progress(phaseIndex: 1, phaseLabel: "单线程计算", completedFraction: 0.45,
                                                   elapsed: 2, duration: 6, warmup: false, message: "采样中"), hasHistory: false)
            resizeWindow(forResults: false, animated: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.snapshots() }
    }

    private func snapshots() {
        let folder = ProcessInfo.processInfo.environment["CPUS2_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        let base = URL(fileURLWithPath: folder)
        if let report = lastReport {
            do {
                try Data(ReportWriter.text(report).utf8).write(to: base.appendingPathComponent("cpus2-report.txt"))
                try Data(ReportWriter.csv(report).utf8).write(to: base.appendingPathComponent("cpus2-report.csv"))
                try ReportWriter.json(report).write(to: base.appendingPathComponent("cpus2-report.json"))
            } catch { fputs("PREVIEW EXPORT FAILED: \(error)\n", stderr); exit(1) }
        }
        for (name, page) in [("overview", 0), ("details", 1)] {
            dashboard.selectPage(page)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            dashboard.scrollToTop()
            snapshot(to: base.appendingPathComponent("cpus2-\(name).png"))
            dashboard.scrollToBottom()
            snapshot(to: base.appendingPathComponent("cpus2-\(name)-bottom.png"))
        }
        NSApp.terminate(nil)
    }
    private func snapshot(to url: URL) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        dashboard.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds) else { return }
        dashboard.cacheDisplay(in: dashboard.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url); print("SNAPSHOT \(url.path)") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
