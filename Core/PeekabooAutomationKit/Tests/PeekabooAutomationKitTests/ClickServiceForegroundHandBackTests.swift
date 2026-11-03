import AppKit
import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

/// A background click must not leave the target app in front. AppKit activates an app that shows a modal
/// sheet after one of its menus was opened through accessibility, so the click hands the front back.
@Suite(.serialized)
struct ClickServiceForegroundHandBackTests {
    private static let snapshotID = SnapshotReferenceFixtures.first.rawValue
    private static let userFrontProcess: pid_t = 4242
    private static let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test
    @MainActor
    func `a background click whose target takes the front hands the front back and reports it`() async throws {
        let target = getpid()
        let front = FakeFrontProcess(Self.userFrontProcess)
        let action = HandBackActionInputDriver(afterPress: { front.processIdentifier = target })
        let service = try await self.service(front: front, action: action, target: target)

        let result = try await self.click(service, target: target)

        #expect(action.pressCount == 1)
        #expect(front.activatedProcessIdentifiers == [Self.userFrontProcess])
        #expect(front.processIdentifier == Self.userFrontProcess)
        #expect(result.foregroundHandBack == ForegroundHandBackReport(
            handBacks: 1,
            targetProcessIdentifier: target,
            restoredProcessIdentifier: Self.userFrontProcess))
    }

    // MARK: - Fixtures

    @MainActor
    private func click(_ service: ClickService, target: pid_t) async throws -> UIInputExecutionResult {
        try await WindowMovementTrackingProviderScope.withProvider(HandBackWindowTracker(bounds: Self.bounds)) {
            try await service.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: Self.snapshotID,
                automationTarget: .exactWindow(.init(identity: Self.identity(target), bounds: Self.bounds)),
                validatesProcessIdentity: true)
        }
    }

    @MainActor
    private func service(
        front: FakeFrontProcess,
        action: HandBackActionInputDriver,
        target: pid_t) async throws -> ClickService
    {
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
                    applicationProcessId: target,
                    windowID: 42,
                    windowBounds: Self.bounds,
                    windowMutationIdentity: Self.identity(target))))
        return try await ClickService(
            snapshotManager: InMemorySnapshotManager.containing(detection),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: action,
            automationElementResolver: HandBackElementResolver(),
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 1 },
            foregroundHandBack: front.handBack)
    }

    private static func identity(_ processIdentifier: pid_t) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 1,
            capturedBounds: self.bounds)
    }
}

/// The front process as the click sees it, and the hand-backs it was asked for.
@MainActor
private final class FakeFrontProcess {
    var processIdentifier: pid_t?
    private(set) var activatedProcessIdentifiers: [pid_t] = []

    init(_ processIdentifier: pid_t?) {
        self.processIdentifier = processIdentifier
    }

    var handBack: ForegroundHandBack {
        ForegroundHandBack(
            frontmostProcessIdentifier: { self.processIdentifier },
            activate: { pid in
                self.activatedProcessIdentifiers.append(pid)
                self.processIdentifier = pid
                return .accepted
            },
            sleep: { _ in })
    }
}

private final class HandBackWindowTracker: WindowTrackingProviding, @unchecked Sendable {
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
private final class HandBackElementResolver: AutomationElementResolving {
    private let element = AutomationElement(Element(AXUIElementCreateApplication(getpid())))

    func resolve(
        detectedElement _: DetectedElement,
        windowContext _: WindowContext?,
        targetProcessIdentifier _: pid_t?) -> AutomationElement?
    {
        self.element
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
private final class HandBackActionInputDriver: ActionInputDriving {
    private let afterPress: () -> Void
    private(set) var pressCount = 0

    init(afterPress: @escaping () -> Void) {
        self.afterPress = afterPress
    }

    func tryClick(
        element _: AutomationElement,
        beforeMutation _: @MainActor () throws -> Void) throws -> UIInputExecutionResult.Action
    {
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
