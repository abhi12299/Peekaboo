import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// MCP tool that runs several input steps in one call.
///
/// Each step is dispatched through the shared ``MCPToolContext`` exactly as a separate call to that tool would be,
/// so validation, execution policy, background targeting and outcome classification stay the step tool's own.
public struct BatchTool: MCPTool {
    private let context: MCPToolContext
    private let stepTools: @MainActor (String) -> (any MCPTool)?
    /// Tools the server exposes; nil when unrestricted. A tool disabled for the server is disabled inside a batch.
    private var enabledToolNames: Set<String>?

    public let name = "batch"

    public var description: String {
        """
        Runs several input steps in order in one call, e.g. pressing several Calculator buttons, filling several
        fields, or typing text and then pressing Cmd+S. Each step is {"tool": <name>, "args": {...}} where tool is
        one of click, type, press, scroll, select_text, set_value, paste or sleep, and args are exactly what that
        tool takes on its own; each step gets the same validation, policy and background delivery as a separate call.
        A step that omits `snapshot` (and names no app/pid/window/coordinate_reference target) reuses the batch
        `snapshot` or the last snapshot an earlier step named. Element clicks delivered as accessibility actions
        keep the snapshot reusable; after any other mutating step, a later step that would reuse it stops the batch
        instead. The batch stops at the first failed step and lists which steps ran and which did not; a step that
        was delivered but is unverified counts as done. Set `observe_after` to true (observe the window of the first
        snapshot) or to `see` arguments such as {"app_target": "Calculator"} to get a fresh `see` after the last
        step; it is skipped when a step fails. When `observe_after` is omitted and a step is unverified, the batch
        observes the window of its snapshot itself and appends that `see` result, so no separate `see` is needed to
        verify; `observe_after: false` turns this off. Use separate calls for app/window lifecycle, menus and dialogs.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "steps": SchemaBuilder.array(
                    items: SchemaBuilder.object(
                        properties: [
                            "tool": SchemaBuilder.string(
                                description: "Step tool name.",
                                enum: Self.stepToolNames.sorted()),
                            "args": SchemaBuilder.object(
                                properties: [:],
                                description: "Arguments for the step tool.",
                                additionalProperties: true),
                        ],
                        required: ["tool"]),
                    description: "Steps to run in order.",
                    minItems: 1),
                "observe_after": SchemaBuilder.anyOf([
                    SchemaBuilder.boolean(),
                    SchemaBuilder.object(properties: [:], additionalProperties: true),
                ], description: "Arguments for a final `see` that runs after every step succeeded. Omitted: " +
                    "observe the snapshot window only when a step is unverified. false: never observe."),
                "snapshot": SchemaBuilder.string(
                    description: "Snapshot ID for steps that do not name their own snapshot or target."),
            ],
            required: ["steps"])
    }

    public init(context: MCPToolContext = .shared) {
        self.init(context: context, stepTools: { Self.stepTool(named: $0, context: context) })
    }

    init(context: MCPToolContext, stepTools: @escaping @MainActor (String) -> (any MCPTool)?) {
        self.context = context
        self.stepTools = stepTools
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let steps: [Step]
        switch self.parseSteps(arguments.getValue(for: "steps")) {
        case let .success(parsed): steps = parsed
        case let .failure(refusal): return refusal.response
        }
        let snapshot = arguments.getString("snapshot").flatMap { $0.isEmpty ? nil : $0 }
        let observedSnapshot = snapshot ?? steps.lazy.compactMap { $0.arguments.getString("snapshot") }.first
        let observeAfter = arguments.getValue(for: "observe_after")
        var observation: Step?
        switch await self.observation(observeAfter, snapshot: observedSnapshot) {
        case let .success(step): observation = step
        case let .failure(refusal): return refusal.response
        }

        let reports = try await self.run(steps, snapshot: snapshot)
        let succeeded = reports.last?.status != .error
        // Unverified delivery needs an observation; take it in this call instead of leaving it to a later one.
        let observesAutomatically = succeeded && observeAfter == nil &&
            reports.contains(where: { $0.status == .unverified })
        if observesAutomatically {
            observation = await self.automaticObservation(snapshot: observedSnapshot)
        }
        let summary = Self.response(reports: reports, total: steps.count, observed: succeeded && observation != nil)
        guard succeeded, let observation else { return summary }
        let observed = try await self.context.execute(tool: observation.tool, arguments: observation.arguments)
        // An automatic observation that fails does not make the steps that ran a failure.
        return ToolResponse(
            content: summary.content + observed.content,
            isError: observesAutomatically ? summary.isError : observed.isError)
    }

    /// The `see` that verifies unverified steps when `observe_after` was not given: the batch snapshot's window, or
    /// none when that window is unknown or `see` is unavailable.
    @MainActor
    private func automaticObservation(snapshot: String?) async -> Step? {
        guard case let .success(step) = await self.observation(.bool(true), snapshot: snapshot) else { return nil }
        return step
    }

    /// Resolves and validates every step before any of them runs.
    @MainActor
    private func parseSteps(_ value: Value?) -> Result<[Step], Refusal> {
        guard case let .array(rawSteps)? = value, !rawSteps.isEmpty else {
            return .failure(Refusal("`steps` must be a nonempty array."))
        }
        var steps: [Step] = []
        for (offset, rawStep) in rawSteps.enumerated() {
            let index = offset + 1
            guard case let .object(step) = rawStep, case let .string(toolName)? = step["tool"] else {
                return .failure(Refusal("Step \(index) must be an object with a string `tool`."))
            }
            guard toolName != self.name else {
                return .failure(Refusal("Step \(index) is a nested batch; put its steps in this batch instead."))
            }
            guard self.allowedStepToolNames.contains(toolName), let tool = self.stepTools(toolName) else {
                return .failure(Refusal(
                    "Step \(index) uses '\(toolName)', which batch cannot run. Allowed step tools: " +
                        "\(self.allowedStepToolNames.sorted().joined(separator: ", "))."))
            }
            let stepArguments = ToolArguments(value: step["args"] ?? .object([:]))
            if let rejection = MCPToolArgumentValidator.rejection(
                tool: tool,
                arguments: stepArguments,
                snapshotEffect: MCPToolSnapshotMutationPolicy.effect(toolName: toolName, arguments: stepArguments))
            {
                return .failure(Refusal(
                    "Step \(index) (\(toolName)) has invalid arguments: \(StepReport.firstLine(of: rejection))"))
            }
            steps.append(Step(tool: tool, arguments: stepArguments))
        }
        return .success(steps)
    }

    /// The final `see`: none when not asked for; `true` observes the window of the batch's first snapshot.
    @MainActor
    private func observation(_ value: Value?, snapshot: String?) async -> Result<Step?, Refusal> {
        let seeArguments: ToolArguments
        switch value {
        case let .object(fields)?:
            seeArguments = ToolArguments(value: .object(fields))
        case .bool(true)?:
            guard let windowArguments = await MCPActionObservation.windowSeeArguments(
                snapshot: snapshot,
                uiSnapshots: self.context.uiSnapshots)
            else {
                return .failure(Refusal(
                    "observe_after: true needs a snapshot whose window is known; pass `see` arguments instead, " +
                        "for example {\"app_target\": \"Calculator\"}."))
            }
            seeArguments = windowArguments
        default:
            return .success(nil)
        }
        guard self.enabledToolNames?.contains("see") ?? true, let seeTool = self.stepTools("see") else {
            return .failure(Refusal("observe_after needs the `see` tool, which is not available."))
        }
        return .success(Step(tool: seeTool, arguments: seeArguments))
    }

    /// Runs the steps in order and stops at the first failure, including a step that would reuse a stale snapshot.
    @MainActor
    private func run(_ steps: [Step], snapshot: String?) async throws -> [StepReport] {
        var carriedSnapshot = snapshot
        // The step after which the carried snapshot may no longer be reused for element targeting.
        var staleAfter: StepReport?
        var reports: [StepReport] = []
        for (offset, step) in steps.enumerated() {
            let index = offset + 1
            var stepArguments = step.arguments
            if let explicitSnapshot = stepArguments.getString("snapshot"), !explicitSnapshot.isEmpty {
                carriedSnapshot = explicitSnapshot
                staleAfter = nil
            } else if let carriedSnapshot, Self.inheritsSnapshot(tool: step.tool, arguments: stepArguments) {
                if let staleAfter {
                    reports.append(StepReport(index: index, toolName: step.tool.name, response: .error(
                        "Not run: snapshot '\(carriedSnapshot)' is stale after step \(staleAfter.index) " +
                            "(\(staleAfter.toolName)), whose result did not say the snapshot may be reused. Run " +
                            "`see` and pass the new snapshot."), dispatched: false))
                    return reports
                }
                stepArguments = Self.arguments(stepArguments, settingSnapshot: carriedSnapshot)
            }
            // The step tool does not observe on its own; the batch observes once after the last step.
            let response = try await self.context.executeWithoutObservation(tool: step.tool, arguments: stepArguments)
            let report = StepReport(index: index, toolName: step.tool.name, response: response)
            reports.append(report)
            if report.status == .error {
                return reports
            }
            if carriedSnapshot != nil, staleAfter == nil,
               Self.mayInvalidateSnapshot(toolName: step.tool.name, arguments: stepArguments, response: response)
            {
                staleAfter = report
            }
        }
        return reports
    }

    /// A copy that only runs steps (and the final `see`) through tools in `toolNames`.
    func restrictingSteps(to toolNames: Set<String>) -> Self {
        var copy = self
        copy.enabledToolNames = toolNames
        return copy
    }

    private var allowedStepToolNames: Set<String> {
        self.enabledToolNames.map { Self.stepToolNames.intersection($0) } ?? Self.stepToolNames
    }

    /// Input and pause tools a batch may run. Observation, app/window lifecycle and nested batches stay separate
    /// calls.
    static let stepToolNames: Set<String> = [
        "click", "paste", "press", "scroll", "select_text", "set_value", "sleep", "type",
    ]

    /// Step argument keys that pick a target on their own; a step that names one does not inherit the snapshot.
    private static let explicitTargetKeys = [
        "app", "coordinate_reference", "pid", "window_id", "window_index", "window_title",
    ]

    @MainActor
    private static func stepTool(named name: String, context: MCPToolContext) -> (any MCPTool)? {
        switch name {
        case "click": ClickTool(context: context)
        case "paste": PasteTool(context: context)
        case "press": PressTool(context: context)
        case "scroll": ScrollTool(context: context)
        case "see": SeeTool(context: context)
        case "select_text": SelectTextTool(context: context)
        case "set_value": SetValueTool(context: context)
        case "sleep": SleepTool()
        case "type": TypeTool(context: context)
        default: nil
        }
    }

    private static func inheritsSnapshot(tool: any MCPTool, arguments: ToolArguments) -> Bool {
        guard case let .object(schema) = tool.inputSchema,
              schema["properties"]?.objectValue?["snapshot"] != nil
        else { return false }
        return !Self.explicitTargetKeys.contains { arguments.getValue(for: $0) != nil }
    }

    /// Every step that can change the UI consumes the snapshot unless its result says otherwise (an element click
    /// delivered as an accessibility action sets `snapshot_reusable_for_element_clicks`).
    private static func mayInvalidateSnapshot(
        toolName: String,
        arguments: ToolArguments,
        response: ToolResponse) -> Bool
    {
        guard MCPToolSnapshotMutationPolicy.effect(toolName: toolName, arguments: arguments) != .none else {
            return false
        }
        let reusableKey = MCPToolResponseMetadataProjector.snapshotReusableForElementClicksKey
        return response.meta?.objectValue?[reusableKey] != .bool(true)
    }

    private static func arguments(_ arguments: ToolArguments, settingSnapshot snapshot: String) -> ToolArguments {
        var fields = arguments.rawValue.objectValue ?? [:]
        fields["snapshot"] = .string(snapshot)
        return ToolArguments(value: .object(fields))
    }

    private static func stepRange(_ first: Int, _ last: Int, ifEmpty empty: String) -> String {
        if last < first { return empty }
        return first == last ? "Step \(first)" : "Steps \(first)-\(last)"
    }

    private static func response(reports: [StepReport], total: Int, observed: Bool) -> ToolResponse {
        let lines = reports.map { "\($0.index). \($0.toolName): \($0.status.rawValue): \($0.message)" }
        guard let failed = reports.last, failed.status == .error else {
            var header = "\(AgentDisplayTokens.Status.success) Ran all \(total) steps."
            let unverified = reports.count(where: { $0.status == .unverified })
            if unverified > 0 {
                header += unverified == 1
                    ? " 1 step was delivered but unverified"
                    : " \(unverified) steps were delivered but unverified"
                header += observed
                    ? "; the observation below verifies them, so do not retry blindly."
                    : "; pass observe_after (true with a batch snapshot, or `see` arguments such as " +
                    "{\"app_target\": \"Calculator\"}) to verify in the same call, or observe the target once, " +
                    "and do not retry blindly."
            }
            return ToolResponse.text(([header] + lines).joined(separator: "\n"))
        }
        let ran = failed.dispatched ? failed.index : failed.index - 1
        var header = "\(AgentDisplayTokens.Status.failure) Stopped at step \(failed.index) of \(total) " +
            "(\(failed.toolName)). " + Self.stepRange(1, ran, ifEmpty: "No steps") + " ran."
        if ran < total {
            header += " " + Self.stepRange(ran + 1, total, ifEmpty: "") + " did not run."
        }
        return ToolResponse.error(([header] + lines).joined(separator: "\n"))
    }
}

private struct Step {
    let tool: any MCPTool
    let arguments: ToolArguments
}

/// A batch refused before any step ran.
private struct Refusal: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var response: ToolResponse {
        ToolResponse.error("\(AgentDisplayTokens.Status.failure) \(self.message) No steps ran.")
    }
}

private struct StepReport {
    enum Status: String {
        case ok
        case unverified
        case error
    }

    let index: Int
    let toolName: String
    let status: Status
    let message: String
    /// False when the batch stopped this step itself instead of dispatching it.
    let dispatched: Bool

    init(index: Int, toolName: String, response: ToolResponse, dispatched: Bool = true) {
        self.index = index
        self.dispatched = dispatched
        self.toolName = toolName
        self.status = if response.isError {
            .error
        } else if MCPActionObservation.isUnverified(response) {
            .unverified
        } else {
            .ok
        }
        self.message = Self.firstLine(of: response)
    }

    static func firstLine(of response: ToolResponse) -> String {
        let text = response.content.lazy.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.first ?? ""
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return firstLine.count > 240 ? String(firstLine.prefix(240)) + "…" : firstLine
    }
}
