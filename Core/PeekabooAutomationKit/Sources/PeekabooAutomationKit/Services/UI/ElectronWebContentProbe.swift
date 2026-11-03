import ApplicationServices
import CoreGraphics
import Foundation

/// Reads what an Electron window holds: its web content (an `AXWebArea`), only Chromium's empty host views, or
/// no Chromium content at all (a native message box or Open/Save panel).
///
/// Before the app's tree is on, a browser window lists its title-bar buttons and a few groups that carry
/// Chromium's `ChromeAXNodeId` (12-13 elements in testing, also for a window that never rendered); a native
/// window has none. A short breadth-first search finds the web area or runs out quickly. Windows on another
/// Space are found the way exact-window reads find them (`AXWindowInventorySupplement`).
enum ElectronWebContentProbe {
    static let maximumDepth = 12
    static let maximumNodes = 400
    static let budget: Duration = .milliseconds(500)

    @MainActor
    static func windowContent(processIdentifier: pid_t, windowID: CGWindowID?) -> ElectronWindowContent {
        let application = AXUIElementCreateApplication(processIdentifier)
        let deadline = ContinuousClock.now.advanced(by: self.budget)
        guard let window = self.window(of: application, processIdentifier: processIdentifier, windowID: windowID,
                                       deadline: deadline)
        else {
            return .unknown
        }
        return self.content(of: window, deadline: deadline)
    }

    @MainActor
    private static func window(
        of application: AXUIElement,
        processIdentifier: pid_t,
        windowID: CGWindowID?,
        deadline: ContinuousClock.Instant) -> AXUIElement?
    {
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = self.elements(application, kAXWindowsAttribute) ?? []
        guard let windowID else {
            return self.element(application, kAXFocusedWindowAttribute) ??
                self.element(application, kAXMainWindowAttribute) ?? windows.first
        }
        return AXWindowInventorySupplement<AXUIElement>.exactWindow(
            Int(windowID),
            inventory: windows,
            inventoryWindowID: { window in
                // Each window element answers on its own messaging timeout, not the application's.
                guard self.applyRemainingTimeout(to: window, deadline: deadline) else { return nil }
                return AXWindowIDResolver.windowID(of: window).map(Int.init)
            },
            makeSupplement: {
                .live(application: application, processIdentifier: processIdentifier, deadline: deadline)
            })
    }

    private static func content(of root: AXUIElement, deadline: ContinuousClock.Instant) -> ElectronWindowContent {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var hostsChromium = false
        while index < queue.count, index < self.maximumNodes {
            let (element, depth) = queue[index]
            index += 1
            guard self.applyRemainingTimeout(to: element, deadline: deadline) else { return .unknown }
            if self.string(element, kAXRoleAttribute) == "AXWebArea" {
                return .webContent
            }
            if !hostsChromium, self.value(element, "ChromeAXNodeId") != nil {
                hostsChromium = true
            }
            if depth < self.maximumDepth {
                queue += (self.elements(element, kAXChildrenAttribute) ?? []).map { ($0, depth + 1) }
            }
        }
        return hostsChromium ? .chromiumHostWithoutWebContent : .native
    }

    /// Bounds the element's next reads by what is left of the probe's budget (at most 0.1 s each); false once
    /// the budget is spent.
    private static func applyRemainingTimeout(to element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0 else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(min(0.1, seconds))) == .success
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        self.value(element, attribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = self.value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let values = self.value(element, attribute) as? [AnyObject] else { return nil }
        return values.compactMap { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeDowncast(value, to: AXUIElement.self) : nil
        }
    }
}

extension ElectronAccessibilityActivator {
    /// One activator for the process, so an MCP server sets the attribute once per app generation.
    static let shared = ElectronAccessibilityActivator(
        windowContent: ElectronWebContentProbe.windowContent(processIdentifier:windowID:),
        enable: ElementDetectionService.enableElectronManualAccessibility(processIdentifier:))
}
