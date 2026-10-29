import AppKit

/// Presentation only. Sampling sessions and exported reports belong to the controller.
final class DashboardView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onRun: (() -> Void)?
    var onCopy: (() -> Void)?
    var onExport: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onAutomaticUpdateChanged: ((Bool) -> Void)?
    var automaticUpdatesEnabled = true
    let runButton = NSButton(title: "开始检测", target: nil, action: nil)
    let navigation = NSSegmentedControl(labels: ["检测概览", "频率详情"], trackingMode: .selectOne, target: nil, action: nil)
    let stagePicker = NSSegmentedControl(labels: ["轻载", "单线程", "多线程"], trackingMode: .selectOne, target: nil, action: nil)
    let sourcePopup = NSPopUpButton()
    let copyButton = NSButton(title: "复制摘要", target: nil, action: nil)
    let exportButton = NSButton(title: "导出报告…", target: nil, action: nil)
    let settingsButton = NSButton(title: "设置", target: nil, action: nil)
    let headline = NSTextField(wrappingLabelWithString: "准备检测")
    let explanation = NSTextField(wrappingLabelWithString: "约 30 秒，依次观察轻载、单线程和多线程下的频率变化。")
    let history = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "尚未生成检测结果")
    let peakTile = MetricTile(title: "频率峰值", unit: "GHz")
    let temperatureTile = MetricTile(title: "最高已读温度", unit: "°C")
    let samplesTile = MetricTile(title: "有效样本", unit: "个")
    let phaseCards = [PhaseCardView(title: "轻载探测", subtitle: "短时唤醒核心"),
                      PhaseCardView(title: "单线程计算", subtitle: "探针自身连续运算"),
                      PhaseCardView(title: "多线程计算", subtitle: "多个后台计算任务")]
    let histogram = HistogramView()
    let chartNote = NSTextField(labelWithString: "检测后可查看各阶段的频率分布")
    let binsTitle = NSTextField(labelWithString: "频率分箱")
    let binsNote = NSTextField(wrappingLabelWithString: "")
    let allBins = NSButton(checkboxWithTitle: "显示未命中的分箱", target: nil, action: nil)
    let phaseTable = NSTableView()
    let tierTable = NSTableView()
    let status = NSTextField(labelWithString: "频率为估算读数，适合观察变化；不承诺绝对精度。")
    private let fixed = NSStackView()
    private let updateBox = NSStackView()
    private let updateLabel = NSTextField(labelWithString: "")
    private let updateProgress = MutedProgressIndicator()
    private var deviceInfo: DeviceInfoView!
    private var tools: NSStackView!
    private var metricsRow: NSStackView!
    private var phasesRow: NSStackView!
    private var graphCard: DashboardCard!
    private var resultsVisible = false
    private let progressBox = NSStackView()
    private let progressTitle = NSTextField(labelWithString: "")
    private let progress = MutedProgressIndicator()
    private let overview = NSStackView()
    private let details = NSStackView()
    private let body = NSStackView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var report: DetectionReport?
    private var device: DeviceSnapshot
    private var availableSources: [Engine.Sampler]
    private var tiers: [Engine.Tier] = []
    private var activePane = 0
    private var savedOffsets: [CGFloat] = [0, 0]
    private var settingsPopover: NSPopover?

    init(device: DeviceSnapshot, sources: [Engine.Sampler]) {
        self.device = device
        availableSources = sources
        super.init(frame: .zero)
        build()
        updateDevice(device)
        render(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedSampler: Engine.Sampler { availableSources[min(max(0, sourcePopup.indexOfSelectedItem), availableSources.count - 1)] }

    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        DashboardColors.page(effectiveAppearance).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scroll.backgroundColor = DashboardColors.page(effectiveAppearance)
        needsDisplay = true
    }

    var compactHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return max(230, fixed.fittingSize.height + 40)
    }
    var hasData: Bool { report?.validCount ?? 0 > 0 }
    var hasUpdateNotice: Bool { !updateBox.isHidden }

    private func build() {
        fixed.orientation = .vertical
        fixed.alignment = .leading
        fixed.spacing = 12
        fixed.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fixed)
        let title = text("CPU-S2", size: 23, weight: .semibold, color: DashboardColors.primaryText)
        let version = text("v\(kAppVersion)", size: 11, color: DashboardColors.secondaryText)
        let header = row([title, version, spacer(), settingsButton, runButton])
        runButton.target = self
        runButton.action = #selector(run)
        runButton.bezelStyle = .rounded
        runButton.bezelColor = DashboardColors.accent
        runButton.keyEquivalent = "\r"
        runButton.widthAnchor.constraint(equalToConstant: 106).isActive = true
        deviceInfo = DeviceInfoView(device: device)
        navigation.selectedSegmentBezelColor = DashboardColors.accent
        navigation.selectedSegment = 0
        navigation.target = self
        navigation.action = #selector(changePane)
        navigation.setAccessibilityLabel("检测页面")
        for (button, selector) in [(copyButton, #selector(copySummary)), (exportButton, #selector(export)), (settingsButton, #selector(settings))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12)
        }
        settingsButton.title = "设置"
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "检测设置与软件更新")
        settingsButton.imagePosition = .imageLeading
        settingsButton.imageHugsTitle = true
        settingsButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        settingsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.toolTip = "检测设置与软件更新"
        for button in [copyButton, exportButton, settingsButton] {
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText
            ])
        }
        tools = row([navigation, spacer(), copyButton, exportButton])
        updateBox.orientation = .horizontal
        updateBox.alignment = .centerY
        updateBox.spacing = 12
        updateLabel.font = .systemFont(ofSize: 12)
        updateLabel.textColor = DashboardColors.secondaryText
        updateLabel.lineBreakMode = .byTruncatingTail
        updateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateProgress.isIndeterminate = false
        updateProgress.minValue = 0; updateProgress.maxValue = 1
        updateProgress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        updateProgress.setAccessibilityLabel("更新下载进度")
        updateBox.addArrangedSubview(updateLabel)
        updateBox.addArrangedSubview(updateProgress)
        updateBox.isHidden = true
        [header, updateBox, deviceInfo!, tools!].forEach { fixed.addArrangedSubview($0); $0.widthAnchor.constraint(equalTo: fixed.widthAnchor).isActive = true }
        progressBox.orientation = .vertical
        progressBox.alignment = .leading
        progressBox.spacing = 6
        progressTitle.font = .systemFont(ofSize: 12)
        progressTitle.textColor = DashboardColors.bodyText
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar
        progress.setAccessibilityLabel("检测进度")
        for view in [progressTitle, progress] { progressBox.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: progressBox.widthAnchor).isActive = true }
        fixed.addArrangedSubview(progressBox)
        progressBox.widthAnchor.constraint(equalTo: fixed.widthAnchor).isActive = true
        progressBox.isHidden = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = DashboardColors.page(effectiveAppearance)
        addSubview(scroll)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            fixed.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            fixed.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            fixed.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: fixed.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor), body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24)
        ])
        for pane in [overview, details] {
            pane.orientation = .vertical; pane.alignment = .leading; pane.spacing = 12
            body.addArrangedSubview(pane)
            pane.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        buildOverview()
        buildDetails()
        status.font = .systemFont(ofSize: 11)
        status.textColor = DashboardColors.secondaryText
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        body.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        details.isHidden = true
        sourcePopup.addItem(withTitle: "内建探针估算")
        if availableSources.contains(.powerLog) { sourcePopup.addItem(withTitle: "已有 PowerLog（兼容模式）") }
    }

    private func buildOverview() {
        headline.font = .systemFont(ofSize: 18, weight: .medium)
        headline.textColor = DashboardColors.primaryText
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = DashboardColors.secondaryText
        history.font = .systemFont(ofSize: 12, weight: .medium)
        history.textColor = DashboardColors.orange
        history.isHidden = true
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = DashboardColors.secondaryText
        metricsRow = row([peakTile, temperatureTile, samplesTile])
        metricsRow.distribution = .fillEqually
        let summary = DashboardCard(content: [history, headline, explanation, metricsRow!, dateLabel])
        summary.contentStack.spacing = 8
        attach(summary, to: overview)
        phasesRow = row(phaseCards)
        phasesRow.alignment = .top
        phasesRow.distribution = .fillEqually
        phasesRow.spacing = 12
        attach(phasesRow, to: overview)
        let graphTitle = text("频率分布", size: 14, weight: .medium, color: DashboardColors.primaryText)
        stagePicker.selectedSegmentBezelColor = DashboardColors.accent
        stagePicker.selectedSegment = 1
        stagePicker.target = self
        stagePicker.action = #selector(changeStage)
        stagePicker.setAccessibilityLabel("频率分布的检测阶段")
        let heading = row([graphTitle, spacer(), stagePicker])
        histogram.heightAnchor.constraint(equalToConstant: 145).isActive = true
        histogram.setAccessibilityElement(true)
        histogram.setAccessibilityLabel("频率分布图")
        chartNote.font = .systemFont(ofSize: 11)
        chartNote.textColor = DashboardColors.secondaryText
        chartNote.lineBreakMode = .byTruncatingTail
        graphCard = DashboardCard(content: [heading, histogram, chartNote])
        graphCard.contentStack.spacing = 6
        attach(graphCard, to: overview)
    }

    private func buildDetails() {
        binsTitle.font = .systemFont(ofSize: 14, weight: .medium)
        binsTitle.textColor = DashboardColors.primaryText
        allBins.attributedTitle = NSAttributedString(string: allBins.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText
        ])
        allBins.target = self
        allBins.action = #selector(changeBins)
        let heading = row([binsTitle, spacer(), allBins])
        binsNote.font = .systemFont(ofSize: 12)
        binsNote.textColor = DashboardColors.secondaryText
        let bins = table(tierTable, columns: [("frequency", "频率", 120), ("light", "轻载", 110), ("single", "单线程", 110), ("multi", "多线程", 110), ("total", "合计", 100)], height: 260)
        attach(DashboardCard(content: [heading, binsNote, bins]), to: details)
        let statistics = table(phaseTable, columns: [("phase", "检测阶段", 110), ("source", "读数来源", 110), ("median", "中位", 85), ("p90", "P90", 85), ("peak", "峰值", 85), ("count", "有效 / 剔除", 100)], height: 122)
        let note = text("中位数：偶数取两项均值；P90：nearest-rank。分箱间隔为 100 MHz，不代表硬件频档。", size: 11, color: DashboardColors.secondaryText, wrapping: true)
        attach(DashboardCard(content: [statistics, note], title: "采样统计"), to: details)
    }

    func updateDevice(_ value: DeviceSnapshot) {
        device = value
        deviceInfo.update(device: value)
    }

    func showUpdate(message: String?, progress: Double?) {
        updateBox.isHidden = message == nil
        updateLabel.stringValue = message ?? ""
        updateLabel.toolTip = message
        updateProgress.isHidden = progress == nil
        updateProgress.doubleValue = progress ?? 0
    }

    private func showResults(_ visible: Bool) {
        resultsVisible = visible
        tools.isHidden = !visible
        overview.isHidden = !visible || activePane != 0
        details.isHidden = !visible || activePane == 0
        status.isHidden = !visible
    }

    func render(_ value: DetectionReport?, stopped: Bool = false) {
        report = value
        history.isHidden = true
        progressBox.isHidden = true
        runButton.isEnabled = true
        runButton.title = value == nil ? "开始检测" : "重新检测"
        settingsButton.isEnabled = true
        copyButton.isEnabled = value != nil
        exportButton.isEnabled = value != nil
        navigation.setEnabled((value?.validCount ?? 0) > 0, forSegment: 1)
        showResults(value != nil)
        if let value = value, stopped {
            history.isHidden = false
            history.stringValue = "上次完整结果 · \(dateText(value.run.finishedAt))"
        }
        guard let value = value else {
            showResults(false)
            progress.isHidden = true
            progressBox.isHidden = !stopped
            progressTitle.stringValue = stopped ? "检测已停止，本次未生成完整结果。" : ""
            headline.stringValue = stopped ? "检测已停止" : "准备检测"
            explanation.stringValue = stopped ? "本次未生成完整结果，点击“开始检测”可重新运行。" : "约 30 秒，依次观察轻载、单线程和多线程下的频率变化。"
            dateLabel.stringValue = "无需管理员权限 · 手动开始，可随时停止"
            for tile in [peakTile, temperatureTile, samplesTile] { tile.set(value: "—") }
            phaseCards.forEach { $0.update(result: nil) }
            histogram.freqs = []
            histogram.setAccessibilityValue(nil)
            tiers = []
            tierTable.reloadData()
            phaseTable.reloadData()
            return
        }
        updateDevice(value.device)
        metricsRow.isHidden = value.validCount == 0
        temperatureTile.isHidden = value.highestTemperature == nil
        phasesRow.isHidden = value.validCount == 0
        graphCard.isHidden = value.validCount == 0
        if value.validCount == 0 { activePane = 0; navigation.selectedSegment = 0; showResults(true) }
        switch value.verdict {
        case .observed:
            headline.stringValue = "观察到频率提升"
            explanation.stringValue = "多个样本高于标称基频 \(frequencyText(value.device.baseMHz))；本次包含探针估算读数。"
        case .notObserved:
            headline.stringValue = "本次未观察到频率提升"
            explanation.stringValue = "本次负载下未持续高于标称基频，不代表硬件不支持或已关闭睿频。"
        case .insufficient:
            headline.stringValue = "数据不足，暂无法判断"
            explanation.stringValue = "缺少标称基频或足够的有效样本，请查看各阶段结果。"
        case .notApplicable:
            headline.stringValue = "已完成频率检测"
            explanation.stringValue = "Apple Silicon 不适用 Intel 睿频判据；当前样本未区分 P/E 核。"
        }
        dateLabel.stringValue = "\(dateText(value.run.finishedAt)) · 用时 \(String(format: "%.1f", value.run.finishedAt.timeIntervalSince(value.run.startedAt))) 秒"
        peakTile.set(value: value.peak > 0 ? String(format: "%.2f", value.peak / 1000) : "—")
        temperatureTile.set(value: value.highestTemperature.map { String(format: "%.0f", $0) } ?? "—", detail: value.highestTemperature == nil ? "暂不可用" : "采样期间读取")
        samplesTile.set(value: "\(value.validCount)", detail: value.droppedCount > 0 ? "已剔除 \(value.droppedCount) 个" : "\(value.run.phases.count) 个检测阶段")
        for index in phaseCards.indices {
            let phase = index < value.run.phases.count ? value.run.phases[index] : nil
            let valid = phase.map { !$0.failed && $0.samples > 0 } ?? false
            phaseCards[index].isHidden = !valid
            stagePicker.setEnabled(valid, forSegment: index)
            if valid { phaseCards[index].update(result: phase) }
        }
        phaseTable.reloadData()
        changeBins()
        changeStage()
    }

    func beginRun(hasHistory: Bool) {
        showResults(false)
        runButton.title = "停止检测"
        settingsButton.isEnabled = false
        settingsPopover?.close()
        progressBox.isHidden = false
        progress.isHidden = false
        progress.doubleValue = 0
        progressTitle.stringValue = "正在准备检测…"
    }

    func showProgress(_ update: Engine.Progress, hasHistory: Bool) {
        progress.doubleValue = min(0.995, max(0, update.completedFraction))
        let remaining = max(0, Int(ceil(update.duration - update.elapsed)))
        progressTitle.stringValue = "\(update.phaseIndex + 1)/3  \(update.phaseLabel) · \(update.warmup ? "预热" : "采样") · 本阶段剩余约 \(remaining) 秒"
    }

    func showStopping() { runButton.isEnabled = false; runButton.title = "正在停止…"; progressTitle.stringValue = "正在停止并清理本次负载…" }

    @objc private func changePane() {
        guard resultsVisible, report != nil else { showResults(false); return }
        if !hasData { activePane = 0; navigation.selectedSegment = 0; showResults(true); return }
        savedOffsets[activePane] = scroll.contentView.bounds.origin.y
        activePane = max(0, navigation.selectedSegment)
        overview.isHidden = activePane != 0
        details.isHidden = activePane == 0
        layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.document.scroll(NSPoint(x: 0, y: self.savedOffsets[self.activePane]))
        }
    }

    func selectPage(_ index: Int) { navigation.selectedSegment = index; changePane() }

    @objc private func changeStage() {
        guard let report = report else { return }
        let valid = report.run.phases.indices.filter { report.run.phases[$0].samples > 0 && !report.run.phases[$0].failed }
        guard !valid.isEmpty else { graphCard.isHidden = true; return }
        if !valid.contains(stagePicker.selectedSegment) { stagePicker.selectedSegment = valid[0] }
        let index = stagePicker.selectedSegment
        guard index >= 0, index < report.run.freqsPerPhase.count else { return }
        let bins = Engine.buildTiers([report.run.freqsPerPhase[index]], floorMhz: 0, ceilingMhz: 0)
        histogram.freqs = bins.map { $0.total }
        histogram.firstIndexFreq = Double(bins.first?.freq ?? 0)
        histogram.base = report.device.baseMHz
        let phase = report.run.phases[index]
        chartNote.stringValue = phase.warning.isEmpty ? "\(phase.label) · \(phase.samples) 个有效样本 · 100 MHz 间隔" : "提示：\(phase.warning)"
        chartNote.toolTip = [phase.source, phase.uncertainty, phase.warning].filter { !$0.isEmpty }.joined(separator: "\n")
        histogram.setAccessibilityValue("\(phase.label)，中位 \(frequencyText(phase.median))，峰值 \(frequencyText(phase.maxF))，有效 \(phase.samples) 个；各频率计数可在频率详情读取。")
    }

    @objc private func changeBins() {
        tiers = report?.tiers.reversed().filter { allBins.state == .on || $0.total > 0 } ?? []
        let hits = report?.tiers.filter { $0.total > 0 }.count ?? 0
        binsTitle.stringValue = "频率分箱 · 命中 \(hits) 档"
        binsNote.stringValue = "分别统计各阶段的有效样本；阶段时长与采样节奏不同，不宜直接比较命中次数。"
        tierTable.reloadData()
    }

    @objc private func settings() {
        let content = NSStackView()
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.addArrangedSubview(text("检测设置", size: 15, weight: .medium, color: DashboardColors.primaryText))
        if availableSources.count > 1 { content.addArrangedSubview(sourcePopup) }
        content.addArrangedSubview(text("内建探针通过指令链计时估算频率。轻载也会唤醒核心，不能用来证明真正空闲时的频率。", size: 12, color: DashboardColors.secondaryText, wrapping: true))
        if availableSources.count > 1 { content.addArrangedSubview(text("PowerLog 仅兼容已有安装，已停止维护。单线程读数仍使用探针。", size: 12, color: DashboardColors.secondaryText, wrapping: true)) }
        content.addArrangedSubview(text("\(device.processor)\n\(device.model) · \(device.system)\n\(device.brief)", size: 11, color: DashboardColors.secondaryText, wrapping: true))
        content.addArrangedSubview(text("软件更新", size: 14, weight: .medium, color: DashboardColors.primaryText))
        let automatic = NSButton(checkboxWithTitle: "自动下载更新并重启", target: self, action: #selector(changeAutomaticUpdates(_:)))
        automatic.state = automaticUpdatesEnabled ? .on : .off
        automatic.attributedTitle = NSAttributedString(string: automatic.title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText])
        content.addArrangedSubview(automatic)
        let check = NSButton(title: "检查更新…", target: self, action: #selector(checkUpdates))
        check.bezelStyle = .rounded
        check.attributedTitle = NSAttributedString(string: check.title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText])
        content.addArrangedSubview(check)
        content.addArrangedSubview(text("从 GitHub Release 获取更新；检测运行期间会暂缓重启。", size: 11, color: DashboardColors.secondaryText, wrapping: true))
        for item in content.arrangedSubviews { item.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: content.fittingSize.height)
        settingsPopover = popover
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .minY)
    }

    @objc private func run() { onRun?() }
    @objc private func copySummary() { onCopy?() }
    @objc private func export() { onExport?() }
    @objc private func checkUpdates() { settingsPopover?.close(); onCheckUpdates?() }
    @objc private func changeAutomaticUpdates(_ sender: NSButton) {
        automaticUpdatesEnabled = sender.state == .on
        onAutomaticUpdateChanged?(automaticUpdatesEnabled)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === phaseTable ? report?.run.phases.count ?? 0 : tiers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let key = tableColumn?.identifier.rawValue else { return nil }
        var value = "—"
        if tableView === phaseTable, let phases = report?.run.phases, index < phases.count {
            let phase = phases[index]
            switch key {
            case "phase": value = phase.label
            case "source": value = phase.coreProbe ? "探针估算" : "PowerLog"
            case "median": value = phase.failed ? "数据不足" : frequencyText(phase.median)
            case "p90": value = frequencyText(phase.p90)
            case "peak": value = frequencyText(phase.maxF)
            case "count": value = "\(phase.samples) / \(phase.droppedSamples)"
            default: break
            }
        } else if index < tiers.count {
            let tier = tiers[index]
            switch key {
            case "frequency": value = "\(tier.freq) MHz"
            case "light": value = "\(tier.counts[0])"
            case "single": value = "\(tier.counts[1])"
            case "multi": value = "\(tier.counts[2])"
            case "total": value = "\(tier.total)"
            default: break
            }
        }
        let field = text(value, size: 12)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = value
        field.setAccessibilityLabel(tableColumn?.title)
        field.setAccessibilityValue(value)
        return field
    }

    private func table(_ table: NSTableView, columns: [(String, String, CGFloat)], height: CGFloat) -> NSScrollView {
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width; column.minWidth = 75
            column.headerCell.textColor = DashboardColors.bodyText
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self
        table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let container = NSScrollView()
        container.hasVerticalScroller = true; container.hasHorizontalScroller = true; container.autohidesScrollers = true
        container.documentView = table
        container.borderType = .bezelBorder
        container.heightAnchor.constraint(equalToConstant: height).isActive = true
        return container
    }

    func scrollToBottom() { document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height))) }
    func scrollToTop() { document.scroll(.zero) }

    private func attach(_ view: NSView, to parent: NSStackView) {
        parent.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = DashboardColors.bodyText, wrapping: Bool = false) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color; label.isSelectable = true
        return label
    }
}
