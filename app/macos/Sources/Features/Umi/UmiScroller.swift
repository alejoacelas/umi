import AppKit

/// Warp's scrollbar for terminals (Warp parity): a thumb 8 points wide with fully round ends and
/// no track, in the text color at 40%, or 90% while the pointer is on it or it is dragged. It
/// shows and hides as macOS overlay scrollbars do.
final class UmiScroller: NSScroller {
    /// The text color: white on dark backgrounds, black on light ones.
    var ink: NSColor = .white { didSet { needsDisplay = true } }

    /// True while the pointer is on the scrollbar or the thumb is dragged.
    private(set) var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    static let thumbWidth: CGFloat = 8
    static let idleAlpha: CGFloat = 0.4
    static let activeAlpha: CGFloat = 0.9

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// The thumb's color now.
    var thumbColor: NSColor { ink.withAlphaComponent(active ? Self.activeAlpha : Self.idleAlpha) }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width = min(Self.thumbWidth, bounds.width)
        let thumb = NSRect(x: bounds.maxX - width, y: knob.minY, width: width, height: knob.height)
        thumbColor.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        active = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        active = false
    }

    override func mouseDown(with event: NSEvent) {
        active = true
        // AppKit tracks the drag inside this call.
        super.mouseDown(with: event)
        let inside = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        active = inside
    }
}

extension UmiScroller {
    /// The terminal's look in a pane beyond what the renderer reports (`debug.terminal`): its
    /// scrollbar and the bell's effects.
    @MainActor
    static func debugInfo(_ pane: Ghostty.SurfaceView) -> [String: Any] {
        var info: [String: Any] = [:]
        if let scroller = pane.enclosingScrollView?.verticalScroller {
            var entry: [String: Any] = ["class": String(describing: type(of: scroller))]
            if let umi = scroller as? UmiScroller {
                let ink = umi.ink.usingColorSpace(.sRGB) ?? umi.ink
                entry["ink"] = [ink.redComponent, ink.greenComponent, ink.blueComponent]
                entry["idle_alpha"] = UmiScroller.idleAlpha
                entry["active_alpha"] = UmiScroller.activeAlpha
                entry["thumb_width"] = UmiScroller.thumbWidth
                entry["track"] = false
            }
            info["scroller"] = entry
        }
        if let config = UmiLayout.ghostty?.config {
            let bell = config.bellFeatures
            info["bell"] = ["system": bell.contains(.system), "audio": bell.contains(.audio),
                            "attention": bell.contains(.attention), "title": bell.contains(.title),
                            "border": bell.contains(.border)]
        }
        return info
    }
}
