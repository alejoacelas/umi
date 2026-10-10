import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dropping tabs and panes on the sidebar (M-4)

/// Tabs and panes dropped on the sidebar. On a row, a tab lands before or after it (by half),
/// and a pane moves into that tab (middle half) or becomes a new tab before or after it (top
/// and bottom quarters). Below the rows, either lands at the end.
@MainActor
enum TernSidebarDrop {
    enum Zone: String { case before, into, after, end }

    enum Payload {
        case tab(TernTab, TerminalController)
        case pane(Ghostty.SurfaceView)
    }

    static let types: [UTType] = [.ghosttySurfaceId, .plainText]

    static func zone(at y: CGFloat, height: CGFloat, pane: Bool) -> Zone {
        let height = max(height, 1)
        if pane {
            if y < height / 4 { return .before }
            if y > height * 3 / 4 { return .after }
            return .into
        }
        return y < height / 2 ? .before : .after
    }

    static func receive(_ providers: [NSItemProvider], perform: @escaping @MainActor (Payload) -> Void) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.ghosttySurfaceId.identifier) }) {
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { result in
                guard case .success(let pane) = result else { return }
                DispatchQueue.main.async { perform(.pane(pane)) }
            }
            return true
        }
        return TernTabDrag.receive(providers) { tab, source in perform(.tab(tab, source)) }
    }

    /// Carry out a drop. Errors (a pane dropped on its own one-pane tab, …) change nothing. A
    /// drop is a placement by hand: the tab stays where it was dropped until the sidebar's order
    /// next changes (S-7), even though the drop selects it.
    @discardableResult
    static func perform(_ payload: Payload, zone: Zone, row: TernTab?, in controller: TerminalController) -> TernTopology.Location? {
        TernTabOrder.hold { performHeld(payload, zone: zone, row: row, in: controller) }
    }

    private static func performHeld(_ payload: Payload, zone: Zone, row: TernTab?, in controller: TerminalController) -> TernTopology.Location? {
        let rowIndex = row.flatMap { controller.index(of: $0) }
        switch payload {
        case .tab(let dragged, let source):
            guard dragged !== row else { return nil }
            // A 0-based position among the window's tabs as they are now.
            var position: Int
            switch zone {
            case .before, .into: position = rowIndex ?? controller.tabs.count
            case .after: position = (rowIndex ?? controller.tabs.count - 1) + 1
            case .end: position = controller.tabs.count
            }
            // Within one window the dragged tab leaves its place first.
            if source === controller, let from = controller.index(of: dragged), from < position { position -= 1 }
            guard let window = try? TernLayout.move(tab: dragged, from: source, toWindow: controller, index: position + 1,
                                                    newWindow: false, focus: true),
                  let pane = dragged.effectiveFocusedSurface else { return nil }
            return TernTopology.Location(window: window, tab: dragged, pane: pane)

        case .pane(let pane):
            do {
                switch zone {
                case .into:
                    guard let row, let anchor = anchor(in: row, of: controller, excluding: pane) else { return nil }
                    return try TernLayout.move(pane, to: .besidePane(anchor, .right), focus: true)
                case .before:
                    return try TernLayout.move(pane, to: .newTab(controller, index: rowIndex ?? controller.tabs.count), focus: true)
                case .after:
                    return try TernLayout.move(pane, to: .newTab(controller, index: (rowIndex.map { $0 + 1 }) ?? controller.tabs.count),
                                               focus: true)
                case .end:
                    return try TernLayout.move(pane, to: .newTab(controller, index: controller.tabs.count), focus: true)
                }
            } catch {
                NSSound.beep()
                return nil
            }
        }
    }

    /// The pane a pane dropped on a tab's row goes beside: the tab's focused pane, as with
    /// ⌃⌘← / ⌃⌘→ and `pane move --tab`. Nil when the pane is already that tab's only pane.
    static func anchor(in tab: TernTab, of window: TerminalController, excluding pane: Ghostty.SurfaceView) -> Ghostty.SurfaceView? {
        let tree = window.tree(of: tab)
        let leaves = tree.root?.leaves() ?? []
        if leaves.contains(where: { $0 === pane }) { return nil }   // already in that tab
        let focused = (tab === window.selectedTab ? window.focusedSurface : nil).flatMap { tree.contains($0) ? $0 : nil }
        return focused ?? tab.effectiveFocusedSurface ?? leaves.first
    }
}

/// A row's drop target: shows where the drop would land as the drag moves.
struct TernSidebarRowDropDelegate: DropDelegate {
    let controller: TerminalController
    let tab: TernTab
    let height: CGFloat
    @Binding var zone: TernSidebarDrop.Zone?

    private func isPane(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.ghosttySurfaceId]) }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: TernSidebarDrop.types)
    }

    func dropEntered(info: DropInfo) {
        zone = TernSidebarDrop.zone(at: info.location.y, height: height, pane: isPane(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = TernSidebarDrop.zone(at: info.location.y, height: height, pane: isPane(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropZone = TernSidebarDrop.zone(at: info.location.y, height: height, pane: isPane(info))
        zone = nil
        let providers = info.itemProviders(for: TernSidebarDrop.types)
        let controller = controller
        let tab = tab
        return TernSidebarDrop.receive(providers) { payload in
            TernSidebarDrop.perform(payload, zone: dropZone, row: tab, in: controller)
        }
    }
}

/// The space below the rows: whatever is dropped there lands at the end.
struct TernSidebarListDropDelegate: DropDelegate {
    let controller: TerminalController
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: TernSidebarDrop.types) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let controller = controller
        return TernSidebarDrop.receive(info.itemProviders(for: TernSidebarDrop.types)) { payload in
            TernSidebarDrop.perform(payload, zone: .end, row: nil, in: controller)
        }
    }
}

/// Drag and drop of tab rows, within a window and between windows (M-4).
@MainActor
enum TernTabDrag {
    nonisolated static let prefix = "tern-tab:"

    static func receive(_ providers: [NSItemProvider], perform: @escaping @MainActor (TernTab, TerminalController) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, string.hasPrefix(prefix) else { return }
            let id = String(string.dropFirst(prefix.count))
            DispatchQueue.main.async {
                for window in TernTopology.windows {
                    if let tab = window.tabs.first(where: { $0.idString == id }) {
                        perform(tab, window)
                        return
                    }
                }
            }
        }
        return true
    }

    /// A tab dragged out and dropped where nothing takes it: outside its window, it becomes a
    /// window of its own there (M-4, as in Warp). Back over its own window, nothing happens.
    @discardableResult
    static func droppedOutside(_ tab: TernTab, at point: NSPoint) -> TerminalController? {
        guard let source = TernTopology.locate(tab: tab) else { return nil }
        if let frame = source.window?.frame, frame.contains(point) { return nil }
        return try? TernLayout.move(tab: tab, from: source, toWindow: nil, index: nil, newWindow: true, focus: true, at: point)
    }
}

/// Starts an AppKit drag for a tab row. SwiftUI's `onDrag` can't say how a drag ended; this
/// can, so a tab dropped outside the window makes a new window there (M-4).
@MainActor
final class TernTabDragSource: NSObject, NSDraggingSource {
    static let shared = TernTabDragSource()

    private weak var tab: TernTab?
    private var escapeMonitor: Any?
    private var cancelledByEscape = false
    private(set) var dragging = false

    func begin(tab: TernTab, in controller: TerminalController, title: String) {
        guard !dragging, let window = controller.window, let view = window.contentView else { return }
        let event: NSEvent
        if let current = NSApp.currentEvent, current.type == .leftMouseDragged || current.type == .leftMouseDown {
            event = current
        } else if let synthesized = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) {
            event = synthesized
        } else {
            return
        }
        let item = NSDraggingItem(pasteboardWriter: (TernTabDrag.prefix + tab.idString) as NSString)
        let image = Self.image(for: title)
        let location = view.convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: location.x - 14, y: location.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        self.tab = tab
        dragging = true
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        cancelledByEscape = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelledByEscape = true }
            return event
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        dragging = false
        guard operation == [], !cancelledByEscape, let tab else { return }
        self.tab = nil
        TernTabDrag.droppedOutside(tab, at: screenPoint)
    }

    /// The tab's title on a small dark plate, as the drag image.
    static func image(for title: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: min(textSize.width + 22, 260), height: textSize.height + 10)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.16, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(in: rect.insetBy(dx: 11, dy: 5), withAttributes: attributes)
            return true
        }
    }
}
