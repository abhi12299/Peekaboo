import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
@testable import PeekabooAutomationKit

// Test doubles for ClickService tests that drive one exact-window accessibility press.

/// The front process as the click sees it, and the hand-backs it was asked for.
@MainActor
final class FakeFrontProcess {
    var processIdentifier: pid_t?
    /// What each re-activation returns; `.accepted` also moves the front to the activated app.
    var activation: ForegroundHandBack.Activation = .accepted
    private(set) var activatedProcessIdentifiers: [pid_t] = []

    init(_ processIdentifier: pid_t?) {
        self.processIdentifier = processIdentifier
    }

    var handBack: ForegroundHandBack {
        ForegroundHandBack(
            frontmostProcessIdentifier: { self.processIdentifier },
            activate: { pid in
                self.activatedProcessIdentifiers.append(pid)
                if self.activation == .accepted {
                    self.processIdentifier = pid
                }
                return self.activation
            },
            sleep: { _ in })
    }
}

final class HandBackWindowTracker: WindowTrackingProviding, @unchecked Sendable {
    private let bounds: CGRect

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    @MainActor
    func windowBounds(for _: CGWindowID) -> CGRect? {
        self.bounds
    }
}

@MainActor
final class HandBackElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))
    /// Runs while the click resolves its element, after it was queued and prepared, before the press.
    var duringResolution: () -> Void = {}

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
        self.duringResolution()
        return self.element
    }

    func resolve(
        query _: String,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?,
        requireTextInput _: Bool) -> AutomationElement?
    {
        self.element
    }
}

@MainActor
final class HandBackActionInputDriver: ActionInputDriving {
    private let afterPress: () -> Void
    private(set) var pressCount = 0

    init(afterPress: @escaping () -> Void) {
        self.afterPress = afterPress
    }

    func tryClick(
        element _: AutomationElement,
        beforeMutation: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        // Like the real driver: revalidate right before the press.
        try beforeMutation()
        self.pressCount += 1
        self.afterPress()
        return AutomationTestFixtures.uiActionReceipt(
            actionName: AXActionNames.kAXPressAction,
            anchorPoint: CGPoint(x: 70, y: 50),
            elementRole: "AXButton")
    }

    func tryRightClick(element _: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryScroll(
        element _: AutomationElement,
        direction _: PeekabooFoundation.ScrollDirection,
        pages _: Int,
        scrollBarScope _: ScrollBarSearchScope) throws -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func trySetText(
        element _: AutomationElement,
        text _: String,
        replace _: Bool,
        beforeMutation _: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryHotkey(application _: NSRunningApplication, keys _: [String]) throws -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt()
    }

    func trySetValue(
        element _: AutomationElement,
        value _: UIElementValue,
        beforeMutation _: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
        AutomationTestFixtures.uiActionReceipt()
    }

    func tryPerformAction(element _: AutomationElement, actionName: String) throws -> UIInputExecutionResult.Action {
        AutomationTestFixtures.uiActionReceipt(actionName: actionName)
    }
}

/// One exact-window accessibility press on button "B1" of window 42, owned by the test process.
@MainActor
struct PressClickHarness {
    static let snapshotID = "ps1_0123456789abcdef0123456789abcdef"
    static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    let target = getpid()
    let front: FakeFrontProcess
    let action: HandBackActionInputDriver
    var resolver = HandBackElementResolver()
    /// Whether window 42 still matches its capture-time receipt; read before and after the press.
    var windowMatchesReceipt: @Sendable () -> Bool = { true }
    /// Whether window 42 is still listed at all.
    var windowIsListed: @Sendable () -> Bool = { true }

    var identity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: self.target,
            ownerProcessStartIdentity: 1,
            capturedBounds: Self.bounds)
    }

    func click() async throws -> UIInputExecutionResult {
        let service = try await self.service()
        return try await WindowMovementTrackingProviderScope.withProvider(HandBackWindowTracker(bounds: Self.bounds)) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                automationTarget: .exactWindow(.init(identity: self.identity, bounds: Self.bounds)),
                validatesProcessIdentity: true)
        }
    }

    private func service() async throws -> ClickService {
        let detection = ElementDetectionResult(
            snapshotId: Self.snapshotID,
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(buttons: [DetectedElement(
                id: "B1",
                type: .button,
                label: "Submit…",
                bounds: CGRect(x: 20, y: 30, width: 100, height: 40))]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: self.target,
                    windowID: 42,
                    windowBounds: Self.bounds,
                    windowMutationIdentity: self.identity)))
        let matches = self.windowMatchesReceipt
        let listed = self.windowIsListed
        return try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: self.action,
            automationElementResolver: self.resolver,
            exactWindowIdentityValidator: { _, _ in matches() },
            processStartIdentityProvider: { _ in 1 },
            foregroundHandBack: self.front.handBack,
            exactWindowIsListed: { _ in listed() })
    }
}
