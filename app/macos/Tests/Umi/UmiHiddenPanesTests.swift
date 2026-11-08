import AppKit
import Testing
@testable import Ghostty

/// Hidden panes (SPEC H-1, H-2): where a pane brought back in goes.
struct UmiHiddenPanesTests {
    @Test func aPaneBroughtInJoinsTheRightEndOfTheTopRowWithAnEqualShare() throws {
        let a = MockView(), b = MockView(), c = MockView()
        let tree = try SplitTree<MockView>(view: a).inserting(view: b, at: a, direction: .right)
        let three = tree.umiAppending(c, atStart: false)
        #expect(three.root?.leaves() == [a, b, c])
        let frames = three.root?.frames(in: CGSize(width: 900, height: 300)) ?? []
        #expect(frames.count == 3)
        for frame in frames { #expect(abs(frame.frame.width - 300) < 1) }
    }

    @Test func atStartGoesToTheLeftEnd() throws {
        let a = MockView(), b = MockView(), c = MockView()
        let tree = try SplitTree<MockView>(view: a).inserting(view: b, at: a, direction: .down)
        let joined = tree.umiAppending(c, atStart: true)
        #expect(joined.root?.leaves() == [c, a, b])
        // The column a/b counts as one member of the row: c gets half.
        let frames = joined.root?.frames(in: CGSize(width: 800, height: 400)) ?? []
        let cFrame = frames.first { $0.view === c }?.frame
        #expect(cFrame.map { abs($0.width - 400) < 1 } ?? false)
        #expect(cFrame?.minX == 0)
    }

    @Test func intoAnEmptyTreeItIsTheOnlyPane() {
        let a = MockView()
        #expect(SplitTree<MockView>().umiAppending(a, atStart: false).root?.leaves() == [a])
    }
}
