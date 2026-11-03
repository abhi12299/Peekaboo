import Foundation
import Testing
@testable import PeekabooAutomationKit

struct SpaceMissionControlOrderTests {
    /// The shape `CGSCopyManagedDisplaySpaces` returned on a one-display Mac whose Mission Control showed
    /// Desktops 1-4 as Space IDs 6, 7, 5 and 4, while `CGSCopySpaces` listed them as 7, 6, 5, 4.
    private static var oneDisplay: NSArray { [
        [
            "Display Identifier": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
            "Current Space": ["ManagedSpaceID": NSNumber(value: 5), "type": NSNumber(value: 0)],
            "Spaces": [
                ["ManagedSpaceID": NSNumber(value: 6), "type": NSNumber(value: 0)],
                ["ManagedSpaceID": NSNumber(value: 7), "type": NSNumber(value: 0)],
                ["ManagedSpaceID": NSNumber(value: 5), "type": NSNumber(value: 0)],
                ["ManagedSpaceID": NSNumber(value: 4), "type": NSNumber(value: 0)],
            ],
        ],
    ] }

    @Test
    func `Spaces are numbered in Mission Control order, not CGSCopySpaces order`() {
        let ordered = SpaceMissionControlOrder.order(
            spaceIDs: [7, 6, 5, 4],
            managedDisplaySpaces: Self.oneDisplay)

        #expect(ordered == [6, 7, 5, 4])
    }

    @Test
    func `displays follow each other and unknown Spaces keep their place at the end`() {
        let twoDisplays: NSArray = [
            ["Display Identifier": "Main", "Spaces": [
                ["ManagedSpaceID": NSNumber(value: 3)],
                ["ManagedSpaceID": NSNumber(value: 1)],
            ]],
            ["Display Identifier": "Side", "Spaces": [
                ["id64": NSNumber(value: 9)],
                ["ManagedSpaceID": NSNumber(value: 8)],
            ]],
        ]

        let ordered = SpaceMissionControlOrder.order(
            spaceIDs: [1, 42, 8, 9, 3, 40],
            managedDisplaySpaces: twoDisplays)

        #expect(ordered == [3, 1, 9, 8, 42, 40])
    }
}
