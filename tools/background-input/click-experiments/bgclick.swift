// Sends one left click to a process without touching the HID stream.
// usage: bgclick <pid> <windowID> <globalX> <globalY> <winX> <winY> [fields] [winloc] [primer] [hid]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let pid = pid_t(a[1])!, wid = Int64(a[2])!
let g = CGPoint(x: Double(a[3])!, y: Double(a[4])!), origin = CGPoint(x: Double(a[5])!, y: Double(a[6])!)
let opts = Set(a.dropFirst(7))
typealias SetWinLoc = @convention(c) (CGEvent, CGPoint) -> Void
let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
let setWinLoc = dlsym(cg, "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWinLoc.self) }
let src = CGEventSource(stateID: opts.contains("hid") ? .hidSystemState : .privateState)
func send(_ type: CGEventType, at p: CGPoint, window: Int64?) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    if opts.contains("fields"), let w = window {
        e.setIntegerValueField(CGEventField(rawValue: 91)!, value: w)
        e.setIntegerValueField(CGEventField(rawValue: 92)!, value: w)
    }
    if opts.contains("winloc"), let f = setWinLoc, window != nil { f(e, CGPoint(x: p.x - origin.x, y: p.y - origin.y)) }
    e.postToPid(pid)
}
if opts.contains("primer") {
    send(.leftMouseDown, at: CGPoint(x: -1, y: -1), window: nil); send(.leftMouseUp, at: CGPoint(x: -1, y: -1), window: nil)
    usleep(30_000)
}
send(.mouseMoved, at: g, window: wid); usleep(30_000)
send(.leftMouseDown, at: g, window: wid); usleep(60_000)
send(.leftMouseUp, at: g, window: wid)
print("posted to pid \(pid) window \(wid) at \(g) opts=\(opts.sorted()) winloc_available=\(setWinLoc != nil)")
