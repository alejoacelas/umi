import Foundation

/// The agents Umi's plugin reports: Claude Code and Codex, run by the user in Umi's panes.
enum UmiAgentKind: String, Codable {
    case claude, codex
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
