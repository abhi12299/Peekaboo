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
        let appName = targetApp.localizedName ?? "PID \(processIdentifier)"
        let placement = self.windowPlacementProvider(windowID)
        let hiddenBy: ElectronHiddenWindow
        if placement.isOtherSpace {
            hiddenBy = .otherSpace(placement)
        } else if self.windowFullyCoveredProvider(windowID) {
            hiddenBy = .coveringWindows
        } else {
            self.electronLogger.warning(
                "Electron window \(windowID) of PID \(processIdentifier) exposes no web content yet")
            return
        }
        throw PeekabooError.operationError(
            message: hiddenBy.message(appName: appName, windowID: windowID))
    }
}

/// Why an Electron window that never built its web content cannot be read: Electron does not render a
/// window that no display shows, so its web content and accessibility tree never appear.
enum ElectronHiddenWindow {
    case otherSpace(WindowSpacePlacement)
    case coveringWindows

    func message(appName: String, windowID: CGWindowID) -> String {
        let timeout = ElectronAccessibilityActivator.webContentTimeout.components
        let seconds = Double(timeout.seconds) + Double(timeout.attoseconds) / 1e18
        let tried = "Peekaboo set AXManualAccessibility and waited \(String(format: "%.1f", seconds)) s; " +
            "nothing was read."
        let relaunch = "if the user agrees, quit the app and start it with `app launch`, which keeps an Electron " +
            "app's hidden windows rendering"
        switch self {
        case let .otherSpace(placement):
            return "\(appName) window \(windowID) is on \(placement.spaceDescription), which no display shows, and " +
                "has no web content there: Electron has not rendered it, so only its title bar can be read. " +
                "\(tried) Moving the window to the current Space does not help on its own: it arrives behind " +
                "other windows and still does not render. Ways out without switching the user's Space: " +
                "\(relaunch); otherwise ask the user to show that Space."
        case .coveringWindows:
            return "\(appName) window \(windowID) is completely covered by other windows and has no web " +
                "content: Electron has not rendered it, so only its title bar can be read. \(tried) Ways out: " +
                "\(relaunch); otherwise ask the user to uncover the window."
        }
    }
}

extension ElementDetectionService {
    private var electronLogger: Logger {
        Logger(subsystem: "boo.peekaboo.core", category: "ElectronAccessibility")
    }
}
