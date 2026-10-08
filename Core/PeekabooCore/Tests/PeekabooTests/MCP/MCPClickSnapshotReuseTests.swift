import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// A background element click delivered as an accessibility action leaves its snapshot usable for further
/// element clicks. Every other delivery keeps requiring a fresh observation.
@Suite(.serialized)
@MainActor
struct MCPClickSnapshotReuseTests {
    @Test
    func `two element clicks share one snapshot when the first was an accessibility action`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified(.accessibilityAction))

        let first = try await Self.click(fixture)
        let second = try await Self.click(fixture)

        #expect(!first.isError)
        #expect(!second.isError)
        #expect(fixture.automation.mutationCalls == 2)
        #expect(fixture.snapshots.finishCalls.map(\.requiresFreshObservation) == [false, false])
        #expect(first.meta?.objectValue?["snapshot_reusable_for_element_clicks"] == .bool(true))
        let text = Self.text(first)
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("may be reused for further element clicks"))
        #expect(text.contains("one observation at the end"))
        #expect(!text.contains("Observe the target to verify the click"))
    }

    @Test
    func `pointer routed click still makes the next click refuse the stale snapshot`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified(.windowTargetedEvents))

        let first = try await Self.click(fixture)
        let second = try await Self.click(fixture)

        #expect(!first.isError)
        #expect(first.meta?.objectValue?["snapshot_reusable_for_element_clicks"] == nil)
        #expect(Self.text(first).contains("Observe the target to verify the click"))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: second)
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.finishCalls.map(\.requiresFreshObservation) == [true])
    }

    @Test
    func `indeterminate accessibility click still requires a fresh observation`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown))

        let first = try await Self.click(fixture)
        let second = try await Self.click(fixture)

        #expect(first.isError)
        #expect(first.meta?.objectValue?["snapshot_reusable_for_element_clicks"] == nil)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: second)
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.finishCalls.map(\.requiresFreshObservation) == [true])
    }

    private static func click(_ fixture: MCPSnapshotMutationTestFixture) async throws -> ToolResponse {
        try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))
    }

    private static func unverified(_ mechanism: DesktopActionOutcome.Delivery.Mechanism) -> DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: mechanism, mode: .background),
            evidence: .deliveryAccepted)
    }

    private static func text(_ response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else {
            Issue.record("Expected a text response")
            return ""
        }
        return text
    }
}
