import AppKit
import CryptoKit
import SwiftUI
import WebKit

/// Pages from the origins in the config's `umi-web-origin` open in panes of their own (E-12): a
/// web pane is an ordinary pane (it splits, moves, stacks, closes and is restored like any other)
/// whose terminal is covered by a web view, as a file pane's is by its editor. Links ⌘-clicked
/// in a terminal and URLs given to `umi edit` open there; links to other origins go to the
/// default browser.
@MainActor
final class UmiWebPanes: ObservableObject {
    static let shared = UmiWebPanes()

    private struct Entry {
        weak var pane: Ghostty.SurfaceView?
        let page: UmiWebPage
    }

    @Published private var entries: [UUID: Entry] = [:]

    func page(of pane: Ghostty.SurfaceView) -> UmiWebPage? { entries[pane.id]?.page }
    func isWebPane(_ id: UUID) -> Bool { entries[id] != nil }

    func attach(_ page: UmiWebPage, to pane: Ghostty.SurfaceView) {
        page.pane = pane
        entries[pane.id] = Entry(pane: pane, page: page)
        UmiState.shared.layoutDidChange()
    }

    /// Every web pane in a window, with its page.
    var open: [(pane: Ghostty.SurfaceView, page: UmiWebPage)] {
        let live = Set(UmiTopology.allSurfaces.map(ObjectIdentifier.init))
        return entries.values.compactMap { entry in
            guard let pane = entry.pane, live.contains(ObjectIdentifier(pane)) else { return nil }
            return (pane, entry.page)
        }
    }

    /// Forget panes that are gone for good (a closed pane stays known while undo can bring it back).
    func prune() {
        for (id, entry) in entries where entry.pane == nil { entries[id] = nil }
    }

    // MARK: Which links open here

    /// The origins whose links open in web panes: the config's `umi-web-origin` lines.
    static var origins: Set<String> {
        let lines = UmiLayout.ghostty?.config.umiWebOrigins ?? []
        return Set(lines.compactMap { URL(string: $0).flatMap(origin(of:)) })
    }

    /// `scheme://host[:port]`, lowercased, without the scheme's default port; nil unless http(s).
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { origin += ":\(port)" }
        return origin
    }

    static func handles(_ url: URL) -> Bool {
        guard let origin = origin(of: url) else { return false }
        return origins.contains(origin)
    }

    // MARK: Opening

    /// Open a page in a pane of its own, placed as a file is (E-9): to the right of `anchor`, or in
    /// the stack at its place in a tab already showing three. A page already open (the same URL) shows where it is.
    @discardableResult
    static func open(_ url: URL, near anchor: Ghostty.SurfaceView,
                     focus: Bool) throws -> (pane: Ghostty.SurfaceView, page: UmiWebPage) {
        if let existing = shared.open.first(where: { $0.page.url.absoluteString == url.absoluteString }) {
            if let location = UmiTopology.locate(existing.pane),
               !location.window.tree(of: location.tab).contains(existing.pane) {
                try UmiStacks.show(existing.pane, focus: focus)
            } else if focus {
                UmiLayout.focusPane(existing.pane, activate: true)
            }
            return existing
        }
        let placed = try UmiFilePanes.newPane(near: anchor, cwd: nil, for: url.absoluteString)
        let page = UmiWebPage(url: url)
        shared.attach(page, to: placed.pane)
        if focus { UmiLayout.focusPane(placed.pane, activate: true) }
        UmiEvents.shared.emit("web.opened", ["url": url.absoluteString, "pane": placed.pane.umiID,
                                             "tab": placed.tab, "window": placed.window])
        return (placed.pane, page)
    }

    /// A link ⌘-clicked in a terminal pane: a page from a listed origin opens in a web pane beside
    /// that pane, and the pane takes focus. Returns false for every other link (the caller opens it
    /// as before). The pane is made on the next turn of the main loop: the click arrives while the
    /// terminal is still handling its mouse event, and making a pane inside that blocks the app.
    /// If no pane can be made there, the link opens in the browser, as other links do.
    static func openFromTerminal(_ raw: String, pane: Ghostty.SurfaceView?) -> Bool {
        guard let pane, let url = URL(string: raw), handles(url) else { return false }
        DispatchQueue.main.async { [weak pane] in
            guard let pane else { return }
            do {
                try open(url, near: pane, focus: true)
            } catch {
                openInBrowser(url, from: pane)
            }
        }
        return true
    }

    /// Links that leave a web pane's origin open in the default browser. `UMI_TEST_BROWSER_LOG`
    /// (tests only) appends each URL to that file instead, so no browser opens during a test run.
    static func openInBrowser(_ url: URL, from pane: Ghostty.SurfaceView?) {
        UmiEvents.shared.emit("web.browser", ["url": url.absoluteString, "pane": pane?.umiID ?? ""])
        if let log = ProcessInfo.processInfo.environment["UMI_TEST_BROWSER_LOG"], !log.isEmpty {
            if let handle = FileHandle(forWritingAtPath: log) ?? {
                FileManager.default.createFile(atPath: log, contents: nil)
                return FileHandle(forWritingAtPath: log)
            }() {
                handle.seekToEndOfFile()
                handle.write(Data((url.absoluteString + "\n").utf8))
                try? handle.close()
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Website data

    /// Web panes keep cookies and local storage (where a page keeps unsaved drafts) on disk, in a
    /// store of their own for this state directory, so they survive a relaunch and an update.
    static let dataStore: WKWebsiteDataStore = {
        if #available(macOS 14.0, *) {
            let digest = Array(SHA256.hash(data: Data(("umi-web-panes:" + UmiPaths.stateDirectory).utf8)))
            var bytes = Array(digest.prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x50   // a name-based UUID (version 5 layout)
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                   bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            return WKWebsiteDataStore(forIdentifier: uuid)
        }
        // macOS 13 has no separate persistent stores: the app's default one (also on disk).
        return .default()
    }()

    // MARK: Focus

    /// A web pane's keyboard focus is its page.
    func focusPage(of pane: Ghostty.SurfaceView) {
        guard let page = entries[pane.id]?.page, let window = page.webView.window else { return }
        if window.firstResponder !== page.webView { window.makeFirstResponder(page.webView) }
    }
}

// MARK: - A page

/// One web pane's page: its web view (kept while the pane moves between tabs and windows), title
/// and address.
@MainActor
final class UmiWebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: UmiWebView
    /// The page's origin: navigation elsewhere goes to the browser.
    let origin: String?
    weak var pane: Ghostty.SurfaceView?
    /// The address shown (and restored after a relaunch): the last one the page reached.
    @Published private(set) var url: URL
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    /// Why the page didn't load, until it does.
    @Published private(set) var failure: String?
    /// What a hosted page (one that speaks to Umi, as the agent server's file page does) last said
    /// about itself; nil until it says so, and again after each navigation.
    @Published private(set) var hosted: UmiHostedPage.State?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        self.url = url
        origin = UmiWebPanes.origin(of: url)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = UmiWebPanes.dataStore
        // Only pages from a listed origin are told they are in Umi and may speak to it (E-12).
        let speaks = UmiWebPanes.handles(url)
        if speaks {
            config.userContentController.addUserScript(WKUserScript(
                source: UmiHostedPage.marker, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = UmiWebView(frame: .zero, configuration: config)
        super.init()
        if speaks {
            webView.configuration.userContentController.add(UmiHostedPage.Relay(page: self), name: UmiHostedPage.handlerName)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.title = web.title ?? "" }
            },
            webView.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, let now = web.url, now.absoluteString != self.url.absoluteString,
                          UmiWebPanes.origin(of: now) == self.origin else { return }
                    self.url = now
                    UmiState.shared.layoutDidChange()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated { self?.loading = web.isLoading }
            },
        ]
        webView.load(URLRequest(url: url))
    }

    /// What the pane's header and its stack strip call it.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed
    }

    func reload() {
        failure = nil
        if webView.url == nil { webView.load(URLRequest(url: url)) } else { webView.reload() }
    }

    func openInBrowser() { UmiWebPanes.openInBrowser(webView.url ?? url, from: pane) }

    // MARK: A hosted page's state and switch

    /// A message from the page: kept only when it comes from this page's own origin in the main
    /// frame and has the expected shape; anything else is ignored.
    func received(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let origin,
              UmiHostedPage.origin(of: message.frameInfo.securityOrigin) == origin,
              let state = UmiHostedPage.State(message: message.body) else { return }
        if hosted != state { hosted = state }
    }

    /// Show the hosted page's preview or source: the page switches itself.
    func setMode(_ mode: UmiHostedPage.Mode) {
        guard hosted?.hasModes == true else { return }
        webView.evaluateJavaScript(UmiHostedPage.setModeScript(mode), completionHandler: nil)
    }

    func toggleMode() {
        guard let hosted, hosted.hasModes else { return }
        setMode(hosted.mode == .preview ? .source : .preview)
    }

    /// The page's file on GitHub, in the default browser; only an https://github.com address.
    func openGitHub() {
        guard let link = hosted?.github, UmiHostedPage.isGitHub(link) else { return }
        UmiWebPanes.openInBrowser(link, from: pane)
    }

    // MARK: Navigation: this origin stays, everything else goes to the browser

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.allow) }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let scheme = target.scheme?.lowercased() ?? ""
        if !mainFrame || scheme == "about" || scheme == "blob" || scheme == "data" {
            return decisionHandler(.allow)
        }
        if let origin, UmiWebPanes.origin(of: target) == origin { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        UmiWebPanes.openInBrowser(target, from: pane)
    }

    /// `target="_blank"` and `window.open`: this origin loads here, others in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = action.request.url {
            if let origin, UmiWebPanes.origin(of: target) == origin {
                webView.load(action.request)
            } else {
                UmiWebPanes.openInBrowser(target, from: pane)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil }

    /// A new document: what the last one said about itself no longer holds.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { hosted = nil }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let error = error as NSError
        // A navigation cancelled by this page's own policy (a link sent to the browser) isn't a failure.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }   // frame load interrupted
        failure = error.localizedDescription
    }

    // MARK: The page's own dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private func present(_ alert: NSAlert, then done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }
}

/// A web pane's web view: taking keyboard focus makes its pane the focused one.
final class UmiWebView: WKWebView {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            MainActor.assumeIsolated {
                if let pane = UmiWebPanes.shared.open.first(where: { $0.page.webView === self })?.pane {
                    UmiFilePanes.shared.editorFocused(pane: pane)
                }
            }
        }
        return result
    }
}

// MARK: - The view over a web pane

/// Drawn over a web pane's terminal: a header (UmiWebPaneHeader) and the page.
struct UmiWebPaneOverlay: View {
    let surfaceView: Ghostty.SurfaceView
    let background: Color
    /// False while the pane is in a stack: the stack's row is its header then (M-7, E-24).
    var showsHeader = true
    @ObservedObject private var web = UmiWebPanes.shared

    var body: some View {
        if let page = web.page(of: surfaceView) {
            UmiFilePaneHosted(content: AnyView(UmiWebPaneContent(surfaceView: surfaceView, page: page,
                                                                  background: background, showsHeader: showsHeader)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UmiWebPaneContent: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var page: UmiWebPage
    let background: Color
    let showsHeader: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { UmiWebPaneHeader(surfaceView: surfaceView, page: page) }
            ZStack {
                UmiWebPageView(page: page, pane: surfaceView)
                if let failure = page.failure {
                    VStack(spacing: 10) {
                        Text("Couldn't load the page").font(UmiTheme.uiFont).foregroundColor(UmiTheme.textPrimary)
                        Text(failure).font(UmiTheme.uiFont).foregroundColor(UmiTheme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Reload") { page.reload() }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                }
            }
        }
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Web page")
    }
}

/// A web pane's header, the same row as a file pane's (E-24): the grip, a globe and the page's
/// title, or for a hosted page "folder / name" from what it says; on the right a hosted page's
/// Preview / Source and GitHub, then Reload, Open in Browser and close.
private struct UmiWebPaneHeader: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var page: UmiWebPage

    var body: some View {
        UmiPaneHeaderBar(surfaceView: surfaceView) {
            Image(systemName: "globe").font(.system(size: 10))
                .foregroundColor(UmiTheme.textSecondary)
            if let hosted = page.hosted {
                let parts = UmiPathTitle.split(hosted.path)
                UmiPathTitle(folder: parts.folder, name: parts.name, dirty: hosted.dirty,
                             help: page.url.absoluteString)
            } else {
                Text(page.displayTitle)
                    .font(UmiTheme.uiFont)
                    .foregroundColor(UmiTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(page.url.absoluteString)
            }
            if page.loading { ProgressView().controlSize(.mini) }
        } trailing: {
            UmiWebPaneControls(surfaceView: surfaceView, page: page)
        }
    }
}

/// The right side of a web pane's header, also shown in its stack's row (M-7): a hosted page's
/// Preview / Source and GitHub, then Reload, Open in Browser and close.
struct UmiWebPaneControls: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var page: UmiWebPage

    var body: some View {
        if let hosted = page.hosted {
            if hosted.hasModes {
                UmiPreviewSourceSwitch(isPreview: hosted.mode == .preview) { page.setMode($0 ? .preview : .source) }
            }
            if hosted.github != nil {
                UmiPaneHeaderButton(symbol: "arrow.triangle.branch", help: "Open on GitHub", label: "GitHub") {
                    page.openGitHub()
                }
            }
        }
        UmiPaneHeaderButton(symbol: "arrow.clockwise", help: "Reload (⌘R)", label: "Reload") { page.reload() }
        UmiPaneHeaderButton(symbol: "arrow.up.forward.square", help: "Open in Browser", label: "Open in Browser") {
            page.openInBrowser()
        }
        UmiPaneHeaderButton(symbol: "xmark", help: "Close (⌘W)", label: "Close \(page.displayTitle)", size: 8) {
            UmiFilePanes.closePane(surfaceView)
        }
    }
}

/// Holds the page's web view; ⌘W closes the pane and ⌘R reloads, every other key goes to the page.
final class UmiWebContainerView: NSView {
    var closePane: (() -> Void)?
    var reload: (() -> Void)?
    weak var page: UmiWebPage?

    /// ⇧⌘M (View ▸ Toggle Markdown Preview) on a hosted page with both views.
    @objc func toggleMarkdownPreview(_ sender: Any?) {
        if page?.hosted?.hasModes == true { page?.toggleMode() } else { NSSound.beep() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "w"):
            closePane?()
            return true
        case ([.command], "r"):
            reload?()
            return true
        case ([.command], "e") where page?.hosted?.hasModes == true,
             ([.command, .shift], "m") where page?.hosted?.hasModes == true:
            // As in a file pane (E-2): a hosted page's Preview / Source.
            page?.toggleMode()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private struct UmiWebPageView: NSViewRepresentable {
    let page: UmiWebPage
    let pane: Ghostty.SurfaceView

    func makeNSView(context: Context) -> UmiWebContainerView {
        let container = UmiWebContainerView()
        update(container)
        return container
    }

    func updateNSView(_ container: UmiWebContainerView, context: Context) { update(container) }

    private func update(_ container: UmiWebContainerView) {
        container.closePane = { [weak pane] in if let pane { UmiFilePanes.closePane(pane) } }
        container.reload = { [weak page] in page?.reload() }
        container.page = page
        let web = page.webView
        guard web.superview !== container else { return }
        // The page's one web view moves into this pane's view (a pane moved, a window rebuilt).
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - Hosted pages

/// What passes between Umi and a page from a listed origin that knows it can be hosted (the agent
/// server's file page, `/o?p=PATH`). Umi marks the page as hosted before its own scripts run
/// (`window.umiHosted` and `<html data-umi="1">`), so the page hides its own header row; the page
/// posts its state to the `umi` message handler on load and on every change, and Umi's header
/// shows that state and calls
/// `window.umiPage.setMode('preview' | 'source')` to switch. Umi never navigates on what a page
/// says; it only opens the GitHub address in the browser when the user asks.
enum UmiHostedPage {
    static let handlerName = "umi"
    /// Run before the page's own scripts. The document element may not exist yet at that moment,
    /// so the page also reads `window.umiHosted` and marks itself.
    static let marker = "window.umiHosted = true; if (document.documentElement) document.documentElement.dataset.umi = '1';"

    enum Mode: String { case preview, source }

    struct State: Equatable {
        /// The file's path, as the page names it ("desk/AGENTS.md").
        let path: String
        let mode: Mode
        let hasModes: Bool
        let github: URL?
        let dirty: Bool

        /// `{path, mode, hasModes, github, dirty}`; nil for anything else (a missing or extra-typed
        /// field, an unknown mode, a GitHub address that isn't https://github.com).
        init?(message body: Any) {
            guard let dict = body as? [String: Any],
                  let path = dict["path"] as? String, Self.validPath(path),
                  let raw = dict["mode"] as? String, let mode = Mode(rawValue: raw),
                  let hasModes = UmiHostedPage.bool(dict["hasModes"]),
                  let dirty = UmiHostedPage.bool(dict["dirty"]) else { return nil }
            var github: URL?
            switch dict["github"] {
            case nil, is NSNull: github = nil
            case let text as String:
                guard text.count <= 2048, let url = URL(string: text), UmiHostedPage.isGitHub(url) else { return nil }
                github = url
            default: return nil
            }
            self.init(path: path, mode: mode, hasModes: hasModes, github: github, dirty: dirty)
        }

        init(path: String, mode: Mode, hasModes: Bool, github: URL?, dirty: Bool) {
            self.path = path
            self.mode = mode
            self.hasModes = hasModes
            self.github = github
            self.dirty = dirty
        }

        private static func validPath(_ path: String) -> Bool {
            !path.isEmpty && path.count <= 1024
                && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }

    /// A JavaScript boolean (not a number that happens to be 0 or 1).
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func isGitHub(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    static func setModeScript(_ mode: Mode) -> String {
        "window.umiPage && window.umiPage.setMode && window.umiPage.setMode('\(mode.rawValue)');"
    }

    /// `scheme://host[:port]` of a frame's origin, as `UmiWebPanes.origin(of:)` writes it.
    static func origin(of security: WKSecurityOrigin) -> String? {
        var parts = URLComponents()
        parts.scheme = security.protocol
        parts.host = security.host
        if security.port != 0 { parts.port = security.port }
        return parts.url.flatMap(UmiWebPanes.origin(of:))
    }

    /// The message handler; holds its page weakly (the web view's configuration keeps the handler).
    final class Relay: NSObject, WKScriptMessageHandler {
        weak var page: UmiWebPage?
        init(page: UmiWebPage) { self.page = page }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { page?.received(message) }
        }
    }
}
