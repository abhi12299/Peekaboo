import CoreGraphics

extension DesktopTargetPlanning {
    /// macOS lists a window that sits on a Space that is not visible (for example after the user switched to a
    /// full-screen app) shifted sideways by about one display width plus a gap, and not on screen. The window did
    /// not move: same window, same size.
    public enum WindowSpaceShift {
        /// True only when the live frame looks like such an offset and nothing else: the window is not on screen,
        /// has the captured size and top edge, and moved sideways by at least its own width (a Space offset is a
        /// display width, so the two frames do not overlap). A window that is on screen at a new origin, was
        /// resized, moved vertically or was nudged a little was really changed, and this returns false.
        ///
        /// Window identity (ID, owner PID, process generation) is not checked here; callers must already have it.
        public static func isSpaceShift(captured: CGRect, live: CGRect, liveIsOnScreen: Bool) -> Bool {
            !liveIsOnScreen &&
                live.size == captured.size &&
                live.minY == captured.minY &&
                abs(live.minX - captured.minX) >= captured.width
        }

        /// The snapshot window as it is now on the other Space: the live window receipt, with the snapshot's
        /// focused element moved by the same offset so it keeps its place inside the window. Nil unless `live` is
        /// the same window (ID and owner process generation) and its frame is a Space offset of the snapshot's.
        public static func rebasing(
            _ snapshotWindow: UIAutomationTarget.ExactWindow,
            onto live: WindowMutationIdentity,
            liveIsOnScreen: Bool) throws -> UIAutomationTarget.ExactWindow?
        {
            guard live.windowID == snapshotWindow.identity.windowID,
                  live.processIdentity == snapshotWindow.identity.processIdentity,
                  let liveBounds = live.capturedBounds,
                  self.isSpaceShift(captured: snapshotWindow.bounds, live: liveBounds, liveIsOnScreen: liveIsOnScreen)
            else { return nil }
            let offset = liveBounds.minX - snapshotWindow.bounds.minX
            let focusedElement = snapshotWindow.focusedElement.map { element in
                FocusedElementIdentity(
                    processIdentifier: element.processIdentifier,
                    windowID: element.windowID,
                    role: element.role,
                    title: element.title,
                    identifier: element.identifier,
                    frame: element.frame.offsetBy(dx: offset, dy: 0))
            }
            return try UIAutomationTarget.ExactWindow(
                identity: live,
                bounds: liveBounds,
                focusedElement: focusedElement)
        }
    }
}
