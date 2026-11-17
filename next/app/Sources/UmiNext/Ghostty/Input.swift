// Trimmed from Ghostty's macOS app; see README.md in this folder for the upstream files.
import AppKit
import Carbon
import GhosttyKit
import UniformTypeIdentifiers

enum GhosttyInput {
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// The current keyboard input source, to notice when a key only switched layouts.
    static var keyboardLayoutID: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            return unsafeBitCast(ptr, to: CFString.self) as String
        }
        return nil
    }
}

extension NSEvent {
    /// A Ghostty key event without text (the caller sets text and composing).
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        // Control and command never contribute to the text; everything else is assumed to.
        ev.mods = GhosttyInput.ghosttyMods(modifierFlags)
        ev.consumed_mods = GhosttyInput.ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// The text for a Ghostty key event: control characters and function-key PUA values are
    /// left to Ghostty's key encoder.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

extension String {
    var startsWithASCIIControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// The string as a key event's text, or nil when empty or starting with a control character.
    var keyEventText: String? {
        guard !isEmpty, !startsWithASCIIControlCharacter else { return nil }
        return self
    }
}

struct LeadSurrogate {
    let char: UTF16Char
    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let c = text.character(at: 0)
        guard UTF16.isLeadSurrogate(c) else { return nil }
        char = c
    }
    func encode(trail: TrailSurrogate) -> String { String(decoding: [char, trail.char], as: UTF16.self) }
}

struct TrailSurrogate {
    let char: UTF16Char
    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let c = text.character(at: 0)
        guard UTF16.isTrailSurrogate(c) else { return nil }
        char = c
    }
}

extension NSPasteboard {
    static let ghosttySelection = NSPasteboard(name: .init("dev.umi.next.selection"))

    static func ghostty(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return ghosttySelection
        default: return nil
        }
    }

    /// File URLs as escaped paths, else any string.
    func opinionatedString() -> String? {
        let strings: [String] = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return url.path.replacingOccurrences(of: " ", with: "\\ ")
            }
            return item.string(forType: .string)
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    func ghosttyData(forMime mime: String) -> Data? {
        if mime == "text/plain" { return opinionatedString().map { Data($0.utf8) } }
        guard let type = PasteboardType(mimeType: mime) else { return nil }
        return data(forType: type)
    }

    func ghosttyAvailableMimes() -> [String] {
        var result: [String] = []
        let types = self.types ?? []
        if types.contains(.string) || types.contains(.fileURL) { result.append("text/plain") }
        for t in types {
            if let mime = UTType(t.rawValue)?.preferredMIMEType, mime != "text/plain", !result.contains(mime) {
                result.append(mime)
            }
        }
        return result
    }
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        if mimeType == "text/plain" { self = .string; return }
        if let ut = UTType(mimeType: mimeType) { self.init(ut.identifier) } else { self.init(mimeType) }
    }
}
