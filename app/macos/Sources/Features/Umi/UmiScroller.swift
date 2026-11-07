import AppKit

/// Warp's scrollbar for terminals (Warp parity): a thumb 8 points wide with fully round ends and
/// no track, 2 points in from the pane's right edge, in the text color at 40%, or 90% while the
/// pointer is on it or it is dragged. It shows and hides as macOS overlay scrollbars do.
final class UmiScroller: NSScroller {
    /// The text color: white on dark backgrounds, black on light ones.
    var ink: NSColor = .white { didSet { updateThumbColor() } }

    /// True while the pointer is on the scrollbar or the thumb is dragged.
    private(set) var active = false { didSet { if active != oldValue { updateThumbColor() } } }
    private var trackingArea: NSTrackingArea?

    /// The thumb. AppKit draws an overlay scroller's knob into a layer of its own, 6 points wide,
    /// which it moves and fades; the thumb is a layer inside that one (sublayers aren't clipped),
    /// so it moves and fades with it at Warp's width.
    private let thumbLayer: CALayer = {
        let layer = CALayer()
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                         "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        return layer
    }()

    static let thumbWidth: CGFloat = 8
    /// The space between the thumb and the pane's right edge (Warp's padding after the track).
    static let edgeInset: CGFloat = 2
    static let idleAlpha: CGFloat = 0.4
    static let activeAlpha: CGFloat = 0.9

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// The thumb's color now.
    var thumbColor: NSColor { ink.withAlphaComponent(active ? Self.activeAlpha : Self.idleAlpha) }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// Where the thumb is, in the scroller's coordinates: 8 points wide, 2 points in from the right
    /// edge, as tall as AppKit's knob.
    var thumbRect: NSRect {
        let knob = rect(for: .knob)
        let inset = min(Self.edgeInset, max(0, bounds.width - Self.thumbWidth))
        let width = min(Self.thumbWidth, bounds.width)
        return NSRect(x: bounds.maxX - inset - width, y: knob.minY, width: width, height: knob.height)
    }

    /// True once the thumb sits in AppKit's knob layer.
    var thumbAttached: Bool { thumbLayer.superlayer != nil }

    /// AppKit calls this when its knob layer needs drawing (it was made, or changed size): the
    /// knob layer draws nothing itself; the thumb layer goes into it, placed for its new size.
    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0,
              let host = layer?.sublayers?.first(where: {
                  $0 !== thumbLayer && abs($0.frame.minX - knob.minX) < 0.5 && abs($0.frame.minY - knob.minY) < 0.5
                      && abs($0.frame.width - knob.width) < 0.5 && abs($0.frame.height - knob.height) < 0.5
              }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if thumbLayer.superlayer !== host { host.addSublayer(thumbLayer) }
        let thumb = thumbRect
        thumbLayer.frame = NSRect(x: thumb.minX - host.frame.minX, y: 0, width: thumb.width, height: host.bounds.height)
        thumbLayer.cornerRadius = thumb.width / 2
        thumbLayer.backgroundColor = thumbColor.cgColor
        CATransaction.commit()
    }

    private func updateThumbColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.backgroundColor = thumbColor.cgColor
        CATransaction.commit()
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
                entry["edge_inset"] = UmiScroller.edgeInset
                entry["track"] = false
            }
            entry["style"] = scroller.scrollerStyle == .overlay ? "overlay" : "legacy"
            entry["hidden"] = scroller.isHiddenOrHasHiddenAncestor
            entry["knob_proportion"] = scroller.knobProportion
            entry["value"] = scroller.doubleValue
            entry["width_pt"] = scroller.bounds.width
            let knob = scroller.rect(for: .knob)
            entry["knob_rect_pt"] = [knob.minX, knob.minY, knob.width, knob.height]
            if let umi = scroller as? UmiScroller {
                let thumb = umi.thumbRect
                entry["thumb_rect_pt"] = [thumb.minX, thumb.minY, thumb.width, thumb.height]
                entry["thumb_attached"] = umi.thumbAttached
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

extension UmiScroller {
    /// An image of a pane's scrollbar as shown now (its layers as on screen, mid-fade included),
    /// over the pane's background, the size of the scrollbar's frame (`debug.terminal.scroller`).
    /// The window's screenshot draws the terminal's own image over it, so tests read the scrollbar
    /// from here.
    @MainActor
    static func capture(_ pane: Ghostty.SurfaceView, to path: String) throws -> [String: Any] {
        guard let scroller = pane.enclosingScrollView?.verticalScroller else {
            throw UmiError.failed("the pane has no scrollbar")
        }
        let bounds = scroller.bounds
        guard bounds.width > 0, bounds.height > 0, let layer = scroller.layer else {
            throw UmiError.failed("the scrollbar has no size")
        }
        let composed = NSImage(size: bounds.size)
        composed.lockFocus()
        NSColor(pane.derivedConfig.backgroundColor).setFill()
        NSRect(origin: .zero, size: bounds.size).fill()
        if let ctx = NSGraphicsContext.current?.cgContext {
            (layer.presentation() ?? layer).render(in: ctx)
        }
        composed.unlockFocus()
        guard let tiff = composed.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw UmiError.failed("could not encode the image")
        }
        try png.write(to: URL(fileURLWithPath: path))
        return ["path": path, "width_pt": bounds.width, "height_pt": bounds.height]
    }
}
