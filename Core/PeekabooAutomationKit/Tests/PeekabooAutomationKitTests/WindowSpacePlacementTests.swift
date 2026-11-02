import Testing
@testable import PeekabooAutomationKit

struct WindowSpacePlacementTests {
    @Test
    func `a window only on Spaces no display shows is on another Space, numbered as space list does`() {
        let placement = WindowSpacePlacement.classify(
            windowSpaceIDs: [5],
            visibleSpaceIDs: [6],
            orderedSpaceIDs: [7, 6, 5, 4])

        #expect(placement == .otherSpace(spaceID: 5, spaceNumber: 3))
        #expect(placement.spaceDescription == "Space 3")
    }

    @Test
    func `a window on any visible Space is on a visible Space`() {
        #expect(WindowSpacePlacement.classify(windowSpaceIDs: [5, 6], visibleSpaceIDs: [6]) == .visibleSpace)
        // Two displays each show a Space.
        #expect(WindowSpacePlacement.classify(windowSpaceIDs: [9], visibleSpaceIDs: [6, 9]) == .visibleSpace)
    }

    @Test
    func `no Space membership or no visible Space is unknown, never another Space`() {
        #expect(WindowSpacePlacement.classify(windowSpaceIDs: [], visibleSpaceIDs: [6]) == .unknown)
        #expect(WindowSpacePlacement.classify(windowSpaceIDs: [5], visibleSpaceIDs: []) == .unknown)
        #expect(WindowSpacePlacement.classify(windowSpaceIDs: [5], visibleSpaceIDs: [6]).spaceDescription ==
            "another Space")
    }
}
