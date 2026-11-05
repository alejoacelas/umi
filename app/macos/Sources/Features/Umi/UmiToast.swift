import AppKit
import SwiftUI

/// Warp's success toast (W: `view_components/dismissible_toast.rs`): the terminal's green with the
/// background's color for text and a check, radius 4, padding 8 by 12, at the top centre of the
/// tab's content 16 points down, for 4 seconds.
@MainActor
enum UmiToast {
    private static var shown: (view: NSView, timer: Timer)?
    /// The last toast's text and when it was shown (for checks).
    private(set) static var last: (text: String, at: Date)?
    static let duration: TimeInterval = 4

    static func show(_ text: String, near pane: Ghostty.SurfaceView?) {
        last = (text, Date())
        guard let pane, let window = pane.window, let content = window.contentView,
              let controller = UmiTopology.locate(pane)?.window else { return }
        dismiss()
        let green = UmiCodeLook.palette()[2]
        let ink = UmiCodeLook.background
        let toast = HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 13))
        }
        .foregroundColor(Color(ink))
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(green)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(Color(green.blended(withFraction: 0.2, of: .black) ?? green), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        let hosting = NSHostingView(rootView: toast)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting, positioned: .above, relativeTo: nil)
        // The tab's content: the window less the sidebar, when it shows.
        let sidebar = UmiState.shared.sidebarVisible ? controller.sidebarWidth : 0
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 16),
            hosting.centerXAnchor.constraint(equalTo: content.centerXAnchor, constant: sidebar / 2),
        ])
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated { dismiss() }
        }
        shown = (hosting, timer)
    }

    static func dismiss() {
        shown?.timer.invalidate()
        shown?.view.removeFromSuperview()
        shown = nil
    }

    static var isShowing: Bool { shown != nil }
}
