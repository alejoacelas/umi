import Foundation
import Testing
@testable import Ghostty

/// Pane data (SPEC D-2, D-6): which attribute names can be written, and the cause a control
/// request is recorded with.
@MainActor struct UmiPaneDataTests {
    @Test func keyNames() {
        for key in ["priority", "agent.status", "role", "my-key_2", "a.b.c"] {
            #expect(UmiAttributes.isValidKey(key), "\(key)")
        }
        for key in ["", "bad key", "a=b", "x|y", "quote\""] {
            #expect(!UmiAttributes.isValidKey(key), "\(key)")
        }
    }

    @Test func readOnlyKeysCantBeWritten() {
        for key in ["cwd", "seen_at", "changed_at", "kind", "visible_count", "idle_for"] {
            #expect(throws: UmiError.self) { try UmiAttributes.checkWritable(key) }
        }
        #expect(throws: Never.self) { try UmiAttributes.checkWritable("agent.title") }
        #expect(throws: Never.self) { try UmiAttributes.checkWritable("pinned") }
    }

    @Test func requestCauses() {
        let plain = UmiCause.request(method: "pane.set",
                                     caller: UmiCaller(pane: "ABC", instance: "x", argv: ["pane", "set", "a=1"]))
        #expect(plain == UmiCause(kind: "cli", command: "umi pane set a=1", pane: "abc"))
        let hook = UmiCause.request(method: "hook", caller: UmiCaller(pane: "p", instance: "x", argv: ["hook", "Stop"]))
        #expect(hook.kind == "hook")
        let palette = UmiCause.request(method: "pane.set",
                                       caller: UmiCaller(pane: "p", instance: "x", cause: "palette", argv: ["pane", "set", "a=1"]))
        #expect(palette == UmiCause(kind: "palette", command: "umi pane set a=1"))
        let key = UmiCause.request(method: "pane.set", caller: UmiCaller(pane: nil, instance: nil, cause: "key:ctrl+cmd+y", argv: []))
        #expect(key.kind == "key" && key.key == "ctrl+cmd+y")
    }

    @Test func aScopeOutranksTheRequest() {
        let inside = UmiCause.during(UmiCause(kind: "palette", command: "X")) { UmiCause.now }
        #expect(inside.kind == "palette")
    }
}
