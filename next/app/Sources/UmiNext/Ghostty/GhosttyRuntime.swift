// Trimmed from Ghostty's macOS app (Ghostty.App.swift, Ghostty.Config.swift); see README.md.
import AppKit
import GhosttyKit

/// What the embedding app hears about its terminals.
protocol GhosttyRuntimeDelegate: AnyObject {
    func surface(_ view: TerminalSurfaceView, titleChanged title: String)
    func surface(_ view: TerminalSurfaceView, pwdChanged pwd: String)
    func surface(_ view: TerminalSurfaceView, commandFinished exitCode: Int)
    func surfaceClosed(_ view: TerminalSurfaceView, processAlive: Bool)
    func quitRequested()
    /// Ghostty's search (find in terminal): started (by a binding), ended, its match count and the
    /// selected match (nil: unknown).
    func surface(_ view: TerminalSurfaceView, search event: String, value: Int?)
}

final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!
    private(set) var config: ghostty_config_t!
    weak var delegate: GhosttyRuntimeDelegate?

    /// Loads the config files in order (later ones override), then creates the app.
    init(configFiles: [String]) {
        guard let cfg = ghostty_config_new() else { fatalError("ghostty_config_new failed") }
        for path in configFiles where FileManager.default.fileExists(atPath: path) {
            ghostty_config_load_file(cfg, path)
        }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        let diags = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diags {
            let d = ghostty_config_get_diagnostic(cfg, i)
            NSLog("umi-next: config: %@", String(cString: d.message))
        }
        config = cfg

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { ud in
                let me = Unmanaged<GhosttyRuntime>.fromOpaque(ud!).takeUnretainedValue()
                DispatchQueue.main.async { if let app = me.app { ghostty_app_tick(app) } }
            },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { ud, loc, state, mimes, n, list in
                GhosttyRuntime.readClipboard(ud, location: loc, state: state, mimes: mimes, mimesLen: n, list: list)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(ud, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { _, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(location: loc, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { ud, alive in
                let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud!).takeUnretainedValue()
                DispatchQueue.main.async { view.runtime?.delegate?.surfaceClosed(view, processAlive: alive) }
            }
        )
        guard let app = ghostty_app_new(&rt, cfg) else { fatalError("ghostty_app_new failed") }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
    }

    // MARK: Callbacks

    private static func view(from surface: ghostty_surface_t?) -> TerminalSurfaceView? {
        guard let surface, let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func runtime(_ app: ghostty_app_t) -> GhosttyRuntime? {
        guard let ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Ghostty's actions. Window, tab and split actions are the UI's, so they're declined
    /// (return false) and the UI's own shortcuts handle them.
    static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let rt = runtime(app)
        let view = target.tag == GHOSTTY_TARGET_SURFACE ? self.view(from: target.target.surface) : nil
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { rt?.delegate?.quitRequested() }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let p = action.action.set_title.title else { return false }
            let s = String(cString: p)
            DispatchQueue.main.async { rt?.delegate?.surface(view, titleChanged: s) }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let view, let p = action.action.pwd.pwd else { return false }
            let s = String(cString: p)
            DispatchQueue.main.async { rt?.delegate?.surface(view, pwdChanged: s) }
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view else { return false }
            let code = Int(action.action.command_finished.exit_code)
            DispatchQueue.main.async { rt?.delegate?.surface(view, commandFinished: code) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view else { return false }
            view.setCursorShape(action.action.mouse_shape)
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let s = action.action.cell_size
            view.cellSize = CGSize(width: Double(s.width), height: Double(s.height))
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            let str = String(decoding: Data(bytes: p, count: Int(u.len)), as: UTF8.self)
            if let url = URL(string: str), let scheme = url.scheme, ["http", "https", "file", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // umi-next: libghostty sets wait-after-command for any surface given a command (every
            // daemon pane runs umi-next-attach), so it would wait for a key. The pane's session
            // ended: the pane leaves (DESIGN), as with no command.
            guard let view else { return false }
            DispatchQueue.main.async { rt?.delegate?.surfaceClosed(view, processAlive: false) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view else { return false }
            DispatchQueue.main.async { rt?.delegate?.surface(view, search: "start", value: nil) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let view else { return false }
            DispatchQueue.main.async { rt?.delegate?.surface(view, search: "end", value: nil) }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view else { return false }
            let n = Int(action.action.search_total.total)
            DispatchQueue.main.async { rt?.delegate?.surface(view, search: "total", value: n < 0 ? nil : n) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view else { return false }
            let n = Int(action.action.search_selected.selected)
            DispatchQueue.main.async { rt?.delegate?.surface(view, search: "selected", value: n < 0 ? nil : n) }
            return true
        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RING_BELL:
            return true
        default:
            return false
        }
    }

    static func readClipboard(
        _ ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?, mimesLen: Int, list: Bool
    ) -> ghostty_clipboard_read_result_e {
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud!).takeUnretainedValue()
        guard let surface = view.surface, let pb = NSPasteboard.ghostty(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        var contents: [(String, Data)] = []
        if let mimes {
            for i in 0..<mimesLen {
                guard let p = mimes[i] else { continue }
                let mime = String(cString: p)
                if contents.contains(where: { $0.0 == mime }) { continue }
                if let d = pb.ghosttyData(forMime: mime) { contents.append((mime, d)) }
            }
        }
        let available = list ? pb.ghosttyAvailableMimes() : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        // umi-next: a ⌘V paste in a synchronized tab goes to every synced terminal (SPEC L-32).
        // Only a paste the user just asked for: a program's clipboard read never leaves the pane.
        if ProcessInfo.processInfo.systemUptime - view.pasteRequestedAt < 1,
           let text = contents.first(where: { $0.0.hasPrefix("text/plain") }).flatMap({ String(data: $0.1, encoding: .utf8) }) {
            view.pasteRequestedAt = 0
            for peer in view.syncPeers(view) { peer.sendText(text) }
        }
        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// No confirmation dialogs here: a paste the user asked for goes ahead (e.g. multi-line
    /// paste protection); anything a program asked for (OSC 52 / kitty reads) is refused.
    static func confirmReadClipboard(
        _ ud: UnsafeMutableRawPointer?, confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
    ) {
        let view = Unmanaged<TerminalSurfaceView>.fromOpaque(ud!).takeUnretainedValue()
        guard let surface = view.surface else { return }
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let c = confirm?.pointee else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        var contents: [(String, Data)] = []
        for i in 0..<c.contents_len {
            let e = c.contents[i]
            guard let m = e.mime, let d = e.data else { continue }
            contents.append((String(cString: m), Data(bytes: d, count: e.len)))
        }
        complete(surface, contents: contents, available: [], state: state, confirmed: true)
    }

    private static func complete(
        _ surface: ghostty_surface_t, contents: [(String, Data)], available: [String],
        state: UnsafeMutableRawPointer?, confirmed: Bool = false
    ) {
        var allocations: [UnsafeMutableRawPointer] = []
        defer { allocations.forEach { free($0) } }
        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let m = strdup(mime) else { continue }
            allocations.append(UnsafeMutableRawPointer(m))
            let buf = malloc(max(data.count, 1))!
            allocations.append(buf)
            data.withUnsafeBytes { if let b = $0.baseAddress { buf.copyMemory(from: b, byteCount: $0.count) } }
            cContents.append(ghostty_clipboard_content_s(mime: m, data: buf.assumingMemoryBound(to: CChar.self), len: data.count))
        }
        var cAvail: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            allocations.append(UnsafeMutableRawPointer(s))
            cAvail.append(UnsafePointer(s))
        }
        cContents.withUnsafeBufferPointer { cb in
            cAvail.withUnsafeBufferPointer { ab in
                var done = ghostty_clipboard_complete_s(
                    contents: cb.baseAddress, contents_len: cb.count,
                    available: ab.baseAddress, available_len: ab.count,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    /// Writes that need confirmation (OSC 52 from a program, by policy) are dropped.
    static func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int, confirm: Bool) {
        guard !confirm, let pb = NSPasteboard.ghostty(location), let content, len > 0 else { return }
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for i in 0..<len {
            let c = content[i]
            guard let m = c.mime, let d = c.data, let t = NSPasteboard.PasteboardType(mimeType: String(cString: m)) else { continue }
            items.append((t, Data(bytes: d, count: c.len)))
        }
        pb.declareTypes(items.map { $0.0 }, owner: nil)
        for (t, d) in items { pb.setData(d, forType: t) }
    }
}
