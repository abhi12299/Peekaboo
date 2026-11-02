import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

/// The benchmark's `window list` called a window on another Space ON-SCREEN while a click on it was refused
/// with "on screen: no". The listing must say where the window is.
@Suite(.serialized)
struct MCPWindowListSpaceTests {
    @Test
    func `window list labels a window on another Space with that Space and says so in metadata`() async throws {
        let app = ServiceApplicationInfo(processIdentifier: 1, bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
        let offSpace = ServiceWindowInfo(
            windowID: 5891,
            title: "Channel details",
            bounds: CGRect(x: 300, y: 490, width: 420, height: 192),
            index: 0,
            spaceID: 5,
            isOnScreen: false)
        let visible = ServiceWindowInfo(
            windowID: 5892,
            title: "Main",
            bounds: CGRect(x: 0, y: 30, width: 800, height: 600),
            index: 1,
            spaceID: 6)
        let applications = await MainActor.run {
            MockApplicationService(applications: [app], windowsByIdentifier: ["Slack": [offSpace, visible]])
        }
        let context = await MCPToolTestHelpers.makeContext(applications: applications)
        let tool = WindowTool(
            context: context,
            spaceVisibility: { SpaceVisibility(visibleSpaceIDs: [6], orderedSpaceIDs: [7, 6, 5, 4]) })

        let response = try await tool.execute(arguments: ToolArguments(raw: ["action": "list", "app": "Slack"]))

        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for window listing")
            return
        }
        let lines = output.split(separator: "\n")
        let offLine = try #require(lines.first { $0.contains("ID: 5891") })
        #expect(offLine.contains("ON ANOTHER SPACE: Space 3 (ID 5)"))
        #expect(!offLine.contains("ON-SCREEN"))
        #expect(lines.first { $0.contains("ID: 5892") }?.contains("ON-SCREEN") == true)
        guard case let .object(meta) = response.meta,
              case let .array(rows)? = meta["windows"],
              case let .object(row) = rows.first
        else {
            Issue.record("Expected window metadata")
            return
        }
        #expect(row["screen_state"] == .string("other_space"))
        #expect(row["space_id"] == .int(5))
    }
}
