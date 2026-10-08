import AppKit

/// What Tern does as the app goes away, however it is asked to (⌘Q, a quit Apple event,
/// SIGTERM, an update).
@MainActor
enum TernAppLifecycle {
    private static var done = false

    static func willTerminate() {
        guard !done else { return }
        done = true
        // Never lose editor edits: save them, or keep a recovery copy (E-3).
        TernEditor.saveAllDirtyDocuments()
        // Windows, tabs, pins and names come back next time (R-3).
        TernPersistence.shared.saveAllNow()
        // A downloaded update installs now that the app is quitting (I-4).
        TernUpdater.shared.installOnQuitIfStaged()
        TernControlServer.shared.stop()
    }
}
