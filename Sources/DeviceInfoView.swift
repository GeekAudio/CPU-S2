import AppKit

/// Hardware context is available before a detection run and remains separate from its results.
final class DeviceInfoView: DashboardCard {
    private let modelValue = DeviceInfoView.valueLabel()
    private let processorValue = DeviceInfoView.valueLabel()
    private let systemValue = DeviceInfoView.valueLabel()
    private let coresValue = DeviceInfoView.valueLabel()
    private let baseValue = DeviceInfoView.valueLabel()
    private let ceilingValue = DeviceInfoView.valueLabel()
    private let processorTitle = DeviceInfoView.fieldLabel("处理器")

    init(device: DeviceSnapshot) {
        super.init(title: "机型信息")
        contentStack.spacing = 12
        let rows = [
            [field("机型标识符", value: modelValue),
             field(title: processorTitle, value: processorValue),
             field("系统版本与构建号", value: systemValue)],
            [field("核心 / 线程", value: coresValue),
             field("标称基频", value: baseValue),
             field("XCPM 上限", value: ceilingValue)]
        ]
        for fields in rows {
            let row = NSStackView(views: fields)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 18
            addContent(row)
        }
        update(device: device)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(device: DeviceSnapshot) {
        modelValue.stringValue = available(device.model)
        processorTitle.stringValue = device.isTranslated ? "处理器 · Rosetta 2" : "处理器"
        processorValue.stringValue = available(device.processor)
        systemValue.stringValue = available(device.system)
        coresValue.stringValue = device.coreInfo?.display ?? device.coreSummary
        coresValue.toolTip = device.coreInfo?.detail
        coresValue.setAccessibilityValue(coresValue.stringValue)
        baseValue.stringValue = frequencyText(device.baseMHz)
        ceilingValue.stringValue = frequencyText(Double(device.ceilingMHz))
        baseValue.toolTip = "系统报告的标称基频，与本轮检测读数分别展示。"
        ceilingValue.toolTip = "系统报告的 XCPM 频率上限；系统未提供时显示不可用。"
    }

    private func available(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "不可用" : value
    }

    private func field(_ title: String, value: NSTextField) -> NSView {
        field(title: Self.fieldLabel(title), value: value)
    }

    private func field(title: NSTextField, value: NSTextField) -> NSView {
        let stack = NSStackView(views: [title, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel(title.stringValue)
        value.setAccessibilityLabel(title.stringValue)
        return stack
    }

    private static func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = DashboardColors.secondaryText
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = DashboardColors.bodyText
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}
