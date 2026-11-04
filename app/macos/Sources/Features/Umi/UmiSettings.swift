import AppKit

/// Settings (⌘,): the user's config file (`UmiPaths.userConfigFile`, by default
/// ~/.config/umi/config) opens in Umi's editor, as Ghostty opens its own config file. A missing
/// file is made, empty, first. Shortcuts are changed with `umi shortcuts` (L-17).
@MainActor
enum UmiSettings {
    static func openConfigFile() {
        let path = UmiPaths.userConfigFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        UmiEditor.openFromSystem(URL(fileURLWithPath: path), inCurrentTab: true)
    }
}
