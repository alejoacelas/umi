import CoreGraphics
import Foundation
// hyper tap | space | withkey | d: real modifier key events (⌃⌥⇧⌘) through the HID tap. tap: the
// modifiers alone; space: Hyper+Space; withkey: Hyper+U; d: Hyper+D (send to the docket).
let mods: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
var flags: CGEventFlags = []
func post(_ code: CGKeyCode, _ down: Bool, _ f: CGEventFlags, flagsChanged: Bool) {
  let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
  if flagsChanged { e.type = .flagsChanged }
  e.flags = f
  e.post(tap: .cghidEventTap); usleep(15000)
}
for (c, f) in mods { flags.insert(f); post(c, true, flags, flagsChanged: true) }
switch CommandLine.arguments[1] {
case "space": post(49, true, flags, flagsChanged: false); post(49, false, flags, flagsChanged: false)
case "withkey": post(32, true, flags, flagsChanged: false); post(32, false, flags, flagsChanged: false)
case "d": post(2, true, flags, flagsChanged: false); post(2, false, flags, flagsChanged: false)
default: break
}
for (c, f) in mods.reversed() { flags.remove(f); post(c, false, flags, flagsChanged: true) }
