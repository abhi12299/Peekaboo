import AppKit
import CoreGraphics
import Foundation

/// Warns when a capture of a window on another Space may be out of date.
///
/// Chromium and Electron do not repaint, and do not update their accessibility tree, for a window on a Space that
/// no display shows. Measured with an Electron window there: the screenshot kept the frame from when the window
/// left the Space, and the element list kept an old clock value and the old tab selection while the page had moved
/// on. Input still reaches the window. An AppKit window there captured fresh content, so it is not flagged.
/// Covered windows on a visible Space are `CoveredWindowCapturePolicy`'s case (pb-chrome-web), not this one.
enum OffSpaceCapturePolicy {
    /// The Chromium switch that keeps a window rendering, and its accessibility tree current, while no display
    /// shows it. `app launch` starts Electron apps with it.
    static let keepsOccludedWindowsRenderingSwitch = "--disable-backgrounding-occluded-windows"

    static func warning(
        kind: WindowRoutedApplicationKind,
        placement: WindowSpacePlacement,
        launchArguments: [String]? = nil) -> String?
    {
        guard kind == .chromium || kind == .electron, placement.isOtherSpace else { return nil }
        // Measured with an Electron app started with the switch: on a hidden Space the screenshot and the
        // element list both showed the current state.
        if launchArguments?.dropFirst().contains(Self.keepsOccludedWindowsRenderingSwitch) == true { return nil }
        // Same "Screenshot may be stale: " prefix as CoveredWindowCapturePolicy, agreed with pb-chrome-web.
        return "Screenshot may be stale: this window is on \(placement.spaceDescription), which no display shows. " +
            "Chromium and Electron apps do not repaint or update a window there, so its accessibility elements " +
            "may be out of date too. Element clicks, `press` and `type` still reach it, but a later `see` cannot " +
            "confirm their effect; ask the user to show that Space when the current state matters."
    }

    @MainActor
    static func liveWarning(processIdentifier: pid_t, windowID: CGWindowID) -> String? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        let kind = WindowRoutedApplicationClassifier.kind(of: application)
        guard kind == .chromium || kind == .electron else { return nil }
        return self.warning(
            kind: kind,
            placement: WindowSpacePlacement.live(windowID: windowID),
            launchArguments: ProcessLaunchArguments.read(processIdentifier: processIdentifier))
    }
}

extension DesktopObservationService {
    func offSpaceWindowWarning(for capture: CaptureResult) -> String? {
        guard capture.metadata.mode == .window,
              let processIdentifier = capture.metadata.applicationInfo?.processIdentifier,
              let rawWindowID = capture.metadata.windowInfo?.windowID,
              let windowID = CGWindowID(exactly: rawWindowID)
        else { return nil }
        return self.offSpaceWindowCaptureWarning(processIdentifier, windowID)
    }
}
