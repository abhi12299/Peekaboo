import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Chooses how one background positional click reaches its exact target window, once the caller has
/// proven the window receipt: an accessibility action on the element at the point, or pointer events
/// routed to the window.
@MainActor
struct BackgroundPositionalClickRouter {
    typealias HitTester = @MainActor (_ point: CGPoint, _ pid: pid_t) -> [any AutomationElementRepresenting]
    typealias WindowIdentityValidator = @MainActor (_ identity: WindowMutationIdentity, _ bounds: CGRect) -> Bool

    private let hitTest: HitTester
    private let isAccessibilityTrusted: @MainActor () -> Bool
    private let validateWindowIdentity: WindowIdentityValidator
    private let pointerDriver: WindowRoutedPointerDriver
    private let focusSession: BackgroundFocusSession

    init(
        hitTest: @escaping HitTester = { point, pid in
            BackgroundInputDriver.hitTestCandidates(at: point, targetProcessIdentifier: pid)
        },
        isAccessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        validateWindowIdentity: @escaping WindowIdentityValidator = {
            SystemIdentityResolver.validateWindowMutationIdentity($0, expectedBounds: $1)
        },
        pointerDriver: WindowRoutedPointerDriver = WindowRoutedPointerDriver(),
        focusSession: BackgroundFocusSession = BackgroundFocusSession())
    {
        self.hitTest = hitTest
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.validateWindowIdentity = validateWindowIdentity
        self.pointerDriver = pointerDriver
        self.focusSession = focusSession
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        target: UIAutomationTarget.ExactWindow,
        allowsAccessibilityValueDelivery: Bool = true) async throws -> DesktopActionOutcome
    {
        let targetProcessIdentifier = target.identity.ownerProcessIdentifier
        if count > 1 || button != .left {
            return try await self.windowRoutedClick(at: point, button: button, count: count, target: target)
        }
        guard count == 1 else {
            throw PeekabooError.invalidInput("Background click count must be between 1 and 3")
        }
        guard self.isAccessibilityTrusted() else {
            throw PeekabooError.permissionDeniedAccessibility
        }

        let candidates = self.hitTest(point, targetProcessIdentifier)
        guard let resolved = BackgroundInputDriver.positionalClickTarget(
            inCandidates: candidates,
            at: point,
            button: button)
        else {
            // Nothing pressable (an empty point, a custom-drawn view, web content): click the window itself.
            return try await self.windowRoutedClick(at: point, button: button, count: count, target: target)
        }
        guard self.validateWindowIdentity(target.identity, target.bounds) else {
            throw PeekabooError.snapshotStale(
                "Exact-window background pointer receipt changed before AX dispatch")
        }
        try BackgroundInputDriver.assertBelongsToTargetWindow(
            resolved.element,
            targetWindowID: CGWindowID(target.identity.windowID),
            at: point)

        return try await BackgroundInputDriver.performPositionalClickAction(
            resolved.action,
            on: resolved.element,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
    }

    /// Left clicks run while the window is key for its owner, because views that refuse first mouse
    /// (text views, web content) ignore a click on a background window. Right and middle clicks keep
    /// the plain route: field 51 alone delivers them, and a context menu has not been proven to survive
    /// the session's undo record.
    private func windowRoutedClick(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        target: UIAutomationTarget.ExactWindow) async throws -> DesktopActionOutcome
    {
        guard button == .left else {
            return try await self.postWindowRoutedClick(at: point, button: button, count: count, target: target)
        }
        return try await self.focusSession.perform(target: target) {
            try await self.postWindowRoutedClick(at: point, button: button, count: count, target: target)
        }
    }

    private func postWindowRoutedClick(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        target: UIAutomationTarget.ExactWindow) async throws -> DesktopActionOutcome
    {
        try await self.pointerDriver.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: target.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(target.identity.windowID),
            expectedWindowIdentity: target.identity,
            expectedWindowBounds: target.bounds)
    }
}
