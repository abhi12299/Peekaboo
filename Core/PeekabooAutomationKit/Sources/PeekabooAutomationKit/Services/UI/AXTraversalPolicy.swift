import Foundation

@_spi(Testing) public enum AXTraversalPolicy {
    private static let maxWebFocusAttempts = 2
    private static let maxElementsBeforeWebFocusFallback = 20

    public static func shouldAttemptWebFocusFallback(
        attempt: Int,
        allowWebFocus: Bool,
        detectedElementCount: Int,
        hasTextField: Bool) -> Bool
    {
        guard !hasTextField else { return false }

        return attempt < self.maxWebFocusAttempts
            && allowWebFocus
            && detectedElementCount <= self.maxElementsBeforeWebFocusFallback
    }
}

/// Where a node sits against the traversal's depth budget.
///
/// Browsers and Electron apps nest the page under their own UI: Chrome's AXWebArea sits eight
/// levels below the window, which used to leave four levels of the default budget for the page.
/// Depth inside web content is therefore counted from the outermost AXWebArea. Nested web areas
/// (iframes) do not restart the count, so the budget stays bounded.
@_spi(Testing) public struct AXTraversalDepth: Sendable, Equatable {
    public let level: Int
    public let isInsideWebContent: Bool

    public static let root = AXTraversalDepth(level: 0, isInsideWebContent: false)

    public init(level: Int, isInsideWebContent: Bool) {
        self.level = level
        self.isInsideWebContent = isInsideWebContent
    }

    /// The depth of a child of a node at this depth. `role` is the parent's role, when it was read.
    public func child(ofRole role: String?) -> AXTraversalDepth {
        if !self.isInsideWebContent, role == "AXWebArea" {
            return AXTraversalDepth(level: 1, isInsideWebContent: true)
        }
        return AXTraversalDepth(level: self.level + 1, isInsideWebContent: self.isInsideWebContent)
    }
}
