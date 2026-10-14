// usage: launch <bundle path> [args...]  — opens an app with activates=false and reports the frontmost app over time.
import AppKit
let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1])
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = false
cfg.addsToRecentItems = false
let hideFirst = ProcessInfo.processInfo.environment["LAUNCH_HIDE"] != nil
cfg.hides = hideFirst
var launched: NSRunningApplication?
if a.count > 2 { cfg.arguments = Array(a.dropFirst(2)); cfg.createsNewApplicationInstance = true }
func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
let prevFront = NSWorkspace.shared.frontmostApplication
print("before: front=\(front())")
var stolenAt: Date?
var done = false
NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
    print("launched pid=\(app?.processIdentifier ?? 0) err=\(String(describing: err))"); launched = app; done = true
}
let start = Date()
var last = ""
var unhid = false
while Date().timeIntervalSince(start) < 8 {
    if hideFirst && !unhid && Date().timeIntervalSince(start) > 4, let app = launched { unhid = true; print(String(format: "+%.1fs unhide -> %@", Date().timeIntervalSince(start), app.unhide() ? "ok" : "failed")) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    if ProcessInfo.processInfo.environment["LAUNCH_RESTORE"] != nil, let l = launched, NSWorkspace.shared.frontmostApplication?.processIdentifier == l.processIdentifier, let p = prevFront {
        if stolenAt == nil { stolenAt = Date() }
        _ = p.activate(); print(String(format: "+%.2fs launched app took front; re-activated %@", Date().timeIntervalSince(start), p.localizedName ?? "?"))
    }
    let f = front(); if f != last { print(String(format: "+%.1fs front=%@", Date().timeIntervalSince(start), f)); last = f }
}
