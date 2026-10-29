import AppKit

/// Compact, copyable settings panel used by the dashboard's transient popover.
/// The controller owns only presentation; update state and sampling stay in DashboardView.
final class SettingsViewController: NSViewController {
    static let panelWidth: CGFloat = 400

    let sourcePopup: NSPopUpButton?
    let automaticUpdateButton: NSButton
    let manualCheckButton: NSButton
    let contentStack = NSStackView()
    let localSummary: NSTextField
    private let onCheckUpdates: () -> Void
    private let onAutomaticUpdateChanged: (Bool) -> Void
    private let sourceCount: Int
    private var scrollView: NSScrollView!
    private var documentView: SettingsDocumentView!

    init(sourcePopup: NSPopUpButton?, deviceSummary: String,
         automaticUpdatesEnabled: Bool,
         onCheckUpdates: @escaping () -> Void,
         onAutomaticUpdateChanged: @escaping (Bool) -> Void) {
        self.sourcePopup = sourcePopup
        self.sourceCount = sourcePopup?.numberOfItems ?? 0
        self.onCheckUpdates = onCheckUpdates
        self.onAutomaticUpdateChanged = onAutomaticUpdateChanged
        automaticUpdateButton = NSButton(checkboxWithTitle: "自动下载更新并重启", target: nil, action: nil)
        manualCheckButton = NSButton(title: "检查更新…", target: nil, action: nil)
        localSummary = NSTextField(wrappingLabelWithString: deviceSummary)
        super.init(nibName: nil, bundle: nil)
        automaticUpdateButton.state = automaticUpdatesEnabled ? .on : .off
        automaticUpdateButton.target = self
        automaticUpdateButton.action = #selector(changeAutomaticUpdate(_:))
        manualCheckButton.target = self
        manualCheckButton.action = #selector(checkForUpdates)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 1))
        root.wantsLayer = true
        root.layer?.backgroundColor = DashboardColors.page(root.effectiveAppearance).cgColor

        scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        documentView = SettingsDocumentView(frame: .zero)
        scrollView.documentView = documentView
        root.addSubview(scrollView)
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -22),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 20),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20)
        ])
        view = root
    }

    /// Height before screen clamping. DashboardView clamps the viewport to the visible display.
    var naturalHeight: CGFloat {
        _ = view
        documentView.setFrameSize(NSSize(width: Self.panelWidth, height: 1))
        view.layoutSubtreeIfNeeded()
        contentStack.layoutSubtreeIfNeeded()
        let contentHeight = contentStack.fittingSize.height
        documentView.setFrameSize(NSSize(width: Self.panelWidth, height: contentHeight + 40))
        documentView.layoutSubtreeIfNeeded()
        return contentHeight + 40
    }

    func setViewportHeight(_ height: CGFloat) {
        _ = view
        view.setFrameSize(NSSize(width: Self.panelWidth, height: height))
        view.layoutSubtreeIfNeeded()
    }

    private func build() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let sourceHeading = heading("检测来源")
        contentStack.addArrangedSubview(sourceHeading)
        if let sourcePopup = sourcePopup, sourceCount > 0 {
            sourcePopup.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(sourcePopup)
            sourcePopup.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let measurementNote = label(
            "内建探针通过指令链估算频率。轻载会唤醒核心，不能证明真正空闲时的频率。",
            size: 12, color: DashboardColors.secondaryText)
        contentStack.addArrangedSubview(measurementNote)
        if sourceCount > 1 {
            contentStack.addArrangedSubview(label(
                "PowerLog 仅兼容本机已有安装，已停止维护；单线程读数仍使用探针。",
                size: 11, color: DashboardColors.secondaryText))
        }

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(heading("软件更新"))
        automaticUpdateButton.translatesAutoresizingMaskIntoConstraints = false
        automaticUpdateButton.font = .systemFont(ofSize: 12)
        automaticUpdateButton.attributedTitle = NSAttributedString(string: automaticUpdateButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText
        ])
        contentStack.addArrangedSubview(automaticUpdateButton)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fill
        actionRow.spacing = 8
        let actionNote = label("GitHub Release；检测时暂缓重启", size: 11, color: DashboardColors.secondaryText)
        actionNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        manualCheckButton.translatesAutoresizingMaskIntoConstraints = false
        manualCheckButton.bezelStyle = .rounded
        manualCheckButton.widthAnchor.constraint(equalToConstant: 132).isActive = true
        manualCheckButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        manualCheckButton.attributedTitle = NSAttributedString(string: manualCheckButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: DashboardColors.bodyText
        ])
        actionRow.addArrangedSubview(actionNote)
        actionRow.addArrangedSubview(spacer())
        actionRow.addArrangedSubview(manualCheckButton)
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(actionRow)
        actionRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        contentStack.addArrangedSubview(separator())
        contentStack.addArrangedSubview(heading("本机摘要"))
        localSummary.font = .systemFont(ofSize: 11)
        localSummary.textColor = DashboardColors.secondaryText
        localSummary.isSelectable = true
        localSummary.maximumNumberOfLines = 0
        localSummary.lineBreakMode = .byWordWrapping
        localSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        localSummary.setContentCompressionResistancePriority(.required, for: .vertical)
        contentStack.addArrangedSubview(localSummary)

        for item in contentStack.arrangedSubviews where item !== actionRow {
            item.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
    }

    private func heading(_ value: String) -> NSTextField {
        let field = label(value, size: 13, color: DashboardColors.primaryText)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.setAccessibilityLabel(value)
        return field
    }

    private func label(_ value: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = DashboardColors.outline(line.effectiveAppearance).cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func checkForUpdates() { onCheckUpdates() }

    @objc private func changeAutomaticUpdate(_ sender: NSButton) {
        onAutomaticUpdateChanged(sender.state == .on)
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
