import CoreGraphics
import Foundation
// key CODE [cmd] [shift] [opt] [ctrl]: one real key press (down and up) through the HID tap, with
// the modifier keys pressed around it as a hand would. CODE is a macOS virtual key code
// (t 17, d 2, w 13, b 11, [ 33, ] 30, 1 18, 2 19, left 123, right 124, down 125, up 126, space 49).
let names: [String: (CGKeyCode, CGEventFlags)] = [
  "ctrl": (59, .maskControl), "opt": (58, .maskAlternate), "shift": (56, .maskShift), "cmd": (55, .maskCommand),
]
let code = CGKeyCode(CommandLine.arguments[1])!
let mods = CommandLine.arguments.dropFirst(2).compactMap { names[$0] }
var flags: CGEventFlags = []
func post(_ c: CGKeyCode, _ down: Bool, flagsChanged: Bool) {
  let e = CGEvent(keyboardEventSource: nil, virtualKey: c, keyDown: down)!
  if flagsChanged { e.type = .flagsChanged }
  e.flags = flags
  e.post(tap: .cghidEventTap); usleep(15000)
}
for (c, f) in mods { flags.insert(f); post(c, true, flagsChanged: true) }
post(code, true, flagsChanged: false); post(code, false, flagsChanged: false)
for (c, f) in mods.reversed() { flags.remove(f); post(c, false, flagsChanged: true) }
