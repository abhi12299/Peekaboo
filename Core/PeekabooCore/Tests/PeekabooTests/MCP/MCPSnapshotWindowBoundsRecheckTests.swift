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
            "window 42 moved or resized after snapshot '\(fixture.snapshotID)' was taken ("))
        #expect(Self.text(response).contains("); run `see` again and use the new snapshot"))
    }

    @Test
    func `the moved-window refusal names the captured and live frames`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        let moved = AutomationTestFixtures.window(
            copying: captured,
            bounds: captured.bounds.insetBy(dx: 0, dy: -11),
            isOnScreen: false)
        fixture.windows.defaultInventorySequence = [.complete([moved])]

        let response = try await Self.click(fixture)

        let capturedText = WindowIdentityDiagnostics.bounds(captured.bounds)
        let liveText = WindowIdentityDiagnostics.bounds(moved.bounds)
        #expect(response.isError)
        #expect(Self.text(response).contains(
            "window 42 moved or resized after snapshot '\(fixture.snapshotID)' was taken " +
                "(captured \(capturedText), now \(liveText), not on screen); run `see` again"))
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

    @Test
    func `a set value on a window that only moved to another Space runs`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted))
        let captured = try Self.capturedWindow(fixture)
        fixture.windows.defaultInventorySequence = [.complete([Self.onAnotherSpace(captured)])]

        let response = try await fixture.context.execute(
            tool: SetValueTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "value": "synthetic"]))

        #expect(!Self.text(response).contains("moved or resized"), "\(Self.text(response))")
        #expect(fixture.automation.setValueCalls == 1)
    }

    @Test
    func `a click on a window that only moved to another Space is still refused`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        fixture.windows.defaultInventorySequence = [.complete([Self.onAnotherSpace(captured)])]

        let response = try await Self.click(fixture)

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(Self.text(response).contains("moved or resized"), "\(Self.text(response))")
        #expect(Self.text(response).contains("not on screen"), "\(Self.text(response))")
    }

    @Test
    func `a key press on a window that only moved to another Space passes the snapshot frame check`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        fixture.windows.defaultInventorySequence = [.complete([Self.onAnotherSpace(captured)])]

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "keys": ["cmd+s"]]))

        #expect(!Self.text(response).contains("moved or resized"), "\(Self.text(response))")
    }

    @Test
    func `a key press on a window that only moved to another Space targets that window as it is now`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        fixture.windows.defaultInventorySequence = [.complete([Self.onAnotherSpace(captured)])]

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "keys": ["cmd+s"]]))

        #expect(!Self.text(response).contains("do not identify the same exact process/window receipt"),
                "\(Self.text(response))")
    }

    @Test
    func `typing on a window that only moved to another Space targets that window as it is now`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        fixture.windows.defaultInventorySequence = [.complete([Self.onAnotherSpace(captured)])]

        let response = try await fixture.context.execute(
            tool: TypeTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "text": "52514"]))

        #expect(!Self.text(response).contains("moved or resized"), "\(Self.text(response))")
        #expect(!Self.text(response).contains("do not identify the same exact process/window receipt"),
                "\(Self.text(response))")
    }

    @Test
    func `the window authorized on another Space keeps the snapshot editor at its place in the window`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let captured = try Self.capturedWindow(fixture)
        let moved = Self.onAnotherSpace(captured)
        fixture.windows.defaultInventorySequence = [.complete([moved])]
        let mirrored = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let detection = try #require(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID))

        let plan = try await fixture.context.backgroundSnapshotTargetPlan(
            toolName: "press",
            snapshotID: fixture.snapshotID,
            mirroredSnapshot: mirrored,
            detectionResult: detection,
            acceptsWindowSpaceShift: true)

        let window = try #require(plan.targetIdentity.exactWindow)
        #expect(window.bounds == moved.bounds)
        #expect(window.focusedElement?.frame == CGRect(x: 120 - 1574, y: 80, width: 180, height: 30))
    }

    // MARK: - Helpers

    /// How macOS lists a window on a Space that is not visible: shifted sideways by a display width plus a gap,
    /// same size, not on screen.
    private static func onAnotherSpace(_ captured: ServiceWindowInfo) -> ServiceWindowInfo {
        AutomationTestFixtures.window(
            copying: captured,
            bounds: captured.bounds.offsetBy(dx: -1574, dy: 0),
            isOnScreen: false)
    }

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
