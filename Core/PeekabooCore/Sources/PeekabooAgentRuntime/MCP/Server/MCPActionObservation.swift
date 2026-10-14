import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// A single input tool whose result can be `dispatched_unverified`. When such a call names its window (through a
/// snapshot, a coordinate reference or `window_id`), ``MCPToolContext/execute(tool:arguments:)`` observes that
/// window with `see` after the action and appends the result, so verifying the action needs no separate call.
/// `observe_after: false` turns this off; `observe_after: true` observes even a verified action.
protocol MCPWindowObservingTool: MCPTool {
    var actionObservation: MCPActionObservation { get set }
}

extension MCPWindowObservingTool {
    /// A copy that observes through `see` (nil: never observe, for a server whose `see` is disabled).
    func observing(with see: (any MCPTool)?) -> Self {
        var copy = self
        copy.actionObservation.seeTool = see
        copy.actionObservation.seeAvailable = see != nil
        return copy
    }
}

/// The `see` that verifies an input action in the same call. Shared by the single input tools and `batch`.
struct MCPActionObservation {
    static let argumentName = "observe_after"
    static let schemaProperty = SchemaBuilder.boolean(
        description: "Append a `see` of the target window. Omitted: only when delivery is unverified. " +
            "false: never. true: always.")

    /// The `see` tool; nil uses the context's own `see`.
    var seeTool: (any MCPTool)?
    /// False when `see` is disabled on this server.
    var seeAvailable = true

    init() {}

    /// Whether a tool result reports delivery that Peekaboo could not verify.
    static func isUnverified(_ response: ToolResponse) -> Bool {
        !response.isError && response.meta?.objectValue?["state"] == .string("dispatched_unverified")
    }

    /// `see` arguments that observe the window of `snapshot`, or nil when that window is unknown.
    @MainActor
    static func windowSeeArguments(snapshot: String?, uiSnapshots: MCPToolUISnapshotStore) async -> ToolArguments? {
        guard let snapshot, let windowID = await uiSnapshots.getSnapshot(id: snapshot)?.windowID else { return nil }
        return ToolArguments(raw: ["window_id": windowID])
    }

    /// Runs `tool` without observing, then observes its window when the result asks for it.
    @MainActor
    func execute(
        tool: any MCPTool,
        arguments: ToolArguments,
        context: MCPToolContext) async throws -> ToolResponse
    {
        let observeAfter = arguments.getBool(Self.argumentName)
        guard observeAfter != false, self.seeAvailable else {
            return try await context.executeWithoutObservation(tool: tool, arguments: arguments)
        }
        // Read the window before the action, which may invalidate its snapshot or close the window.
        let window = await ObservedWindow(arguments: arguments, uiSnapshots: context.uiSnapshots)
        let response = try await context.executeWithoutObservation(tool: tool, arguments: arguments)
        let unverified = Self.isUnverified(response)
        guard !response.isError, unverified || observeAfter == true, let window else { return response }

        let see = self.seeTool ?? SeeTool(context: context)
        let observed: ToolResponse
        do {
            observed = try await context.execute(tool: see, arguments: ToolArguments(raw: ["window_id": window.id]))
        } catch {
            return response
        }
        let summary = unverified ? Self.observedSummary(response) : response
        // A failed observation never turns the action into a failure; a window the action closed gets one line.
        var tail = observed.content
        if observed.isError, let goneLine = await window.goneLine(windows: context.windows) {
            tail = [.text(text: goneLine, annotations: nil, _meta: nil)]
        }
        return ToolResponse(content: summary.content + tail, isError: false, meta: response.meta)
    }

    /// The action's text, saying that the appended observation verifies it instead of asking for one.
    static func observedSummary(_ response: ToolResponse) -> ToolResponse {
        var content = response.content
        guard let index = content.firstIndex(where: {
            if case .text = $0 { return true }
            return false
        }), case let .text(text, annotations, meta) = content[index] else { return response }
        content[index] = .text(
            text: MCPDeliveredUnverifiedInput.observedMessage(text),
            annotations: annotations,
            _meta: meta)
        return ToolResponse(content: content, isError: response.isError, meta: response.meta)
    }
}

/// The window an input call targets, read before the action runs.
private struct ObservedWindow {
    let id: Int
    let processIdentifier: Int32?

    @MainActor
    init?(arguments: ToolArguments, uiSnapshots: MCPToolUISnapshotStore) async {
        for key in ["snapshot", "coordinate_reference"] {
            guard let reference = arguments.getString(key), !reference.isEmpty,
                  let snapshot = await uiSnapshots.getSnapshot(id: reference),
                  let windowID = snapshot.windowID
            else { continue }
            self.id = windowID
            self.processIdentifier = snapshot.applicationProcessId
            return
        }
        guard case let .int(windowID)? = arguments.getValue(for: "window_id"), windowID > 0 else { return nil }
        self.id = windowID
        self.processIdentifier = nil
    }

    /// One line when the window is gone (for example its close button was clicked), naming a dialog the app now
    /// shows; nil when the window is still listed or its app's windows cannot be read.
    @MainActor
    func goneLine(windows: any WindowManagementServiceProtocol) async -> String? {
        guard let processIdentifier,
              let appWindows = try? await windows.listWindows(target: .application("PID:\(processIdentifier)")),
              !appWindows.contains(where: { $0.windowID == self.id })
        else { return nil }
        var line = "Window \(self.id) is no longer open."
        if let dialog = appWindows.first(where: { Self.dialogSubroles.contains($0.subrole ?? "") }) {
            let title = dialog.title.isEmpty ? "" : " \"\(dialog.title)\""
            line += " The app now shows a dialog\(title); use the dialog tool to answer it."
        }
        return line
    }

    private static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXSheet"]
}
