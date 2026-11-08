import AppKit
import Testing
@testable import Ghostty

/// The drawer's slide (SPEC DR-1; prototypes/drawer.html, option B: `transform .26s ease`).
@MainActor
struct UmiDrawerTests {
    @Test func easeIsCSSEase() {
        #expect(UmiDrawer.ease(0) == 0)
        #expect(abs(UmiDrawer.ease(1) - 1) < 1e-9)
        // cubic-bezier(0.25, 0.1, 0.25, 1) at x = 0.5 is about 0.8024.
        #expect(abs(UmiDrawer.ease(0.5) - 0.8024) < 0.002)
        // It only goes forward.
        var last = 0.0
        for i in 1...100 {
            let y = UmiDrawer.ease(Double(i) / 100)
            #expect(y >= last)
            last = y
        }
        #expect(UmiDrawer.slideDuration == 0.26)
    }

    @Test func slidesUpAndDownOverItsDuration() async throws {
        let drawer = UmiDrawerModel()
        #expect(drawer.rise == 0 && !drawer.isSliding)
        let start = Date()
        drawer.slide(to: 1, reduceMotion: false)
        #expect(drawer.isSliding)
        var seen: [CGFloat] = []
        while drawer.isSliding, Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            seen.append(drawer.rise)
        }
        let took = Date().timeIntervalSince(start)
        #expect(drawer.rise == 1)
        #expect(took >= 0.24 && took < 0.6, "rose in \(took) s")
        #expect(seen.contains { $0 > 0.05 && $0 < 0.95 }, "passed through the middle: \(seen)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 })

        // And back down; reversed half way, it takes the rest of the way back.
        drawer.slide(to: 0, reduceMotion: false)
        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(drawer.isSliding && drawer.rise < 1 && drawer.rise > 0)
        let partway = drawer.rise
        drawer.slide(to: 1, reduceMotion: false)
        let back = Date()
        while drawer.isSliding, Date().timeIntervalSince(back) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(drawer.rise == 1)
        #expect(Date().timeIntervalSince(back) < 0.26 * Double(1 - partway) + 0.2)
    }

    @Test func reduceMotionMovesAtOnce() {
        let drawer = UmiDrawerModel()
        drawer.slide(to: 1, reduceMotion: true)
        #expect(drawer.rise == 1 && !drawer.isSliding)
        drawer.slide(to: 0, reduceMotion: true)
        #expect(drawer.rise == 0 && !drawer.isSliding)
    }
}
