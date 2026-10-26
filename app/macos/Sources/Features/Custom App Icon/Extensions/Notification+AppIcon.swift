import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Ghostty -> DockTilePlugin
    /// Umi's own name, so Ghostty's (or Tern's) dock tile plugin doesn't react to Umi's changes.
    static let ghosttyIconDidChange = Notification.Name("dev.umi.app.iconDidChange")
}
