// Trimmed from Ghostty's macOS app (SurfaceView_AppKit.swift, SurfaceView.swift); see README.md.
import AppKit
import GhosttyKit

/// One libghostty terminal: an NSView whose Metal layer libghostty draws into, with keyboard
/// (incl. IME through NSTextInputClient), mouse, scroll, resize and focus wired to the surface.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    struct Config {
        var command: String?
        var workingDirectory: String?
        var environment: [String: String] = [:]
    }

    let paneID: String
    weak var runtime: GhosttyRuntime?
    private(set) var surface: ghostty_surface_t?
    var cellSize: CGSize = .zero
    private(set) var focused = false
    /// Called when this view becomes the first responder (a click or keyboard focus).
    var onFocus: ((TerminalSurfaceView) -> Void)?
    /// umi-next: synchronized input (SPEC L-32). The other terminals what's typed here also goes to;
    /// ⌘ keys and text still being composed stay here.
    var syncPeers: (TerminalSurfaceView) -> [TerminalSurfaceView] = { _ in [] }
    /// umi-next: when ⌘V (Ghostty's paste binding) was pressed here, so the paste it reads from the
    /// clipboard is typed into the sync peers too.
    var pasteRequestedAt: TimeInterval = 0
    /// umi-next: the font size last set on this terminal (nil: the config's).
    var appliedFontSize: Double?
    /// umi-next: a right-click the program didn't take (no mouse reporting): the page shows the
    /// terminal's menu (SPEC L-31). The point is in the view; `selectedBefore`: text was selected
    /// before the click (Ghostty's right-click may select the word under it).
    var onContextMenu: ((TerminalSurfaceView, NSPoint, Bool) -> Void)?
    /// umi-next: Ghostty's read-only mode (toggle_readonly), as the core reports it.
    var readonly = false

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var leadSurrogate: LeadSurrogate?
    private var cursor: NSCursor = .iBeam

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    /// `frame` should be the view's real slot: the program starts at that size.
    init(runtime: GhosttyRuntime, paneID: String, frame: NSRect, config: Config) {
        self.paneID = paneID
        self.runtime = runtime
        super.init(frame: frame)
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.font_size = 0
        cfg.wait_after_command = false
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let keys = Array(config.environment.keys).map { strdup($0) }
        let values = keys.indices.map { strdup(config.environment[String(cString: keys[$0]!)]!) }
        defer { (keys + values).forEach { free($0) } }
        var env = keys.indices.map { ghostty_env_var_s(key: keys[$0], value: values[$0]) }
        let cmd = config.command.flatMap { strdup($0) }
        let cwd = config.workingDirectory.flatMap { strdup($0) }
        defer { free(cmd); free(cwd) }
        cfg.command = UnsafePointer(cmd)
        cfg.working_directory = UnsafePointer(cwd)
        surface = env.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            return ghostty_surface_new(runtime.app, &cfg)
        }
        // libghostty starts a surface focused; it isn't until it becomes first responder.
        if let surface { ghostty_surface_set_focus(surface, false) }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit { if let surface { ghostty_surface_free(surface) } }

    /// Ends the terminal (its program gets SIGHUP). The view must not be used afterwards.
    func close() {
        removeFromSuperview()
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    // MARK: Size, scale, occlusion

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // umi-next: never draw outside the slot, even with a frame rendered at the old size
        // (a terminal whose program is idle redraws late; during a resize its old image would
        // cover the chrome around it).
        layer?.masksToBounds = true
        sendSize()
    }

    private func sendSize() {
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let px = convertToBacking(NSRect(origin: .zero, size: frame.size)).size
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        sendSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, let surface else { return }
        if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, id.uint32Value)
        }
        viewDidChangeBackingProperties()
    }

    func setVisible(_ visible: Bool) {
        if isHidden == visible { isHidden = !visible }
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { setFocused(true); onFocus?(self) }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { setFocused(false) }
        return r
    }

    private func setFocused(_ f: Bool) {
        guard focused != f else { return }
        focused = f
        if let surface { ghostty_surface_set_focus(surface, f) }
    }

    // MARK: Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        default: return
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, GhosttyInput.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        let selectedBefore = ghostty_surface_has_selection(surface)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, GhosttyInput.ghosttyMods(event.modifierFlags)) {
            if let onContextMenu {
                onContextMenu(self, convert(event.locationInWindow, from: nil), selectedBefore)
            } else {
                super.rightMouseDown(with: event)
            }
        }
    }

    var hasSelection: Bool { surface.map { ghostty_surface_has_selection($0) } ?? false }
    /// A program's full-screen view (vim, less) shows: the alternate screen.
    var alternateScreen: Bool { surface.map { ghostty_surface_umi_alternate_screen($0) } ?? false }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, GhosttyInput.ghosttyMods(event.modifierFlags)) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.ghosttyMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Packed scroll mods (src/input/mouse.zig): bit 0 precision, bits 1-3 momentum phase.
        var mods: Int32 = precise ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }

        // Option-as-alt and similar configs change which modifiers translate to text.
        let ghosttyTM = GhosttyInput.eventModifierFlags(mods: ghostty_surface_key_translation_mods(surface, GhosttyInput.ghosttyMods(event.modifierFlags)))
        var tm = event.modifierFlags
        for f in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if ghosttyTM.contains(f) { tm.insert(f) } else { tm.remove(f) }
        }
        // Reuse the original event when nothing changed: IMEs (e.g. Korean) need the same object.
        let translationEvent: NSEvent
        if tm == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: tm,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: tm) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        let layoutBefore: String? = markedBefore ? nil : GhosttyInput.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // The key switched input sources: an input method took it.
        if !markedBefore && layoutBefore != GhosttyInput.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if markedBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = committedTextAction(action, text: text)
            }
            if shouldReplayCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent, text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// ⌘/⌃ keys reach here before keyDown. Ghostty bindings (⌘C, ⌘V, …) are performed; the
    /// rest go back through AppKit (the menu, then keyDown via doCommand).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        var ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { p -> Bool in
            ev.text = p
            var flags = ghostty_binding_flags_e(0)
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding {
            if event.charactersIgnoringModifiers?.lowercased() == "v",
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                pasteRequestedAt = ProcessInfo.processInfo.systemUptime
            }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let mods = GhosttyInput.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        // Synchronized input: the same key into each peer, except ⌘ keys and composing text.
        let peers = composing || event.modifierFlags.contains(.command) ? [] : syncPeers(self).compactMap(\.surface)
        if let text = text?.keyEventText {
            return text.withCString { p in
                ev.text = p
                for peer in peers { _ = ghostty_surface_key(peer, ev) }
                return ghostty_surface_key(surface, ev)
            }
        }
        for peer in peers { _ = ghostty_surface_key(peer, ev) }
        return ghostty_surface_key(surface, ev)
    }

    private func committedTextAction(_ action: ghostty_input_action_e, text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        let peers = syncPeers(self).compactMap(\.surface)
        return text.withCString { p in
            ev.text = p
            for peer in peers { _ = ghostty_surface_key(peer, ev) }
            return ghostty_surface_key(surface, ev)
        }
    }

    /// Runs a Ghostty binding action on this terminal ("search:foo", "set_font_size:14", …).
    @discardableResult
    func bindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: return true // down, right, up
        case 0x7B: return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command]) // left
        default: return false
        }
    }

    static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    // MARK: Copy / paste (Edit menu)

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        _ = "copy_to_clipboard".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    @objc func paste(_ sender: Any?) {
        guard let surface else { return }
        // Typed into the synchronized terminals too, as ⌘V (GhosttyRuntime.readClipboard).
        pasteRequestedAt = ProcessInfo.processInfo.systemUptime
        _ = "paste_from_clipboard".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let surface else { return }
        _ = "select_all".withCString { ghostty_surface_binding_action(surface, $0, UInt(strlen($0))) }
    }

    /// Text sent as if typed (no key events): a paste into the synchronized terminals.
    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    /// The visible screen as text (the debug hook's `screen` command).
    func visibleText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0) }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0, w > 0 { w = 0; x += Double(cellSize.width) * Double(range.location + range.length) }
        let viewRect = NSRect(x: x, y: frame.size.height - y, width: w, height: max(h, Double(cellSize.height)))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var chars = ""
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as NSString:
            if let lead = LeadSurrogate(v) {
                leadSurrogate = lead
            } else if let trail = TrailSurrogate(v) {
                chars = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                chars = v as String
                leadSurrogate = nil
            }
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator!.append(chars)
            return
        }
        if !chars.isEmpty { _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars) }
    }

    override func doCommand(by selector: Selector) {
        // A ⌘ key performKeyEquivalent passed on comes back here: send it again so keyDown encodes it.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 { str.withCString { ghostty_surface_preedit(surface, $0, UInt(len - 1)) } }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
