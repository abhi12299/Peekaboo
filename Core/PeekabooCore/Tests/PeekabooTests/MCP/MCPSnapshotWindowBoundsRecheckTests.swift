import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// A background snapshot click re-reads the live window once when the only disagreement with the snapshot is the
/// window frame (same window ID, PID and process generation), e.g. while a just-launched app settles its window.
@Suite(.serialized)
@MainActor
struct MCPSnapshotWindowBoundsRecheckTests {
    @Test
    func `a window frame that settles back to the snapshot frame on a second read lets the click run`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
        let captured = try Self.capturedWindow(fixture)
        let settling = AutomationTestFixtures.window(
            copying: captured,
            bounds: captured.bounds.offsetBy(dx: 0, dy: 40))
        fixture.windows.defaultInventorySequence = [.complete([settling]), .complete([captured])]

        let response = try await Self.click(fixture)

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.mutationCalls == 1)
    }

    @Test
    func `a window that stays moved is still refused and the refusal says to observe it again`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        let moved = AutomationTestFixtures.window(
            copying: captured,
            bounds: captured.bounds.offsetBy(dx: 0, dy: 40))
        fixture.windows.defaultInventorySequence = [.complete([moved])]

        let response = try await Self.click(fixture)

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.windows.windowMutationInventoryRequests.count == 2)
        #expect(Self.text(response).contains(
            "window 42 moved or resized after snapshot '\(fixture.snapshotID)' was taken; run `see` again"))
    }

    @Test
    func `a window from another process generation is refused without a second read`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        let relaunched = AutomationTestFixtures.window(
            copying: captured,
            bounds: captured.bounds.offsetBy(dx: 0, dy: 40),
            processIdentity: .init(processIdentifier: 333, processStartIdentity: 34))
        fixture.windows.defaultInventorySequence = [.complete([relaunched]), .complete([captured])]

        let response = try await Self.click(fixture)

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.windows.windowMutationInventoryRequests.count == 1)
        #expect(!Self.text(response).contains("moved or resized"))
    }

    // MARK: - Helpers

    private static func capturedWindow(_ fixture: MCPSnapshotMutationTestFixture) throws -> ServiceWindowInfo {
        try #require(fixture.windows.windowsByIdentifier.values.lazy.flatMap(\.self).first { $0.windowID == 42 })
    }

    private static func click(_ fixture: MCPSnapshotMutationTestFixture) async throws -> ToolResponse {
        try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))
    }

    private static func text(_ response: ToolResponse) -> String {
        response.content.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}
