# Trimmed copy of Ghostty's macOS embedding

These files are the minimum of Ghostty's own Swift wrapper that umi-next needs to embed
libghostty terminal views. They come from this repository's `app/macos/Sources/` (Ghostty
upstream at `35a81a980` plus Umi's fork), cut down and with every Umi hook removed:

| Here | Upstream |
|---|---|
| `GhosttyRuntime.swift` | `Ghostty/Ghostty.App.swift` (app init, runtime callbacks, wakeup → tick, clipboard), `Ghostty/Ghostty.Config.swift` (`loadConfig`) |
| `TerminalSurfaceView.swift` | `Ghostty/Surface View/SurfaceView_AppKit.swift` (keyboard incl. `NSTextInputClient`, mouse, scroll, resize, focus), `Ghostty/Surface View/SurfaceView.swift` (`SurfaceConfiguration.withCValue`) |
| `Input.swift` | `Ghostty/Ghostty.Input.swift` (mods), `Ghostty/NSEvent+Extension.swift`, `Helpers/KeyboardLayout.swift`, `Helpers/Extensions/String+Extension.swift`, `Helpers/Extensions/NSPasteboard+Extension.swift`, the surrogate helpers at the end of `SurfaceView_AppKit.swift` |

Left out: SwiftUI wrappers, the scroll view and scrollbar, the search bar (the runtime
passes Ghostty's search actions on; the page draws the bar), inspector, notifications, QuickLook, services, drag and drop, accessibility, secure input, key tables and sequences,
clipboard confirmation dialogs (OSC 52 reads and writes that need confirmation are refused;
paste confirmations are accepted).
