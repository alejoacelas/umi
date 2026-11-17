import AppKit
import WebKit

/// The window: a WKWebView fills it and draws all chrome; terminal views sit above it in a
/// layer that only takes clicks where a terminal is, at the rects the web layer reports.
final class UmiWindow: NSWindow {
    /// The page's shortcut table (Shortcuts.swift): a key it matches is handled before the terminal,
    /// the page or the menu sees it; any other key goes on as usual.
    var shortcutHandler: ((NSEvent) -> Bool)?

    /// ⌘/⌃ keys come here before sendEvent (AppKit tries key equivalents first, and the terminal
    /// would take its own Ghostty bindings such as ⌘T and ⌘D), so the table is checked here too.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, shortcutHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, shortcutHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Holds the terminals. Flipped, so a CSS rect (top-left origin) is its frame as is.
final class TerminalLayerView: NSView {
    override var isFlipped: Bool { true }
    /// Areas over terminals whose clicks go to the web layer (the dividers' grab areas), in this
    /// view's coordinates.
    var passThrough: [CGRect] = []
    /// Web chrome in the title bar that takes clicks (the pane strip's chips), in this view's coordinates.
    var chrome: [CGRect] = []
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if passThrough.contains(where: { $0.contains(local) }) { return nil }
        let hit = super.hitTest(point)
        return hit === self || hit is FocusTintView ? nil : hit
    }
}

/// White at 3% over the focused terminal of a tab showing several panes (SPEC PI-3), as Umi does.
final class FocusTintView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A strip along the top that drags the window (the web view would take those clicks).
final class DragStripView: NSView {
    weak var terminalLayer: TerminalLayerView?
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let layer = terminalLayer {
            let p = layer.convert(point, from: superview)
            if layer.chrome.contains(where: { $0.contains(p) }) { return nil }
        }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}

final class MainWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, GhosttyRuntimeDelegate {
    let runtime: GhosttyRuntime
    let window: UmiWindow
    let webView: WKWebView
    let terminalLayer = TerminalLayerView()
    private let focusTint = FocusTintView(frame: .zero)
    private let banner = NSTextField(labelWithString: "")
    private var watcher: FileWatcher?
    let sessions = SessionMonitor()
    private var hyperMonitor: Any?
    private var hyperDown = false, hyperSpoiled = false
    private(set) var shortcuts = ShortcutTable()
    private(set) var shortcutsHandled = 0
    private(set) lazy var services = WebServices { [weak self] in self?.send($0) }

    /// paneID → terminal. Terminals live here whatever the web layer does.
    private(set) var surfaces: [String: TerminalSurfaceView] = [:]
    /// paneID → session and what the terminal reported.
    private(set) var paneInfo: [String: [String: Any]] = [:]
    /// The layout as the web layer last sent it (with sessions merged in), as JSON.
    private(set) var layout: [String: Any]?
    private var liveSessions: Set<String>?
    /// Panes in the layout whose terminal starts when they first get a slot.
    private(set) var pending: [String: [String: Any]] = [:]
    /// paneID → the last `attach` request acted on, so a request is acted on once.
    private var attachHandled: [String: String] = [:]

    // State the debug hook reports.
    private(set) var webReady = false
    private(set) var lastRects: [String: CGRect] = [:]
    private(set) var lastViewport: CGSize = .zero
    private(set) var webErrors: [String] = []
    private(set) var reloads: [[String: Double]] = []
    private var pendingReload: [String: Double]?
    private(set) var resizeLags: [Double] = []
    /// (time, viewport width) of every rects message, for the debug hook's resize timing.
    private(set) var rectsLog: [(t: Double, w: Double)] = []
    private var resizeAt: (size: CGSize, t: Double)?
    private var helloWatchdog: DispatchWorkItem?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        window = UmiWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Umi next"
        window.backgroundColor = NSColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        window.setFrameAutosaveName("UmiNextMain")
        window.minSize = NSSize(width: 480, height: 300)

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = .nonPersistent()
        let errorScript = """
        (function(){
          function post(m){ try { window.webkit.messageHandlers.umi.postMessage({type:'error', message:m}); } catch(e){} }
          window.addEventListener('error', function(e){ post((e.message||'error') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')); }, true);
          window.addEventListener('unhandledrejection', function(e){ post('unhandled rejection: ' + (e.reason && e.reason.message || e.reason)); });
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        super.init()
        config.userContentController.add(self, name: "umi")
        webView.navigationDelegate = self
        runtime.delegate = self

        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        for v in [webView, terminalLayer] as [NSView] {
            v.frame = root.bounds
            v.autoresizingMask = [.width, .height]
            root.addSubview(v)
        }
        let strip = DragStripView(frame: NSRect(x: 0, y: root.bounds.height - 28, width: root.bounds.width, height: 28))
        strip.autoresizingMask = [.width, .minYMargin]
        strip.terminalLayer = terminalLayer
        root.addSubview(strip)

        banner.isHidden = true
        banner.drawsBackground = true
        banner.backgroundColor = NSColor(red: 0.55, green: 0.1, blue: 0.08, alpha: 0.95)
        banner.textColor = .white
        banner.font = .systemFont(ofSize: 12, weight: .medium)
        banner.lineBreakMode = .byTruncatingTail
        banner.frame = NSRect(x: 80, y: root.bounds.height - 26, width: root.bounds.width - 100, height: 20)
        banner.autoresizingMask = [.width, .minYMargin]
        root.addSubview(banner)

        window.delegate = self
        window.shortcutHandler = { [weak self] in self?.handleShortcut($0) ?? false }
        loadSavedShortcuts()

        if let err = SessionBackend.startDaemon() { showBanner(err) }
        restoreLayout()
        loadWeb()
        sessions.shownSessions = { [weak self] in
            Set(self?.paneInfo.values.compactMap { $0["session"] as? String } ?? [])
        }
        sessions.onUpdate = { [weak self] list in self?.send(["type": "sessions", "list": list]) }
        sessions.start()
        installHyperMonitor()
        watcher = FileWatcher(path: Paths.webDir) { [weak self] in self?.webFilesChanged() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Web layer

    private func loadWeb() {
        let index = URL(fileURLWithPath: Paths.webDir + "/index.html")
        webReady = false
        armWatchdog()
        webView.loadFileURL(index, allowingReadAccessTo: URL(fileURLWithPath: Paths.webDir, isDirectory: true))
    }

    private func webFilesChanged() {
        let now = Self.now()
        pendingReload = ["changedAt": now]
        webReady = false
        webErrors = []
        armWatchdog()
        webView.reloadFromOrigin()
        pendingReload?["reloadCalledAt"] = Self.now()
    }

    func reloadWeb() { webFilesChanged() }

    private func armWatchdog() {
        helloWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.webReady else { return }
            let why = self.webErrors.last.map { ": \($0)" } ?? " (no hello from web/app.js)"
            self.showBanner("The web layer didn't start\(why). Terminals keep running; fix the file and save.")
        }
        helloWatchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func showBanner(_ text: String) {
        banner.stringValue = "  " + text
        banner.isHidden = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showBanner("Web layer failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showBanner("Web layer failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showBanner("Web content process ended; reloading.")
        loadWeb()
    }

    /// Sends a message to web/app.js (`umiNative.receive`).
    func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.umiNative && window.umiNative.receive(\(json))", completionHandler: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msg = message.body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "hello":
            webReady = true
            helloWatchdog?.cancel()
            banner.isHidden = true
            webErrors = []
            services.reset()
            pendingReload?["helloAt"] = Self.now()
            send(stateMessage())
            send(["type": "sessions", "list": sessions.last])
            if let u = pendingTaskURL { pendingTaskURL = nil; openURL(u) }
        case "layout":
            if let l = msg["layout"] as? [String: Any] { applyLayout(l, closed: msg["closed"] as? [String: String] ?? [:]) }
        case "rects":
            applyRects(msg)
        case "request":
            services.handle(msg)
        case "shortcuts":
            if let table = msg["table"] as? [[String: Any]] { setShortcuts(table, save: true) }
        case "focus":
            if let id = msg["pane"] as? String { focusPane(id) }
        case "focusWeb":
            // The web layer wants the keys (an open panel, a pane it draws itself).
            window.makeFirstResponder(webView)
        case "error":
            let text = msg["message"] as? String ?? "error"
            webErrors.append(text)
            showBanner("Web layer error: \(text). Terminals keep running.")
        case "reload":
            reloadWeb()
        case "exitSession":
            if let id = msg["session"] as? String { SessionBackend.endSession(sessionID: id); sessions.pollSoon() }
        case "pastSessions":
            let project = msg["project"] as? String ?? NSHomeDirectory()
            sessions.past(project: project) { [weak self] list in
                self?.send(["type": "pastSessions", "project": project, "list": list])
            }
        case "refreshSessions":
            sessions.pollSoon()
        case "docket":
            if let id = msg["session"] as? String { sessions.setDocketed(id, true, name: msg["name"] as? String) }
        case "undocket":
            if let id = msg["session"] as? String { sessions.setDocketed(id, false) }
        case "log":
            NSLog("umi-next web: %@", String(describing: msg["message"] ?? ""))
        default:
            break
        }
    }

    private func stateMessage() -> [String: Any] {
        [
            "type": "state",
            "layout": layout ?? NSNull(),
            "panes": paneInfo,
            "focusedPane": focusedPaneID() ?? NSNull(),
            "sessionMode": SessionBackend.mode,
            // The commands the picker starts, without permission prompts by Alejo's standing rule
            // (override with UMI_NEXT_CLAUDE_CMD / UMI_NEXT_CODEX_CMD).
            "commands": [
                "claude": Paths.env["UMI_NEXT_CLAUDE_CMD"] ?? "claude --dangerously-skip-permissions",
                "codex": Paths.env["UMI_NEXT_CODEX_CMD"] ?? "codex --dangerously-bypass-approvals-and-sandbox",
            ],
            "home": NSHomeDirectory(),
        ]
    }

    // MARK: Layout and terminals

    private func restoreLayout() {
        guard let data = FileManager.default.contents(atPath: Paths.layoutFile),
              let l = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        liveSessions = SessionBackend.liveSessionIDs()
        applyLayout(l, save: false)
    }

    /// Creates a terminal for every pane the layout has and ends the terminals of panes it lost.
    /// Creates a terminal for every terminal pane the layout has and ends the terminals of panes
    /// it lost. `closed` says how the user closed each removed pane ("close" or "detach").
    /// A pane whose view isn't "terminal" (e.g. the picker the web layer draws) has no terminal.
    /// A pane with `attach` set to another session shows that session instead (one pane per session).
    private func applyLayout(_ newLayout: [String: Any], closed: [String: String] = [:], save: Bool = true) {
        var wanted: [String: [String: Any]] = [:]
        Self.panes(in: newLayout).forEach { pane in
            let view = pane["view"] as? String ?? "terminal"
            if view == "terminal" { wanted[pane["id"] as! String] = pane }
        }

        for (id, pane) in wanted {
            guard let target = pane["attach"] as? String, attachHandled[id] != target else { continue }
            attachHandled[id] = target
            if target == paneInfo[id]?["session"] as? String { continue }
            endTerminal(id, how: "detach")
            var p = pane
            p["session"] = target
            wanted[id] = p
        }
        for id in Set(surfaces.keys).union(pending.keys) where wanted[id] == nil {
            endTerminal(id, how: closed[id] ?? "detach")
        }
        for (id, pane) in wanted where surfaces[id] == nil && pending[id] == nil {
            // New panes wait for their first slot, so their program starts at its real size.
            pending[id] = pane
            var info: [String: Any] = [:]
            if let s = pane["session"] { info["session"] = s }
            if let c = pane["cwd"] { info["pwd"] = c }
            paneInfo[id] = info
        }
        layout = Self.withSessions(newLayout, paneInfo)
        if save { saveLayout() }
    }

    private func endTerminal(_ id: String, how: String) {
        if let view = surfaces.removeValue(forKey: id) {
            view.close()
            if let s = paneInfo[id]?["session"] as? String { SessionBackend.paneClosed(sessionID: s, how: how) }
        }
        pending[id] = nil
        paneInfo[id] = nil
        lastRects[id] = nil
    }

    private func startTerminal(_ id: String, frame: CGRect) -> TerminalSurfaceView? {
        guard let pane = pending.removeValue(forKey: id) else { return nil }
        if let want = pane["session"] as? String, liveSessions?.contains(want) != true {
            liveSessions = SessionBackend.liveSessionIDs()
        }
        let cwd = (pane["cwd"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        // A new session the picker asked for: {cmd, name, cwd}.
        let start = pane["start"] as? [String: Any]
        let startCwd = (start?["cwd"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? cwd
        let launch = SessionBackend.launch(existing: pane["session"] as? String, live: liveSessions, cwd: startCwd,
                                           name: start?["name"] as? String, cmd: start?["cmd"] as? String)
        sessions.pollSoon()
        let env = ["UMI_NEXT_PANE": id, "UMI_NEXT_SESSION": launch.sessionID, "UMI_NEXT_STATE_DIR": Paths.stateDir]
        let view = TerminalSurfaceView(runtime: runtime, paneID: id, frame: frame, config: .init(
            command: launch.command, workingDirectory: launch.workingDirectory, environment: env))
        view.onFocus = { [weak self] v in self?.send(["type": "focused", "pane": v.paneID]) }
        terminalLayer.addSubview(view)
        surfaces[id] = view
        var info: [String: Any] = ["session": launch.sessionID]
        if let cwd { info["pwd"] = cwd }
        paneInfo[id] = info
        send(["type": "pane", "id": id, "info": info])
        layout = layout.map { Self.withSessions($0, paneInfo) }
        saveLayout()
        return view
    }

    private func saveLayout() {
        guard let layout, let data = try? JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.layoutFile), options: .atomic)
    }

    /// Moves each terminal to its slot in one transaction; terminals without a slot are hidden.
    private func applyRects(_ msg: [String: Any]) {
        guard let rects = msg["rects"] as? [String: [String: Double]] else { return }
        let zoom = webView.pageZoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var shown = Set<String>()
        for (id, r) in rects {
            guard let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] else { continue }
            let frame = CGRect(x: x * zoom, y: y * zoom, width: max(w * zoom, 1), height: max(h * zoom, 1))
            guard let v = surfaces[id] ?? startTerminal(id, frame: frame) else { continue }
            if v.frame != frame { v.frame = frame }
            v.setVisible(true)
            lastRects[id] = frame
            shown.insert(id)
        }
        for (id, v) in surfaces where !shown.contains(id) {
            v.setVisible(false)
            lastRects[id] = nil
        }
        func rect(_ r: [String: Double]?) -> CGRect? {
            guard let r, let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] else { return nil }
            return CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
        }
        // The bottom panel lies over the panes: terminals keep their frames and are clipped where it
        // covers them, so the web layer's panel shows through and takes the clicks there.
        let cover = rect(msg["cover"] as? [String: Double])
        for id in shown { if let v = surfaces[id] { clip(v, by: cover) } }
        terminalLayer.passThrough = ((msg["passThrough"] as? [[String: Double]]) ?? []).compactMap { rect($0) }
            + (cover.map { [$0] } ?? [])
        terminalLayer.chrome = ((msg["chrome"] as? [[String: Double]]) ?? []).compactMap { r in
            guard let x = r["x"], let y = r["y"], let w = r["w"], let h = r["h"] else { return nil }
            return CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
        }
        if let id = msg["tint"] as? String, var frame = lastRects[id] {
            if let cover, cover.intersects(frame) { frame.size.height = max(0, cover.minY - frame.minY) }
            focusTint.frame = frame
            if focusTint.superview == nil { terminalLayer.addSubview(focusTint) }
            else if terminalLayer.subviews.last !== focusTint { terminalLayer.addSubview(focusTint, positioned: .above, relativeTo: nil) }
            focusTint.isHidden = false
        } else {
            focusTint.isHidden = true
        }
        CATransaction.commit()

        let t = Self.now()
        if let vp = msg["viewport"] as? [String: Double], let w = vp["w"], let h = vp["h"] {
            lastViewport = CGSize(width: w * zoom, height: h * zoom)
            rectsLog.append((t, w * zoom))
            if rectsLog.count > 2000 { rectsLog.removeFirst(1000) }
            if let r = resizeAt, abs(r.size.width - lastViewport.width) < 1, abs(r.size.height - lastViewport.height) < 1 {
                resizeLags.append(t - r.t)
                if resizeLags.count > 500 { resizeLags.removeFirst() }
                resizeAt = nil
            }
        }
        if var p = pendingReload, p["helloAt"] != nil {
            p["rectsAt"] = t
            reloads.append(p)
            pendingReload = nil
        }
        if let f = msg["focus"] as? String { focusPane(f) }
    }

    /// Hides the part of a terminal under `cover` (a band along the bottom of the work area).
    private func clip(_ v: TerminalSurfaceView, by cover: CGRect?) {
        guard let layer = v.layer else { return }
        let f = v.frame
        guard let cover, cover.intersects(f) else { layer.mask = nil; return }
        let visible = max(0, min(f.height, cover.minY - f.minY))
        let mask = layer.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        // The view isn't flipped: layer y runs up from the bottom, so the visible top part starts at
        // height - visible.
        mask.frame = CGRect(x: 0, y: f.height - visible, width: f.width, height: visible)
        layer.mask = mask
    }

    func focusPane(_ id: String) {
        guard let v = surfaces[id], !v.isHidden else { return }
        if window.firstResponder !== v { window.makeFirstResponder(v) }
    }

    func focusedPaneID() -> String? {
        (window.firstResponder as? TerminalSurfaceView)?.paneID
    }

    // MARK: Shortcuts

    private func loadSavedShortcuts() {
        guard let data = FileManager.default.contents(atPath: ShortcutTable.file),
              let table = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        setShortcuts(table, save: false)
    }

    private func setShortcuts(_ table: [[String: Any]], save: Bool) {
        let bad = shortcuts.load(table)
        if !bad.isEmpty { showBanner("Shortcut table: can't read the keys of \(bad.joined(separator: ", ")).") }
        if save, let data = try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: ShortcutTable.file), options: .atomic)
        }
    }

    /// A key the page's table names: native entries run here, the rest go to the page as
    /// `{type: "shortcut", id}`.
    private func handleShortcut(_ e: NSEvent) -> Bool {
        guard e.window === window, let entry = shortcuts.match(e) else { return false }
        if entry.terminalOnly && !(window.firstResponder is TerminalSurfaceView) { return false }
        shortcutsHandled += 1
        switch entry.native {
        case "reload": reloadWeb(); return true
        case "quit": NSApp.terminate(nil); return true
        default: break
        }
        guard webReady else {
            showBanner("Web layer not ready: \(entry.id) ignored.")
            return true
        }
        send(["type": "shortcut", "id": entry.id])
        return true
    }

    // MARK: Hyper

    /// A lone Hyper tap (⌃⌥⇧⌘ all down, then all up, no key between) or Hyper+Space opens the
    /// palette. Seen here, before the terminal, through a local event monitor.
    private func installHyperMonitor() {
        let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        hyperMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let mods = e.modifierFlags.intersection(hyper)
            if e.type == .leftMouseDown || e.type == .rightMouseDown {
                if self.hyperDown { self.hyperSpoiled = true }
                return e
            }
            if e.type == .keyDown {
                // Hyper with a key (Hyper+Space opens the palette) is the shortcut table's.
                if self.hyperDown { self.hyperSpoiled = true }
                return e
            }
            if mods == hyper {
                if !self.hyperDown { self.hyperDown = true; self.hyperSpoiled = false }
            } else if mods.isEmpty && self.hyperDown {
                self.hyperDown = false
                if !self.hyperSpoiled { self.openPalette() }
            }
            return e
        }
    }

    private func openPalette() {
        lastHyperAt = Self.now()
        if webReady { send(["type": "action", "name": "togglePalette"]) } else { showBanner("Web layer not ready: palette unavailable.") }
    }
    private(set) var lastHyperAt: Double = 0

    // MARK: Task links

    private var pendingTaskURL: URL?
    static let taskOrigin = "https://agent-server.tail622085.ts.net/umi/"

    /// `umi-next://open?task=<URL of a task JSON>`: show the task's live session, or resume its agent
    /// session in ~/best/<folder>. Task URLs must be on agent-server's /umi/ (in debug mode also
    /// under $UMI_NEXT_DEBUG_TASK_ORIGIN); anything else is refused with a note.
    func openURL(_ url: URL) {
        guard webReady else { pendingTaskURL = url; return }
        guard url.scheme == "umi-next", url.host == "open",
              let task = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "task" })?.value,
              let taskURL = URL(string: task) else {
            return showBanner("Not a task link: \(url.absoluteString)")
        }
        var allowed = [Self.taskOrigin]
        if Paths.debugEnabled, let o = Paths.env["UMI_NEXT_DEBUG_TASK_ORIGIN"], !o.isEmpty { allowed.append(o) }
        guard allowed.contains(where: { taskURL.absoluteString.hasPrefix($0) }) else {
            return showBanner("Refused task link: \(taskURL.absoluteString) is not on \(Self.taskOrigin)")
        }
        URLSession.shared.dataTask(with: URLRequest(url: taskURL, timeoutInterval: 15)) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, code == 200, let data, let t = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { self.showBanner("Task link failed: \(err?.localizedDescription ?? "HTTP \(code)") (\(taskURL.absoluteString))") }
                return
            }
            let live = SessionBackend.liveSessionIDs() ?? []
            DispatchQueue.main.async { self.openTask(t, live: live) }
        }.resume()
    }

    private func openTask(_ t: [String: Any], live: Set<String>) {
        let title = t["title"] as? String ?? "task"
        if let sid = t["next_session"] as? String, live.contains(sid) {
            sessions.setDocketed(sid, false)
            send(["type": "action", "name": "openTask", "session": sid, "title": title])
            return
        }
        guard let folder = t["folder"] as? String, let agentSession = t["session"] as? String else {
            return showBanner("Task \(title): no live session and nothing to resume (needs folder and session)")
        }
        let cwd = NSHomeDirectory() + "/best/" + folder
        guard FileManager.default.fileExists(atPath: cwd) else { return showBanner("Task \(title): no folder \(cwd)") }
        let agent = t["agent"] as? String ?? "claude"
        send(["type": "action", "name": "openTask", "title": title, "resume": ["agent": agent, "id": agentSession, "cwd": cwd]])
    }

    // MARK: Window

    func windowDidResize(_ notification: Notification) {
        resizeAt = (webView.frame.size, Self.now())
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: GhosttyRuntimeDelegate

    private func update(_ view: TerminalSurfaceView, _ key: String, _ value: Any) {
        guard surfaces[view.paneID] === view else { return }
        paneInfo[view.paneID]?[key] = value
        send(["type": "pane", "id": view.paneID, "info": paneInfo[view.paneID] ?? [:]])
    }

    func surface(_ view: TerminalSurfaceView, titleChanged title: String) { update(view, "title", title) }
    func surface(_ view: TerminalSurfaceView, pwdChanged pwd: String) {
        update(view, "pwd", pwd)
        if let s = paneInfo[view.paneID]?["session"] as? String { sessions.notePwd(session: s, pwd: pwd) }
        sessions.projectAsync(pwd) { [weak self, weak view] p in
            guard let self, let view, self.paneInfo[view.paneID]?["pwd"] as? String == pwd else { return }
            self.update(view, "project", p)
        }
    }
    func surface(_ view: TerminalSurfaceView, commandFinished exitCode: Int) { update(view, "exitCode", exitCode) }

    func surfaceClosed(_ view: TerminalSurfaceView, processAlive: Bool) {
        guard surfaces[view.paneID] === view else { return }
        if let s = paneInfo[view.paneID]?["session"] as? String { SessionBackend.sessionEnded(sessionID: s) }
        if webReady {
            send(["type": "paneExited", "pane": view.paneID])
        } else {
            showBanner("A pane's program ended while the web layer is down; it closes when the web layer is back.")
        }
    }

    func quitRequested() { NSApp.terminate(nil) }

    // MARK: Helpers

    static func now() -> Double { Date().timeIntervalSince1970 }

    static func panes(in node: Any?) -> [[String: Any]] {
        guard let d = node as? [String: Any] else { return [] }
        if let tabs = d["tabs"] as? [Any] { return tabs.flatMap { panes(in: ($0 as? [String: Any])?["root"]) } }
        if d["type"] as? String == "pane", d["id"] is String { return [d] }
        return panes(in: d["a"]) + panes(in: d["b"])
    }

    /// The layout with each pane's session id recorded, for layout.json.
    static func withSessions(_ node: [String: Any], _ info: [String: [String: Any]]) -> [String: Any] {
        var d = node
        if let tabs = d["tabs"] as? [[String: Any]] {
            d["tabs"] = tabs.map { t -> [String: Any] in
                var t = t
                if let r = t["root"] as? [String: Any] { t["root"] = withSessions(r, info) }
                return t
            }
            return d
        }
        if d["type"] as? String == "pane", let id = d["id"] as? String {
            if let s = info[id]?["session"] { d["session"] = s }
            if let p = info[id]?["pwd"] { d["cwd"] = p }
            return d
        }
        if let a = d["a"] as? [String: Any] { d["a"] = withSessions(a, info) }
        if let b = d["b"] as? [String: Any] { d["b"] = withSessions(b, info) }
        return d
    }
}

/// Watches a folder tree with FSEvents and calls back (debounced) on the main thread.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private var pending: DispatchWorkItem?

    init(path: String, callback: @escaping () -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
            me.fire()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.02,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func fire() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.callback() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
    }
}
