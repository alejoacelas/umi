import AppKit
import Combine
import SwiftUI

// A managed session's view, drawn over its pane's terminal (AP-1, AP-10).
//
// AppKit text views throughout: the transcript is one read-only text view (selectable,
// copyable, and read whole by accessibility), the composer is a text view that takes
// Enter to send, Shift+Enter for a newline and Esc to interrupt.

/// What the split tree draws over a leaf.
struct TernAgentPaneOverlay: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject private var ui = TernAgentUI.shared

    var body: some View {
        if let session = ui.attachments[surfaceView.id] {
            if ui.showingTerminal.contains(surfaceView.id) {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            ui.toggleTerminal(surfaceView)
                        } label: {
                            Label("Show agent", systemImage: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(TernTheme.chromeFill))
                        .padding(6)
                        .help("Show the managed session in this pane again")
                    }
                    Spacer()
                }
            } else {
                TernAgentPaneRepresentable(surfaceView: surfaceView, sessionID: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct TernAgentPaneRepresentable: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView
    let sessionID: String

    func makeNSView(context: Context) -> TernAgentPaneView {
        TernAgentPaneView.view(for: surfaceView, sessionID: sessionID)
    }

    func updateNSView(_ view: TernAgentPaneView, context: Context) {
        view.surface = surfaceView
    }

    /// Always exactly the pane's size, whatever its content would like.
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TernAgentPaneView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }

    static func dismantleNSView(_ view: TernAgentPaneView, coordinator: ()) {
        view.removeFromSuperview()
    }
}

/// A grip that drags the pane, like a terminal pane's grab handle (AP-2, M-4).
private struct TernAgentDragHandle: View {
    let surfaceView: Ghostty.SurfaceView
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hovering ? TernTheme.textSecondary : TernTheme.textTertiary)
            Ghostty.SurfaceDragSource(surfaceView: surfaceView, isDragging: $dragging, isHovering: $hovering)
        }
        .frame(width: 22, height: 18)
        .help("Drag to move this pane")
    }
}

@MainActor
final class TernAgentPaneView: NSView, NSTextViewDelegate {
    let sessionID: String
    weak var surface: Ghostty.SurfaceView? {
        didSet { if surface !== oldValue { rebuildDragHandle() } }
    }
    private let model: TernAgentViewModel
    private var cancellables: Set<AnyCancellable> = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let interruptButton = NSButton(title: "Interrupt", target: nil, action: nil)
    private let terminalButton = NSButton(title: "Terminal", target: nil, action: nil)
    private var dragHost: NSHostingView<AnyView>?
    private let headerStack = NSStackView()

    private let transcriptScroll = NSScrollView()
    let transcript = TernTranscriptView()
    private let requestsStack = NSStackView()
    private let queuedLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let composerScroll = NSScrollView()
    let composer = TernComposerView()
    private let placeholder = NSTextField(labelWithString: "")
    private var composerHeight: NSLayoutConstraint?

    private var lastItemsVersion = -1
    private var renderedRequests: [String] = []

    /// One view per pane, reused when the pane moves (the split tree rebuilds its views), so
    /// the scroll position and composer survive.
    private static var cache: [UUID: TernAgentPaneView] = [:]

    static func view(for surface: Ghostty.SurfaceView, sessionID: String) -> TernAgentPaneView {
        if let cached = cache[surface.id], cached.sessionID == sessionID {
            cached.surface = surface
            return cached
        }
        let view = TernAgentPaneView(sessionID: sessionID, surface: surface)
        cache[surface.id] = view
        if cache.count > 64 {
            let live = Set(TernTopology.allSurfaces.map(\.id))
            cache = cache.filter { live.contains($0.key) }
        }
        return view
    }

    init(sessionID: String, surface: Ghostty.SurfaceView) {
        self.sessionID = sessionID
        self.surface = surface
        self.model = TernAgentUI.shared.model(for: sessionID)
        super.init(frame: .zero)
        build()
        rebuildDragHandle()
        model.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            guard let self, let snapshot else { return }
            MainActor.assumeIsolated { self.render(snapshot) }
        }.store(in: &cancellables)
        model.$removed.receive(on: DispatchQueue.main).sink { [weak self] removed in
            guard let self, removed else { return }
            MainActor.assumeIsolated {
                self.statusLabel.stringValue = "this session was removed"
                self.composer.isEditable = false
            }
        }.store(in: &cancellables)
        model.$expanded.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.lastItemsVersion = -1
                if let snapshot = self.model.snapshot { self.render(snapshot) }
            }
        }.store(in: &cancellables)
        if let snapshot = model.snapshot { render(snapshot) }
        TernAgentUI.shared.registerComposer(composer, for: surface.id)
        composer.string = TernAgentUI.shared.drafts[sessionID] ?? ""
        updatePlaceholder()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: Layout

    private func build() {
        wantsLayer = true
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent session")

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 7),
                                     statusDot.heightAnchor.constraint(equalToConstant: 7)])
        for button in [interruptButton, terminalButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
        }
        interruptButton.action = #selector(interruptPressed)
        interruptButton.toolTip = "Interrupt the running turn (Esc)"
        terminalButton.action = #selector(terminalPressed)
        terminalButton.toolTip = "Show the shell in the session's folder"

        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 8)
        headerStack.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        headerStack.distribution = .fill
        for view in [statusDot, titleLabel, spacer, interruptButton, terminalButton] { headerStack.addArrangedSubview(view) }
        // A narrow pane truncates the title instead of growing past its edge.
        headerStack.setHuggingPriority(.init(1), for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.init(10), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.init(20), for: .horizontal)
        for button in [interruptButton, terminalButton] {
            button.setContentCompressionResistancePriority(.init(30), for: .horizontal)
        }

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 12, height: 8)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.delegate = self
        transcript.unregisterDraggedTypes()
        // Links (tool lines that expand) keep their own colors.
        transcript.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        transcript.setAccessibilityLabel("Transcript")
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder

        requestsStack.orientation = .vertical
        requestsStack.alignment = .leading
        requestsStack.spacing = 8
        requestsStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        queuedLabel.font = .systemFont(ofSize: 11)
        queuedLabel.isHidden = true
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        composer.isRichText = false
        composer.allowsUndo = true
        composer.font = .systemFont(ofSize: 13)
        composer.drawsBackground = false
        composer.textContainerInset = NSSize(width: 6, height: 6)
        composer.isVerticallyResizable = true
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.minSize = .zero
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.delegate = self
        composer.unregisterDraggedTypes()
        composer.owner = self
        composer.setAccessibilityLabel("Message the agent")
        composerScroll.documentView = composer
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.drawsBackground = false
        composerScroll.borderType = .noBorder
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 8

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        for label in [queuedLabel, errorLabel] {
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        placeholder.isEditable = false
        placeholder.isSelectable = false
        placeholder.setAccessibilityElement(false)

        for view in [headerStack, statusLabel, transcriptScroll, requestsStack, queuedLabel, errorLabel, composerScroll, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let height = composerScroll.heightAnchor.constraint(equalToConstant: 34)
        composerHeight = height
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            transcriptScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            requestsStack.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 4),
            requestsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            requestsStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            queuedLabel.topAnchor.constraint(equalTo: requestsStack.bottomAnchor, constant: 4),
            queuedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            queuedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            errorLabel.topAnchor.constraint(equalTo: queuedLabel.bottomAnchor, constant: 2),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            composerScroll.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 4),
            composerScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            composerScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            composerScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            height,

            placeholder.leadingAnchor.constraint(equalTo: composerScroll.leadingAnchor, constant: 11),
            placeholder.centerYAnchor.constraint(equalTo: composerScroll.topAnchor, constant: 17),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: composerScroll.trailingAnchor, constant: -8),
        ])
        applyColors()
    }

    override func layout() {
        super.layout()
        // Text views wrap at their scroll view's width.
        for (scroll, text) in [(transcriptScroll, transcript as NSTextView), (composerScroll, composer as NSTextView)] {
            let width = scroll.contentSize.width
            if abs(text.frame.width - width) > 0.5 {
                text.setFrameSize(NSSize(width: width, height: max(text.frame.height, scroll.contentSize.height)))
            }
        }
    }

    private func rebuildDragHandle() {
        dragHost?.removeFromSuperview()
        dragHost = nil
        guard let surface else { return }
        let host = NSHostingView(rootView: AnyView(TernAgentDragHandle(surfaceView: surface)))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerStack.insertArrangedSubview(host, at: 0)
        dragHost = host
    }

    private func applyColors() {
        let ink = TernTheme.textNSColor
        titleLabel.textColor = ink
        statusLabel.textColor = ink.withAlphaComponent(0.55)
        queuedLabel.textColor = ink.withAlphaComponent(0.5)
        placeholder.textColor = ink.withAlphaComponent(0.35)
        composer.textColor = ink
        composer.insertionPointColor = TernTheme.accentNSColor
        interruptButton.contentTintColor = ink.withAlphaComponent(0.7)
        terminalButton.contentTintColor = ink.withAlphaComponent(0.7)
        composerScroll.layer?.backgroundColor = ink.withAlphaComponent(TernTheme.isLight ? 0.05 : 0.06).cgColor
        layer?.backgroundColor = TernAgentPaneView.background.cgColor
    }

    /// The pane's background: the terminal's own, so the pane blends in (S-1).
    static var background: NSColor {
        if let ghostty = TernLayout.ghostty {
            return NSColor(ghostty.config.backgroundColor)
        }
        return NSColor.windowBackgroundColor
    }

    // MARK: Rendering

    private func render(_ snapshot: TernAgentSnapshot) {
        applyColors()
        titleLabel.stringValue = snapshot.name
        let kind = snapshot.kind == .claude ? "Claude" : "Codex"
        var status = "\(kind) · \(snapshot.status)"
        if !snapshot.activity.isEmpty, snapshot.activity != snapshot.status { status += " · \(snapshot.activity)" }
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        statusDot.layer?.backgroundColor = Self.color(for: snapshot.status).cgColor
        interruptButton.isHidden = snapshot.status != "working" && snapshot.status != "needs_input"
        setAccessibilityValue("\(snapshot.name): \(snapshot.status)")

        if snapshot.version != lastItemsVersion {
            lastItemsVersion = snapshot.version
            renderTranscript(snapshot)
        }
        renderRequests(snapshot.requests)
        if snapshot.queued.isEmpty {
            queuedLabel.isHidden = true
        } else {
            queuedLabel.isHidden = false
            queuedLabel.stringValue = "Queued (\(snapshot.queued.count)): "
                + snapshot.queued.map { TernAgentText.oneLine($0, max: 80) }.joined(separator: " · ")
        }
    }

    static func color(for status: String) -> NSColor {
        switch status {
        case "working", "starting": return TernTheme.accentNSColor
        case "needs_input": return .systemOrange
        case "error": return .systemRed
        case "idle": return .systemGreen
        default: return .tertiaryLabelColor
        }
    }

    /// A view that hasn't shown its transcript yet starts at the latest turn.
    private var scrolledOnce = false

    private func renderTranscript(_ snapshot: TernAgentSnapshot) {
        let clip = transcriptScroll.contentView
        let atBottom = clip.bounds.maxY >= (transcript.frame.height - 24)
        let text = TernAgentTranscriptRenderer.render(snapshot.items, expanded: model.expanded, light: TernTheme.isLight)
        transcript.textStorage?.setAttributedString(text)
        transcript.setAccessibilityValue(text.string)
        if atBottom || !scrolledOnce {
            transcript.scrollToEndOfDocument(nil)
            if !scrolledOnce {
                // Once laid out at its real size, too.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.layoutSubtreeIfNeeded()
                    self.transcript.scrollToEndOfDocument(nil)
                    self.scrolledOnce = self.window != nil
                }
            }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil, !scrolledOnce else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.transcript.scrollToEndOfDocument(nil)
            self.scrolledOnce = true
        }
    }

    private func renderRequests(_ requests: [TernAgentRequest]) {
        let ids = requests.map { "\($0.id):\($0.questions.count)" }
        guard ids != renderedRequests else { return }
        renderedRequests = ids
        for view in requestsStack.arrangedSubviews { view.removeFromSuperview() }
        for request in requests {
            let card = TernAgentRequestCard(request: request, sessionID: sessionID)
            requestsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(lessThanOrEqualTo: requestsStack.widthAnchor, constant: -24).isActive = true
        }
    }

    // MARK: Actions

    @objc private func interruptPressed() {
        TernAgentActions.interrupt(sessionID)
    }

    @objc private func terminalPressed() {
        guard let surface else { return }
        TernAgentUI.shared.toggleTerminal(surface)
    }

    func sendComposer() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let session = sessionID
        TernAgentActions.send(session, text: text) { [weak self] error in
            guard let self else { return }
            if let error {
                // The text stays (AP-6).
                self.errorLabel.stringValue = "Not sent: \(error)"
                self.errorLabel.isHidden = false
            } else {
                self.errorLabel.isHidden = true
                if self.composer.string.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    self.composer.string = ""
                    TernAgentUI.shared.drafts[session] = nil
                    self.updatePlaceholder()
                    self.resizeComposer()
                }
            }
        }
    }

    func interruptFromComposer() {
        TernAgentActions.interrupt(sessionID)
    }

    func composerBecameFirstResponder() {
        guard let surface else { return }
        TernAgentUI.shared.composerFocused(pane: surface)
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === composer else { return }
        TernAgentUI.shared.drafts[sessionID] = composer.string
        updatePlaceholder()
        resizeComposer()
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !composer.string.isEmpty
        placeholder.stringValue = "Message \(model.snapshot?.name ?? "the agent") — Enter sends, Shift+Enter adds a line, Esc interrupts"
    }

    private func resizeComposer() {
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + composer.textContainerInset.height * 2
        composerHeight?.constant = min(max(34, used), 160)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard textView === transcript else { return false }
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if raw.hasPrefix("tern-tool:") {
            let id = String(raw.dropFirst("tern-tool:".count))
            if model.expanded.contains(id) { model.expanded.remove(id) } else { model.expanded.insert(id) }
            return true
        }
        if let url = (link as? URL) ?? URL(string: raw) { NSWorkspace.shared.open(url) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let surface else { return }
        TernAgentUI.shared.registerComposer(composer, for: surface.id)
        // A pane that was focused when it moved keeps its keyboard focus.
        if let location = TernTopology.locate(surface), location.window.focusedSurface === surface,
           location.window.window?.firstResponder === surface {
            DispatchQueue.main.async { TernAgentUI.shared.focusComposer(of: surface) }
        }
    }
}

/// The transcript: read-only, selectable, links clickable.
final class TernTranscriptView: NSTextView {
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
}

/// The composer: Enter sends, Shift+Enter adds a line, Esc interrupts.
final class TernComposerView: NSTextView {
    weak var owner: TernAgentPaneView?

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                MainActor.assumeIsolated { owner?.sendComposer() }
            }
            return
        }
        if selector == #selector(cancelOperation(_:)) {
            MainActor.assumeIsolated { owner?.interruptFromComposer() }
            return
        }
        super.doCommand(by: selector)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { MainActor.assumeIsolated { owner?.composerBecameFirstResponder() } }
        return ok
    }
}

/// An approval or question, with buttons (AP-1, AP-10).
@MainActor
final class TernAgentRequestCard: NSView {
    private let request: TernAgentRequest
    private let sessionID: String
    private var fields: [String: NSTextField] = [:]

    init(request: TernAgentRequest, sessionID: String) {
        self.request = request
        self.sessionID = sessionID
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Labels wrap at the card's width.
    override func layout() {
        super.layout()
        let width = max(40, bounds.width - 20)
        var changed = false
        func update(_ view: NSView) {
            if let label = view as? NSTextField, !label.isEditable, label.cell?.wraps == true,
               abs(label.preferredMaxLayoutWidth - width) > 1 {
                label.preferredMaxLayoutWidth = width
                changed = true
            }
            view.subviews.forEach(update)
        }
        update(self)
        if changed { super.layout() }
    }

    private func build() {
        wantsLayer = true
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setClippingResistancePriority(.init(100), for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let ink = TernTheme.textNSColor
        let title = NSTextField(labelWithString: request.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = ink
        stack.addArrangedSubview(title)
        if !request.detail.isEmpty, request.kind == "approval" || request.questions.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: request.detail)
            detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            detail.textColor = ink.withAlphaComponent(0.8)
            detail.preferredMaxLayoutWidth = 360
            stack.addArrangedSubview(detail)
        }
        if request.kind == "question" {
            for (index, question) in request.questions.enumerated() {
                let label = NSTextField(wrappingLabelWithString: "\(index + 1). \(question.question)")
                label.font = .systemFont(ofSize: 12)
                label.textColor = ink
                label.preferredMaxLayoutWidth = 360
                stack.addArrangedSubview(label)
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6
                for option in question.options {
                    let button = TernAgentOptionButton(title: option, target: self, action: #selector(optionPressed(_:)))
                    button.questionID = question.id
                    if question.multiSelect { button.setButtonType(.pushOnPushOff) }
                    button.bezelStyle = .rounded
                    button.controlSize = .small
                    row.addArrangedSubview(button)
                }
                let field = NSTextField(string: "")
                field.placeholderString = question.options.isEmpty ? "Answer" : "Or type an answer"
                field.controlSize = .small
                let minimum = field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
                minimum.priority = .init(200)
                minimum.isActive = true
                field.setAccessibilityLabel("Answer to question \(index + 1)")
                fields[question.id] = field
                row.addArrangedSubview(field)
                stack.addArrangedSubview(row)
            }
            let submit = NSButton(title: "Answer", target: self, action: #selector(submitPressed))
            submit.bezelStyle = .rounded
            submit.controlSize = .small
            var actions = [submit]
            // Codex's questions can only be answered (its protocol has no way to decline them).
            if request.method != "item/tool/requestUserInput" {
                let deny = NSButton(title: "Decline", target: self, action: #selector(denyPressed))
                deny.bezelStyle = .rounded
                deny.controlSize = .small
                actions.append(deny)
            }
            let row = NSStackView(views: actions)
            row.spacing = 6
            stack.addArrangedSubview(row)
        } else {
            var buttons: [NSButton] = []
            if let url = request.url {
                let open = NSButton(title: "Open link", target: self, action: #selector(openPressed))
                open.toolTip = url
                buttons.append(open)
            }
            buttons.append(NSButton(title: request.url != nil ? "Done" : "Allow", target: self, action: #selector(allowPressed)))
            if request.ruleTool != nil {
                buttons.append(NSButton(title: "Always allow", target: self, action: #selector(alwaysPressed)))
            }
            buttons.append(NSButton(title: "Deny", target: self, action: #selector(denyPressed)))
            for button in buttons {
                button.bezelStyle = .rounded
                button.controlSize = .small
            }
            let row = NSStackView(views: buttons)
            row.spacing = 6
            stack.addArrangedSubview(row)
        }
        // However narrow the pane, the card fits: rows clip, labels wrap, fields shrink.
        func relax(_ view: NSView) {
            view.setContentCompressionResistancePriority(.init(100), for: .horizontal)
            if let row = view as? NSStackView { row.setClippingResistancePriority(.init(100), for: .horizontal) }
            if let label = view as? NSTextField, !label.isEditable {
                label.preferredMaxLayoutWidth = 0
                label.cell?.wraps = true
                label.cell?.truncatesLastVisibleLine = true
            }
            for child in view.subviews { relax(child) }
        }
        relax(stack)
    }

    @objc private func optionPressed(_ sender: TernAgentOptionButton) {
        guard let id = sender.questionID, let question = request.questions.first(where: { $0.id == id }) else { return }
        if question.multiSelect {
            // Several options: each click adds or removes one; Answer sends them.
            var chosen = (fields[id]?.stringValue ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let index = chosen.firstIndex(of: sender.title) { chosen.remove(at: index) } else { chosen.append(sender.title) }
            fields[id]?.stringValue = chosen.joined(separator: ", ")
            sender.state = chosen.contains(sender.title) ? .on : .off
            return
        }
        fields[id]?.stringValue = sender.title
        if request.questions.count == 1 { submitPressed() }
    }

    @objc private func submitPressed() {
        var answers: [String: String] = [:]
        for question in request.questions {
            let text = fields[question.id]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            guard !text.isEmpty else {
                NSSound.beep()
                fields[question.id]?.becomeFirstResponder()
                return
            }
            answers[question.id] = text
        }
        TernAgentActions.respond(sessionID, request.id, .answers(answers))
    }

    @objc private func allowPressed() { TernAgentActions.respond(sessionID, request.id, .allow(always: false, message: nil)) }
    @objc private func alwaysPressed() { TernAgentActions.respond(sessionID, request.id, .allow(always: true, message: nil)) }
    @objc private func denyPressed() { TernAgentActions.respond(sessionID, request.id, .deny(message: nil)) }
    @objc private func openPressed() {
        if let url = request.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
    }
}

final class TernAgentOptionButton: NSButton {
    var questionID: String?
}

/// What the pane's controls do: the same operations as the CLI.
enum TernAgentActions {
    static func send(_ sessionID: String, text: String, done: @escaping @MainActor (String?) -> Void) {
        TernAgents.queue.async {
            var error: String?
            if let session = TernAgents.shared.session(id: sessionID) {
                var isDir = ObjCBool(false)
                if !session.live, !(FileManager.default.fileExists(atPath: session.record.cwd, isDirectory: &isDir) && isDir.boolValue) {
                    error = "the session's folder \(session.record.cwd) no longer exists"
                } else {
                    session.enqueue(text: text)
                    session.pump()
                }
            } else {
                error = "the session no longer exists"
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(error) } }
        }
    }

    static func interrupt(_ sessionID: String) {
        TernAgents.queue.async { TernAgents.shared.session(id: sessionID)?.interrupt() }
    }

    static func respond(_ sessionID: String, _ requestID: String, _ answer: TernAgentAnswer) {
        TernAgents.queue.async {
            guard let session = TernAgents.shared.session(id: sessionID), let request = try? session.request(requestID) else { return }
            do {
                try session.respond(request, answer)
            } catch {
                session.notice("Couldn't answer \(request.title.lowercased()): \((error as? TernError)?.message ?? "\(error)")")
            }
        }
    }
}
