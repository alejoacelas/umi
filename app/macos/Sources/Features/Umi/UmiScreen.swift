import CoreGraphics

/// Whether anyone can see the screen right now.
enum UmiScreen {
    /// The session's screen is locked, or the main display is asleep.
    static var isUnavailable: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
