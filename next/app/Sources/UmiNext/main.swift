import AppKit
import GhosttyKit

// Terminals must not inherit the identity of an Umi pane this was started from.
for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("UMI_") && !key.hasPrefix("UMI_NEXT_") {
    unsetenv(key)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write("umi-next: ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

// One UI per state directory: two would fight over layout.json.
let lockFD = open(Paths.stateDir + "/ui.lock", O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write("umi-next: another UI is running for \(Paths.stateDir)\n".data(using: .utf8)!)
    exit(2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: GhosttyRuntime!
    var main: MainWindowController!
    var debug: DebugServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        runtime = GhosttyRuntime(configFiles: Paths.terminalConfigFiles)
        main = MainWindowController(runtime: runtime)
        main.show()
        if Paths.debugEnabled { debug = DebugServer(controller: main) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Reload Web Layer", action: #selector(AppDelegate.reloadWeb(_:)), keyEquivalent: "R").keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Umi next", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        menu.addItem(winItem)
        NSApp.windowsMenu = win
        return menu
    }

    @objc func reloadWeb(_ sender: Any?) { main.reloadWeb() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
