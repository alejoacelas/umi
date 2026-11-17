import CoreGraphics
import Foundation
// click X Y [up]: a left click at global top-left screen points; "drag X1 Y1 X2 Y2" drags.
let a = CommandLine.arguments
func post(_ t: CGEventType, _ x: Double, _ y: Double) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!.post(tap: .cghidEventTap)
}
if a[1] == "drag" {
  let x1 = Double(a[2])!, y1 = Double(a[3])!, x2 = Double(a[4])!, y2 = Double(a[5])!
  post(.mouseMoved, x1, y1); usleep(50000); post(.leftMouseDown, x1, y1)
  for i in 1...20 { usleep(16000); post(.leftMouseDragged, x1 + (x2-x1)*Double(i)/20, y1 + (y2-y1)*Double(i)/20) }
  post(.leftMouseUp, x2, y2)
} else {
  let x = Double(a[1])!, y = Double(a[2])!
  post(.mouseMoved, x, y); usleep(50000); post(.leftMouseDown, x, y); usleep(30000); post(.leftMouseUp, x, y)
}
