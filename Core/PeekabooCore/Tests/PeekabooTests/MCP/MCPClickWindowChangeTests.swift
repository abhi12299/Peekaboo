import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// A click that closes its window (a tab) or changes it (opens a sheet) says so, and its snapshot needs a
/// fresh observation: the window it describes is gone or different.
@Suite(.serialized)
@MainActor
struct MCPClickWindowChangeTests {
    @Test(arguments: [
        (TargetWindowChange.closed, "The click's window then closed"),
        (TargetWindowChange.changed, "The click's window then changed size or position"),
    ])
    func `click result names the window change and retires the snapshot`(
        change: TargetWindowChange,
        sentence: String) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
        fixture.automation.uiAutomationOutcomeScript.clickTargetWindowChange = change

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0, "observe_after": false,
            ]))

        #expect(!response.isError)
        guard case let .text(text, _, _)? = response.content.first else {
            Issue.record("Expected a text response")
            return
        }
        #expect(text.contains(sentence))
        #expect(!text.contains("may be reused"))
        #expect(!text.contains("identity validation failed"))
        #expect(response.meta?.objectValue?["target_window_change"] == .string(change.rawValue))
        #expect(fixture.snapshots.finishCalls.map(\.requiresFreshObservation) == [true])
    }
}
