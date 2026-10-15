import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// A single input tool whose delivery is unverified observes its own window in the same call, as `batch` does,
/// so the model does not follow every action with a separate `see`.
@Suite(.serialized)
@MainActor
struct MCPActionObservationTests {
    @Test
    func `an unverified click observes the snapshot window in the same call`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.text("observed window"))

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(see.log.arguments.map { $0.getInt("window_id") } == [42])
        let text = Self.text(response)
        #expect(text.contains("The observation below verifies the click"))
        #expect(!text.contains("Observe the target to verify"))
        #expect(text.hasSuffix("observed window"))
    }

    @Test
    func `observe_after false turns off the observation of a single action`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.text("observed window"))
        let click = ClickTool(context: fixture.context).observing(with: see)

        let response = try await fixture.context.execute(
            tool: click,
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0, "observe_after": false,
            ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(see.log.arguments.isEmpty)
        #expect(Self.text(response).contains("Observe the target to verify the click"))
        #expect(MCPToolArgumentValidator.rejection(
            tool: click,
            arguments: ToolArguments(raw: ["on": "T1", "observe_after": false]),
            snapshotEffect: .none) == nil)
    }

    @Test
    func `observe_after true observes a verified action, which is not observed by default`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let see = ObservationProbe(response: ToolResponse.text("observed window"))
        let click = ClickTool(context: fixture.context).observing(with: see)

        let quiet = try await fixture.context.execute(
            tool: click,
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))
        let observed = try await fixture.context.execute(
            tool: click,
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0, "observe_after": true,
            ]))

        #expect(!quiet.isError, "\(Self.text(quiet))")
        #expect(!observed.isError, "\(Self.text(observed))")
        #expect(see.log.arguments.map { $0.getInt("window_id") } == [42])
        #expect(!Self.text(quiet).contains("observed window"))
        #expect(Self.text(observed).hasSuffix("observed window"))
    }

    @Test
    func `an action that closed its window says so in one line and still succeeds`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        // The click closed window 42 and the app opened a save dialog; `see` no longer finds the window.
        let see = ObservationProbe(response: ToolResponse.error("Window 42 was not found")) {
            fixture.windows.replaceWindowsForTesting(["PID:333": [ServiceWindowInfo(
                windowID: 77,
                title: "Do you want to save?",
                bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                subrole: "AXDialog")]])
        }

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(see.log.arguments.count == 1)
        let text = Self.text(response)
        #expect(text.hasSuffix(
            "Window 42 is no longer open. The app now shows a dialog \"Do you want to save?\"; " +
                "use the dialog tool to answer it."))
        #expect(!text.contains("was not found"))
    }

    @Test
    func `a background Cmd+W press reports the closed window and the save sheet it left`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.error("Window 42 was not found")) {
            fixture.windows.replaceWindowsForTesting(["PID:333": [ServiceWindowInfo(
                windowID: 77,
                title: "Save changes?",
                bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                subrole: "AXSheet")]])
        }

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "key": "w", "modifiers": ["cmd"]]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.exactHotkeyCalls == 1)
        #expect(see.log.arguments.map { $0.getInt("window_id") } == [42])
        #expect(Self.text(response).hasSuffix(
            "Window 42 is no longer open. The app now shows a dialog \"Save changes?\"; " +
                "use the dialog tool to answer it."))
    }

    @Test
    func `a background Cmd+Q press whose app quit reports the window gone and still succeeds`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.error("Application PID:333 was not found")) {
            fixture.windows.listWindowsError = PeekabooError.appNotFound("PID:333")
        }

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "key": "q", "modifiers": ["cmd"]]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.exactHotkeyCalls == 1)
        let text = Self.text(response)
        #expect(text.hasSuffix("Window 42 is no longer open; its app is no longer running."))
        #expect(!text.contains("was not found"))
    }

    @Test
    func `a press that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        // What the host throws when its focused-element receipt check fails, e.g. for Calculator's input view.
        fixture.automation.mutationError = PeekabooError.invalidInput(
            field: "target",
            reason: "Exact focused-element receipt is stale: frame mismatch.")
        let see = ObservationProbe(response: ToolResponse.text("observed window"))

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "key": "q", "modifiers": ["cmd"]]))

        #expect(response.isError)
        let text = Self.text(response)
        #expect(text.contains("may not have been delivered"), "\(text)")
        #expect(text.contains("Exact focused-element receipt is stale"), "\(text)")
        #expect(!text.contains("without valid canonical result semantics"))
        guard case let .valid(projection) =
            MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        else {
            Issue.record("Expected a valid canonical outcome, got \(String(describing: response.meta))")
            return
        }
        #expect(projection.outcome.state == .indeterminate)
        #expect(see.log.arguments.isEmpty)
    }

    @Test
    func `typing that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.typeError = PeekabooError.invalidInput(
            field: "target",
            reason: "Exact focused-element receipt is stale: frame mismatch.")
        let see = ObservationProbe(response: ToolResponse.text("observed window"))

        let response = try await fixture.context.execute(
            tool: TypeTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "text": "52514"]))

        Self.expectCanonicalUnknownFailure(response, cause: "Exact focused-element receipt is stale")
        #expect(see.log.arguments.isEmpty)
    }

    @Test
    func `a click that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = PeekabooError.commandFailed("Window server rejected the click.")

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        Self.expectCanonicalUnknownFailure(response, cause: "Window server rejected the click.")
    }

    @Test
    func `a scroll that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = PeekabooError.commandFailed("Window server rejected the scroll.")

        let response = try await fixture.context.execute(
            tool: ScrollTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "direction": "down"]))

        Self.expectCanonicalUnknownFailure(response, cause: "Window server rejected the scroll.")
    }

    @Test
    func `a set value that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = PeekabooError.commandFailed("The element rejected AXValue.")

        let response = try await fixture.context.execute(
            tool: SetValueTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "value": "synthetic"]))

        Self.expectCanonicalUnknownFailure(response, cause: "The element rejected AXValue.")
    }

    @Test
    func `an action that fails with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = PeekabooError.commandFailed("The element rejected AXIncrement.")

        let response = try await fixture.context.execute(
            tool: ActionTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "action": "AXIncrement"]))

        Self.expectCanonicalUnknownFailure(response, cause: "The element rejected AXIncrement.")
    }

    @Test
    func `a text selection failing with a plain host error reports a canonical outcome with its cause`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = PeekabooError.commandFailed("The element rejected AXSelectedTextRange.")

        let response = try await fixture.context.execute(
            tool: SelectTextTool(context: fixture.context),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "text": "needle"]))

        Self.expectCanonicalUnknownFailure(response, cause: "The element rejected AXSelectedTextRange.")
    }

    @Test
    func `a failed observation of a window that is still open is appended without failing the action`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.error("Failed to capture UI state"))

        let response = try await fixture.context.execute(
            tool: ClickTool(context: fixture.context).observing(with: see),
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(!response.isError, "\(Self.text(response))")
        let text = Self.text(response)
        #expect(text.hasSuffix("Failed to capture UI state"))
        #expect(!text.contains("no longer open"))
    }

    @Test
    func `a batch step does not observe on its own and the batch observes once at the end`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))
        let stepSee = ObservationProbe(response: ToolResponse.text("step observation"))
        let batchSee = ObservationProbe(response: ToolResponse.text("batch observation"))
        let batch = BatchTool(context: fixture.context, stepTools: { name in
            switch name {
            case "click": ClickTool(context: fixture.context).observing(with: stepSee)
            case "see": batchSee
            default: nil
            }
        })

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [
                ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                ["tool": "click", "args": ["on": "T1", "wait_for": 0, "observe_after": true]],
            ],
        ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.mutationCalls == 2)
        #expect(stepSee.log.arguments.isEmpty)
        #expect(batchSee.log.arguments.map { $0.getInt("window_id") } == [42])
        #expect(Self.text(response).hasSuffix("batch observation"))
    }

    @Test
    func `single actions do not observe when see is disabled on the server`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let tools = MCPToolCatalog.tools(
            context: fixture.context,
            inputPolicy: .currentBehavior,
            filters: ToolFiltering.filters(config: nil, environment: ["PEEKABOO_DISABLE_TOOLS": "see"]))
        let click = try #require(tools.first { $0.name == "click" })

        let response = try await fixture.context.execute(
            tool: click,
            arguments: ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "wait_for": 0]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(response.content.count == 1)
        #expect(Self.text(response).contains("Observe the target to verify the click"))
    }

    @Test(arguments: ["press", "type", "scroll"])
    func `unverified keyboard and scroll actions observe the snapshot window too`(toolName: String) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(Self.unverified)
        let see = ObservationProbe(response: ToolResponse.text("observed window"))
        let (tool, arguments): (any MCPTool, [String: Any]) = switch toolName {
        case "press": (PressTool(context: fixture.context).observing(with: see), ["key": "s", "modifiers": ["cmd"]])
        case "type": (TypeTool(context: fixture.context).observing(with: see), ["text": "synthetic"])
        default: (ScrollTool(context: fixture.context).observing(with: see), ["on": "T1", "direction": "down"])
        }

        let response = try await fixture.context.execute(
            tool: tool,
            arguments: ToolArguments(raw: arguments.merging(["snapshot": fixture.snapshotID]) { $1 }))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(see.log.arguments.map { $0.getInt("window_id") } == [42])
        let text = Self.text(response)
        #expect(text.contains("The observation below verifies the"))
        #expect(!text.contains("Observe the target to verify"))
        #expect(text.hasSuffix("observed window"))
    }

    @Test
    func `input tools that can be unverified take observe_after and always-verified tools do not`() async {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let tools = MCPToolCatalog.tools(
            context: context,
            inputPolicy: .currentBehavior,
            filters: ToolFiltering.filters(config: nil, environment: [:]))

        let observing = Set(tools.filter { tool in
            guard case let .object(schema) = tool.inputSchema else { return false }
            return tool is any MCPWindowObservingTool && schema["properties"]?.objectValue?["observe_after"] != nil
        }.map(\.name))

        #expect(observing == ["click", "drag", "paste", "press", "scroll", "type"])
    }

    // MARK: - Helpers

    private static let unverified = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
        evidence: .deliveryAccepted)

    private static func expectCanonicalUnknownFailure(_ response: ToolResponse, cause: String) {
        #expect(response.isError)
        let text = Self.text(response)
        #expect(text.contains("may not have been delivered"), "\(text)")
        #expect(text.contains(cause), "\(text)")
        #expect(!text.contains("without valid canonical result semantics"))
        guard case let .valid(projection) =
            MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta)
        else {
            Issue.record("Expected a valid canonical outcome, got \(String(describing: response.meta))")
            return
        }
        #expect(projection.outcome.state == .indeterminate)
    }

    private static func text(_ response: ToolResponse) -> String {
        response.content.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}

@MainActor
private final class ObservationProbeLog {
    private(set) var arguments: [ToolArguments] = []

    func record(_ arguments: ToolArguments) {
        self.arguments.append(arguments)
    }
}

/// Stands in for `see`: records its arguments and returns a canned response.
private struct ObservationProbe: MCPTool {
    let name = "see"
    let description = "Observation probe"
    let log: ObservationProbeLog
    let response: ToolResponse
    let onExecute: @MainActor @Sendable () -> Void

    @MainActor
    init(response: ToolResponse, onExecute: @escaping @MainActor @Sendable () -> Void = {}) {
        self.log = ObservationProbeLog()
        self.response = response
        self.onExecute = onExecute
    }

    var inputSchema: Value {
        SchemaBuilder.object(properties: ["window_id": SchemaBuilder.integer()], required: [])
    }

    @MainActor
    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        self.log.record(arguments)
        self.onExecute()
        return self.response
    }
}
