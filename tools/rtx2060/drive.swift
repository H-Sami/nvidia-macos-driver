// drive - scripted input for the desktop scenarios, posted as HID events so WindowServer handles them as a user's.
//   drive trusted                 prints 1 if this process may post events (System Settings > Privacy > Accessibility)
//   drive drag X Y SECONDS        holds the button at X,Y and circles 300 pt at 1 kHz, the title-bar drag of #356
//   drive scroll X Y SECONDS      pixel scroll at 120 Hz over X,Y, changing direction every 2 s
//   drive sweep SECONDS           moves the cursor left and right along the bottom edge (the Dock, for magnification)
import ApplicationServices
import Foundation

let a = CommandLine.arguments
func arg(_ i: Int) -> Double { Double(a[i]) ?? 0 }
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func run(_ secs: Double, hz: Double, _ step: (Double) -> Void) {
    let t0 = Date()
    while true {
        let t = Date().timeIntervalSince(t0)
        if t >= secs { break }
        step(t)
        usleep(useconds_t(1_000_000 / hz))
    }
}

switch a.count > 1 ? a[1] : "" {
case "trusted":
    print(AXIsProcessTrusted() ? 1 : 0)
case "drag" where a.count == 5:
    let c = CGPoint(x: arg(2), y: arg(3))
    post(.mouseMoved, c); usleep(100_000)
    post(.leftMouseDown, c); usleep(100_000)
    var last = c
    // one full circle every 2 s; starts at the press point so the window does not jump
    run(arg(4), hz: 1000) { t in
        let th = t * .pi
        last = CGPoint(x: c.x + 300 * sin(th), y: c.y + 150 * (1 - cos(th)))
        post(.leftMouseDragged, last)
    }
    post(.leftMouseUp, last)
case "scroll" where a.count == 5:
    post(.mouseMoved, CGPoint(x: arg(2), y: arg(3))); usleep(100_000)
    run(arg(4), hz: 120) { t in
        let dir: Int32 = Int(t / 2) % 2 == 0 ? -24 : 24
        CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: dir, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
case "sweep" where a.count == 3:
    let b = CGDisplayBounds(CGMainDisplayID())
    run(arg(2), hz: 250) { t in
        let f = (sin(t * .pi / 2) + 1) / 2
        post(.mouseMoved, CGPoint(x: b.width * (0.2 + 0.6 * f), y: b.height - 20))
    }
default:
    FileHandle.standardError.write("usage: drive trusted | drag X Y SECONDS | scroll X Y SECONDS | sweep SECONDS\n".data(using: .utf8)!)
    exit(2)
}
