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

    @Test func slidesUpAndDownOverItsDuration() {
        // Frames at chosen times (the timer would call step every 1/120 s).
        let drawer = UmiDrawerModel()
        #expect(drawer.rise == 0 && !drawer.isSliding)
        let t0 = Date()
        drawer.slide(to: 1, reduceMotion: false, now: t0)
        #expect(drawer.isSliding)
        var last: CGFloat = 0
        for ms in stride(from: 20, through: 240, by: 20) {
            drawer.step(now: t0.addingTimeInterval(Double(ms) / 1000))
            #expect(drawer.rise > last && drawer.rise < 1, "at \(ms) ms: \(drawer.rise)")
            last = drawer.rise
        }
        drawer.step(now: t0.addingTimeInterval(0.13))
        #expect(abs(drawer.rise - CGFloat(UmiDrawer.ease(0.5))) < 1e-6)
        drawer.step(now: t0.addingTimeInterval(0.26))
        #expect(drawer.rise == 1 && !drawer.isSliding)

        // Down, reversed part way: back up from there, in that share of the time.
        let t1 = Date()
        drawer.slide(to: 0, reduceMotion: false, now: t1)
        drawer.step(now: t1.addingTimeInterval(0.1))
        let partway = drawer.rise
        #expect(partway > 0 && partway < 1 && drawer.isSliding)
        let t2 = t1.addingTimeInterval(0.1)
        drawer.slide(to: 1, reduceMotion: false, now: t2)
        drawer.step(now: t2.addingTimeInterval(0.01))
        #expect(drawer.rise > partway)
        drawer.step(now: t2.addingTimeInterval(0.26 * Double(1 - partway)))
        #expect(drawer.rise == 1 && !drawer.isSliding)
    }

    @Test func theTimerRunsTheSlide() async throws {
        let drawer = UmiDrawerModel()
        let start = Date()
        drawer.slide(to: 1, reduceMotion: false)
        while drawer.isSliding, Date().timeIntervalSince(start) < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(drawer.rise == 1 && !drawer.isSliding)
        #expect(Date().timeIntervalSince(start) >= 0.25)
    }

    @Test func reduceMotionMovesAtOnce() {
        let drawer = UmiDrawerModel()
        drawer.slide(to: 1, reduceMotion: true)
        #expect(drawer.rise == 1 && !drawer.isSliding)
        drawer.slide(to: 0, reduceMotion: true)
        #expect(drawer.rise == 0 && !drawer.isSliding)
    }
}
