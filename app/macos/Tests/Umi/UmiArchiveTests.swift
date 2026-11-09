import AppKit
import Testing
@testable import Ghostty

/// The archive (design/archive.md): where archived tabs sit in their window's order, where they come
/// back, what is selected instead, and what the tab keys and moves see. The acceptance suite checks
/// the same through the CLI and the sidebar (tests/test_archive.py).
@MainActor
struct UmiArchiveTests {
    /// A window of empty tabs (no panes, so no shells), never shown.
    private func makeWindow(tabs count: Int) throws -> (TerminalController, [UmiTab]) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        try #require(ghostty.app != nil)
        let tabs = (0..<count).map { _ in UmiTab(tree: .init()) }
        return (TerminalController(ghostty, tabs: tabs, selected: tabs[0]), tabs)
    }

    private func ids(_ tabs: [UmiTab]) -> [UUID] { tabs.map(\.id) }

    @Test func archivedTabsGoLastInTheOrderTheyWereArchived() throws {
        let (window, t) = try makeWindow(tabs: 4)
        UmiArchive.archive(t[2], in: window)
        UmiArchive.archive(t[0], in: window)
        #expect(ids(window.activeTabs) == ids([t[1], t[3]]))
        #expect(ids(window.archivedTabs) == ids([t[2], t[0]]))
        #expect(t[2].archived && t[2].attributes["archived"] == "true")
    }

    @Test func unarchivingGoesToTheTopOfTheUnpinnedTabs() throws {
        let (window, t) = try makeWindow(tabs: 4)
        window.setPinned(t[3], true)
        UmiArchive.archive(t[2], in: window)
        UmiArchive.unarchive(t[2], in: window)
        #expect(ids(window.tabs) == ids([t[3], t[2], t[0], t[1]]))
        #expect(!t[2].archived && t[2].attributes["archived"] == nil)
    }

    @Test func archivingUnpinsAndTakesTheTabOutOfItsGroup() throws {
        let (window, t) = try makeWindow(tabs: 3)
        window.setPinned(t[0], true)
        let group = UmiTabGroup()
        window.sidebarModel.groups.append(group)
        t[1].groupID = group.id
        t[2].groupID = group.id
        UmiArchive.archive(t[0], in: window)
        UmiArchive.archive(t[1], in: window)
        #expect(!t[0].pinned && t[1].groupID == nil && t[2].groupID == group.id)
        UmiArchive.unarchive(t[0], in: window)
        #expect(!t[0].pinned)
    }

    @Test func archivingTheSelectedTabSelectsWhatClosingItWould() throws {
        let (window, t) = try makeWindow(tabs: 4)
        window.selectTab(t[1], focus: false)
        UmiArchive.archive(t[1], in: window)
        #expect(window.selectedTab === t[2])
        window.selectTab(t[3], focus: false)
        UmiArchive.archive(t[3], in: window)
        #expect(window.selectedTab === t[2])
        // The only tab out of the archive stays shown when it goes in.
        UmiArchive.archive(t[0], in: window)
        UmiArchive.archive(t[2], in: window)
        #expect(window.selectedTab === t[2] && t[2].archived)
    }

    @Test func closingATabSelectsANeighbourOutsideTheArchive() throws {
        let (window, t) = try makeWindow(tabs: 4)
        UmiArchive.archive(t[3], in: window)
        window.selectTab(t[2], focus: false)
        window.detachTab(t[2], focusNeighbor: false)
        #expect(window.selectedTab === t[1])
    }

    @Test func tabMovesStopAtTheArchive() throws {
        let (window, t) = try makeWindow(tabs: 3)
        UmiArchive.archive(t[2], in: window)
        // The first tab moving up lands in the archive; an archived tab moving down comes back.
        #expect(UmiNavigation.canMoveTab(t[0], by: -1, in: window))
        #expect(!UmiNavigation.canMoveTab(t[0], by: -1, in: window, throughArchive: false))
        #expect(!UmiNavigation.canMoveTab(t[1], by: 1, in: window), "the last tab can't move down into the archive")
        #expect(UmiNavigation.canMoveTab(t[2], by: 1, in: window) && !UmiNavigation.canMoveTab(t[2], by: -1, in: window))
        #expect(UmiNavigation.moveTab(t[0], by: -1, in: window) && t[0].archived)
        #expect(UmiNavigation.moveTab(t[2], by: 1, in: window) && !t[2].archived)
        #expect(ids(window.tabs) == ids([t[2], t[1], t[0]]))
    }

    @Test func newTabsBesideAnArchivedTabGoLastAmongTheOthers() throws {
        let (window, t) = try makeWindow(tabs: 3)
        UmiArchive.archive(t[1], in: window)
        window.selectTab(t[1], focus: false)
        #expect(window.newTabIndex(selecting: true) == 2)
    }

    @Test func tabArchivedReadsTrueOrFalse() throws {
        let (window, t) = try makeWindow(tabs: 2)
        #expect(UmiAttributes.shared.all(t[0], in: window)["archived"] == "false")
        UmiArchive.archive(t[0], in: window)
        #expect(UmiAttributes.shared.all(t[0], in: window)["archived"] == "true")
    }
}
