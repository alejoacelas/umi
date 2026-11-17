import AppKit
import WebKit

/// Test hook, only with UMI_NEXT_DEBUG=1: a Unix socket at <state>/debug.sock taking one JSON
/// command per connection and answering with one JSON line. `next/app/umi-next-ui-debug` wraps it.
///
/// Input commands synthesize NSEvents and send them through NSApp.sendEvent, so they take the
/// same path as real keys and clicks (shortcut table, performKeyEquivalent, interpretKeyEvents,
/// hit testing); only the OS's event tap is skipped.
final class DebugServer {
    private weak var controller: MainWindowController?
    private var fd: Int32 = -1

    init(controller: MainWindowController) {
        self.controller = controller
        let path = Paths.debugSocket
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            path.withCString { strncpy(buf.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buf.count - 1) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { NSLog("umi-next: debug socket failed"); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[n - 1] == 10 { break }
            }
            let sem = DispatchSemaphore(value: 0)
            var reply: Any = ["error": "bad request"]
            if let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    self.handle(cmd) { reply = $0; sem.signal() }
                }
                sem.wait()
            }
            var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
            out.append(10)
            out.withUnsafeBytes { _ = write(c, $0.baseAddress, out.count) }
            close(c)
        }
    }

    private func handle(_ cmd: [String: Any], done: @escaping (Any) -> Void) {
        guard let c = controller else { return done(["error": "no window"]) }
        let name = cmd["cmd"] as? String ?? ""
        switch name {
        case "state":
            done(state(c))
        case "screen":
            guard let id = (cmd["pane"] as? String) ?? c.focusedPaneID(), let v = c.surfaces[id] else { return done(["error": "no pane"]) }
            done(["pane": id, "text": v.visibleText()])
        case "keys":
            // Types each character as a key press into the key window.
            for ch in (cmd["text"] as? String ?? "") { postKey(String(ch), mods: [], window: c.window) }
            done(["ok": true])
        case "shortcut":
            var mods: NSEvent.ModifierFlags = []
            for m in cmd["mods"] as? [String] ?? [] {
                switch m {
                case "cmd": mods.insert(.command)
                case "shift": mods.insert(.shift)
                case "opt": mods.insert(.option)
                case "ctrl": mods.insert(.control)
                default: break
                }
            }
            postKey(cmd["key"] as? String ?? "", mods: mods, window: c.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(["ok": true]) }
        case "click":
            // x, y: window points from the top-left of the content.
            let x = cmd["x"] as? Double ?? 0, y = cmd["y"] as? Double ?? 0
            let h = c.window.contentView!.bounds.height
            let p = NSPoint(x: x, y: h - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(e)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(["ok": true]) }
        case "eval":
            c.webView.evaluateJavaScript(cmd["js"] as? String ?? "") { r, e in
                done(["result": r.map { "\($0)" as Any } ?? NSNull(), "error": e.map { "\($0)" as Any } ?? NSNull()])
            }
        case "resize":
            var f = c.window.frame
            let w = cmd["w"] as? Double ?? f.width, h = cmd["h"] as? Double ?? f.height
            f.origin.y += f.height - h
            f.size = NSSize(width: w, height: h)
            c.window.setFrame(f, display: true)
            done(["ok": true, "frame": "\(c.window.frame)"])
        case "liveResize":
            // Steps the window width from `from` to `to` every `interval` ms, as a drag would.
            // For each step: ms from setFrame until a rects message for that width arrived
            // (null: none did, the web layer skipped that size).
            let from = cmd["from"] as? Double ?? 1000, to = cmd["to"] as? Double ?? 1300
            let steps = max(cmd["steps"] as? Int ?? 30, 1), interval = cmd["interval"] as? Double ?? 16
            var sent: [(t: Double, w: Double)] = []
            var i = 0
            func step() {
                guard i <= steps else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let log = c.rectsLog
                        let lags: [Any] = sent.map { s in
                            guard let hit = log.first(where: { $0.t >= s.t && abs($0.w - s.w) < 0.5 }) else { return NSNull() }
                            return ((hit.t - s.t) * 10000).rounded() / 10
                        }
                        done(["stepsSent": sent.count, "lagMs": lags, "mismatchNow": self.mismatches(c)])
                    }
                    return
                }
                var f = c.window.frame
                f.size.width = (from + (to - from) * Double(i) / Double(steps)).rounded()
                let t = MainWindowController.now()
                c.window.setFrame(f, display: true)
                sent.append((t, c.webView.frame.width))
                i += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + interval / 1000, execute: step)
            }
            step()
        case "activate":
            // Brings this window to the front with the keys (for tests sending real key events).
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(["ok": true, "active": NSApp.isActive, "key": c.window.isKeyWindow]) }
        case "reloadWeb":
            c.reloadWeb()
            done(["ok": true])
        default:
            done(["error": "unknown command \(name)"])
        }
    }

    private func state(_ c: MainWindowController) -> [String: Any] {
        func r(_ f: CGRect) -> [String: Double] { ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height] }
        var panes: [[String: Any]] = []
        for (id, v) in c.surfaces.sorted(by: { $0.key < $1.key }) {
            var p: [String: Any] = [
                "id": id, "frame": r(v.frame), "visible": !v.isHidden,
                "firstResponder": c.window.firstResponder === v,
                "view": "\(Unmanaged.passUnretained(v).toOpaque())",
                "grid": ["cols": v.gridSize.cols, "rows": v.gridSize.rows],
            ]
            if let w = c.lastRects[id] { p["webRect"] = r(w) }
            p["info"] = c.paneInfo[id] ?? [:]
            panes.append(p)
        }
        return [
            "window": r(c.window.frame), "content": r(c.window.contentView!.bounds),
            "windowNumber": c.window.windowNumber,
            // The content's top-left in global top-left screen points (CGEvent coordinates).
            "contentOriginGlobal": ["x": c.window.frame.minX,
                                    "y": (NSScreen.screens.first?.frame.height ?? 0) - c.window.frame.maxY],
            "webReady": c.webReady, "webErrors": c.webErrors, "webDir": Paths.webDir,
            "viewportReported": ["w": c.lastViewport.width, "h": c.lastViewport.height],
            "panes": panes, "pendingPanes": Array(c.pending.keys).sorted(), "focusedPane": c.focusedPaneID() ?? NSNull(),
            "reloads": c.reloads, "mismatches": mismatches(c),
            "layout": c.layout ?? NSNull(), "sessionMode": SessionBackend.mode,
            "active": NSApp.isActive && c.window.isKeyWindow, "pid": Int(getpid()),
            "shortcuts": c.shortcuts.entries.map(\.id), "shortcutsHandled": c.shortcutsHandled,
        ]
    }

    /// Visible terminals whose frame differs from their slot in the web layout right now,
    /// measured by asking nothing: frame vs the last reported rect, and that rect's viewport vs the window.
    private func mismatches(_ c: MainWindowController) -> [String] {
        var out: [String] = []
        let content = c.webView.frame.size
        if abs(content.width - c.lastViewport.width) > 0.5 || abs(content.height - c.lastViewport.height) > 0.5 {
            out.append("viewport \(c.lastViewport) != webview \(content)")
        }
        for (id, v) in c.surfaces where !v.isHidden {
            if let w = c.lastRects[id], w != v.frame { out.append("\(id): frame \(v.frame) != slot \(w)") }
        }
        return out
    }

    private static let keyCodes: [Character: UInt16] = {
        var m: [Character: UInt16] = [:]
        let letters: [(Character, UInt16)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31), ("u", 32),
            ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50), (" ", 49), ("\r", 36), ("\n", 36), ("\t", 48), ("\u{1b}", 53)]
        for (ch, code) in letters { m[ch] = code }
        return m
    }()

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    private static let arrows: [String: (UInt16, Int)] = [
        "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
        "down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey),
    ]

    private func postKey(_ s: String, mods: NSEvent.ModifierFlags, window: NSWindow) {
        if let (code, fn) = Self.arrows[s] {
            let chars = String(Character(UnicodeScalar(UInt16(fn))!))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods.union([.function, .numericPad]),
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
            return
        }
        guard let ch = s.first else { return }
        var flags = mods
        var base = ch
        if ch.isUppercase { flags.insert(.shift); base = Character(ch.lowercased()) }
        if let b = Self.shifted[ch] { flags.insert(.shift); base = b }
        let code = Self.keyCodes[base] ?? 0
        let chars = ch == "\n" ? "\r" : String(ch)
        let ign = flags.contains(.shift) ? chars : String(base)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: flags.contains(.command) ? String(base) : chars,
                                        charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }
}
