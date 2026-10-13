import Foundation
import PeekabooFoundation

/// Recognises the errors a dialog lookup throws when the target simply has no dialog open.
///
/// A read-only `dialog list` treats this as an empty result rather than a failure. Every other
/// error (application or window not found, permission denied, accessibility failure, ambiguity)
/// remains a failure.
public enum DialogAbsence {
    /// Message of the refusal a targeted dialog lookup throws when no dialog matched the target.
    public static let noDialogMatchedMessage = "No dialog matched the selected target."

    public static func isNoDialogOpen(_ error: any Error) -> Bool {
        if case DialogError.noActiveDialog? = error as? DialogError {
            return true
        }
        guard let failure = error as? DesktopActionFailure else { return false }
        return failure.outcome.refusalReason == .targetUnavailable &&
            failure.message == self.noDialogMatchedMessage
    }
}
