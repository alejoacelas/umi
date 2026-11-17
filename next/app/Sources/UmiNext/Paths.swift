import Foundation

enum Paths {
    static let env = ProcessInfo.processInfo.environment

    /// `$UMI_NEXT_STATE_DIR`, else ~/Library/Application Support/<UmiNextStateName> (Umi-next, or
    /// Umi-next-test-NAME for a `build.sh --test NAME` copy).
    static let stateDir: String = {
        let name = (Bundle.main.object(forInfoDictionaryKey: "UmiNextStateName") as? String) ?? "Umi-next"
        let dir = env["UMI_NEXT_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/Library/Application Support/" + name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var layoutFile: String { stateDir + "/layout.json" }
    static var debugSocket: String { stateDir + "/debug.sock" }
    /// The `umi-next` CLI's socket (ControlServer.swift).
    static var uiSocket: String { stateDir + "/ui.sock" }

    /// The repository's next/app folder, recorded in Info.plist by build.sh.
    static let appSourceDir: String? = Bundle.main.object(forInfoDictionaryKey: "UmiNextSourceDir") as? String

    /// The web layer's folder: `$UMI_NEXT_WEB_DIR`, else next/app/web in the repository it was built from.
    static let webDir: String = env["UMI_NEXT_WEB_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? ((appSourceDir ?? "") + "/web")

    /// Terminal config: next/app/terminal.conf, then the user's Umi config (read only).
    static var terminalConfigFiles: [String] {
        var files: [String] = []
        if let dir = appSourceDir { files.append(dir + "/terminal.conf") }
        files.append(NSHomeDirectory() + "/.config/umi/config")
        if let extra = env["UMI_NEXT_TERMINAL_CONFIG"] { files.append(extra) }
        return files
    }

    static var debugEnabled: Bool { env["UMI_NEXT_DEBUG"] == "1" }
    /// UMI_NEXT_OFFSCREEN=1 (with UMI_NEXT_DEBUG=1): the window stays off screen and inactive.
    static var offscreen: Bool { debugEnabled && env["UMI_NEXT_OFFSCREEN"] == "1" }
}
