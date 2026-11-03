import AppKit
import ApplicationServices
import os.log
import Foundation
import PeekabooFoundation

extension ElementDetectionService {
    enum ElectronAccessibilityError: Error, CustomStringConvertible {
        case attributeRejected(AXError)

        var description: String {
            switch self {
            case let .attributeRejected(error):
                "AXManualAccessibility was rejected (AXError \(error.rawValue))"
            }
        }
    }

    /// Electron apps build their accessibility tree only after an assistive client asks for it.
    /// Setting `AXManualAccessibility` on the application element is the documented opt-in.
    static func enableElectronManualAccessibility(processIdentifier: pid_t) throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        // Keep an unresponsive app from stalling the caller for the global AX timeout.
        AXUIElementSetMessagingTimeout(application, 0.5)
        let error = AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue)
        guard error == .success else {
            throw ElectronAccessibilityError.attributeRejected(error)
        }
    }

    /// Turns on the Electron app's web accessibility tree and waits for the target window to expose it. A
    /// window on a Space no display shows that still has none fails here, instead of returning only its
    /// title bar: Electron does not render a window there, so its web content cannot appear.
    func prepareElectronWebContent(
        targetApp: NSRunningApplication,
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        windowID: CGWindowID?) async throws
    {
        let outcome = await self.electronAccessibilityActivator.prepare(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            windowID: windowID)
        guard outcome == .noWebContent else { return }
        guard let windowID else {
            self.electronLogger.warning("Electron PID \(processIdentifier) exposes no web content yet")
            return
        }
        let placement = self.windowPlacementProvider(windowID)
        guard placement.isOtherSpace else {
            self.electronLogger.warning(
                "Electron window \(windowID) of PID \(processIdentifier) exposes no web content yet")
            return
        }
        let appName = targetApp.localizedName ?? "PID \(processIdentifier)"
        throw PeekabooError.operationError(message: Self.offSpaceElectronWithoutWebContentMessage(
            appName: appName,
            windowID: windowID,
            placement: placement))
    }

    static func offSpaceElectronWithoutWebContentMessage(
        appName: String,
        windowID: CGWindowID,
        placement: WindowSpacePlacement) -> String
    {
        let seconds = Double(ElectronAccessibilityActivator.webContentTimeout.components.seconds) +
            Double(ElectronAccessibilityActivator.webContentTimeout.components.attoseconds) / 1e18
        return "\(appName) window \(windowID) is on \(placement.spaceDescription), which no display shows, and has " +
            "no web content there: Electron does not render a window on a hidden Space, so only its title bar " +
            "can be read. Peekaboo set AXManualAccessibility and waited \(String(format: "%.1f", seconds)) s. " +
            "Nothing was read. Ways out without switching the user's Space: move the window to the current " +
            "Space with `space move-window` (`to_current: true`; it changes the user's window layout), or, if " +
            "the user agrees, quit the app and start it with `app launch`, which keeps an Electron app's " +
            "windows on other Spaces live. Otherwise ask the user to show that Space."
    }

    private var electronLogger: Logger {
        Logger(subsystem: "boo.peekaboo.core", category: "ElectronAccessibility")
    }
}
