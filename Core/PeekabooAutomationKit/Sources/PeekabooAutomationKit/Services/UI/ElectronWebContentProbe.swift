import ApplicationServices
import CoreGraphics
import Foundation

/// Reads whether an Electron window exposes its web content (an `AXWebArea`) to accessibility.
///
/// Before the app's tree is on, an Electron window lists only its title-bar buttons and a few empty groups
/// (12-13 elements in testing), so a short breadth-first search finds the web area or runs out quickly.
/// Windows on another Space are found the way exact-window reads find them (`AXWindowInventorySupplement`).
enum ElectronWebContentProbe {
    static let maximumDepth = 12
    static let maximumNodes = 400
    static let budget: Duration = .milliseconds(500)

    @MainActor
    static func windowExposesWebContent(processIdentifier: pid_t, windowID: CGWindowID?) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        let deadline = ContinuousClock.now.advanced(by: self.budget)
        guard let window = self.window(of: application, processIdentifier: processIdentifier, windowID: windowID,
                                       deadline: deadline)
        else {
            return false
        }
        return self.containsWebArea(window, deadline: deadline)
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
            inventoryWindowID: { AXWindowIDResolver.windowID(of: $0).map(Int.init) },
            makeSupplement: {
                .live(application: application, processIdentifier: processIdentifier, deadline: deadline)
            })
    }

    private static func containsWebArea(_ root: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < self.maximumNodes, ContinuousClock.now < deadline {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            if self.string(element, kAXRoleAttribute) == "AXWebArea" {
                return true
            }
            if depth < self.maximumDepth {
                queue += (self.elements(element, kAXChildrenAttribute) ?? []).map { ($0, depth + 1) }
            }
        }
        return false
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
        hasWebContent: ElectronWebContentProbe.windowExposesWebContent(processIdentifier:windowID:),
        enable: ElementDetectionService.enableElectronManualAccessibility(processIdentifier:))
}
