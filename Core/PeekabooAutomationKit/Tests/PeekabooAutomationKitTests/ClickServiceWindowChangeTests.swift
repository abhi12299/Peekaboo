import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// An accessibility press is bound to its element, so a window that closes or changes after the press is the
/// click's own effect (a tab closed, a sheet opened), not a sign the click went elsewhere. The result says
/// what happened instead of failing as "final target identity validation failed".
@Suite(.serialized)
struct ClickServiceWindowChangeTests {
    @Test
    @MainActor
    func `an accessibility press whose window then changes reports the change`() async throws {
        let pressed = PressedFlag()
        var harness = PressClickHarness(
            front: FakeFrontProcess(nil),
            action: HandBackActionInputDriver(afterPress: { pressed.value = true }))
        harness.windowMatchesReceipt = { !pressed.value }

        let result = try await harness.click()

        #expect(result.targetWindowChange == .changed)
        #expect(result.outcome.dispatchState.mutationDispatched)
    }

    @Test
    @MainActor
    func `an accessibility press whose window then closes reports the close`() async throws {
        let pressed = PressedFlag()
        var harness = PressClickHarness(
            front: FakeFrontProcess(nil),
            action: HandBackActionInputDriver(afterPress: { pressed.value = true }))
        harness.windowMatchesReceipt = { !pressed.value }
        harness.windowIsListed = { !pressed.value }

        let result = try await harness.click()

        #expect(result.targetWindowChange == .closed)
    }

    @Test
    @MainActor
    func `an accessibility press whose window is unchanged reports no change`() async throws {
        let harness = PressClickHarness(front: FakeFrontProcess(nil), action: HandBackActionInputDriver(afterPress: {}))

        let result = try await harness.click()

        #expect(result.targetWindowChange == nil)
    }
}

private final class PressedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { self.lock.withLock { self.stored } }
        set { self.lock.withLock { self.stored = newValue } }
    }
}
