import AppKit
import Testing
@testable import Ghostty

/// S-7: a window's tabs keep their order, as in Warp. Selecting never moves a tab; only the user's
/// moves, pins and new tabs change the order. The acceptance suite checks the same through the CLI,
/// with agents finishing turns (tests/test_umi_nav.py, tests/test_live.py).
@MainActor
struct UmiTabOrderTests {
    /// A window of empty tabs (no panes, so no shells), never shown.
    private func makeWindow(tabs count: Int) throws -> (TerminalController, [UmiTab]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.app != nil)
        let tabs = (0..<count).map { _ in UmiTab(tree: .init()) }
        return (TerminalController(ghostty, tabs: tabs, selected: tabs[0]), tabs)
    }

    private func ids(_ tabs: [UmiTab]) -> [UUID] { tabs.map(\.id) }

    @Test func selectingNeverMovesATab() throws {
        let (window, tabs) = try makeWindow(tabs: 4)
        for tab in [tabs[2], tabs[3], tabs[0], tabs[1], tabs[3]] {
            window.selectTab(tab, focus: false)
            #expect(window.selectedTab === tab)
            #expect(ids(window.tabs) == ids(tabs))
        }
    }

    @Test func pinningMovesOnlyThatTab() throws {
        let (window, t) = try makeWindow(tabs: 4)
        window.setPinned(t[2], true)
        #expect(ids(window.tabs) == ids([t[2], t[0], t[1], t[3]]))
        // A pinned tab goes to the end of the pinned tabs…
        window.setPinned(t[3], true)
        #expect(ids(window.tabs) == ids([t[2], t[3], t[0], t[1]]))
        window.selectTab(t[3], focus: false)
        #expect(ids(window.tabs) == ids([t[2], t[3], t[0], t[1]]))
        // …and an unpinned one to the top of the others, as in Warp.
        window.setPinned(t[2], false)
        #expect(ids(window.tabs) == ids([t[3], t[2], t[0], t[1]]))
    }

    @Test func movesStayInTheirPinGroup() throws {
        let (window, t) = try makeWindow(tabs: 4)
        window.setPinned(t[0], true)
        window.moveTab(t[3], to: 0)
        #expect(ids(window.tabs) == ids([t[0], t[3], t[1], t[2]]))
        window.moveTab(t[0], to: 3)
        #expect(ids(window.tabs) == ids([t[0], t[3], t[1], t[2]]))
        window.moveTab(t[3], to: 3)
        #expect(ids(window.tabs) == ids([t[0], t[1], t[2], t[3]]))
    }

    @Test func newTabsOpenAfterTheCurrentTabOrLastInTheBackground() throws {
        let (window, t) = try makeWindow(tabs: 3)
        let afterCurrent = window.ghostty.config.windowNewTabPosition == "current"
        window.selectTab(t[1], focus: false)
        #expect(window.newTabIndex(selecting: true) == (afterCurrent ? 2 : 3))
        #expect(window.newTabIndex(selecting: false) == 3)

        // Below the pinned tabs when the current tab is pinned.
        window.setPinned(t[1], true)
        let new = UmiTab(tree: .init())
        window.insertTab(new, at: window.newTabIndex(selecting: true))
        #expect(ids(window.tabs) == ids(afterCurrent ? [t[1], new, t[0], t[2]] : [t[1], t[0], t[2], new]))
        let background = UmiTab(tree: .init())
        window.insertTab(background, at: window.newTabIndex(selecting: false))
        #expect(window.tabs.last === background)
    }
}
