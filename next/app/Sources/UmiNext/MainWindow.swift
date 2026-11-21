import AppKit
import WebKit
import GhosttyKit

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

    /// The user typed or clicked (the focus log's activity).
    var onUserInput: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: onUserInput?()
        default: break
        }
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
    let control = ControlServer()
    let focusLog = FocusLog()

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
    /// (time, viewport width) of every rects message, for the debug hook's resize timing.
    private(set) var rectsLog: [(t: Double, w: Double)] = []
    /// Panes whose program ended while the page was down: it hears of them at its next hello.
    private var exitedWhileDown: [String] = []
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

        services.popUpMenu = { [weak self] items, x, y in self?.popUpMenu(items, x: x, y: y) }
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
        control.sendToPage = { [weak self] in self?.send($0) }
        control.native["native.focusOpen"] = { [weak self] _ in
            ["ok": true, "result": ["stretch": (self?.focusLog.openStretch()).map { $0 as Any } ?? NSNull()]]
        }
        focusLog.current = { [weak self] in self?.focusShows() }
        focusLog.appCounts = { [weak self] in NSApp.isActive && self?.window.isKeyWindow == true }
        window.onUserInput = { [weak self] in self?.focusLog.userActed() }
        focusLog.start()
    }

    /// What the focused pane of the active tab shows, for the focus log (Umi's stretch fields).
    private func focusShows() -> (pane: String, shows: [String: Any])? {
        guard let layout, let tabs = layout["tabs"] as? [[String: Any]], !tabs.isEmpty else { return nil }
        let tab = tabs.first { $0["id"] as? String == layout["activeTab"] as? String } ?? tabs[0]
        guard let id = tab["focused"] as? String,
              let node = Self.panes(in: tab["root"]).first(where: { $0["id"] as? String == id }) else { return nil }
        let info = paneInfo[id] ?? [:]
        let kind = node["view"] as? String ?? "terminal"
        var shows: [String: Any] = [
            "title": info["title"] as? String ?? "", "kind": kind,
            "cwd": info["pwd"] as? String ?? node["cwd"] as? String ?? "", "attributes": [String: Any](),
            "tab": tab["id"] as? String ?? "", "window": "main",
        ]
        if kind == "file", let path = node["path"] as? String { shows["file"] = path; shows["title"] = (path as NSString).lastPathComponent }
        if let sid = info["session"] as? String ?? node["session"] as? String {
            shows["session"] = sid
            let s = sessions.last.first { $0["id"] as? String == sid }
            let name = ((layout["meta"] as? [String: Any])?["sessions"] as? [String: Any]).flatMap { ($0[sid] as? [String: Any])?["name"] as? String }
                ?? s?["name"] as? String ?? ""
            if let agent = s?["agent"] as? [String: Any] {
                var a: [String: Any] = ["kind": agent["agent"] ?? "claude", "title": name]
                if let sess = agent["agentSession"] { a["session"] = sess }
                shows["agent"] = a
            }
        }
        return (id, shows)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Web layer

    private func loadWeb() {
        let index = URL(fileURLWithPath: Paths.webDir + "/index.html")
        webReady = false
        control.pageGone()
        armWatchdog()
        webView.loadFileURL(index, allowingReadAccessTo: URL(fileURLWithPath: Paths.webDir, isDirectory: true))
    }

    private func webFilesChanged() {
        let now = Self.now()
        pendingReload = ["changedAt": now]
        webReady = false
        control.pageGone()
        webErrors = []
        armWatchdog()
        webView.reloadFromOrigin()
        pendingReload?["reloadCalledAt"] = Self.now()
    }

    func reloadWeb() { webFilesChanged() }

    private var updating: Process?

    /// The palette's Update and restart: runs next/install.sh from the checkout the app was built
    /// from, which builds, quits this app, installs the new copy and opens it. Sessions keep running
    /// in the daemon. A failed build leaves this app running and says so; the log is
    /// <state>/update.log.
    func updateAndRestart() {
        guard updating == nil else { showBanner("Already updating; log: \(Paths.stateDir)/update.log"); return }
        guard let app = Paths.appSourceDir else { showBanner("Can't update: this build doesn't record its checkout."); return }
        let script = (app as NSString).deletingLastPathComponent + "/install.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else { showBanner("Can't update: no \(script)."); return }
        let logPath = Paths.stateDir + "/update.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let log = FileHandle(forWritingAtPath: logPath) else { showBanner("Can't update: can't write \(logPath)."); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script]
        p.currentDirectoryURL = URL(fileURLWithPath: (app as NSString).deletingLastPathComponent)
        // An app opened from Finder has a bare PATH; the build needs swift, and install.sh trash.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("UMI_") }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + NSHomeDirectory() + "/.local/bin"
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.updating = nil
                if proc.terminationStatus != 0 { self?.showBanner("Update failed (exit \(proc.terminationStatus)); log: \(logPath)") }
            }
        }
        do { try p.run() } catch { showBanner("Can't update: \(error.localizedDescription)"); return }
        updating = p
        showBanner("Updating: building from \((app as NSString).deletingLastPathComponent)… Umi next restarts when it's built.")
    }

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
            // Only a polled list: an empty one before the first poll would read as "every session ended".
            if sessions.polled { send(["type": "sessions", "list": sessions.last]) }
            for id in exitedWhileDown where surfaces[id] != nil { send(["type": "paneExited", "pane": id]) }
            exitedWhileDown = []
            if let u = pendingTaskURL { pendingTaskURL = nil; openURL(u) }
            control.pageReady()
        case "cliReply":
            control.reply(msg)
        case "layout":
            if let l = msg["layout"] as? [String: Any] { applyLayout(l) }
        case "rects":
            applyRects(msg)
        case "request":
            if !handleTerminalRequest(msg) { services.handle(msg) }
        case "shortcuts":
            if let table = msg["table"] as? [[String: Any]] { setShortcuts(table, save: true) }
        case "focusWeb":
            // The web layer wants the keys (an open panel, a pane it draws itself).
            window.makeFirstResponder(webView)
        case "error":
            let text = msg["message"] as? String ?? "error"
            webErrors.append(text)
            showBanner("Web layer error: \(text). Terminals keep running.")
        case "reload":
            reloadWeb()
        case "updateApp":
            updateAndRestart()
        case "exitSession":
            if let id = msg["session"] as? String { SessionBackend.endSession(sessionID: id); sessions.pollSoon() }
        case "agentProjects":
            sessions.agentProjects { [weak self] list in
                self?.send(["type": "agentProjects", "list": list])
            }
        case "pastSessions":
            let project = msg["project"] as? String ?? NSHomeDirectory()
            sessions.past(project: project) { [weak self] list in
                self?.send(["type": "pastSessions", "project": project, "list": list])
            }
        case "badge":
            // The Dock badge: Review items of the current project (web/views/marks.js).
            let n = msg["count"] as? Int ?? 0
            NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
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
                "antigravity": Paths.env["UMI_NEXT_ANTIGRAVITY_CMD"] ?? "agy --dangerously-skip-permissions",
            ],
            "home": NSHomeDirectory(),
            "fontBase": baseFontSize,
        ]
    }

    // MARK: Layout and terminals

    private func restoreLayout() {
        guard let data = FileManager.default.contents(atPath: Paths.layoutFile),
              let l = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        liveSessions = SessionBackend.liveSessionIDs()
        applyLayout(l, save: false)
    }

    /// Creates a terminal for every terminal pane the layout has and ends the terminals of panes
    /// it lost.
    /// A pane whose view isn't "terminal" (e.g. the picker the web layer draws) has no terminal.
    /// A pane with `attach` set to another session shows that session instead (one pane per session).
    private func applyLayout(_ newLayout: [String: Any], save: Bool = true) {
        var wanted: [String: [String: Any]] = [:]
        Self.panes(in: newLayout).forEach { pane in
            let view = pane["view"] as? String ?? "terminal"
            if view == "terminal" { wanted[pane["id"] as! String] = pane }
        }

        for (id, pane) in wanted {
            guard let target = pane["attach"] as? String, attachHandled[id] != target else { continue }
            attachHandled[id] = target
            // A pane new to this process starts from its `session`: the page sets it to `attach`
            // on panes it creates, and after a restart `attach` is stale (it stays in the layout
            // after the pane shows the session, which may have been replaced since).
            guard surfaces[id] != nil || pending[id] != nil else { continue }
            if target == paneInfo[id]?["session"] as? String { continue }
            endTerminal(id)
            var p = pane
            p["session"] = target
            wanted[id] = p
        }
        for id in Set(surfaces.keys).union(pending.keys) where wanted[id] == nil {
            endTerminal(id)
        }
        for (id, pane) in wanted where surfaces[id] == nil && pending[id] == nil {
            // New panes wait for their first slot, so their program starts at its real size.
            pending[id] = pane
            var info: [String: Any] = [:]
            if let s = pane["session"] { info["session"] = s }
            if let c = pane["cwd"] { info["pwd"] = c }
            paneInfo[id] = info
        }
        startUnshownSessions(newLayout)
        layout = Self.withSessions(newLayout, paneInfo)
        applyZoom(newLayout["zoom"] as? [String: Any])
        syncedPanes = Self.syncedPanes(newLayout)
        if save { saveLayout() }
        focusLog.update()
    }

    /// A new session asked for in a tab that isn't showing (`umi-next tab new --no-focus --cmd …`)
    /// starts now instead of waiting for the tab's first slot, at the size of the terminal in
    /// front; showing the tab attaches to it, which resizes it to its slot. Panes in the active tab
    /// still wait for their slot, so their program starts at its real size.
    private func startUnshownSessions(_ layout: [String: Any]) {
        guard !SessionBackend.plainShell else { return }
        let tabs = layout["tabs"] as? [[String: Any]] ?? []
        let active = tabs.first { $0["id"] as? String == layout["activeTab"] as? String } ?? tabs.first
        let inActiveTab = Set(Self.panes(in: active?["root"]).compactMap { $0["id"] as? String })
        let size = (focusedPaneID().flatMap { surfaces[$0] } ?? surfaces.values.first)?.gridSize
        for (id, pane) in pending where !inActiveTab.contains(id) && pane["session"] == nil {
            guard let start = pane["start"] as? [String: Any] else { continue }
            let cwd = ((start["cwd"] ?? pane["cwd"]) as? String)
            let launch = SessionBackend.launch(existing: nil, live: nil, cwd: cwd, name: start["name"] as? String,
                                               cmd: start["cmd"] as? String, by: start["by"] as? String ?? "user", size: size)
            // A refused session waits for its slot, where the pane shows the failure.
            guard !launch.failed else { continue }
            var p = pane
            p["session"] = launch.sessionID
            p["start"] = nil
            pending[id] = p
            liveSessions?.insert(launch.sessionID)
            var info: [String: Any] = ["session": launch.sessionID]
            if let cwd { info["pwd"] = cwd }
            paneInfo[id] = info
            send(["type": "pane", "id": id, "info": info])
            sessions.pollSoon()
        }
    }

    private func endTerminal(_ id: String) {
        surfaces.removeValue(forKey: id)?.close()
        pending[id] = nil
        paneInfo[id] = nil
        lastRects[id] = nil
    }

    private func startTerminal(_ id: String, frame: CGRect) -> TerminalSurfaceView? {
        guard let pane = pending.removeValue(forKey: id) else { return nil }
        if let want = pane["session"] as? String, liveSessions?.contains(want) != true {
            liveSessions = SessionBackend.liveSessionIDs()
        }
        let cwd = (pane["cwd"] as? String)
        // A new session the picker asked for: {cmd, name, cwd}. A pane whose session is gone (the
        // daemon restarted) resumes the agent it showed, if the page recorded one (`resume`).
        let existing = pane["session"] as? String
        let gone = existing.map { liveSessions?.contains($0) != true } ?? false
        let start = pane["start"] as? [String: Any] ?? (gone ? pane["resume"] as? [String: Any] : nil)
        let startCwd = (start?["cwd"] as? String) ?? cwd
        let launch = SessionBackend.launch(existing: pane["session"] as? String, live: liveSessions, cwd: startCwd,
                                           name: start?["name"] as? String, cmd: start?["cmd"] as? String,
                                           by: start?["by"] as? String ?? "user")
        sessions.pollSoon()
        let env = ["UMI_NEXT_SESSION": launch.sessionID, "UMI_NEXT_STATE_DIR": Paths.stateDir]
        let view = TerminalSurfaceView(runtime: runtime, paneID: id, frame: frame, config: .init(
            command: launch.command, workingDirectory: launch.workingDirectory, environment: env))
        view.onFocus = { [weak self] v in self?.send(["type": "focused", "pane": v.paneID]) }
        view.syncPeers = { [weak self] v in self?.syncPeers(of: v) ?? [] }
        view.onContextMenu = { [weak self] v, p, before in self?.terminalMenu(v, at: p, selectedBefore: before) }
        terminalLayer.addSubview(view)
        applyFont(to: view)
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
        // Web chrome lying over terminals (the find bar) is cut out of them and takes the clicks.
        let holes = ((msg["holes"] as? [[String: Double]]) ?? []).compactMap { rect($0) }
        for id in shown { if let v = surfaces[id] { clip(v, by: cover, holes: holes) } }
        terminalLayer.passThrough = ((msg["passThrough"] as? [[String: Double]]) ?? []).compactMap { rect($0) }
            + (cover.map { [$0] } ?? []) + holes
        terminalLayer.chrome = ((msg["chrome"] as? [[String: Double]]) ?? []).compactMap { rect($0) }
        if let id = msg["tint"] as? String, let frame = lastRects[id] {
            focusTint.frame = frame
            clip(focusTint, by: cover, holes: holes)
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
        }
        if var p = pendingReload, p["helloAt"] != nil {
            p["rectsAt"] = t
            reloads.append(p)
            pendingReload = nil
        }
        if let f = msg["focus"] as? String { focusPane(f) }
        // L-11: a tab switch fades the terminals in from the window's background (140 ms, none with
        // Reduce Motion); typing and clicks go on meanwhile.
        if msg["fade"] as? Bool == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            terminalLayer.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                terminalLayer.animator().alphaValue = 1
            }
        }
    }

    /// A native context menu for the web layer (the explorer's right-click menu, as Umi's is native).
    /// Items: {title, enabled?, checked?, key?} or {separator: true}; `key` is a shortcut as
    /// web/shortcuts.js writes it (`cmd+shift+d`), shown beside the title (a context menu's keys
    /// don't act on their own). Returns the chosen item's index.
    private func popUpMenu(_ items: [[String: Any]], x: Double, y: Double) -> Int? {
        final class Picker: NSObject { var chosen: Int?; @objc func pick(_ s: NSMenuItem) { chosen = s.tag } }
        let picker = Picker()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, it) in items.enumerated() {
            if it["separator"] as? Bool == true { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: it["title"] as? String ?? "", action: #selector(Picker.pick(_:)), keyEquivalent: "")
            item.target = picker
            item.tag = i
            item.isEnabled = it["enabled"] as? Bool ?? true
            item.state = it["checked"] as? Bool == true ? .on : .off
            if let keys = it["key"] as? String, let e = ShortcutTable.parse("", keys, nil), let k = e.keyEquivalent {
                item.keyEquivalent = k
                item.keyEquivalentModifierMask = e.mods
            }
            menu.addItem(item)
        }
        let zoom = webView.pageZoom
        let p = NSPoint(x: x * zoom, y: webView.isFlipped ? y * zoom : webView.bounds.height - y * zoom)
        menu.popUp(positioning: nil, at: p, in: webView)
        return picker.chosen
    }

    /// Hides the part of a view under `cover` (the bottom palette, or quick open over the top of the
    /// panes) and under each of `holes` (web chrome lying over a terminal, such as the find bar): a
    /// mask with a hole where each is.
    private func clip(_ v: NSView, by cover: CGRect?, holes: [CGRect] = []) {
        guard let layer = v.layer else { return }
        let f = v.frame
        let cut = ([cover].compactMap { $0 } + holes).filter { $0.intersects(f) }
        guard !cut.isEmpty else { layer.mask = nil; return }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: f.size))
        for c in cut {
            let hole = c.intersection(f)
            // The view isn't flipped: layer y runs up from the bottom.
            path.addRect(CGRect(x: hole.minX - f.minX, y: f.maxY - hole.maxY, width: hole.width, height: hole.height))
        }
        mask.frame = CGRect(origin: .zero, size: f.size)
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.path = path
        layer.mask = mask
    }

    // MARK: Find, zoom, synchronized input

    /// A right-click in a terminal its program didn't take: the page shows the menu
    /// (web/views/termmenu.js), with what it needs to choose the items.
    private func terminalMenu(_ v: TerminalSurfaceView, at p: NSPoint, selectedBefore: Bool) {
        let w = webView.convert(v.convert(p, to: nil), from: nil)
        let zoom = webView.pageZoom
        send(["type": "termMenu", "pane": v.paneID, "x": w.x / zoom,
              "y": (webView.isFlipped ? w.y : webView.bounds.height - w.y) / zoom,
              "selected": v.hasSelection, "selectedBefore": selectedBefore, "alternate": v.alternateScreen,
              "clipboard": !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty, "readonly": v.readonly])
    }

    /// The page's requests about terminals: find (web/views/find.js) `termSearch {pane, needle}`,
    /// `termSearchNav {pane, dir}`, `termSearchEnd {pane}`; the right-click menu's
    /// (web/views/termmenu.js) `termAction {pane, action}`, action `copy`, `paste` (into the
    /// synchronized terminals too, as ⌘V), `clear`, `reset`, `readonly` (toggles). Returns false
    /// for other ops.
    private func handleTerminalRequest(_ msg: [String: Any]) -> Bool {
        guard let op = msg["op"] as? String, op.hasPrefix("termSearch") || op == "termAction", let id = msg["id"] as? String else { return false }
        let args = msg["args"] as? [String: Any] ?? [:]
        guard let pane = args["pane"] as? String, let v = surfaces[pane] else {
            send(["type": "reply", "id": id, "ok": false, "error": ["code": "notFound", "message": "no terminal for that pane"]])
            return true
        }
        let done: Bool
        switch op {
        case "termSearch": v.bindingAction("search:" + (args["needle"] as? String ?? "")); done = true
        case "termSearchNav": done = v.bindingAction("navigate_search:" + ((args["dir"] as? String) == "previous" ? "previous" : "next"))
        case "termSearchEnd": done = v.bindingAction("end_search")
        case "termAction":
            switch args["action"] as? String {
            case "copy": v.copy(nil); done = true
            case "paste": v.paste(nil); done = true
            case "clear": done = v.bindingAction("clear_screen")
            case "reset": done = v.bindingAction("reset")
            case "readonly": done = v.bindingAction("toggle_readonly")
            default: done = false
            }
        default: done = false
        }
        send(["type": "reply", "id": id, "ok": true, "result": done])
        return true
    }

    /// The config's font-size (Ghostty's default 13 when unset).
    private(set) lazy var baseFontSize: Double = {
        var size: Float = 0
        let key = "font-size"
        let ok = ghostty_config_get(runtime.config, &size, key, UInt(key.utf8.count))
        return ok && size > 0 ? Double(size) : 13
    }()
    private var uiZoom: Double = 1
    private var fontDelta: Double = 0
    /// SPEC L-33: the page's zoom (layout.zoom.ui) scales the page; the terminals show
    /// clamp(font-size + layout.zoom.font, 5, 25) times it.
    private func applyZoom(_ z: [String: Any]?) {
        let ui = min(3.5, max(0.5, (z?["ui"] as? Double) ?? 1)), font = (z?["font"] as? Double) ?? 0
        guard ui != uiZoom || font != fontDelta else { return }
        uiZoom = ui
        fontDelta = font
        if webView.pageZoom != ui { webView.pageZoom = ui }
        for v in surfaces.values { applyFont(to: v) }
    }
    private func applyFont(to v: TerminalSurfaceView) {
        let size = min(25, max(5, baseFontSize + fontDelta)) * uiZoom
        if v.appliedFontSize == nil && abs(size - baseFontSize) < 0.01 { return }
        if let a = v.appliedFontSize, abs(a - size) < 0.01 { return }
        v.bindingAction(String(format: "set_font_size:%.2f", size))
        v.appliedFontSize = size
    }

    /// SPEC L-32: the terminal panes of every synced tab (layout.sync {all} or {tabs: [ids]}).
    private var syncedPanes: Set<String> = []
    private func syncPeers(of v: TerminalSurfaceView) -> [TerminalSurfaceView] {
        guard syncedPanes.contains(v.paneID) else { return [] }
        return syncedPanes.compactMap { $0 == v.paneID ? nil : surfaces[$0] }
    }
    static func syncedPanes(_ layout: [String: Any]) -> Set<String> {
        guard let sync = layout["sync"] as? [String: Any], let tabs = layout["tabs"] as? [[String: Any]] else { return [] }
        let all = sync["all"] as? Bool ?? false, ids = Set(sync["tabs"] as? [String] ?? [])
        var out = Set<String>()
        for t in tabs where all || ids.contains(t["id"] as? String ?? "") {
            for p in panes(in: t["root"]) where (p["view"] as? String ?? "terminal") == "terminal" {
                if let id = p["id"] as? String { out.insert(id) }
            }
        }
        return out
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
        if webReady { send(["type": "action", "name": "togglePalette"]) } else { showBanner("Web layer not ready: palette unavailable.") }
    }

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

    func surface(_ view: TerminalSurfaceView, search event: String, value: Int?) {
        guard surfaces[view.paneID] === view else { return }
        switch event {
        case "end": send(["type": "searchEnded", "pane": view.paneID])
        case "start": send(["type": "action", "name": "find"])
        case "total": send(["type": "search", "pane": view.paneID, "total": value ?? NSNull()])
        default: send(["type": "search", "pane": view.paneID, "selected": value ?? NSNull()])
        }
    }

    func surfaceClosed(_ view: TerminalSurfaceView, processAlive: Bool) {
        guard surfaces[view.paneID] === view else { return }
        if let s = paneInfo[view.paneID]?["session"] as? String { SessionBackend.sessionEnded(sessionID: s) }
        if webReady {
            send(["type": "paneExited", "pane": view.paneID])
        } else {
            if !exitedWhileDown.contains(view.paneID) { exitedWhileDown.append(view.paneID) }
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
