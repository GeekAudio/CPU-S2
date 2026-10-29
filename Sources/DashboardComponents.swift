import AppKit

/// Opaque neutral surfaces and full-width outlines, independent of system separator alpha.
enum DashboardColors {
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    // Original v2.3 surfaces and accents, with softer neutral text hierarchy.
    static let accent = color(0xEE5C9C)
    static let primaryText = color(0x53535F)
    static let bodyText = color(0x62626D)
    static let secondaryText = color(0x74747F)
    static let secondary = color(0xE7E7EB)
    static let orange = color(0xE08A4A)
    static func page(_ appearance: NSAppearance) -> NSColor { color(0xF4F4F6) }
    static func surface(_ appearance: NSAppearance) -> NSColor { .white }
    static func outline(_ appearance: NSAppearance) -> NSColor { color(0xEAEAEE) }
    static func chart(_ appearance: NSAppearance) -> NSColor { color(0x4C9FE0) }
    static func chartHover(_ appearance: NSAppearance) -> NSColor { color(0x2E6FA6) }
    static func grid(_ appearance: NSAppearance) -> NSColor { color(0xE4E4E8) }
    static func track(_ appearance: NSAppearance) -> NSColor { color(0xE9E9ED) }
}

/// Rasterize one continuous inset border; fractional CALayer hairlines can disappear at 1x.
class DashboardSurface: NSView {
    let surfaceRadius: CGFloat
    var emphasized = false { didSet { needsDisplay = true } }
    init(cornerRadius: CGFloat) {
        surfaceRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.needsDisplayOnBoundsChange = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        // Align the stroke's outside edges before moving its center in by half a point.
        let aligned = backingAlignedRect(bounds.insetBy(dx: 1, dy: 1), options: .alignAllEdgesInward)
        let rect = aligned.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: surfaceRadius, yRadius: surfaceRadius)
        DashboardColors.surface(effectiveAppearance).setFill()
        path.fill()
        (emphasized ? DashboardColors.accent : DashboardColors.outline(effectiveAppearance)).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func layout() { super.layout(); needsDisplay = true }
}

/// Shared native surface for dashboard sections. Its width is supplied by its parent.
class DashboardCard: DashboardSurface {
    let contentStack = NSStackView()
    var titleLabel: NSTextField?

    init(content: [NSView] = [], title: String? = nil) {
        super.init(cornerRadius: 12)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        if let title = title {
            let label = dashboardLabel(title, size: 14, weight: .medium, color: DashboardColors.primaryText)
            titleLabel = label
            addContent(label)
            setAccessibilityLabel(title)
        }
        content.forEach(addContent)
        setAccessibilityRole(.group)
        refreshSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addContent(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    func refreshSurface() { needsDisplay = true }
}

/// A single headline number with a stable label and optional explanatory detail.
final class MetricTile: NSView {
    let titleLabel: NSTextField
    let valueLabel = dashboardLabel("—", size: 31, weight: .medium, color: DashboardColors.primaryText)
    let unitLabel: NSTextField
    let detailLabel = dashboardLabel("", size: 12, color: DashboardColors.secondaryText, wrapping: true)

    init(title: String, unit: String) {
        titleLabel = dashboardLabel(title, size: 12, color: DashboardColors.secondaryText)
        unitLabel = dashboardLabel(unit, size: 12, color: DashboardColors.secondaryText)
        super.init(frame: .zero)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 31, weight: .medium)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.lineBreakMode = .byTruncatingTail
        unitLabel.setContentHuggingPriority(.required, for: .horizontal)
        let reading = NSStackView(views: [valueLabel, unitLabel])
        reading.orientation = .horizontal
        reading.alignment = .firstBaseline
        reading.spacing = 5
        let content = NSStackView(views: [titleLabel, reading, detailLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            reading.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        titleLabel.setAccessibilityLabel(title)
        valueLabel.setAccessibilityLabel(title)
    }

    convenience init(label: String, value: String = "—", unit: String = "") {
        self.init(title: label, unit: unit)
        set(value: value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(value: String, detail: String = "") {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
        valueLabel.setAccessibilityValue([value, unitLabel.stringValue].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// One stage of the same local test. Place three cards in a .fillEqually horizontal stack.
final class PhaseCardView: DashboardSurface {
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField
    let stateLabel = dashboardLabel("待检测", size: 11, weight: .medium, color: DashboardColors.secondaryText)
    let sourceLabel = dashboardLabel("探针估算", size: 11, color: DashboardColors.secondaryText)
    let valueLabel = dashboardLabel("—", size: 28, weight: .medium, color: DashboardColors.primaryText)
    let peakLabel = dashboardLabel("—", size: 12)
    let utilizationLabel = dashboardLabel("—", size: 12)
    let temperatureLabel = dashboardLabel("—", size: 12)
    let sampleCountLabel = dashboardLabel("—", size: 12)
    private let droppedCountLabel = dashboardLabel("", size: 11, color: DashboardColors.secondaryText)
    private var active = false

    init(title: String, subtitle: String) {
        titleLabel = dashboardLabel(title, size: 14, weight: .medium, color: DashboardColors.primaryText)
        subtitleLabel = dashboardLabel(subtitle, size: 12, color: DashboardColors.secondaryText, wrapping: true)
        super.init(cornerRadius: 10)
        // A 20pt badge is taller than NSTextField's natural line box.
        // Center the cell's drawing rect instead of moving the whole badge.
        let centeredCell = CenteredStatusCell(textCell: stateLabel.stringValue)
        centeredCell.isEditable = false
        centeredCell.isBordered = false
        centeredCell.isBezeled = false
        centeredCell.drawsBackground = false
        stateLabel.cell = centeredCell
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = DashboardColors.secondaryText
        stateLabel.alignment = .center
        stateLabel.wantsLayer = true
        stateLabel.layer?.cornerRadius = 5
        stateLabel.layer?.masksToBounds = true
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        stateLabel.heightAnchor.constraint(equalToConstant: 20).isActive = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [titleLabel, spacer, stateLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        let unit = dashboardLabel("GHz", size: 12, color: DashboardColors.secondaryText)
        let reading = NSStackView(views: [valueLabel, unit])
        reading.orientation = .horizontal
        reading.alignment = .firstBaseline
        reading.spacing = 4
        let readingTitle = dashboardLabel("中位频率", size: 11, color: DashboardColors.secondaryText)
        let sourceSpacer = NSView()
        sourceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let readingContext = NSStackView(views: [readingTitle, sourceSpacer, sourceLabel])
        readingContext.orientation = .horizontal
        readingContext.alignment = .firstBaseline
        readingContext.spacing = 4
        let readingGroup = NSStackView(views: [readingContext, reading])
        readingGroup.orientation = .vertical
        readingGroup.alignment = .leading
        readingGroup.spacing = 3
        readingContext.widthAnchor.constraint(equalTo: readingGroup.widthAnchor).isActive = true
        reading.widthAnchor.constraint(lessThanOrEqualTo: readingGroup.widthAnchor).isActive = true
        let loadTitle = dashboardLabel("利用率", size: 11, color: DashboardColors.secondaryText)
        loadTitle.toolTip = "采样期间的系统平均 CPU 利用率"
        let tempTitle = dashboardLabel("最高温", size: 11, color: DashboardColors.secondaryText)
        let detailSpacer = NSView()
        detailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let loadAndTemperature = NSStackView(views: [loadTitle, utilizationLabel, detailSpacer, tempTitle, temperatureLabel])
        loadAndTemperature.orientation = .horizontal
        loadAndTemperature.alignment = .firstBaseline
        loadAndTemperature.spacing = 4
        let sampleTitle = dashboardLabel("有效样本", size: 11, color: DashboardColors.secondaryText)
        let sampleSpacer = NSView()
        sampleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sampleRow = NSStackView(views: [sampleTitle, sampleCountLabel, sampleSpacer, droppedCountLabel])
        sampleRow.orientation = .horizontal
        sampleRow.alignment = .firstBaseline
        sampleRow.spacing = 4
        let stack = NSStackView(views: [heading, subtitleLabel, readingGroup,
                                      detailRow("峰值", value: peakLabel), loadAndTemperature, sampleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(10, after: subtitleLabel)
        stack.setCustomSpacing(10, after: readingGroup)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        valueLabel.setAccessibilityLabel("\(title)中位频率，GHz")
        peakLabel.setAccessibilityLabel("\(title)峰值频率，GHz")
        utilizationLabel.setAccessibilityLabel("\(title)系统利用率")
        temperatureLabel.setAccessibilityLabel("\(title)最高温度，摄氏度")
        sampleCountLabel.setAccessibilityLabel("\(title)有效样本数")
        refreshSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(result: PhaseResult?) {
        guard let result = result else {
            valueLabel.stringValue = "—"
            peakLabel.stringValue = "—"
            utilizationLabel.stringValue = "—"
            temperatureLabel.stringValue = "—"
            sampleCountLabel.stringValue = "—"
            droppedCountLabel.stringValue = ""
            sourceLabel.stringValue = "探针估算"
            toolTip = nil
            sourceLabel.toolTip = nil
            setState(message: "待检测", active: false)
            return
        }
        let valid = result.samples > 0 && !result.failed && result.median.isFinite && result.median > 0
        valueLabel.stringValue = Self.frequency(result.median)
        peakLabel.stringValue = result.maxF.isFinite && result.maxF > 0 ? "\(Self.frequency(result.maxF)) GHz" : "—"
        utilizationLabel.stringValue = result.utilAvg.isFinite && result.utilAvg >= 0 && result.samples > 0
            ? String(format: "%.0f%%", result.utilAvg) : "—"
        temperatureLabel.stringValue = result.tempMax.isFinite && result.tempMax > 0
            ? String(format: "%.0f °C", result.tempMax) : "—"
        sampleCountLabel.stringValue = String(max(0, result.samples))
        droppedCountLabel.stringValue = "剔除 \(max(0, result.droppedSamples))"
        sampleCountLabel.toolTip = result.droppedSamples > 0 ? "已剔除 \(result.droppedSamples) 个无效样本" : nil
        sourceLabel.stringValue = result.source.localizedCaseInsensitiveContains("PowerLog") ? "PowerLog" : "探针估算"
        sourceLabel.toolTip = [result.source, result.uncertainty].filter { !$0.isEmpty }.joined(separator: "\n")
        toolTip = result.warning.isEmpty ? result.uncertainty : [result.warning, result.uncertainty].filter { !$0.isEmpty }.joined(separator: "\n")
        setState(message: valid ? "已完成" : "数据不足", active: false)
    }

    func setState(message: String, active: Bool) {
        self.active = active
        stateLabel.stringValue = message
        stateLabel.textColor = active ? DashboardColors.accent : DashboardColors.secondaryText
        refreshSurface()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    private func refreshSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            emphasized = active
            needsDisplay = true
            stateLabel.layer?.backgroundColor = active
                ? DashboardColors.accent.withAlphaComponent(0.12).cgColor
                : DashboardColors.track(effectiveAppearance).cgColor
        }
    }

    private func detailRow(_ title: String, value: NSTextField) -> NSStackView {
        let label = dashboardLabel(title, size: 12, color: DashboardColors.secondaryText)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        let row = NSStackView(views: [label, spacer, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 4
        return row
    }

    private static func frequency(_ value: Double) -> String {
        value.isFinite && value > 0 ? String(format: "%.2f", value / 1000) : "—"
    }
}

private func dashboardLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                            color: NSColor = DashboardColors.bodyText, wrapping: Bool = false) -> NSTextField {
    let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.isSelectable = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}
