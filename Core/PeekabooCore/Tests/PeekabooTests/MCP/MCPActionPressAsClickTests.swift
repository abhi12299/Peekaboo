import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// `click` on an element is already a background accessibility press. A background-only session runs
/// `action AXPress` on a snapshot element as that same click, so the two tools agree.
@Suite(.serialized)
@MainActor
struct MCPActionPressAsClickTests {
    @Test
    func `background action AXPress on a snapshot element runs as a background click`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))

        let response = try await fixture.context.execute(
            tool: ActionTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "action": "AXPress"]))

        #expect(!response.isError)
        guard case let .text(text, _, _)? = response.content.first else {
            Issue.record("Expected a text response")
            return
        }
        #expect(text.hasPrefix("AXPress ran as a background click: "))
        #expect(text.contains("Dispatched click single"))
        #expect(fixture.automation.uiAutomationOutcomeScript.callCount(for: .click) == 1)
        #expect(fixture.automation.actionCalls == 0)
    }

    @Test
    func `background action AXShowMenu stays refused`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()

        let response = try await fixture.context.execute(
            tool: ActionTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "action": "AXShowMenu"]))

        #expect(response.isError)
        #expect(fixture.automation.uiAutomationOutcomeScript.callCount(for: .click) == 0)
        #expect(fixture.automation.actionCalls == 0)
    }
}
