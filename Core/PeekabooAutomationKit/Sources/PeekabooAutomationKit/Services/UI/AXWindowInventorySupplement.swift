import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func createAXElementWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Whether exact-window accessibility reads may look past `AXWindows` for a window on another Space.
public enum OffSpaceAXWindowSwitch {
    /// Set to `0` to trust `AXWindows` alone (windows on other Spaces stay unobservable).
    public static let environmentKey = "PEEKABOO_OFFSPACE_AX_WINDOWS"

    public static func isEnabled(
        readEnvironment: (String) -> String? = { ProcessInfo.processInfo.environment[$0] }) -> Bool
    {
        readEnvironment(self.environmentKey) != "0"
    }
}

/// Finds exact windows that `AXWindows` omits, which macOS does for windows on a non-active Space.
struct AXWindowInventorySupplement<Window> {
    static var remoteTokenScanLimit: Int {
        1000
    }

    let mainWindow: () -> Window?
    let focusedWindow: () -> Window?
    let remoteWindow: (_ elementIdentifier: Int) -> Window?
    let windowID: (Window) -> Int?
    let canContinue: () -> Bool
    let readEnvironment: (String) -> String?
    let scanLimit: Int

    func window(matching targetWindowID: Int, missingFrom inventoryWindowIDs: [Int?]) -> Window? {
        self.windows(matching: [targetWindowID], missingFrom: inventoryWindowIDs).first?.window
    }

    /// Returns windows for the target IDs absent from the inventory. A candidate is kept only when its
    /// own window identifier is exactly one of those targets, so no other window is ever substituted.
    func windows(
        matching targetWindowIDs: Set<Int>,
        missingFrom inventoryWindowIDs: [Int?]) -> [(windowID: Int, window: Window)]
    {
        var missing = targetWindowIDs.subtracting(inventoryWindowIDs.compactMap(\.self))
        guard !missing.isEmpty, OffSpaceAXWindowSwitch.isEnabled(readEnvironment: self.readEnvironment) else {
            return []
        }
        var found: [(windowID: Int, window: Window)] = []
        func claim(_ candidate: Window?) {
            guard let candidate, let windowID = self.windowID(candidate), missing.remove(windowID) != nil else {
                return
            }
            found.append((windowID, candidate))
        }

        // Public attributes first: they still name an off-Space window that `AXWindows` leaves out.
        for read in [self.mainWindow, self.focusedWindow] {
            guard !missing.isEmpty, self.canContinue() else { return found }
            claim(read())
        }
        for elementIdentifier in 0..<self.scanLimit {
            guard !missing.isEmpty, self.canContinue() else { return found }
            claim(self.remoteWindow(elementIdentifier))
        }
        return found
    }

    /// The `AXWindows` entry carrying exactly `targetWindowID`; when the inventory omits it (a window on
    /// another Space), the supplement's exact match. `makeSupplement` runs only in that case.
    static func exactWindow(
        _ targetWindowID: Int,
        inventory: [Window],
        inventoryWindowID: (Window) -> Int?,
        makeSupplement: () -> Self) -> Window?
    {
        var inventoryWindowIDs: [Int?] = []
        for window in inventory {
            let windowID = inventoryWindowID(window)
            if windowID == targetWindowID {
                return window
            }
            inventoryWindowIDs.append(windowID)
        }
        return makeSupplement().window(matching: targetWindowID, missingFrom: inventoryWindowIDs)
    }
}

extension AXWindowInventorySupplement where Window == AXUIElement {
    /// A responsive app answers the whole token scan in a few hundredths of a second; the budget only
    /// stops an unresponsive one from spending the surrounding read's deadline on it.
    private static var maximumSupplementSeconds: Double {
        0.5
    }

    private static var windowSubroles: Set<String> {
        [kAXStandardWindowSubrole as String, kAXDialogSubrole as String]
    }

    /// Live reads against one application. Every read is bounded by `deadline` (when given), the
    /// supplement's own budget, and a short per-call messaging timeout.
    static func live(
        application: AXUIElement,
        processIdentifier: pid_t,
        deadline: ContinuousClock.Instant? = nil,
        messagingTimeout: Float = 0.05) -> Self
    {
        let budgetEnd = ContinuousClock.now.advanced(by: .seconds(Self.maximumSupplementSeconds))
        let end = deadline.map { min($0, budgetEnd) } ?? budgetEnd
        func applyTimeout(_ element: AXUIElement) -> Bool {
            let remaining = ContinuousClock.now.duration(to: end).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { return false }
            return AXUIElementSetMessagingTimeout(element, min(messagingTimeout, Float(seconds))) == .success
        }
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard applyTimeout(element) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func applicationWindow(_ name: String) -> AXUIElement? {
            guard let value = attribute(name, of: application),
                  CFGetTypeID(value) == AXUIElementGetTypeID()
            else {
                return nil
            }
            let window = unsafeDowncast(value, to: AXUIElement.self)
            var owner: pid_t = 0
            guard AXUIElementGetPid(window, &owner) == .success, owner == processIdentifier else { return nil }
            return window
        }
        return AXWindowInventorySupplement(
            mainWindow: { applicationWindow(kAXMainWindowAttribute) },
            focusedWindow: { applicationWindow(kAXFocusedWindowAttribute) },
            remoteWindow: { elementIdentifier in
                guard let element = Self.remoteElement(
                    processIdentifier: processIdentifier,
                    elementIdentifier: elementIdentifier),
                    let subrole = attribute(kAXSubroleAttribute, of: element) as? String,
                    Self.windowSubroles.contains(subrole)
                else {
                    return nil
                }
                return element
            },
            windowID: { window in
                guard applyTimeout(window),
                      let windowID = AXWindowIDResolver.windowID(of: window), windowID > 0
                else {
                    return nil
                }
                return Int(windowID)
            },
            canContinue: { ContinuousClock.now < end },
            readEnvironment: { ProcessInfo.processInfo.environment[$0] },
            scanLimit: Self.remoteTokenScanLimit)
    }

    /// AppKit's remote element token: owner PID, a zero word, the `coco` tag, then the element identifier.
    static func remoteToken(processIdentifier: pid_t, elementIdentifier: Int) -> Data {
        var token = Data(capacity: 20)
        for word in [Int32(processIdentifier), 0, 0x636F_636F] {
            withUnsafeBytes(of: word) { token.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UInt64(elementIdentifier)) { token.append(contentsOf: $0) }
        return token
    }

    private static func remoteElement(processIdentifier: pid_t, elementIdentifier: Int) -> AXUIElement? {
        guard elementIdentifier >= 0 else { return nil }
        let token = self.remoteToken(processIdentifier: processIdentifier, elementIdentifier: elementIdentifier)
        return createAXElementWithRemoteToken(token as CFData)?.takeRetainedValue()
    }
}
