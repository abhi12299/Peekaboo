import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogInputFieldLabelTests {
    /// The Save panel's name field has no title of its own; its label is the static text before it.
    private static func savePanel() -> (panel: Element, name: Element, tags: Element) {
        let name = Self.node(2, role: "AXTextField", ["AXIdentifier": .string("saveAsNameTextField")])
        let tags = Self.node(4, role: "AXTextField", ["AXDescription": .string("tag editor")])
        let panel = Self.node(9, role: "AXSheet", [:], children: [
            Self.node(1, role: "AXStaticText", ["AXValue": .string("Save As:")]),
            name,
            Self.node(3, role: "AXStaticText", ["AXValue": .string("Tags:")]),
            tags,
        ])
        return (panel, name, tags)
    }

    @Test(arguments: ["Save As:", "Save As", "save as"])
    func `a field is found by the label shown before it`(label: String) throws {
        let fixture = Self.savePanel()
        let field = try DialogService().exactDialogInputField(in: fixture.panel, identifier: label)
        #expect(field == fixture.name)
    }

    private static func node(
        _ id: Int32,
        role: String,
        _ attributes: [String: AttributeValue],
        children: [Element] = []) -> Element
    {
        Element(
            AXUIElementCreateApplication(-id),
            attributes: attributes.merging(["AXRole": .string(role)]) { current, _ in current },
            children: children,
            actions: [])
    }
}
