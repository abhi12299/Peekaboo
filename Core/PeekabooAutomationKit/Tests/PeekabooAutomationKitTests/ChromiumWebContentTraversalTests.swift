import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

/// Chromium clips web-content AX frames to the visible viewport. Below the fold a table cell keeps its
/// document geometry, but its `AXStaticText` child reports a zero-height frame and is never published.
struct ChromiumWebContentTraversalTests {
    @Test
    func `table cell without its own label takes the text of its children`() {
        let cell = ElementLabelInfo(
            role: "AXCell",
            label: nil,
            title: "",
            value: nil,
            roleDescription: "cell",
            description: "",
            identifier: nil,
            placeholder: nil)

        #expect(ElementLabelResolver.needsChildTexts(info: cell))
        #expect(ElementLabelResolver.resolve(
            info: cell,
            childTexts: ["Quillfield"],
            identifierCleaner: { $0 }) == "Quillfield")
    }
}
