import PeekabooAutomationKit
import PeekabooFoundation

/// Input the receiver accepted but whose effect Peekaboo could not verify.
///
/// For raw input (`click`, `press`, `type`, `scroll`) this is the normal result of a delivered action, so
/// the tool reports it as a success with a warning instead of an error. The canonical outcome metadata is
/// unchanged: the action stays `dispatched_unverified` and retry-unsafe.
enum MCPDeliveredUnverifiedInput {
    static func matches(_ outcome: DesktopActionOutcome?) -> Bool {
        outcome?.state == .dispatchedUnverified && outcome?.evidence == .deliveryAccepted
    }

    /// The policy an input leaf applies to its returned outcome. Every other non-confirmed state, and an
    /// unverified operation that is still running, keeps failing the confirmed-only policy.
    static func successPolicy(for outcome: DesktopActionOutcome?) -> DesktopActionOutcome.SuccessPolicy {
        self.matches(outcome) ? .confirmedOrDispatched : .confirmed
    }

    static func message(dispatched summary: String, verifying subject: String) -> String {
        "\(AgentDisplayTokens.Status.success) Dispatched \(summary). Observe the target to verify the \(subject); " +
            "\(self.unverifiedClause)."
    }

    private static let unverifiedClause = "delivery is unverified and unsafe to retry blindly"

    /// `text` from ``message(dispatched:verifying:)`` (or a variant that names the same clause) for a result that
    /// carries its own observation: it says the observation below verifies the action instead of asking for one.
    static func observedMessage(_ text: String) -> String {
        let lead = "Observe the target to verify the "
        if text.contains(lead) {
            return text.replacingOccurrences(of: lead, with: "The observation below verifies the ")
        }
        return text.replacingOccurrences(
            of: self.unverifiedClause,
            with: "\(self.unverifiedClause); the observation below verifies it")
    }
}
