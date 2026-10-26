import AppKit

/// What Tern does as the app goes away, however it is asked to (⌘Q, a quit Apple event,
/// SIGTERM, an update).
@MainActor
enum TernAppLifecycle {
    private static var done = false

    static func willTerminate() {
        guard !done else { return }
        done = true
        // Managed sessions: running turns are interrupted cleanly (they continue at the next
        // launch) and every harness and what it started is stopped (R-1, R-10).
        TernAgents.shared.shutdown(reason: TernUpdater.shared.isQuittingForUpdate ? "update" : "quit")
        // Never lose editor edits: save them, or keep a recovery copy (E-3).
        TernEditor.saveAllDirtyDocuments()
        // Windows, tabs, pins and names come back next time (R-3).
        TernPersistence.shared.saveAllNow()
        // A downloaded update installs now that the app is quitting (I-4).
        TernUpdater.shared.installOnQuitIfStaged()
        TernControlServer.shared.stop()
    }
}


/// Logs undo-group opening and closing when TERN_TRACE_UNDO is set (debugging aid).
enum TernUndoTrace {
    static func install(_ manager: UndoManager) {
        guard ProcessInfo.processInfo.environment["TERN_TRACE_UNDO"] != nil else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup,
                     .NSUndoManagerWillUndoChange, .NSUndoManagerDidUndoChange] {
            center.addObserver(forName: name, object: manager, queue: nil) { note in
                let stack = Thread.callStackSymbols.dropFirst(3).prefix(12)
                    .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
                    .joined(separator: " < ")
                FileHandle.standardError.write("\(Date().timeIntervalSince1970) \(note.name.rawValue) level=\(manager.groupingLevel) \(stack)\n".data(using: .utf8)!)
            }
        }
    }
}
