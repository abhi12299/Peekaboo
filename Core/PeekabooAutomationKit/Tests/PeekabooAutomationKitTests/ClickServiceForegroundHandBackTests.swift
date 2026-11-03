import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// A background click must not leave the target app in front. AppKit activates an app that shows a modal
/// sheet after one of its menus was opened through accessibility, so the click hands the front back.
@Suite(.serialized)
struct ClickServiceForegroundHandBackTests {
    private static let userFrontProcess: pid_t = 999_996

    @Test
    @MainActor
    func `a background click whose target takes the front hands the front back and reports it`() async throws {
        let front = FakeFrontProcess(Self.userFrontProcess)
        let target = getpid()
        let action = HandBackActionInputDriver(afterPress: { front.processIdentifier = target })
        let result = try await PressClickHarness(front: front, action: action).click()

        #expect(action.pressCount == 1)
        #expect(front.activatedProcessIdentifiers == [Self.userFrontProcess])
        #expect(front.processIdentifier == Self.userFrontProcess)
        #expect(result.foregroundHandBack == ForegroundHandBackReport(
            handBacks: 1,
            targetProcessIdentifier: target,
            restoredProcessIdentifier: Self.userFrontProcess))
    }

    @Test
    @MainActor
    func `the front goes back to the app that was in front when the press was sent`() async throws {
        let laterFrontProcess: pid_t = 999_995
        let front = FakeFrontProcess(Self.userFrontProcess)
        let target = getpid()
        let harness = PressClickHarness(
            front: front,
            action: HandBackActionInputDriver(afterPress: { front.processIdentifier = target }))
        // The user switched apps while the click was being prepared.
        harness.resolver.duringResolution = { front.processIdentifier = laterFrontProcess }

        let result = try await harness.click()

        #expect(front.activatedProcessIdentifiers == [laterFrontProcess])
        #expect(result.foregroundHandBack?.restoredProcessIdentifier == laterFrontProcess)
    }

    @Test
    @MainActor
    func `a target the user brought to the front before the press is left in front`() async throws {
        let front = FakeFrontProcess(Self.userFrontProcess)
        let target = getpid()
        let harness = PressClickHarness(front: front, action: HandBackActionInputDriver(afterPress: {}))
        harness.resolver.duringResolution = { front.processIdentifier = target }

        let result = try await harness.click()

        #expect(front.activatedProcessIdentifiers.isEmpty)
        #expect(result.foregroundHandBack == nil)
    }

    @Test(arguments: [ForegroundHandBack.Activation.refused, .gone])
    @MainActor
    func `a hand-back that does not take is still reported`(activation: ForegroundHandBack.Activation) async throws {
        let front = FakeFrontProcess(Self.userFrontProcess)
        front.activation = activation
        let target = getpid()
        let result = try await PressClickHarness(
            front: front,
            action: HandBackActionInputDriver(afterPress: { front.processIdentifier = target })).click()

        let report = try #require(result.foregroundHandBack)
        #expect(report.handBacks == 0)
        #expect(report.targetKeptFront)
        #expect(report.targetProcessIdentifier == target)
    }
}
