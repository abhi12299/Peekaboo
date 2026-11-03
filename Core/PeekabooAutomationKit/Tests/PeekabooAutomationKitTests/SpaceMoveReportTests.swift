import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct SpaceMoveReportTests {
    private static func space(_ id: UInt64, active: Bool) -> SpaceInfo {
        SpaceInfo(id: id, type: .user, isActive: active, displayID: nil, name: nil, ownerPIDs: [])
    }

    private static let spaces = [
        Self.space(6, active: false),
        Self.space(7, active: false),
        Self.space(5, active: true),
        Self.space(4, active: false),
    ]

    @Test
    func `confirmed move names the verified Space and says the user's Space stayed put`() {
        let text = SpaceMoveReport.text(
            windowTitle: "Remote Panel",
            destinationID: 5,
            outcomeState: .confirmedChange,
            spacesBefore: Self.spaces,
            spacesAfter: Self.spaces)

        #expect(text == "Moved window 'Remote Panel' to Space 3 (ID 5), the user's current Space. " +
            "Verified: the window is now only on that Space. The user's Space did not change (Space 3).")
    }

    @Test
    func `move to another Space and an already-placed window read differently`() {
        let moved = SpaceMoveReport.text(
            windowTitle: "Remote Panel",
            destinationID: 7,
            outcomeState: .confirmedChange,
            spacesBefore: Self.spaces,
            spacesAfter: Self.spaces)
        let already = SpaceMoveReport.text(
            windowTitle: "Remote Panel",
            destinationID: 7,
            outcomeState: .confirmedNoChange,
            spacesBefore: Self.spaces,
            spacesAfter: Self.spaces)

        #expect(moved.hasPrefix("Moved window 'Remote Panel' to Space 2 (ID 7). Verified:"))
        #expect(already.hasPrefix("Window 'Remote Panel' was already only on Space 2 (ID 7); nothing moved."))
    }

    @Test
    func `unverified move and a changed user Space are both stated`() {
        let after = [
            Self.space(6, active: false),
            Self.space(7, active: true),
            Self.space(5, active: false),
        ]

        let text = SpaceMoveReport.text(
            windowTitle: "Remote Panel",
            destinationID: 7,
            outcomeState: .dispatchedUnverified,
            spacesBefore: Self.spaces,
            spacesAfter: after)

        #expect(text == "Asked macOS to move window 'Remote Panel' to Space 2 (ID 7); the result was not " +
            "verified. The user's Space changed from Space 3 to Space 2.")
    }
}
