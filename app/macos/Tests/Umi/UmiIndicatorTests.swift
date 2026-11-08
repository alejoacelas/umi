import AppKit
import Testing
@testable import Ghostty

/// The pane indicator (SPEC PI-3, PI-4): reading the slots' values, and how a mark is drawn.
@MainActor
struct UmiIndicatorTests {
    @Test func colourValues() throws {
        #expect(try UmiIndicator.parseColour("muted", state: .working).map(UmiIndicator.hexString) == "#6f7f76")
        #expect(try UmiIndicator.parseColour("muted", state: .finished).map(UmiIndicator.hexString) == "#bdbdbd")
        #expect(try UmiIndicator.parseColour("Amber", state: .needsYou).map(UmiIndicator.hexString) == "#e0a93e")
        #expect(try UmiIndicator.parseColour(" #FF0000 ", state: .needsYou).map(UmiIndicator.hexString) == "#ff0000")
        #expect(try UmiIndicator.parseColour("none", state: .working) == nil)
        #expect(throws: UmiIndicator.BadValue.self) { try UmiIndicator.parseColour("blinking", state: .working) }
        #expect(throws: UmiIndicator.BadValue.self) { try UmiIndicator.parseColour("#ff00", state: .working) }
    }

    @Test func focusAmounts() throws {
        #expect(try UmiIndicator.parseAmount("3%") == 0.03)
        #expect(try UmiIndicator.parseAmount("0.1") == 0.1)
        #expect(try UmiIndicator.parseAmount("0") == 0)
        #expect(try UmiIndicator.parseAmount("15") == 0.15)
        #expect(throws: UmiIndicator.BadValue.self) { try UmiIndicator.parseAmount("50%") }
        #expect(throws: UmiIndicator.BadValue.self) { try UmiIndicator.parseAmount("-1") }
        #expect(throws: UmiIndicator.BadValue.self) { try UmiIndicator.parseAmount("lots") }
        #expect(UmiIndicator.slotError("indicator.focus", "50%") != nil)
        #expect(UmiIndicator.slotError("indicator.working", "green") == nil)
        #expect(UmiIndicator.slotError("badge", "anything") == nil)
    }

    @Test func looks() {
        let indicator = UmiIndicator.shared
        // Defaults (the test host has no config of its own).
        let needs = indicator.look(.needsYou, focused: false, split: true)
        #expect(needs?.size == 7 && needs?.opacity == 1)
        let working = indicator.look(.working, focused: false, split: true)
        #expect(working?.opacity == UmiIndicator.unfocusedOpacity && working?.size == 7)
        #expect(indicator.look(.working, focused: true, split: true)?.size == 9)
        // An idle focused pane: a grey mark in a split, nothing alone; an idle pane without focus: nothing.
        #expect(indicator.look(.none, focused: true, split: true)?.color == UmiIndicator.idleFocus)
        #expect(indicator.look(.none, focused: true, split: false) == nil)
        #expect(indicator.look(.none, focused: false, split: true) == nil)
    }
}
