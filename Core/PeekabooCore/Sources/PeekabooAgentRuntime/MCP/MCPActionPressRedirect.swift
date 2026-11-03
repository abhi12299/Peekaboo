import Foundation
import MCP
import TachikomaMCP

/// `click` on an element is already a background accessibility press, with the exact-window checks, the
/// dialog refusal and the front hand-back. A background-only policy refuses `action AXPress` as something that
/// can raise foreground UI, which left the two tools disagreeing about the same press. When the policy refuses
/// it, a press on a snapshot element runs as `click` on that element instead; the click's own policy and
/// checks then decide.
enum MCPActionPressRedirect {
    static let prefix = "AXPress ran as a background click: "

    /// The click arguments for an `action` call that presses a snapshot element, or nil for anything else.
    static func clickArguments(toolName: String, arguments: ToolArguments) -> ToolArguments? {
        guard toolName == "action",
              let action = arguments.getString("action")?.trimmingCharacters(in: .whitespacesAndNewlines),
              ["axpress", "press"].contains(action.lowercased()),
              let on = Self.nonEmpty(arguments.getString("on")),
              let snapshot = Self.nonEmpty(arguments.getString("snapshot"))
        else {
            return nil
        }
        return ToolArguments(raw: ["on": on, "snapshot": snapshot])
    }

    /// Prefixes the click's first text so the caller knows which tool ran.
    static func annotate(_ response: ToolResponse) -> ToolResponse {
        var content = response.content
        if case let .text(text, annotations, meta)? = content.first {
            content[0] = .text(text: Self.prefix + text, annotations: annotations, _meta: meta)
        }
        return ToolResponse(
            content: content,
            isError: response.isError,
            meta: response.meta,
            structuredContent: response.structuredContent)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
