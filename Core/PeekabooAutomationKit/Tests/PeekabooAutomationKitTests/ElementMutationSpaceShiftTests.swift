import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

/// Accessibility element actions do not depend on where the window is, so a window that macOS lists shifted to a
/// Space that is not visible stays a valid target for them.
@MainActor
struct ElementMutationSpaceShiftTests {
    private static let process = ApplicationProcessIdentity(processIdentifier: 612, processStartIdentity: 13)
    private static let identity = WindowMutationIdentity(
        windowID: 303,
        ownerProcessIdentifier: 612,
        ownerProcessStartIdentity: 13,
        capturedBounds: CGRect(x: 152, y: 73, width: 656, height: 422))

    @Test
    func `an element action runs on a window that only moved to another Space`() async throws {
        let driver = RecordingActionInputDriver(allowsElementActions: true)
        let service = try await Self.service(driver: driver, spaceShifted: true)

        _ = try await service.performAction(
            target: "B1",
            actionName: "AXPress",
            snapshotId: SnapshotReferenceFixtures.first.rawValue)

        #expect(driver.performActionCallCount == 1)
    }

    @Test
    func `an element action on a window that really moved is still refused before dispatch`() async throws {
        let driver = RecordingActionInputDriver(allowsElementActions: true)
        let service = try await Self.service(driver: driver, spaceShifted: false)

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await service.performAction(
                target: "B1",
                actionName: "AXPress",
                snapshotId: SnapshotReferenceFixtures.first.rawValue)
        }

        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(driver.performActionCallCount == 0)
    }

    // MARK: - Helpers

    private static func service(
        driver: RecordingActionInputDriver,
        spaceShifted: Bool) async throws -> UIAutomationService
    {
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let detected = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 200, y: 120, width: 80, height: 24))
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/\(snapshotID).png",
            elements: DetectedElements(buttons: [detected]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: Self.identity.ownerProcessIdentifier,
                    windowID: Self.identity.windowID,
                    windowBounds: Self.identity.capturedBounds,
                    windowMutationIdentity: Self.identity)))
        let identity = Self.identity
        let processStartIdentity = Self.process.processStartIdentity
        return try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: driver,
            automationElementResolver: FixedActionAutomationElementResolver(),
            exactWindowIdentityValidator: { _, _ in false },
            spaceShiftedWindowIdentityValidator: { actual, bounds in
                spaceShifted && actual == identity && bounds == identity.capturedBounds
            },
            processStartIdentityProvider: { _ in processStartIdentity })
    }
}
