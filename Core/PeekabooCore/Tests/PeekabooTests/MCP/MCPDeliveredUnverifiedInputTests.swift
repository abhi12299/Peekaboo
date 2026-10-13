import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// Input that the receiver accepted but Peekaboo could not verify is a success with a warning: the agent
/// must observe the target, but the tool call itself did not fail.
@Suite(.serialized)
@MainActor
struct MCPDeliveredUnverifiedInputTests {
    @Test
    func `click whose delivery was accepted but not verified succeeds with an unverified warning`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let outcome = Self.deliveredUnverified(.accessibilityAction)
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let text = Self.text(response)
        #expect(text.hasPrefix("\(AgentDisplayTokens.Status.success) Dispatched click"))
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("unsafe to retry blindly"))
        #expect(fixture.automation.mutationCalls == 1)
    }

    @Test
    func `click whose completion is indeterminate stays an error`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown)
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(Self.text(response).contains("Click did not return a confirmed outcome."))
    }

    @Test
    func `press whose delivery was accepted but not verified succeeds with an unverified warning`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let outcome = Self.deliveredUnverified(.windowTargetedEvents)
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "key": "s", "modifiers": ["cmd"]]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(response.meta?.objectValue?["requires_fresh_observation"] == .bool(true))
        let text = Self.text(response)
        #expect(text.hasPrefix("\(AgentDisplayTokens.Status.success) Dispatched press"))
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("unsafe to retry blindly"))
        #expect(fixture.automation.exactHotkeyCalls == 1)
    }

    @Test
    func `typing whose delivery was accepted but not verified succeeds with an unverified warning`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let outcome = Self.deliveredUnverified(.windowTargetedEvents)
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)

        let response = try await fixture.context.execute(
            tool: TypeTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "text": "synthetic"]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let text = Self.text(response)
        #expect(text.hasPrefix("\(AgentDisplayTokens.Status.success) Dispatched typing"))
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("unsafe to retry blindly"))
        #expect(fixture.automation.typeCalls == 1)
    }

    @Test
    func `scroll whose delivery was accepted but not verified succeeds with an unverified warning`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let outcome = Self.deliveredUnverified(.windowTargetedEvents)
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)

        let response = try await fixture.context.execute(
            tool: ScrollTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "direction": "down"]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let text = Self.text(response)
        #expect(text.hasPrefix("\(AgentDisplayTokens.Status.success) Dispatched scroll"))
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("unsafe to retry blindly"))
        #expect(fixture.automation.scrollRequests.count == 1)
    }

    @Test
    func `background text paste whose delivery was accepted but not verified succeeds with a warning`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = MockConfirmedTypeAutomationService(accessibilityGranted: true)
        let outcome = Self.deliveredUnverified(.processTargetedEvents)
        automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)
        let clipboard = ScriptedClipboardService()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: MockApplicationService(applications: [app]),
            clipboard: clipboard)

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: ["app": "Editor", "text": "hello"]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let text = Self.text(response)
        #expect(text.hasPrefix("\(AgentDisplayTokens.Status.success) Dispatched paste"))
        #expect(text.contains("delivery is unverified"))
        #expect(text.contains("unsafe to retry blindly"))
        #expect(response.meta?.objectValue?["characters_typed"] == Value.null)
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test(arguments: [
        DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .completionUnknown),
        DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background)),
    ])
    func `background text paste that is not accepted delivery stays an error`(
        outcome: DesktopActionOutcome) async throws
    {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = MockConfirmedTypeAutomationService(accessibilityGranted: true)
        automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: MockApplicationService(applications: [app]),
            clipboard: ScriptedClipboardService())

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: ["app": "Editor", "text": "hello"]))

        #expect(response.isError)
        #expect(!Self.text(response).contains("Dispatched paste"))
    }

    private static func deliveredUnverified(
        _ mechanism: DesktopActionOutcome.Delivery.Mechanism,
        mode: DesktopActionOutcome.Delivery.Mode = .background) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: mechanism, mode: mode),
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
