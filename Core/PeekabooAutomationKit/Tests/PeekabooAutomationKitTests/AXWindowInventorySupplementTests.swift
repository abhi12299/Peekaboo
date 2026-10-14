import ApplicationServices
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct AXWindowInventorySupplementTests {
    /// Fake windows are plain window IDs; `nil` IDs model windows whose identifier cannot be read.
    private final class Reads {
        var events: [String] = []
        var main: Int?
        var focused: Int?
        var remote: [Int: Int] = [:]
        var environment: [String: String] = [:]
        var remainingReads = Int.max

        func supplement(scanLimit: Int = AXWindowInventorySupplement<Int>.remoteTokenScanLimit)
            -> AXWindowInventorySupplement<Int>
        {
            AXWindowInventorySupplement(
                mainWindow: {
                    self.events.append("main")
                    return self.main
                },
                focusedWindow: {
                    self.events.append("focused")
                    return self.focused
                },
                remoteWindow: { token in
                    self.events.append("remote:\(token)")
                    return self.remote[token]
                },
                windowID: { $0 },
                canContinue: {
                    self.remainingReads -= 1
                    return self.remainingReads >= 0
                },
                readEnvironment: { self.environment[$0] },
                scanLimit: scanLimit)
        }
    }

    @Test
    func `inventory that already lists the target performs no supplement reads`() {
        let reads = Reads()
        reads.main = 42

        let window = reads.supplement().window(matching: 42, missingFrom: [7, 42])

        #expect(window == nil)
        #expect(reads.events.isEmpty)
    }

    @Test
    func `empty inventory uses the main window when it is the exact target`() {
        let reads = Reads()
        reads.main = 42

        let window = reads.supplement().window(matching: 42, missingFrom: [])

        #expect(window == 42)
        #expect(reads.events == ["main"])
    }

    @Test
    func `main and focused windows with another identifier are skipped for the remote token scan`() {
        let reads = Reads()
        reads.main = 7
        reads.focused = 8
        reads.remote = [1: 9, 2: 42, 3: 42]

        let window = reads.supplement().window(matching: 42, missingFrom: [])

        #expect(window == 42)
        #expect(reads.events == ["main", "focused", "remote:0", "remote:1", "remote:2"])
    }

    @Test
    func `no exact match after a full bounded scan returns nothing`() {
        let reads = Reads()
        reads.main = 7
        reads.focused = 8
        reads.remote = [0: 9, 4: 10]

        let window = reads.supplement(scanLimit: 5).window(matching: 42, missingFrom: [nil, 7])

        #expect(window == nil)
        #expect(reads.events == ["main", "focused"] + (0..<5).map { "remote:\($0)" })
    }

    @Test
    func `kill switch performs no supplement reads`() {
        let reads = Reads()
        reads.main = 42
        reads.environment = ["PEEKABOO_OFFSPACE_AX_WINDOWS": "0"]

        let window = reads.supplement().window(matching: 42, missingFrom: [])

        #expect(window == nil)
        #expect(reads.events.isEmpty)
        #expect(OffSpaceAXWindowSwitch.isEnabled(readEnvironment: { _ in nil }))
        #expect(OffSpaceAXWindowSwitch.isEnabled(readEnvironment: { _ in "1" }))
    }

    @Test
    func `supplement stops reading once its deadline budget is spent`() {
        let reads = Reads()
        reads.remote = [10: 42]
        reads.remainingReads = 5

        let window = reads.supplement().window(matching: 42, missingFrom: [])

        #expect(window == nil)
        #expect(reads.events == ["main", "focused", "remote:0", "remote:1", "remote:2"])

        let expired = Reads()
        expired.main = 42
        expired.remainingReads = 0
        #expect(expired.supplement().window(matching: 42, missingFrom: []) == nil)
        #expect(expired.events.isEmpty)
    }

    @Test
    func `several missing targets are each claimed once by exact identifier`() {
        let reads = Reads()
        reads.main = 42
        reads.focused = 42
        reads.remote = [0: 5, 1: 43, 2: 43]

        let windows = reads.supplement().windows(matching: [42, 43, 44], missingFrom: [44])

        #expect(windows.map(\.windowID) == [42, 43])
        #expect(reads.events == ["main", "focused", "remote:0", "remote:1"])
    }

    @Test
    func `exact window lookup falls back to the supplement when the inventory omits the target`() {
        let reads = Reads()
        reads.main = 7
        reads.remote = [3: 42]

        let window = AXWindowInventorySupplement<Int>.exactWindow(
            42,
            inventory: [5, 7],
            inventoryWindowID: { $0 },
            makeSupplement: { reads.supplement() })

        #expect(window == 42)
        #expect(reads.events.prefix(2) == ["main", "focused"])
    }

    @Test
    func `remote token is the owner PID, a zero word, the coco tag, and the element identifier`() {
        let token = AXWindowInventorySupplement.remoteToken(processIdentifier: 0x0102_0304, elementIdentifier: 42)

        #expect(Array(token) == [
            0x04, 0x03, 0x02, 0x01,
            0, 0, 0, 0,
            0x6F, 0x63, 0x6F, 0x63,
            42, 0, 0, 0, 0, 0, 0, 0,
        ])
    }
}
