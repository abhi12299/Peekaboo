@preconcurrency import AXorcist
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

    @Test @MainActor
    func `collected cell below the fold carries the text of its clipped child`() throws {
        let cell = Self.fakeElement(1)
        let clippedText = Self.fakeElement(2)
        let collector = AXTreeCollector(
            descriptorReader: { element in
                // The clipped static text fails the useful-frame check and is never published.
                element == cell ? .descriptor(Self.descriptor(role: "AXCell", roleDescription: "cell")) : .absent
            },
            childrenReader: { element in element == cell ? [clippedText] : [] },
            textReader: { element in
                element == clippedText ? AXTextualNode(role: "AXStaticText", text: "Quillfield") : nil
            })

        let result = collector.collect(window: cell, deadline: Date().addingTimeInterval(1))

        let published = try #require(result.elements.first)
        #expect(result.elements.count == 1)
        #expect(published.label == "Quillfield")
    }

    /// Distinct AX element references that are never messaged: every read goes through the injected readers.
    @MainActor static func fakeElement(_ index: Int32) -> Element {
        Element(AXUIElementCreateApplication(900_000 + index))
    }

    static func descriptor(
        role: String,
        title: String? = nil,
        roleDescription: String? = nil,
        frame: CGRect = CGRect(x: 225, y: 1646, width: 119, height: 39)) -> AXDescriptorReader.Descriptor
    {
        AXDescriptorReader.Descriptor(
            frame: frame,
            role: role,
            title: title,
            label: nil,
            value: nil,
            description: nil,
            help: nil,
            roleDescription: roleDescription,
            identifier: nil,
            isEnabled: true,
            isSelected: nil,
            isFocused: nil,
            placeholder: nil)
    }
}
