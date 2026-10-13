import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// `batch` runs several input steps in one MCP call. Each step goes through the step tool's own execution path
/// on the shared context; the batch stops at the first failed step and says which steps did not run.
@Suite(.serialized)
@MainActor
struct MCPBatchToolTests {
    @Test
    func `runs every step in order through the step tools`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
            "press": ToolResponse.text("pressed"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "press", "args": ["label": "b"]],
            ["tool": "click", "args": ["label": "c"]],
        ]]))

        #expect(!response.isError)
        #expect(log.calls == ["click:a", "press:b", "click:c"])
        #expect(Self.text(response).contains("Ran all 3 steps"))
    }

    @Test
    func `stops at the first failed step and says which steps did not run`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
            "press": ToolResponse.error("Key press was refused"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "press", "args": ["label": "b"]],
            ["tool": "click", "args": ["label": "c"]],
            ["tool": "click", "args": ["label": "d"]],
        ]]))

        #expect(response.isError)
        #expect(log.calls == ["click:a", "press:b"])
        let text = Self.text(response)
        #expect(text.contains("Stopped at step 2 of 4 (press)"))
        #expect(text.contains("Steps 3-4 did not run"))
        #expect(text.contains("2. press: error: Key press was refused"))
        #expect(text.contains("1. click: ok: clicked"))
    }

    @Test
    func `a delivered but unverified step is reported as unverified and the batch continues`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let unverified = try ToolResponse(
            content: [.text(text: "[ok] Dispatched click; delivery is unverified", annotations: nil, _meta: nil)],
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: [:],
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted)))
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": unverified,
            "press": ToolResponse.text("pressed"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "press", "args": ["label": "b"]],
        ]]))

        #expect(!response.isError)
        #expect(log.calls == ["click:a", "press:b"])
        let text = Self.text(response)
        #expect(text.contains("1. click: unverified: [ok] Dispatched click; delivery is unverified"))
        #expect(text.contains("2. press: ok: pressed"))
        #expect(text.contains("1 step was delivered but unverified"))
    }

    @Test
    func `a step tool outside the allowlist refuses the whole batch before any step runs`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
            "app": ToolResponse.text("quit"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "app", "args": ["label": "b"]],
        ]]))

        #expect(response.isError)
        #expect(log.calls.isEmpty)
        let text = Self.text(response)
        #expect(text.contains("Step 2 uses 'app', which batch cannot run"))
        #expect(text.contains("No steps ran"))
    }

    @Test
    func `a nested batch step refuses the whole batch before any step runs`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
            "batch": ToolResponse.text("nested"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "batch", "args": ["label": "b"]],
        ]]))

        #expect(response.isError)
        #expect(log.calls.isEmpty)
        let text = Self.text(response)
        #expect(text.contains("Step 2 is a nested batch"))
        #expect(text.contains("No steps ran"))
    }

    @Test
    func `invalid arguments in a later step refuse the whole batch before any step runs`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: ["steps": [
            ["tool": "click", "args": ["label": "a"]],
            ["tool": "click", "args": ["label": "b", "bogus": true]],
        ]]))

        #expect(response.isError)
        #expect(log.calls.isEmpty)
        let text = Self.text(response)
        #expect(text.contains("Step 2 (click) has invalid arguments"))
        #expect(text.contains("bogus"))
        #expect(text.contains("No steps ran"))
    }

    @Test
    func `element clicks without their own snapshot reuse the batch snapshot`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted))

        let response = try await fixture.context.execute(
            tool: BatchTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID,
                "steps": [
                    ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                    ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                ],
            ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.mutationCalls == 2)
        #expect(fixture.snapshots.finishCalls.map(\.requiresFreshObservation) == [false, false])
    }

    @Test
    func `a step that leaves the snapshot stale stops later steps from inheriting it`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted))

        let response = try await fixture.context.execute(
            tool: BatchTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID,
                "steps": [
                    ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                    ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                    ["tool": "click", "args": ["on": "T1", "wait_for": 0]],
                ],
            ]))

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 1)
        let text = Self.text(response)
        #expect(text.contains("Stopped at step 2 of 3 (click)"))
        #expect(text.contains("Step 1 ran. Steps 2-3 did not run."))
        #expect(text.contains("snapshot '\(fixture.snapshotID)' is stale after step 1 (click)"))
        #expect(text.contains("1. click: unverified:"))
    }

    @Test
    func `observe_after runs see with the given arguments after the last step and appends its result`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": ToolResponse.text("clicked"),
            "see": ToolResponse.text("Calculator display: 33033"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: [
            "steps": [["tool": "click", "args": ["label": "a"]]],
            "observe_after": ["app_target": "Calculator", "label": "observe"],
        ]))

        #expect(!response.isError)
        #expect(log.calls == ["click:a", "see:observe"])
        #expect(log.arguments.last?.getString("app_target") == "Calculator")
        let text = Self.text(response)
        #expect(text.contains("Ran all 1 steps"))
        #expect(text.hasSuffix("Calculator display: 33033"))
    }

    @Test
    func `observe_after true observes the window of the batch snapshot`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let log = BatchProbeLog()
        let batch = BatchTool(context: fixture.context, stepTools: Self.probes(log, [
            "sleep": ToolResponse.text("paused"),
            "see": ToolResponse.text("observed"),
        ]))

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [["tool": "sleep", "args": ["label": "a"]]],
            "observe_after": true,
        ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(log.calls == ["sleep:a", "see:"])
        #expect(log.arguments.last?.getInt("window_id") == 42)
        #expect(Self.text(response).hasSuffix("observed"))
    }

    @Test
    func `unverified steps without observe_after observe the batch snapshot window in the same call`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let log = BatchProbeLog()
        let batch = BatchTool(context: fixture.context, stepTools: Self.probes(log, [
            "click": try Self.unverifiedClick,
            "see": ToolResponse.text("observed"),
        ]))

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [["tool": "click", "args": ["label": "a"]]],
        ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(log.calls == ["click:a", "see:"])
        #expect(log.arguments.last?.getInt("window_id") == 42)
        let text = Self.text(response)
        #expect(text.contains("1 step was delivered but unverified; the observation below verifies them"))
        #expect(text.hasSuffix("observed"))
    }

    @Test
    func `a failed automatic observation is appended without failing the steps that ran`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let log = BatchProbeLog()
        let batch = BatchTool(context: fixture.context, stepTools: Self.probes(log, [
            "click": try Self.unverifiedClick,
            "see": ToolResponse.error("Failed to capture UI state"),
        ]))

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [["tool": "click", "args": ["label": "a"]]],
        ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(log.calls == ["click:a", "see:"])
        let text = Self.text(response)
        #expect(text.contains("Ran all 1 steps"))
        #expect(text.contains("Failed to capture UI state"))
    }

    @Test
    func `observe_after false turns off the automatic observation`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let log = BatchProbeLog()
        let batch = BatchTool(context: fixture.context, stepTools: Self.probes(log, [
            "click": try Self.unverifiedClick,
            "see": ToolResponse.text("observed"),
        ]))

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [["tool": "click", "args": ["label": "a"]]],
            "observe_after": false,
        ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(log.calls == ["click:a"])
        #expect(Self.text(response).contains("1 step was delivered but unverified"))
    }

    @Test
    func `unverified steps with no known window say how to verify in the same call`() async throws {
        let log = BatchProbeLog()
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let batch = BatchTool(context: context, stepTools: Self.probes(log, [
            "click": try Self.unverifiedClick,
            "see": ToolResponse.text("observed"),
        ]))

        let response = try await context.execute(tool: batch, arguments: ToolArguments(raw: [
            "steps": [["tool": "click", "args": ["label": "a"]]],
        ]))

        #expect(!response.isError)
        #expect(log.calls == ["click:a"])
        #expect(Self.text(response).contains(
            "pass observe_after (true with a batch snapshot, or `see` arguments such as " +
                "{\"app_target\": \"Calculator\"}) to verify in the same call"))
    }

    @Test
    func `the description says unverified steps are observed in the same call unless observe_after is false`() async {
        let context = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let description = BatchTool(context: context).description

        #expect(description.contains("When `observe_after` is omitted and a step is unverified"))
        #expect(description.contains("`observe_after: false` turns this off"))
    }

    @Test
    func `batch is in the MCP catalog and PEEKABOO_DISABLE_TOOLS removes it`() async {
        let context = await MCPToolTestHelpers.makeContext()

        let listed = MCPToolCatalog.tools(
            context: context,
            inputPolicy: .currentBehavior,
            filters: ToolFiltering.filters(config: nil, environment: [:])).map(\.name)
        let disabled = MCPToolCatalog.tools(
            context: context,
            inputPolicy: .currentBehavior,
            filters: ToolFiltering.filters(config: nil, environment: ["PEEKABOO_DISABLE_TOOLS": "batch"])).map(\.name)

        #expect(listed.contains("batch"))
        #expect(!disabled.contains("batch"))
        #expect(disabled.contains("click"))
    }

    @Test
    func `a step tool disabled by PEEKABOO_DISABLE_TOOLS is refused inside batch`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let tools = MCPToolCatalog.tools(
            context: fixture.context,
            inputPolicy: .currentBehavior,
            filters: ToolFiltering.filters(config: nil, environment: ["PEEKABOO_DISABLE_TOOLS": "click"]))
        let batch = try #require(tools.first { $0.name == "batch" })

        let response = try await fixture.context.execute(tool: batch, arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "steps": [["tool": "click", "args": ["on": "T1", "wait_for": 0]]],
        ]))

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(Self.text(response).contains("Step 1 uses 'click', which batch cannot run"))
    }

    // MARK: - Helpers

    private static var unverifiedClick: ToolResponse {
        get throws {
            try ToolResponse(
                content: [.text(text: "[ok] Dispatched click; delivery is unverified", annotations: nil, _meta: nil)],
                meta: MCPToolResponseMetadataProjector.metadata(
                    merging: [:],
                    outcome: .dispatchedUnverified(
                        delivery: .init(mechanism: .accessibilityAction, mode: .background),
                        evidence: .deliveryAccepted)))
        }
    }

    private static func probes(
        _ log: BatchProbeLog,
        _ responses: [String: ToolResponse]) -> @MainActor (String) -> (any MCPTool)?
    {
        { name in
            responses[name].map { BatchProbeTool(name: name, log: log, response: $0) }
        }
    }

    private static func text(_ response: ToolResponse) -> String {
        response.content.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}

@MainActor
private final class BatchProbeLog {
    private(set) var calls: [String] = []
    private(set) var arguments: [ToolArguments] = []

    func record(_ name: String, _ arguments: ToolArguments) {
        self.calls.append("\(name):\(arguments.getString("label") ?? "")")
        self.arguments.append(arguments)
    }
}

private struct BatchProbeTool: MCPTool {
    let name: String
    let log: BatchProbeLog
    let response: ToolResponse
    let description = "Batch step probe"

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "label": SchemaBuilder.string(),
                "snapshot": SchemaBuilder.string(),
                "app": SchemaBuilder.string(),
                "app_target": SchemaBuilder.string(),
                "window_id": SchemaBuilder.integer(),
            ],
            required: [])
    }

    @MainActor
    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        self.log.record(self.name, arguments)
        return self.response
    }
}
