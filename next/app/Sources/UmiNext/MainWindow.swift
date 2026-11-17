import AppKit
import WebKit

/// The window: a WKWebView fills it and draws all chrome; terminal views sit above it in a
/// layer that only takes clicks where a terminal is, at the rects the web layer reports.
final class UmiWindow: NSWindow {
    /// Native shortcut table: ⌘ keys handled before the terminal sees them, as web actions.
    var shortcutHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, shortcutHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the terminals. Flipped, so a CSS rect (top-left origin) is its frame as is.
final class TerminalLayerView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A strip along the top that drags the window (the web view would take those clicks).
final class DragStripView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}

final class MainWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, GhosttyRuntimeDelegate {
    let runtime: GhosttyRuntime
    let window: UmiWindow
    let webView: WKWebView
    let terminalLayer = TerminalLayerView()
    private let banner = NSTextField(labelWithString: "")
    private var watcher: FileWatcher?

    /// paneID → terminal. Terminals live here whatever the web layer does.
    private(set) var surfaces: [String: TerminalSurfaceView] = [:]
    /// paneID → session and what the terminal reported.
    private(set) var paneInfo: [String: [String: Any]] = [:]
    /// The layout as the web layer last sent it (with sessions merged in), as JSON.
    private(set) var layout: [String: Any]?
    private var liveSessions: Set<String>?
    /// Panes in the layout whose terminal starts when they first get a slot.
    private(set) var pending: [String: [String: Any]] = [:]

    // State the debug hook reports.
    private(set) var webReady = false
    private(set) var lastRects: [String: CGRect] = [:]
    private(set) var lastViewport: CGSize = .zero
    private(set) var webErrors: [String] = []
    private(set) var reloads: [[String: Double]] = []
    private var pendingReload: [String: Double]?
    private(set) var resizeLags: [Double] = []
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

        restoreLayout()
        loadWeb()
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
        armWatchdog()
        webView.reloadFromOrigin()
        pendingReload?["reloadCalledAt"] = Self.now()
    }

    func reloadWeb() { webFilesChanged() }

    private func armWatchdog() {
        helloWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.webReady else { return }
            self.showBanner("The web layer didn't start (no hello from web/app.js). Terminals keep running; fix the file and save.")
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
            pendingReload?["helloAt"] = Self.now()
            send(stateMessage())
        case "layout":
            if let l = msg["layout"] as? [String: Any] { applyLayout(l) }
        case "rects":
            applyRects(msg)
        case "focus":
            if let id = msg["pane"] as? String { focusPane(id) }
        case "error":
            let text = msg["message"] as? String ?? "error"
            webErrors.append(text)
            showBanner("Web layer error: \(text). Terminals keep running.")
        case "reload":
            reloadWeb()
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
    private func applyLayout(_ newLayout: [String: Any], save: Bool = true) {
        var wanted: [String: [String: Any]] = [:]
        Self.panes(in: newLayout).forEach { wanted[$0["id"] as! String] = $0 }

        for (id, view) in surfaces where wanted[id] == nil {
            view.close()
            surfaces[id] = nil
            if let s = paneInfo[id]?["session"] as? String { SessionBackend.paneClosed(sessionID: s) }
            paneInfo[id] = nil
            lastRects[id] = nil
        }
        // New panes wait for their first slot, so their program starts at its real size.
        for id in pending.keys where wanted[id] == nil {
            pending[id] = nil
            paneInfo[id] = nil
        }
        for (id, pane) in wanted where surfaces[id] == nil && pending[id] == nil {
            pending[id] = pane
            var info: [String: Any] = [:]
            if let s = pane["session"] { info["session"] = s }
            if let c = pane["cwd"] { info["pwd"] = c }
            paneInfo[id] = info
        }
        layout = Self.withSessions(newLayout, paneInfo)
        if save { saveLayout() }
    }

    private func startTerminal(_ id: String, frame: CGRect) -> TerminalSurfaceView? {
        guard let pane = pending.removeValue(forKey: id) else { return nil }
        let cwd = (pane["cwd"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let launch = SessionBackend.launch(existing: pane["session"] as? String, live: liveSessions, cwd: cwd, name: nil)
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
        CATransaction.commit()

        let t = Self.now()
        if let vp = msg["viewport"] as? [String: Double], let w = vp["w"], let h = vp["h"] {
            lastViewport = CGSize(width: w * zoom, height: h * zoom)
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

    func focusPane(_ id: String) {
        guard let v = surfaces[id], !v.isHidden else { return }
        if window.firstResponder !== v { window.makeFirstResponder(v) }
    }

    func focusedPaneID() -> String? {
        (window.firstResponder as? TerminalSurfaceView)?.paneID
    }

    // MARK: Shortcuts

    /// keyCode → action, for ⌘ (and ⇧⌘) keys. The web layer implements the actions.
    private func handleShortcut(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let cmd: NSEvent.ModifierFlags = [.command]
        let shiftCmd: NSEvent.ModifierFlags = [.command, .shift]
        let optCmd: NSEvent.ModifierFlags = [.command, .option]
        var action: [String: Any]?
        switch (e.keyCode, mods) {
        case (17, cmd): action = ["name": "newTab"]                     // ⌘T
        case (2, cmd): action = ["name": "splitRight"]                  // ⌘D
        case (2, shiftCmd): action = ["name": "splitDown"]              // ⇧⌘D
        case (13, cmd): action = ["name": "closePane"]                  // ⌘W
        case (11, cmd): action = ["name": "toggleSidebar"]              // ⌘B
        case (33, shiftCmd): action = ["name": "prevTab"]               // ⇧⌘[
        case (30, shiftCmd): action = ["name": "nextTab"]               // ⇧⌘]
        case (123, optCmd): action = ["name": "focusDir", "dir": "left"]
        case (124, optCmd): action = ["name": "focusDir", "dir": "right"]
        case (126, optCmd): action = ["name": "focusDir", "dir": "up"]
        case (125, optCmd): action = ["name": "focusDir", "dir": "down"]
        case (15, shiftCmd): reloadWeb(); return true                   // ⇧⌘R reloads the web layer
        case (12, cmd): NSApp.terminate(nil); return true               // ⌘Q
        default:
            // By character, so the keypad's digits count too.
            if mods == cmd, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
                action = ["name": "selectTab", "index": n]
            }
        }
        guard var a = action else { return false }
        guard webReady else {
            showBanner("Web layer not ready: \(a["name"]!) ignored.")
            return true
        }
        a["type"] = "action"
        send(a)
        return true
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
    func surface(_ view: TerminalSurfaceView, pwdChanged pwd: String) { update(view, "pwd", pwd) }
    func surface(_ view: TerminalSurfaceView, commandFinished exitCode: Int) { update(view, "exitCode", exitCode) }

    func surfaceClosed(_ view: TerminalSurfaceView, processAlive: Bool) {
        guard surfaces[view.paneID] === view else { return }
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
