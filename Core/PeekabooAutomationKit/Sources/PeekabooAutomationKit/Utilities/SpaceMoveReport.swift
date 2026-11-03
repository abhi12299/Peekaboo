import PeekabooFoundation

/// The one-line result of a `space move-window`, shared by the CLI and the MCP tool.
///
/// It names the Space the window ended up on (number as `space list` prints it, and ID), says whether that was
/// verified, and says whether the user's own Space changed between the two inventories.
public enum SpaceMoveReport {
    public static func text(
        windowTitle: String,
        destinationID: UInt64,
        outcomeState: DesktopActionOutcome.State,
        spacesBefore: [SpaceInfo],
        spacesAfter: [SpaceInfo]) -> String
    {
        let userSpaceBefore = spacesBefore.first(where: \.isActive)?.id
        let userSpaceAfter = spacesAfter.first(where: \.isActive)?.id
        var destination = self.describe(destinationID, in: spacesBefore)
        if destinationID == userSpaceBefore {
            destination += ", the user's current Space"
        }

        var text = switch outcomeState {
        case .confirmedChange:
            "Moved window '\(windowTitle)' to \(destination). Verified: the window is now only on that Space."
        case .confirmedNoChange:
            "Window '\(windowTitle)' was already only on \(destination); nothing moved."
        default:
            "Asked macOS to move window '\(windowTitle)' to \(destination); the result was not verified."
        }

        if let before = userSpaceBefore, let after = userSpaceAfter {
            let beforeName = self.name(before, in: spacesBefore)
            text += before == after
                ? " The user's Space did not change (\(beforeName))."
                : " The user's Space changed from \(beforeName) to \(self.name(after, in: spacesAfter))."
        }
        return text
    }

    /// "Space 3 (ID 5)", or "Space ID 5" when the Space isn't in the list.
    static func describe(_ id: UInt64, in spaces: [SpaceInfo]) -> String {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return "Space ID \(id)" }
        return "Space \(index + 1) (ID \(id))"
    }

    private static func name(_ id: UInt64, in spaces: [SpaceInfo]) -> String {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return "Space ID \(id)" }
        return "Space \(index + 1)"
    }
}
