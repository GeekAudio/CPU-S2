import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Histogram centers are rounded to 100 MHz. Axis edges are center ±50 MHz.
/// Counts are phase-specific; exact values are also exposed in the native table.
final class HistogramView: NSView {
    var freqs: [Int] = [] { didSet { hovered = nil; needsDisplay = true } }
    var base: Double = 0 { didSet { needsDisplay = true } }
    var ceiling: Double = 0 { didSet { needsDisplay = true } }
    var firstIndexFreq: Double = 0 { didSet { needsDisplay = true } }
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    private var plot: NSRect { NSRect(x: 42, y: 30, width: max(0, bounds.width - 68), height: max(0, bounds.height - 62)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = tracking { removeTrackingArea(old) }
        let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if plot.contains(point), !freqs.isEmpty, plot.width > 0 {
            let index = min(freqs.count - 1, max(0, Int((point.x - plot.minX) / plot.width * CGFloat(freqs.count))))
            hovered = index
            toolTip = "\(Int(firstIndexFreq) + index * 100) MHz 分箱 · \(freqs[index]) 个有效样本"
        } else { hovered = nil; toolTip = nil }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; toolTip = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: DashboardColors.secondaryText]
        guard !freqs.isEmpty, plot.width > 10, plot.height > 10 else {
            ("本阶段没有有效频率样本" as NSString).draw(at: NSPoint(x: 20, y: 45), withAttributes: attrs)
            return
        }
        let low = firstIndexFreq - 50
        let high = low + Double(freqs.count) * 100
        let maxCount = max(1, freqs.max() ?? 1)
        let tickStep = max(1, Int(ceil(Double(maxCount) / 3)))
        let axisMaximum = Int(ceil(Double(maxCount) / Double(tickStep))) * tickStep
        let slot = plot.width / CGFloat(freqs.count)
        for count in stride(from: 0, through: axisMaximum, by: tickStep) {
            let fraction = Double(count) / Double(axisMaximum)
            let y = plot.maxY - plot.height * CGFloat(fraction)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            DashboardColors.grid(effectiveAppearance).setStroke()
            line.lineWidth = 0.5
            line.stroke()
            let text = String(count) as NSString
            text.draw(at: NSPoint(x: 0, y: y - 7), withAttributes: attrs)
        }
        for (index, count) in freqs.enumerated() where count > 0 {
            let height = plot.height * CGFloat(Double(count) / Double(axisMaximum))
            let x = plot.minX + slot * (CGFloat(index) + 0.5)
            (hovered == index ? DashboardColors.chartHover(effectiveAppearance) : DashboardColors.chart(effectiveAppearance)).setFill()
            let width = max(1, min(slot - 0.3, slot * 0.68))
            NSBezierPath(roundedRect: NSRect(x: x - width / 2, y: plot.maxY - height, width: width, height: height), xRadius: 2, yRadius: 2).fill()
        }
        if base.isFinite, base > low, base < high {
            let x = plot.minX + plot.width * CGFloat((base - low) / (high - low))
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plot.minY))
            line.line(to: NSPoint(x: x, y: plot.maxY))
            line.setLineDash([3, 3], count: 2, phase: 0)
            DashboardColors.secondaryText.setStroke()
            line.stroke()
            ("标称基频" as NSString).draw(at: NSPoint(x: min(plot.maxX - 50, max(plot.minX, x - 25)), y: 6), withAttributes: attrs)
        }
        let step = max(1, Int(ceil(Double(freqs.count) / max(2, Double(plot.width / 85)))))
        for index in stride(from: 0, to: freqs.count, by: step) {
            let text = "\(Int(firstIndexFreq) + index * 100)" as NSString
            let x = plot.minX + slot * (CGFloat(index) + 0.5)
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: x - size.width / 2, y: plot.maxY + 8), withAttributes: attrs)
        }
        ("MHz" as NSString).draw(at: NSPoint(x: plot.maxX - 24, y: bounds.height - 14), withAttributes: attrs)
        if let index = hovered, index < freqs.count {
            let text = "\(Int(firstIndexFreq) + index * 100) MHz · \(freqs[index]) 次" as NSString
            let width = text.size(withAttributes: attrs).width
            text.draw(at: NSPoint(x: max(plot.minX, plot.maxX - width), y: 6), withAttributes: attrs)
        }
    }
}
