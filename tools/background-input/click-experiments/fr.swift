// Focus-record background input experiment.
// usage: fr <opts,comma,separated> <targetPid> <x> <y> [x2 y2]
// opts: rec1   = focus record (0x01) to target only (Peekaboo's current recipe)
//       rec2   = defocus record (0x02) to the previous front app, then focus record (0x01) to target (yabai recipe)
//       sky    = post with SLEventPostToPid instead of CGEvent.postToPid
//       fields = stamp fields 91/92 with the target window id
//       winloc = CGEventSetWindowLocation with window-local point
//       primer = (-1,-1) down/up first
//       restore= afterwards: defocus target, refocus the previous front app's window
//       none   = no input events, records only
// With x2 y2 it drags from (x,y) to (x2,y2) instead of clicking.
import AppKit
import ApplicationServices
import CoreGraphics

let a = CommandLine.arguments
let opts = Set(a[1].split(separator: ",").map(String.init))
let pid = pid_t(a[2])!
let p1 = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
let p2: CGPoint? = a.count >= 7 ? CGPoint(x: Double(a[5])!, y: Double(a[6])!) : nil

func topWindow(of owner: pid_t) -> (id: CGWindowID, bounds: CGRect)? {
    let all = ProcessInfo.processInfo.environment["FR_ALL"] != nil
    let list = CGWindowListCopyWindowInfo(all ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowBounds as String] as! [String: CGFloat])["Height"]! > 100 && (w[kCGWindowOwnerPID as String] as? pid_t) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        return (w[kCGWindowNumber as String] as! CGWindowID, CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!))
    }
    return nil
}
func zIndex(of wid: CGWindowID) -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    return normal.firstIndex { ($0[kCGWindowNumber as String] as? CGWindowID) == wid } ?? -1
}
func state(_ label: String, _ wid: CGWindowID) {
    let front = NSWorkspace.shared.frontmostApplication
    let target = NSRunningApplication(processIdentifier: pid)
    let cur = CGEvent(source: nil)?.location ?? .zero
    print("[\(label)] front=\(front?.localizedName ?? "?") targetActive=\(target?.isActive ?? false) targetZ=\(zIndex(of: wid)) cursor=(\(Int(cur.x)),\(Int(cur.y)))")
}

let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let asv = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
typealias PostRec = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
typealias SLPost = @convention(c) (pid_t, CGEvent) -> Void
typealias SetWinLoc = @convention(c) (CGEvent, CGPoint) -> Void
let getPSN = unsafeBitCast(dlsym(asv, "GetProcessForPID")!, to: GetPSN.self)
let postRec = unsafeBitCast(dlsym(sl, "SLPSPostEventRecordTo")!, to: PostRec.self)
let slPost = unsafeBitCast(dlsym(sl, "SLEventPostToPid")!, to: SLPost.self)
let setWinLoc = unsafeBitCast(dlsym(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW), "CGEventSetWindowLocation")!, to: SetWinLoc.self)

func record(_ kind: UInt8, _ wid: CGWindowID, to owner: pid_t) -> Int32 {
    var psn: [UInt32] = [0, 0]
    _ = psn.withUnsafeMutableBytes { getPSN(owner, $0.baseAddress!) }
    var r = [UInt8](repeating: 0, count: 0xF8)
    r[0x04] = 0xF8; r[0x08] = 0x0D; r[0x8A] = kind
    for i in 0..<4 { r[0x3C + i] = UInt8(truncatingIfNeeded: wid >> (i * 8)) }
    return psn.withUnsafeBytes { p in r.withUnsafeBytes { e in postRec(p.baseAddress!, e.baseAddress!) } }
}

let src = CGEventSource(stateID: opts.contains("hidsrc") ? .hidSystemState : .privateState)
guard let target = topWindow(of: pid) else { print("no on-screen window for pid \(pid)"); exit(1) }
let prevApp = NSWorkspace.shared.frontmostApplication!
let prevPid = prevApp.processIdentifier
let prevWin = topWindow(of: prevPid)
print("target wid=\(target.id) bounds=\(target.bounds) prev=\(prevApp.localizedName ?? "?") pid=\(prevPid) wid=\(prevWin?.id ?? 0)")
state("before", target.id)

if opts.contains("rec2"), let pw = prevWin {
    print("defocus prev rc=\(record(0x02, pw.id, to: prevPid))")
}
if opts.contains("rec1") || opts.contains("rec2") {
    print("focus target rc=\(record(0x01, target.id, to: pid))")
    usleep(50_000)
}
if opts.contains("axmain") {
    let app = AXUIElementCreateApplication(pid)
    var wins: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &wins)
    for w in (wins as? [AXUIElement]) ?? [] {
        var posRef: CFTypeRef?; AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
        var pos = CGPoint.zero; if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
        if abs(pos.x - target.bounds.minX) < 2 && abs(pos.y - target.bounds.minY) < 2 {
            print("AXMain set rc=\(AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue)")
        }
    }
    usleep(100_000)
}
if opts.contains("shiftkey") {
    for down in [true, false] {
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: down) {
            e.type = .flagsChanged; e.flags = down ? .maskShift : []
            if opts.contains("f51") { e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(target.id)) }
            e.postToPid(pid)
        }
        usleep(30_000)
    }
    usleep(100_000)
}
state("after-record", target.id)

let screenH = NSScreen.screens[0].frame.height
func nsEvent(_ type: CGEventType, _ p: CGPoint) -> CGEvent? {
    let t: NSEvent.EventType = type == .leftMouseDown ? .leftMouseDown : type == .leftMouseUp ? .leftMouseUp : type == .leftMouseDragged ? .leftMouseDragged : .mouseMoved
    // locationInWindow in window coordinates (bottom-left origin).
    let loc = NSPoint(x: p.x - target.bounds.minX, y: target.bounds.maxY - p.y)
    return NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.id), context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)?.cgEvent
}
func send(_ type: CGEventType, _ p: CGPoint, stamp: Bool = true) {
    guard let e = (stamp && opts.contains("nsevent")) ? nsEvent(type, p) : CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    if stamp && opts.contains("f51") {
        e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(target.id))
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    }
    if stamp && opts.contains("fields") {
        e.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(target.id))
        e.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(target.id))
    }
    if stamp && opts.contains("winloc") { setWinLoc(e, CGPoint(x: p.x - target.bounds.minX, y: p.y - target.bounds.minY)) }
    if opts.contains("sky") { slPost(pid, e) } else { e.postToPid(pid) }
}
func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], text: String? = nil) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
    e.flags = flags
    if let text { let u = Array(text.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
    if opts.contains("f51") { e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(target.id)) }
    if opts.contains("sky") { slPost(pid, e) } else { e.postToPid(pid) }
}
if opts.contains("kbd") {
    if opts.contains("kpre") { let q = CGPoint(x: target.bounds.minX - 10, y: target.bounds.minY - 10); send(.leftMouseDown, q); usleep(60_000); send(.leftMouseUp, q); usleep(200_000) }
    if let t = ProcessInfo.processInfo.environment["FR_TYPE"] {
        for ch in t { key(0, down: true, text: String(ch)); usleep(8_000); key(0, down: false, text: String(ch)); usleep(8_000) }
    }
    if let k = ProcessInfo.processInfo.environment["FR_KEYCODE"] {
        let n = Int(ProcessInfo.processInfo.environment["FR_REPEAT"] ?? "1")!
        for _ in 0..<n { key(CGKeyCode(k)!, down: true); usleep(30_000); key(CGKeyCode(k)!, down: false); usleep(30_000) }
    }
    if let k = ProcessInfo.processInfo.environment["FR_CMDKEY"] {
        let code = CGKeyCode(k)!
        key(55, down: true, flags: .maskCommand); usleep(20_000)
        key(code, down: true, flags: .maskCommand); usleep(20_000)
        key(code, down: false, flags: .maskCommand); usleep(20_000)
        key(55, down: false); usleep(200_000)
    }
    if opts.contains("cmds") {
        key(55, down: true, flags: .maskCommand); usleep(20_000)
        key(1, down: true, flags: .maskCommand); usleep(20_000)
        key(1, down: false, flags: .maskCommand); usleep(20_000)
        key(55, down: false); usleep(200_000)
    }
} else if !opts.contains("none") {
    if opts.contains("primer") { send(.leftMouseDown, CGPoint(x: -1, y: -1), stamp: false); send(.leftMouseUp, CGPoint(x: -1, y: -1), stamp: false); usleep(30_000) }
    send(.mouseMoved, p1); usleep(30_000)
    if opts.contains("preout") { let q = CGPoint(x: target.bounds.minX - 10, y: target.bounds.minY - 10); send(.leftMouseDown, q); usleep(60_000); send(.leftMouseUp, q); usleep(300_000) }
    if opts.contains("pre") { send(.leftMouseDown, p1); usleep(60_000); send(.leftMouseUp, p1); usleep(300_000) }
    send(.leftMouseDown, p1); usleep(80_000)
    print("global left button after down: \(CGEventSource.buttonState(.combinedSessionState, button: .left)) hid=\(CGEventSource.buttonState(.hidSystemState, button: .left))")
    if let p2 {
        let env = ProcessInfo.processInfo.environment
        let steps = Int(env["FR_STEPS"] ?? "20")!, delay = UInt32(env["FR_DELAY_MS"] ?? "20")! * 1000
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            send(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); usleep(delay)
        }
        if env["FR_HOLD_MS"] != nil { usleep(UInt32(env["FR_HOLD_MS"]!)! * 1000) }
        send(.leftMouseUp, p2)
    } else {
        send(.leftMouseUp, p1)
    }
    usleep(200_000)
}
state("after-input", target.id)

if opts.contains("undo1") {
    print("defocus target only rc=\(record(0x02, target.id, to: pid))")
    usleep(100_000)
    state("after-undo1", target.id)
}
if opts.contains("restore"), let pw = prevWin {
    print("defocus target rc=\(record(0x02, target.id, to: pid))")
    print("refocus prev rc=\(record(0x01, pw.id, to: prevPid))")
    usleep(100_000)
    state("after-restore", target.id)
}
