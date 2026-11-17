import Foundation

enum Paths {
    static let env = ProcessInfo.processInfo.environment

    /// `$UMI_NEXT_STATE_DIR`, else ~/Library/Application Support/Umi-next.
    static let stateDir: String = {
        let dir = env["UMI_NEXT_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() + "/Library/Application Support/Umi-next")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var layoutFile: String { stateDir + "/layout.json" }
    static var debugSocket: String { stateDir + "/debug.sock" }

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
}
