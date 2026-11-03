import Foundation

/// Orders Space IDs the way Mission Control shows them: display by display, left to right.
///
/// `CGSCopySpaces` returns Spaces in an order of its own (on one Mac it listed Desktop 2 first), so numbering
/// its result made Peekaboo's "Space 1" a different desktop from the user's Desktop 1.
enum SpaceMissionControlOrder {
    /// Returns `spaceIDs` sorted by their position in `CGSCopyManagedDisplaySpaces`; IDs that list doesn't name
    /// keep their relative order after the rest.
    static func order(spaceIDs: [CGSSpaceID], managedDisplaySpaces: NSArray) -> [CGSSpaceID] {
        var position: [CGSSpaceID: Int] = [:]
        for case let display as [String: Any] in managedDisplaySpaces {
            for case let space as [String: Any] in display["Spaces"] as? [Any] ?? [] {
                guard let id = ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value,
                      position[id] == nil
                else { continue }
                position[id] = position.count
            }
        }
        let known = spaceIDs.filter { position[$0] != nil }.sorted { position[$0]! < position[$1]! }
        return known + spaceIDs.filter { position[$0] == nil }
    }
}
