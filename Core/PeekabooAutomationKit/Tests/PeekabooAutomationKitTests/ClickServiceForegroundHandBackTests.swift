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
}
