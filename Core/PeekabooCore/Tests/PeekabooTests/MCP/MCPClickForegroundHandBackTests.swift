import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// When a background click's target app takes the front (AppKit does so for a modal sheet after one of the
/// app's menus was opened through accessibility), the click hands the front back. The agent must be told.
@Suite(.serialized)
@MainActor
struct MCPClickForegroundHandBackTests {
    @Test
    func `click result says the target took the front and it was handed back`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
        // No running app has these PIDs, so the text names them by PID.
        let restored: pid_t = 999_998
        fixture.automation.uiAutomationOutcomeScript.clickForegroundHandBack = ForegroundHandBackReport(
            handBacks: 1,
            targetProcessIdentifier: 999_997,
            restoredProcessIdentifier: restored)

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
        #expect(text.contains("PID 999997 came to the front during the click"))
        #expect(text.contains("the front was handed back to PID 999998."))
        let meta = response.meta?.objectValue
        #expect(meta?["front_hand_backs"] == .int(1))
        #expect(meta?["front_restored_pid"] == .int(Int(restored)))
    }

    @Test
    func `click result says when the front could not be handed back`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
        fixture.automation.uiAutomationOutcomeScript.clickForegroundHandBack = ForegroundHandBackReport(
            handBacks: 0,
            targetProcessIdentifier: 999_997,
            restoredProcessIdentifier: 999_998,
            targetKeptFront: true)

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
        #expect(text.contains("PID 999997 came to the front during the click"))
        #expect(text.contains("Peekaboo could not hand the front back to PID 999998; PID 999997 is still in front."))
        #expect(!text.contains("was handed back"))
        #expect(response.meta?.objectValue?["front_hand_backs"] == .int(0))
        #expect(response.meta?.objectValue?["front_target_kept"] == .bool(true))
    }
}
