import AppKit

/// Keep native progress semantics and accessibility, with the original pink accent used by the controls.
final class MutedProgressIndicator: NSProgressIndicator {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override var doubleValue: Double {
        get { super.doubleValue }
        set { super.doubleValue = newValue; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        DashboardColors.track(effectiveAppearance).setFill()
        track.fill()
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        guard fraction.isFinite, fraction > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        DashboardColors.accent.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Vertically center status text inside a fixed-height badge, preserving native text accessibility.
final class CenteredStatusCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let naturalHeight = cellSize(forBounds: rect).height
        if naturalHeight > 0, naturalHeight < result.height {
            result.origin.y += (result.height - naturalHeight) / 2
            result.size.height = naturalHeight
        }
        return result
    }
}
