// Real mouse drag for manual verification: swift script/mouse-drag.swift x1 y1 x2 y2 (global points)
import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard args.count == 4 else { print("usage: x1 y1 x2 y2"); exit(2) }
let from = CGPoint(x: args[0], y: args[1]), to = CGPoint(x: args[2], y: args[3])
func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, from); usleep(150_000)
post(.leftMouseDown, from); usleep(250_000)
for step in 1...40 {
    let t = Double(step) / 40
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
    usleep(25_000)
}
// FOLIO_DRAG_HOLD=<seconds> keeps the button down at the target (e.g. to screenshot a drop overlay).
let hold = Double(ProcessInfo.processInfo.environment["FOLIO_DRAG_HOLD"] ?? "") ?? 0.6
usleep(useconds_t(hold * 1_000_000))
post(.leftMouseUp, to)
