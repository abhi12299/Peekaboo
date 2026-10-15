import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

/// macOS lists a window on a Space that is not visible shifted sideways by about one display width (plus a gap).
struct WindowSpaceShiftTests {
    private static let captured = CGRect(x: 152, y: 73, width: 656, height: 422)

    @Test
    func `an off-screen window shifted sideways by a display width only changed Space`() {
        #expect(DesktopTargetPlanning.WindowSpaceShift.isSpaceShift(
            captured: Self.captured,
            live: CGRect(x: -1422, y: 73, width: 656, height: 422),
            liveIsOnScreen: false))
    }

    @Test
    func `a window that is on screen at a new origin was really moved`() {
        #expect(!DesktopTargetPlanning.WindowSpaceShift.isSpaceShift(
            captured: Self.captured,
            live: CGRect(x: -1422, y: 73, width: 656, height: 422),
            liveIsOnScreen: true))
    }

    @Test
    func `an off-screen window with a different size was resized`() {
        #expect(!DesktopTargetPlanning.WindowSpaceShift.isSpaceShift(
            captured: Self.captured,
            live: CGRect(x: -1422, y: 73, width: 700, height: 422),
            liveIsOnScreen: false))
    }

    @Test
    func `an off-screen window that also moved vertically is not a Space offset`() {
        #expect(!DesktopTargetPlanning.WindowSpaceShift.isSpaceShift(
            captured: Self.captured,
            live: CGRect(x: -1422, y: 120, width: 656, height: 422),
            liveIsOnScreen: false))
    }

    @Test
    func `an off-screen window nudged sideways by less than its width is not a Space offset`() {
        #expect(!DesktopTargetPlanning.WindowSpaceShift.isSpaceShift(
            captured: Self.captured,
            live: CGRect(x: 300, y: 73, width: 656, height: 422),
            liveIsOnScreen: false))
    }

    @Test
    func `the position-independent window check accepts the receipted window on another Space`() {
        let live = Self.liveWindow(bounds: CGRect(x: -1422, y: 73, width: 656, height: 422))

        #expect(SystemIdentityResolver.validateWindowMutationIdentityAllowingSpaceShift(
            Self.receipt,
            expectedBounds: Self.captured,
            processStartIdentityProvider: { _ in 33 },
            windowIdentityProvider: { _ in live }))
    }

    @Test
    func `the position-independent window check refuses another owner or process generation`() {
        let shifted = CGRect(x: -1422, y: 73, width: 656, height: 422)

        #expect(!SystemIdentityResolver.validateWindowMutationIdentityAllowingSpaceShift(
            Self.receipt,
            expectedBounds: Self.captured,
            processStartIdentityProvider: { _ in 33 },
            windowIdentityProvider: { _ in Self.liveWindow(bounds: shifted, ownerProcessIdentifier: 444) }))
        #expect(!SystemIdentityResolver.validateWindowMutationIdentityAllowingSpaceShift(
            Self.receipt,
            expectedBounds: Self.captured,
            processStartIdentityProvider: { _ in 34 },
            windowIdentityProvider: { _ in Self.liveWindow(bounds: shifted) }))
    }

    @Test
    func `the position-independent window check still accepts the window where it was captured`() {
        #expect(SystemIdentityResolver.validateWindowMutationIdentityAllowingSpaceShift(
            Self.receipt,
            expectedBounds: Self.captured,
            processStartIdentityProvider: { _ in 33 },
            windowIdentityProvider: { _ in Self.liveWindow(bounds: Self.captured, isOnScreen: true) }))
    }

    @Test
    func `rebasing onto the window on another Space moves the focused element with it`() throws {
        let editor = FocusedElementIdentity(
            processIdentifier: 333,
            windowID: 272,
            role: "AXTextArea",
            frame: CGRect(x: 160, y: 120, width: 600, height: 300))
        let snapshot = try UIAutomationTarget.ExactWindow(
            identity: Self.receipt,
            bounds: Self.captured,
            focusedElement: editor)
        let shifted = CGRect(x: -1422, y: 73, width: 656, height: 422)
        let live = WindowMutationIdentity(
            windowID: 272,
            ownerProcessIdentifier: 333,
            ownerProcessStartIdentity: 33,
            capturedBounds: shifted)

        let rebased = try #require(try DesktopTargetPlanning.WindowSpaceShift.rebasing(
            snapshot,
            onto: live,
            liveIsOnScreen: false))

        #expect(rebased.identity == live)
        #expect(rebased.bounds == shifted)
        #expect(rebased.focusedElement?.frame == CGRect(x: -1414, y: 120, width: 600, height: 300))
        #expect(rebased.focusedElement?.role == "AXTextArea")
    }

    @Test
    func `rebasing refuses another window, another process generation, or a real move`() throws {
        let snapshot = try UIAutomationTarget.ExactWindow(identity: Self.receipt, bounds: Self.captured)
        let shifted = CGRect(x: -1422, y: 73, width: 656, height: 422)
        func live(windowID: Int = 272, generation: UInt64 = 33, bounds: CGRect = shifted) -> WindowMutationIdentity {
            WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 333,
                ownerProcessStartIdentity: generation,
                capturedBounds: bounds)
        }

        for (candidate, isOnScreen) in [
            (live(windowID: 273), false),
            (live(generation: 34), false),
            (live(), true),
            (live(bounds: CGRect(x: 300, y: 73, width: 656, height: 422)), false),
        ] {
            #expect(try DesktopTargetPlanning.WindowSpaceShift.rebasing(
                snapshot,
                onto: candidate,
                liveIsOnScreen: isOnScreen) == nil)
        }
    }

    // MARK: - Helpers

    private static let receipt = WindowMutationIdentity(
        windowID: 272,
        ownerProcessIdentifier: 333,
        ownerProcessStartIdentity: 33,
        capturedBounds: Self.captured)

    private static func liveWindow(
        bounds: CGRect,
        ownerProcessIdentifier: pid_t = 333,
        isOnScreen: Bool = false) -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 272,
            ownerProcessIdentifier: ownerProcessIdentifier,
            title: "Untitled",
            bounds: bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: isOnScreen,
            sharingState: nil)
    }
}
