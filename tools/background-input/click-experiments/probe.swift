// Event probe: a small AppKit app that logs every event it receives and what its views do with it.
// usage: probe <logfile>
import AppKit

let logURL = URL(fileURLWithPath: CommandLine.arguments[1])
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try! FileHandle(forWritingTo: logURL)
func log(_ s: String) {
    let line = String(format: "%.3f ", Date().timeIntervalSince1970) + s + "\n"
    logHandle.seekToEndOfFile(); logHandle.write(line.data(using: .utf8)!)
}

final class ProbeApp: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .keyDown, .keyUp, .flagsChanged:
            log("app.sendEvent type=\(event.type.rawValue) chars=\((event.type == .keyDown) ? (event.characters ?? "") : "") win=\(event.windowNumber) onActiveSpace=\(self.windows.first?.isOnActiveSpace ?? false) loc=\(event.locationInWindow) appActive=\(self.isActive) key=\(self.keyWindow?.windowNumber ?? 0)")
        default: break
        }
        super.sendEvent(event)
    }
}

final class Pad: NSView {
    let name: String, firstMouse: Bool
    init(frame: NSRect, name: String, firstMouse: Bool) { self.name = name; self.firstMouse = firstMouse; super.init(frame: frame); wantsLayer = true; layer?.backgroundColor = (firstMouse ? NSColor.systemGreen : NSColor.systemOrange).cgColor }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { log("\(name).acceptsFirstMouse asked -> \(firstMouse)"); return firstMouse }
    override func mouseDown(with e: NSEvent) { log("\(name).mouseDown at \(convert(e.locationInWindow, from: nil)) appActive=\(NSApp.isActive) winKey=\(window?.isKeyWindow ?? false)") }
    override func mouseDragged(with e: NSEvent) { log("\(name).mouseDragged at \(convert(e.locationInWindow, from: nil))") }
    override func mouseUp(with e: NSEvent) { log("\(name).mouseUp at \(convert(e.locationInWindow, from: nil))") }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    @objc func pressed(_ s: NSButton) { log("button.pressed appActive=\(NSApp.isActive)") }
    @objc func slid(_ s: NSSlider) { log("slider.value=\(Int(s.doubleValue))") }
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 900, y: 300, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Event Probe"
        let v = window.contentView!
        v.addSubview(Pad(frame: NSRect(x: 20, y: 160, width: 180, height: 120), name: "padYes", firstMouse: true))
        v.addSubview(Pad(frame: NSRect(x: 220, y: 160, width: 180, height: 120), name: "padNo", firstMouse: false))
        let b = NSButton(title: "Press me", target: self, action: #selector(pressed(_:))); b.frame = NSRect(x: 20, y: 100, width: 120, height: 32); v.addSubview(b)
        let s = NSSlider(value: 0, minValue: 0, maxValue: 100, target: self, action: #selector(slid(_:))); s.frame = NSRect(x: 20, y: 40, width: 380, height: 24); v.addSubview(s)
        window.orderFrontRegardless()
        if ProcessInfo.processInfo.environment["PROBE_ACTIVATE"] != nil { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        log("launched pid=\(getpid()) win=\(window.windowNumber) frame=\(window.frame) appActive=\(NSApp.isActive)")
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { _ in log("window didBecomeKey appActive=\(NSApp.isActive)") }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { _ in log("window didResignKey") }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in log("app didBecomeActive") }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in log("app didResignActive") }
    }
}

let app = ProbeApp.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
