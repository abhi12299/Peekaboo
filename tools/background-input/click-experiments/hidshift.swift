// Posts a bare Shift down/up through the HID event tap (goes wherever the system routes real keyboard input).
import CoreGraphics
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 56, keyDown: down)!
    e.type = .flagsChanged; e.flags = down ? .maskShift : []
    e.post(tap: .cghidEventTap); usleep(50_000)
}
