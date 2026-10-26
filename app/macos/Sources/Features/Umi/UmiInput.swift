import AppKit
import GhosttyKit
import UserNotifications

/// Sending input to panes and reading their output (T-1, T-2).
@MainActor
enum UmiInput {
    /// Send text with paste semantics (bracketed paste when the program asked for it),
    /// optionally followed by Enter.
    static func send(text: String, to pane: Ghostty.SurfaceView, enter: Bool) async throws {
        guard let surface = pane.surfaceModel else { throw UmiError.failed("the pane has no terminal") }
        if !text.isEmpty {
            surface.sendText(text)
        }
        if enter {
            // Let the program take in a (bracketed) paste before Enter, or some TUIs treat
            // Enter as part of the paste.
            if !text.isEmpty { try? await Task.sleep(nanoseconds: 60_000_000) }
            try send(keys: ["enter"], to: pane)
        }
    }

    static func send(keys: [String], to pane: Ghostty.SurfaceView) throws {
        guard let surface = pane.surfaceModel else { throw UmiError.failed("the pane has no terminal") }
        let parsed = try keys.map(parseKey)
        for (key, mods, text, codepoint) in parsed {
            let translation = surface.keyTranslationMods(mods)
            let consumed = mods.subtracting(translation.subtracting(.shift))
            _ = consumed
            surface.sendKeyEvent(.init(key: key, action: .press, text: text, mods: mods,
                                       consumedMods: text == nil ? [] : mods.intersection(.shift),
                                       unshiftedCodepoint: codepoint))
            surface.sendKeyEvent(.init(key: key, action: .release, mods: mods, unshiftedCodepoint: codepoint))
        }
    }

    /// "ctrl+c", "shift+tab", "enter", "esc", "up", "f5", "a", …
    static func parseKey(_ spec: String) throws -> (Ghostty.Input.Key, Ghostty.Input.Mods, String?, UInt32) {
        var mods: Ghostty.Input.Mods = []
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let keyName = parts.popLast(), !keyName.isEmpty else {
            throw UmiError.badRequest("invalid key \"\(spec)\"")
        }
        for part in parts {
            switch part.lowercased() {
            case "ctrl", "control", "c": mods.insert(.ctrl)
            case "shift", "s": mods.insert(.shift)
            case "alt", "opt", "option", "meta", "m": mods.insert(.alt)
            case "cmd", "command", "super": mods.insert(.super)
            default: throw UmiError.badRequest("unknown modifier \"\(part)\" in \"\(spec)\"")
            }
        }

        let aliases: [String: String] = [
            "esc": "escape", "return": "enter", "ret": "enter", "cr": "enter", "nl": "enter",
            "up": "arrowUp", "down": "arrowDown", "left": "arrowLeft", "right": "arrowRight",
            "bs": "backspace", "del": "delete", "pgup": "pageUp", "pgdn": "pageDown",
            "pageup": "pageUp", "pagedown": "pageDown", "spc": "space",
            "-": "minus", "=": "equal", ",": "comma", ".": "period", "/": "slash",
            ";": "semicolon", "'": "quote", "[": "bracketLeft", "]": "bracketRight",
            "\\": "backslash", "`": "backquote", " ": "space",
        ]
        var name = aliases[keyName.lowercased()] ?? keyName
        var text: String?
        var codepoint: UInt32 = 0
        if name.count == 1, let c = name.first {
            if c.isNumber {
                name = "digit\(c)"
                text = String(c)
                codepoint = c.unicodeScalars.first.map { $0.value } ?? 0
            } else if c.isLetter, c.isASCII {
                if c.isUppercase { mods.insert(.shift) }
                let lower = c.lowercased()
                name = lower
                codepoint = lower.unicodeScalars.first.map { $0.value } ?? 0
                text = mods.contains(.shift) ? lower.uppercased() : lower
            }
        } else if let original = aliases[keyName.lowercased()], keyName.count == 1 {
            text = keyName
            codepoint = keyName.unicodeScalars.first.map { $0.value } ?? 0
            name = original
        }
        if name == "space" { text = " "; codepoint = 0x20 }
        // Control and command chords are encoded from the key, not text.
        if mods.contains(.ctrl) || mods.contains(.super) { text = nil }

        let lowered = name.lowercased()
        guard let key = Ghostty.Input.Key(rawValue: name)
            ?? allKeyNames.first(where: { $0.lowercased() == lowered }).flatMap(Ghostty.Input.Key.init(rawValue:)) else {
            throw UmiError.badRequest("unknown key \"\(keyName)\" (try enter, esc, tab, backspace, up, ctrl+c, …)")
        }
        // Shifted digits and punctuation type what the keyboard types with Shift
        // ("shift+1" is "!" on a US keyboard).
        if mods.contains(.shift), let typed = text, typed.count == 1, let c = typed.first, !c.isLetter, c != " " {
            text = key.keyCode.flatMap { KeyboardLayout.character(for: $0, modifiers: .shift) }.map(String.init)
                ?? usShifted[c].map(String.init) ?? typed
        }
        return (key, mods, text, codepoint)
    }

    private static let usShifted: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", ",": "<", ".": ">", "/": "?", ";": ":", "'": "\"", "[": "{", "]": "}",
        "\\": "|", "`": "~",
    ]

    private static let allKeyNames: [String] = {
        var names = ["enter", "escape", "tab", "backspace", "delete", "space", "home", "end", "pageUp", "pageDown",
                     "arrowUp", "arrowDown", "arrowLeft", "arrowRight", "insert"]
        for n in 1...24 { names.append("f\(n)") }
        return names
    }()

    /// The pane's text: the screen (the active area, wherever the user scrolled to) or
    /// everything in scrollback, optionally only the last `lines` lines. With `outputOnly`,
    /// the shell's prompt and the typed command lines are left out (when the shell marks
    /// them), so a pattern never matches the command that is about to print it.
    static func read(_ pane: Ghostty.SurfaceView, scrollback: Bool, lines: Int?, outputOnly: Bool = false) -> String {
        guard let surface = pane.surface else { return "" }
        var text = ghostty_text_s()
        let tag = scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_ACTIVE
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        let ok = outputOnly
            ? ghostty_surface_read_output_text(surface, sel, &text)
            : ghostty_surface_read_text(surface, sel, &text)
        guard ok else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return tidy(String(cString: text.text), lines: lines)
    }

    /// The program output in the last `rows` rows of the screen, scrollback included.
    static func readOutputTail(_ pane: Ghostty.SurfaceView, rows: Int) -> String {
        guard let surface = pane.surface, rows > 0 else { return "" }
        var text = ghostty_text_s()
        guard ghostty_surface_read_output_tail(surface, UInt32(clamping: rows), &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return tidy(String(cString: text.text), lines: nil)
    }

    /// The pane's selected text, if any.
    static func selection(_ pane: Ghostty.SurfaceView) -> String? {
        guard let surface = pane.surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Warp's look in the pane, as the terminal describes it (`debug.blocks`).
    static func blocks(_ pane: Ghostty.SurfaceView) -> [String: Any] {
        guard let surface = pane.surface else { return [:] }
        var text = ghostty_text_s()
        guard ghostty_surface_umi_blocks(surface, &text) else { return [:] }
        defer { ghostty_surface_free_text(surface, &text) }
        let data = Data(bytes: text.text, count: Int(text.text_len))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Bytes the pane's program has written so far.
    static func outputBytes(_ pane: Ghostty.SurfaceView) -> UInt64 {
        guard let surface = pane.surface else { return 0 }
        return ghostty_surface_output_bytes(surface)
    }

    private static func tidy(_ raw: String, lines: Int?) -> String {
        // Trailing blank rows are just empty screen.
        var rows = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var line = line
            while line.last == " " { line = line.dropLast() }
            return line
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        if let lines, lines > 0 { rows = Array(rows.suffix(lines)) }
        return rows.joined(separator: "\n")
    }
}

/// Desktop notifications from panes (T-6).
@MainActor
enum UmiNotify {
    static func post(title: String, body: String?, pane: Ghostty.SurfaceView?) async throws {
        guard !title.isEmpty else { throw UmiError.badRequest("notify needs a title") }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // Ask, but never wait on the person to answer.
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                Task { @MainActor in deliver(title: title, body: body, pane: pane) }
            }
        case .denied:
            UmiEvents.shared.emit("notify.suppressed", ["title": title])
        default:
            deliver(title: title, body: body, pane: pane)
        }
        UmiEvents.shared.emit("notify", ["title": title, "body": body ?? "", "pane": pane?.umiID ?? ""])
    }

    private static func deliver(title: String, body: String?, pane: Ghostty.SurfaceView?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        if let pane {
            content.categoryIdentifier = Ghostty.userNotificationCategory
            content.userInfo = ["surface": pane.id.uuidString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// An image of a window, terminal contents included (T-7).
@MainActor
enum UmiScreenshot {
    static func capture(_ controller: TerminalController, to path: String) async throws {
        guard let window = controller.window, let content = window.contentView else {
            throw UmiError.failed("the window has no content")
        }
        // Let pending layout and terminal rendering settle.
        content.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 120_000_000)

        let bounds = content.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw UmiError.failed("the window has no size")
        }
        content.cacheDisplay(in: bounds, to: rep)

        // Terminal panes draw with Metal; draw each visible pane's own image on top.
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let composed = NSImage(size: bounds.size)
        composed.lockFocus()
        (window.backgroundColor ?? .black).setFill()
        bounds.fill()
        image.draw(in: bounds)
        // (A pane showing a session's read-only view is drawn by its AppKit view, already in the capture.)
        for pane in controller.surfaceTree.root?.leaves() ?? [] where pane.window === window && !pane.isHiddenOrHasHiddenAncestor
            && !UmiAgentUI.shared.isShowingAgent(pane.id) {
            guard let paneImage = pane.terminalImage() else { continue }
            let frame = pane.convert(pane.bounds, to: content)
            paneImage.draw(in: frame)
        }
        // Overlays drawn above the terminals (the palettes) go on top again.
        if controller.palette.isPresented, let overlay = controller.palette.capturedImage(in: content) {
            overlay.image.draw(in: overlay.frame)
        }
        composed.unlockFocus()

        guard let tiff = composed.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw UmiError.failed("couldn't encode the image")
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            throw UmiError.failed("couldn't write \(path): \(error.localizedDescription)")
        }
    }
}

extension Ghostty.SurfaceView {
    /// The terminal's rendered contents, read from its layer (Metal content doesn't show
    /// up in AppKit's view caching).
    func terminalImage() -> NSImage? {
        if let layer, let contents = layer.contents {
            let typeID = CFGetTypeID(contents as CFTypeRef)
            if typeID == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let ci = CIImage(ioSurface: surface)
                let context = CIContext()
                if let cg = context.createCGImage(ci, from: ci.extent) {
                    return NSImage(cgImage: cg, size: bounds.size)
                }
            } else if typeID == CGImage.typeID {
                return NSImage(cgImage: contents as! CGImage, size: bounds.size)
            }
        }
        for sublayer in layer?.sublayers ?? [] {
            if let contents = sublayer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let ci = CIImage(ioSurface: surface)
                if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                    return NSImage(cgImage: cg, size: bounds.size)
                }
            }
        }
        return asImage
    }
}

/// The app's version, as stamped by the release script.
enum UmiVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Release builds are stamped "release"; development builds never update themselves.
    static var isRelease: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UmiBuildKind") as? String) == "release"
    }
}
