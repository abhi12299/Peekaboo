import ApplicationServices
import Foundation

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
}
