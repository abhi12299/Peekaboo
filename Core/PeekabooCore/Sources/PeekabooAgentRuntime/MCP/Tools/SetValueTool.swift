import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct SetValueTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SetValueTool")
    private let context: MCPToolContext

    public let name = "set_value"

    public var description: String {
        """
        Sets a control's value directly through accessibility, in the background and without keystrokes, then reads
        it back. Use it on elements `see` or `inspect_ui` marks "[value settable]": text fields, combo boxes (pass the
        item text, e.g. "EUR"), sliders, checkboxes, a date picker (pass yyyy-MM-dd, e.g. "2027-03-15"; its time of
        day is kept) and a stepper (pass the number; it is stepped there and checked, about 0.1 s per step, so a text
        field paired with it is quicker to set). Prefer it to typing or clicking arrows. When the window's structure
        is unchanged the result says the snapshot may be reused, so several set_value steps can run in one `batch`.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "on": SchemaBuilder.string(
                    description: "Opaque element ID copied exactly from current `see` or `inspect_ui` output, " +
                        "or a query string."),
                "value": SchemaBuilder.anyOf(
                    [
                        SchemaBuilder.string(),
                        SchemaBuilder.boolean(),
                        SchemaBuilder.integer(),
                        SchemaBuilder.number(),
                    ],
                    description: "Value to set: string, boolean, integer, or number. Dates as yyyy-MM-dd."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
            ],
            required: ["on", "value"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        var effectiveSnapshotId: String?
        do {
            let request = try SetValueRequest(arguments: arguments)
            guard let automation = self.context.automation as? any ElementActionAutomationServiceProtocol else {
                throw SetValueToolError(
                    "set_value is not supported by this automation host",
                    errorCode: "RUNTIME_INCOMPATIBLE",
                    refusalReason: .runtimeIncompatible)
            }
            guard automation.supportsSetValueResultTargetBinding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot return a verifiable set-value result.",
                    hint: "Update the runtime host before retrying set-value.")
            }
            guard automation.supportsProcessGenerationBoundElementMutations else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot bind set-value to one process generation.",
                    hint: "Update the runtime host before retrying set-value.")
            }
            guard let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot return a receipted set-value outcome.",
                    hint: "Update the runtime host before retrying set-value.")
            }

            let startTime = Date()
            let snapshot = try await self.effectiveSnapshot(request.snapshotId)
            effectiveSnapshotId = snapshot.id
            let expectedTarget = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot)
            let (actionResult, invalidatedSnapshotId) = try await MCPElementActionSnapshotAuthority
                .withConfirmedMutation(
                    snapshot: snapshot,
                    expectedTarget: expectedTarget,
                    context: self.context,
                    operation: "Set value",
                    mutate: {
                        try await outcomeAutomation.setValueWithOutcome(
                            target: request.target,
                            value: request.value,
                            snapshotId: snapshot.id)
                    })
            let reusable = await MCPSetValueSnapshotReuse.keepsSnapshotReusable(
                outcome: actionResult.outcome,
                snapshotID: snapshot.id,
                context: self.context)
            let elapsed = Date().timeIntervalSince(startTime)
            return try self.buildResponse(
                actionResult: actionResult,
                value: request.value,
                executionTime: elapsed,
                invalidatedSnapshotId: invalidatedSnapshotId,
                reusableSnapshotId: reusable ? snapshot.id : nil)
        } catch let error as SetValueToolError {
            return try Self.preDispatchErrorResponse(error)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: effectiveSnapshotId,
                additionalFields: ObservationActionResultSupport.standardErrorFields(failure))
        } catch {
            self.logger.error("set_value failed: \(error.localizedDescription)")
            guard !(error is CancellationError) else {
                return ToolResponse.error("Failed to set value: \(error.localizedDescription)")
            }
            return MCPToolResponseMetadataProjector.unknownCompletionResponse(action: "Set value", error: error)
        }
    }

    private func effectiveSnapshot(_ requestedSnapshotId: String?) async throws -> UISnapshot {
        if let requestedSnapshotId {
            guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: requestedSnapshotId) else {
                throw SetValueToolError(
                    "Snapshot '\(requestedSnapshotId)' not found. Run 'see' or 'inspect_ui' again.",
                    errorCode: "SNAPSHOT_NOT_FOUND",
                    refusalReason: .targetUnavailable)
            }
            return snapshot
        }

        guard let snapshot = await self.context.uiSnapshots.getSnapshot(id: nil) else {
            throw SetValueToolError(
                "No active UI snapshot is available. Run 'see' or 'inspect_ui' before using set_value.",
                errorCode: "SNAPSHOT_NOT_FOUND",
                refusalReason: .targetUnavailable)
        }
        return snapshot
    }

    private static func preDispatchErrorResponse(_ error: SetValueToolError) throws -> ToolResponse {
        MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: error.message,
            reason: error.refusalReason,
            additionalFields: ["error_code": .string(error.errorCode)])
    }

    private func buildResponse(
        actionResult: UIAutomationActionResult<ElementActionResult>,
        value: UIElementValue,
        executionTime: TimeInterval,
        invalidatedSnapshotId: String?,
        reusableSnapshotId: String?) throws -> ToolResponse
    {
        let result = actionResult.payload
        var message = "\(AgentDisplayTokens.Status.success) Set value on \(result.target) in " +
            "\(String(format: "%.2f", executionTime))s"
        if let reusableSnapshotId {
            message += ". The window's structure is unchanged, so snapshot '\(reusableSnapshotId)' may be reused " +
                "for further element actions (pass it as `snapshot`)."
        }

        var meta: [String: Value] = [
            "execution_time": .double(executionTime),
            "target": .string(result.target),
            "value": Self.valueToMCP(value),
        ]

        if let oldValue = result.oldValue {
            meta["old_value"] = .string(oldValue)
        }
        if let newValue = result.newValue {
            meta["new_value"] = .string(newValue)
        }
        if let actionName = result.actionName {
            meta["action_name"] = .string(actionName)
        }
        if let anchor = result.anchorPoint {
            meta["anchor"] = .object([
                "x": .double(Double(anchor.x)),
                "y": .double(Double(anchor.y)),
            ])
        }
        if let invalidatedSnapshotId {
            meta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
        }
        if reusableSnapshotId != nil {
            meta[MCPToolResponseMetadataProjector.snapshotReusableForElementClicksKey] = .bool(true)
        }
        meta = try MCPDesktopTargetMetadataProjector.fields(actionResult.targetIdentity, merging: meta)

        return try ToolResponse.text(
            message,
            meta: MCPToolResponseMetadataProjector.metadata(merging: meta, outcome: actionResult.outcome))
    }

    private static func valueToMCP(_ value: UIElementValue) -> Value {
        switch value {
        case let .bool(raw):
            .bool(raw)
        case let .int(raw):
            .int(raw)
        case let .double(raw):
            .double(raw)
        case let .string(raw):
            .string(raw)
        }
    }
}

private struct SetValueRequest {
    let target: String
    let value: UIElementValue
    let snapshotId: String?

    init(arguments: ToolArguments) throws {
        guard let target = arguments.getString("on")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw SetValueToolError("Element target 'on' is required")
        }
        guard let rawValue = arguments.getValue(for: "value") else {
            throw SetValueToolError("Value is required")
        }

        self.target = target
        self.value = try Self.parseValue(rawValue)
        self.snapshotId = arguments.getString("snapshot")
    }

    private static func parseValue(_ value: Value) throws -> UIElementValue {
        switch value {
        case let .string(raw):
            .string(raw)
        case let .bool(raw):
            .bool(raw)
        case let .int(raw):
            .int(raw)
        case let .double(raw):
            .double(raw)
        case .null, .array, .object, .data:
            throw SetValueToolError("Value must be a string, boolean, integer, or number")
        }
    }
}

private struct SetValueToolError: Error {
    let message: String
    let errorCode: String
    let refusalReason: DesktopActionOutcome.RefusalReason

    init(
        _ message: String,
        errorCode: String = "VALIDATION_ERROR",
        refusalReason: DesktopActionOutcome.RefusalReason = .invalidRequest)
    {
        self.message = message
        self.errorCode = errorCode
        self.refusalReason = refusalReason
    }
}
