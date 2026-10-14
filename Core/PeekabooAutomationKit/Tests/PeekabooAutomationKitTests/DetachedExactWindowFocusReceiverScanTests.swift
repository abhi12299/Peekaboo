import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct DetachedExactWindowFocusReceiverScanTests {
    private let expected = FocusedElementIdentity(
        processIdentifier: 42,
        windowID: 7,
        role: "AXUnknown",
        frame: CGRect(x: 313, y: 374, width: 210, height: 42))

    /// Calculator's focused input view is the app's AXFocusedUIElement, but its parent's AXChildren list only a
    /// static text, so a walk down from the window never reaches it.
    @Test
    func `the app's focused element is a receiver even when the window's children do not list it`() {
        let focused = Node(role: "AXUnknown", frame: self.expected.frame)
        let scrollArea = Node(role: "AXScrollArea", frame: self.expected.frame, children: [
            Node(role: "AXStaticText", frame: self.expected.frame),
        ])
        let window = Node(role: "AXWindow", frame: CGRect(x: 303, y: 288, width: 230, height: 408), children: [
            scrollArea,
        ])

        let scan = self.scan(window: window, focusedElement: focused)

        #expect(scan.exactMatches.count == 1)
        #expect(scan.exactMatches.first === focused)
    }

    @Test
    func `a focused element the window's tree already reaches is one receiver, not two`() {
        let focused = Node(role: "AXUnknown", frame: self.expected.frame)
        let window = Node(role: "AXWindow", frame: CGRect(x: 303, y: 288, width: 230, height: 408), children: [
            focused,
        ])

        let scan = self.scan(window: window, focusedElement: focused)

        #expect(scan.exactMatches.count == 1)
        #expect(scan.exactMatches.first === focused)
    }

    private func scan(window: Node, focusedElement: Node?) -> DetachedExactWindowFocusReader.ReceiverScan<Node> {
        DetachedExactWindowFocusReader.scanReceivers(
            window: window,
            focusedElement: focusedElement,
            expected: self.expected,
            phase: .initial,
            same: { $0 === $1 },
            role: { $0.role },
            frame: { $0.frame },
            metadata: { (title: $0.title, identifier: $0.identifier) },
            children: { $0.children })
    }
}

private final class Node {
    let role: String?
    let frame: CGRect?
    let title: String?
    let identifier: String?
    let children: [Node]

    init(role: String?, frame: CGRect?, title: String? = nil, identifier: String? = nil, children: [Node] = []) {
        self.role = role
        self.frame = frame
        self.title = title
        self.identifier = identifier
        self.children = children
    }
}
