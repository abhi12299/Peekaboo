import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct RestoredWindowSettleTests {
    private let bounds = CGRect(x: 30, y: 40, width: 900, height: 700)

    private func sample(
        minimized: Bool? = false,
        bounds: CGRect? = nil,
        onScreen: Bool? = true) -> RestoredWindowSettleSample
    {
        RestoredWindowSettleSample(
            isMinimized: minimized,
            bounds: bounds ?? self.bounds,
            isOnScreen: onScreen,
            alpha: 1)
    }

    @Test
    func `restore waits until the exact window reads the same settled state several times`() async throws {
        var samples = [
            self.sample(onScreen: false),
            self.sample(),
            self.sample(),
            self.sample(),
            self.sample(),
        ]
        var reads = 0
        var sleeps: [Duration] = []

        let settled = try await waitForRestoredWindowToSettle(
            expectedBounds: self.bounds,
            read: {
                reads += 1
                return samples.removeFirst()
            },
            sleep: { sleeps.append($0) },
            now: { ContinuousClock.now },
            interval: .milliseconds(100),
            requiredStableReads: 3)

        #expect(settled)
        #expect(reads == 4)
        #expect(sleeps == Array(repeating: .milliseconds(100), count: 3))
    }

    @Test
    func `restore stops waiting at its bounded timeout when the frame keeps changing`() async throws {
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        var reads = 0

        let settled = try await waitForRestoredWindowToSettle(
            expectedBounds: self.bounds,
            read: {
                reads += 1
                // Alternates between the receipt frame and an animating one, so it never reads stable.
                return reads.isMultiple(of: 2)
                    ? self.sample()
                    : self.sample(bounds: CGRect(x: 30, y: 40, width: 899, height: 700))
            },
            sleep: { elapsed += $0 },
            now: { start.advanced(by: elapsed) },
            timeout: .seconds(1),
            interval: .milliseconds(100),
            requiredStableReads: 2)

        #expect(!settled)
        #expect(reads == 11)
    }

    @Test
    func `a minimized or unreadable window never counts as settled`() async throws {
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        var samples: [RestoredWindowSettleSample?] = [self.sample(minimized: true), nil, self.sample(minimized: nil)]

        let settled = try await waitForRestoredWindowToSettle(
            expectedBounds: self.bounds,
            read: { samples.isEmpty ? self.sample(minimized: true) : samples.removeFirst() },
            sleep: { elapsed += $0 },
            now: { start.advanced(by: elapsed) },
            timeout: .milliseconds(500),
            requiredStableReads: 1)

        #expect(!settled)
    }
}
