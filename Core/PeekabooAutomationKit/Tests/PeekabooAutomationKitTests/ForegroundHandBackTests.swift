import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ForegroundHandBackTests {
    @Test
    @MainActor
    func `a watch cancelled after a hand-back still reports it`() async throws {
        var front: pid_t? = 2
        var sleeps = 0
        let handBack = ForegroundHandBack(
            frontmostProcessIdentifier: { front },
            activate: { pid in
                front = pid
                return .accepted
            },
            sleep: { _ in
                sleeps += 1
                front = 2
                throw CancellationError()
            })

        let report = await handBack.watch(
            target: 2,
            previousFrontmost: 1,
            window: .seconds(1),
            pollInterval: .milliseconds(10),
            checkFirst: true)

        #expect(sleeps == 1)
        #expect(report?.handBacks == 1)
        #expect(report?.targetKeptFront == true)
    }
}
