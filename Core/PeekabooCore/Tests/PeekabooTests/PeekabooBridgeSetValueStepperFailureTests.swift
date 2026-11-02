import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

/// A stepper set that stalls after several AXIncrement steps reaches Bridge callers as a partial failure only when it
/// keeps set-value's one logical accessibilityValue unit.
struct PeekabooBridgeSetValueStepperFailureTests {
    @Test
    func `a set-value partial failure carries one accessibilityValue unit`() {
        typealias Semantics = PeekabooBridgeOperationResultSemantics
        let request = PeekabooBridgeRequest.setValue(.init(target: "elem_20", value: .int(34), snapshotId: "snapshot"))
        let partial = { (units: Int) in
            DesktopActionOutcome.partial(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .init(units))
        }

        #expect(Semantics.failureOutcomeMatchesContract(partial(1), request: request))
        #expect(!Semantics.failureOutcomeMatchesContract(partial(4), request: request))
    }
}
