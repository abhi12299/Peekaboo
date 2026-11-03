import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

/// The Bridge response does not carry `targetWindowChange`, so a remote client would see a click whose window
/// closed or changed as an ordinary success and offer its snapshot for reuse. Until the field crosses the
/// Bridge, the host reports such a click as indeterminate, as it did before the change was reported locally.
@Suite(.serialized)
@MainActor
struct PeekabooBridgeClickWindowChangeTests {
    @Test(arguments: [TargetWindowChange.closed, .changed])
    func `a click whose window changed reaches a remote client as indeterminate`(change: TargetWindowChange) throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background)
        let result = UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: .one))
            .withTargetWindowChange(change)

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try PeekabooBridgeServer.handledActionResponse(
                response: .ok,
                result: result,
                fallbackTarget: .requestPinned)
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.delivery == delivery)
        #expect(failure?.localizedDescription.contains("window then \(change.rawValue)") == true)
    }

    @Test
    func `a click whose window is unchanged is handled as before`() throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: delivery,
            evidence: .deliveryAccepted,
            unitCount: .one)

        let handled = try PeekabooBridgeServer.handledActionResponse(
            response: .ok,
            result: UIAutomationActionResult(payload: (), outcome: outcome),
            fallbackTarget: .requestPinned)

        #expect(handled.outcome == outcome)
    }
}
