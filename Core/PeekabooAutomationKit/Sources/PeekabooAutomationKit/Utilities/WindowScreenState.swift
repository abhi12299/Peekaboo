import Foundation

/// How a listed window can be seen right now. macOS lists a window on a Space that no display shows as not on
/// screen with ordinary bounds, so neither the on-screen flag nor the geometry alone says where it is.
public enum WindowScreenState: Equatable, Sendable {
    case onScreen
    case minimized
    /// On a Space that is not showing. Input and accessibility still reach it; captures may be stale.
    case otherSpace(WindowSpacePlacement)
    /// Not on screen while its Space is visible (hidden, ordered out), off every display, or Space unknown.
    case offScreen

    public static func of(_ window: ServiceWindowInfo, spaces: SpaceVisibility) -> Self {
        if window.isMinimized { return .minimized }
        if !window.isOnScreen {
            let placement = spaces.placement(ofWindowInSpaces: window.spaceID.map { [$0] } ?? [])
            return placement.isOtherSpace ? .otherSpace(placement) : .offScreen
        }
        return window.isOffScreen ? .offScreen : .onScreen
    }

    public var label: String {
        switch self {
        case .onScreen: "ON-SCREEN"
        case .minimized: "MINIMIZED"
        case let .otherSpace(placement): "ON ANOTHER SPACE: \(placement.spaceDescription)"
        case .offScreen: "OFF-SCREEN"
        }
    }

    /// Stable machine-readable form for tool metadata.
    public var metadataValue: String {
        switch self {
        case .onScreen: "on_screen"
        case .minimized: "minimized"
        case .otherSpace: "other_space"
        case .offScreen: "off_screen"
        }
    }
}
