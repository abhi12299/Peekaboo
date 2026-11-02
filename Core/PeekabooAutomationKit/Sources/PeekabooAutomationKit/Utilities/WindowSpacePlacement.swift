import CoreGraphics
import Foundation

/// Where a window sits relative to the Spaces the user can see right now.
///
/// macOS lists a window on a Space that is not visible as not on screen, the same as a minimized or hidden
/// window. Background input treats the two differently: a window on another Space still takes keyboard input,
/// accessibility actions and (AppKit only) routed clicks, while a minimized or hidden one does not.
public enum WindowSpacePlacement: Equatable, Sendable {
    /// The window belongs to at least one Space that is visible on some display.
    case visibleSpace
    /// The window belongs only to Spaces that no display is showing. `spaceNumber` is the 1-based position in
    /// the user's Space list (as `space list` prints it), when known.
    case otherSpace(spaceID: UInt64, spaceNumber: Int?)
    /// macOS reported no Space for the window, or the Space list could not be read.
    case unknown

    /// Classifies a window from its Space memberships and the Spaces each display is showing.
    /// `orderedSpaceIDs` is the user's Space list in display order, used only to number the Space.
    public static func classify(
        windowSpaceIDs: [UInt64],
        visibleSpaceIDs: Set<UInt64>,
        orderedSpaceIDs: [UInt64] = []) -> Self
    {
        guard let first = windowSpaceIDs.first, !visibleSpaceIDs.isEmpty else { return .unknown }
        if windowSpaceIDs.contains(where: visibleSpaceIDs.contains) {
            return .visibleSpace
        }
        let number = orderedSpaceIDs.firstIndex(of: first).map { $0 + 1 }
        return .otherSpace(spaceID: first, spaceNumber: number)
    }

    public var isOtherSpace: Bool {
        if case .otherSpace = self { return true }
        return false
    }

    /// "Space 3" when the number is known, otherwise "another Space".
    public var spaceDescription: String {
        switch self {
        case let .otherSpace(_, number?):
            "Space \(number)"
        case .otherSpace, .visibleSpace, .unknown:
            "another Space"
        }
    }
}

extension WindowSpacePlacement {
    /// Reads the window's Space memberships and the Space each display shows from the window server.
    @MainActor
    public static func live(windowID: CGWindowID) -> Self {
        let connection = _CGSDefaultConnection()
        guard connection != 0,
              let windowSpaces = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, [windowID] as CFArray)
        else {
            return .unknown
        }
        let windowSpaceIDs = (windowSpaces as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
        var visible = Set<UInt64>()
        var ordered: [UInt64] = []
        for case let display as [String: Any] in CGSCopyManagedDisplaySpaces(connection) as NSArray {
            if let current = display["Current Space"] as? [String: Any], let id = Self.spaceID(current) {
                visible.insert(id)
            }
            for case let space as [String: Any] in display["Spaces"] as? [Any] ?? [] {
                if let id = Self.spaceID(space) { ordered.append(id) }
            }
        }
        if visible.isEmpty {
            let active = CGSGetActiveSpace(connection)
            if active != 0 { visible.insert(active) }
        }
        return self.classify(windowSpaceIDs: windowSpaceIDs, visibleSpaceIDs: visible, orderedSpaceIDs: ordered)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value
    }
}
