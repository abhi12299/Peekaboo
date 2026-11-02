@preconcurrency import AXorcist
import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation
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

    /// Chrome nests its page under eight levels of browser UI, so the default depth of 12 used to stop
    /// at the table cells. Depth inside web content is counted from the page's AXWebArea.
    @Test @MainActor
    func `default depth reaches table cells under Chrome's browser chrome`() {
        // window → 7 browser groups → AXWebArea (depth 8) → group → table → row → cell (depth 12) → text
        let roles = Array(repeating: "AXGroup", count: 8) + ["AXWebArea", "AXGroup", "AXTable", "AXRow", "AXCell"]
        let chain = roles.indices.map { Self.fakeElement(100 + Int32($0)) }
        let text = Self.fakeElement(99)
        let collector = AXTreeCollector(
            descriptorReader: { element in
                if element == text {
                    return .descriptor(Self.descriptor(role: "AXStaticText", title: "Quillfield"))
                }
                guard let index = chain.firstIndex(of: element) else { return .absent }
                return .descriptor(Self.descriptor(role: roles[index]))
            },
            childrenReader: { element in
                guard let index = chain.firstIndex(of: element) else { return [] }
                return index + 1 < chain.count ? [chain[index + 1]] : [text]
            },
            textReader: { _ in nil })

        let result = collector.collect(window: chain[0], deadline: Date().addingTimeInterval(1))

        #expect(result.truncationInfo == nil)
        #expect(result.elements.contains { $0.label == "Quillfield" })
    }

    @Test @MainActor
    func `native trees without web content keep the absolute depth limit`() {
        let chain = (0..<14).map { Self.fakeElement(200 + Int32($0)) }
        let collector = AXTreeCollector(
            descriptorReader: { _ in .descriptor(Self.descriptor(role: "AXGroup")) },
            childrenReader: { element in
                guard let index = chain.firstIndex(of: element), index + 1 < chain.count else { return [] }
                return [chain[index + 1]]
            },
            textReader: { _ in nil })

        let result = collector.collect(window: chain[0], deadline: Date().addingTimeInterval(1))

        #expect(result.elements.count == AXTraversalBudget.defaultMaxDepth)
        #expect(result.truncationInfo?.maxDepthReached == true)
    }

    /// Live Chrome 156: a cell's AXStaticText answers AXTitle "" (success, empty), AXLabel unsupported,
    /// AXValue "Quillfield". The text readers must skip the empty title instead of stopping at it.
    @Test
    func `descendant text skips an empty title and takes the value`() {
        #expect(AXTextualNode.firstNonBlank(["", nil, "Quillfield", ""]) == "Quillfield")
        #expect(AXTextualNode.firstNonBlank(["  ", nil]) == nil)
    }

    /// A cell holding a large widget and no text must not turn the label walk into a tree walk, and a
    /// node that lists itself among its children (Chrome ARIA tabs) is read once.
    @Test
    func `descendant text walk is bounded and visits each node once`() {
        var childrenReads = 0
        var textReads = 0
        let texts = ElementLabelResolver.childTexts(
            of: 0,
            parentRole: "AXCell",
            children: { (node: Int) -> [Int] in
                childrenReads += 1
                return node == 1 ? [1] + (0..<100).map { 1000 + node * 100 + $0 } : (0..<100).map { node * 100 + $0 + 1 }
            },
            textualNode: { _ in
                textReads += 1
                return AXTextualNode(role: "AXGroup", text: nil)
            })

        #expect(texts.isEmpty)
        #expect(childrenReads + textReads <= ElementLabelResolver.childTextNodeBudget * 2)
    }

    @Test
    func `descendant text walk stops when told to`() {
        var textReads = 0
        let texts = ElementLabelResolver.childTexts(
            of: 0,
            parentRole: "AXCell",
            children: { (node: Int) -> [Int] in node < 50 ? [node + 1] : [] },
            textualNode: { node in
                textReads += 1
                return AXTextualNode(role: "AXStaticText", text: "t\(node)")
            },
            shouldContinue: { textReads < 1 })

        #expect(texts == ["t1"])
        #expect(textReads == 1)
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

/// AXScrollToVisible is the only AX scroll route Chromium web content offers. The renderer scrolls
/// asynchronously, so the driver samples the target frame instead of trusting the action's return.
struct ChromiumScrollIntoViewDriverTests {
    private static let visiblePage = CGRect(x: 200, y: 180, width: 1000, height: 713)

    @Test @MainActor
    func `scroll into view confirms once the target frame enters the visible page`() async throws {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 225, y: 1646, width: 119, height: 39),
            actionNames: ["AXShowMenu", "AXScrollToVisible"])
        let driver = ActionInputDriver(observationDelay: {
            cell.frame = CGRect(x: 225, y: 840, width: 119, height: 39)
        })

        let result = try await driver.tryScrollIntoViewForTesting(element: cell, visibleBounds: Self.visiblePage)

        #expect(cell.performedActions == ["AXScrollToVisible"])
        #expect(result.actionName == "AXScrollToVisible")
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
    }

    /// A fully covered Chrome window stops rendering frames. It still applies AXScrollToVisible, but
    /// reports the new geometry only once the next AX action flushes it. Live: y 1786 stayed put
    /// after one action and read 791 within 20 ms of a second, idempotent one.
    @Test @MainActor
    func `occluded renderer geometry is flushed by one repeated AXScrollToVisible`() async throws {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 295, y: 1786, width: 119, height: 39),
            actionNames: ["AXScrollToVisible"])
        let driver = ActionInputDriver(observationDelay: {
            if cell.performedActions.count >= 2 {
                cell.frame = CGRect(x: 295, y: 791, width: 119, height: 39)
            }
        })

        let result = try await driver.tryScrollIntoViewForTesting(element: cell, visibleBounds: Self.visiblePage)

        #expect(cell.performedActions == ["AXScrollToVisible", "AXScrollToVisible"])
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @Test @MainActor
    func `scroll into view is indeterminate when the target never enters the visible page`() async {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 225, y: 1646, width: 119, height: 39),
            actionNames: ["AXScrollToVisible"])
        var samples = 0
        let driver = ActionInputDriver(observationDelay: { samples += 1 })

        do {
            _ = try await driver.tryScrollIntoViewForTesting(element: cell, visibleBounds: Self.visiblePage)
            Issue.record("Expected an indeterminate outcome")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(cell.performedActions == ["AXScrollToVisible", "AXScrollToVisible"])
        #expect(samples > 0)
    }

    /// A target already partly inside the page must end fully inside it. An accepted action that leaves
    /// the frame where it was proves nothing, even though the frame intersects the page.
    @Test @MainActor
    func `partly clipped target that never moves is indeterminate`() async {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 225, y: 880, width: 119, height: 39),
            actionNames: ["AXScrollToVisible"])
        let driver = ActionInputDriver(observationDelay: {})

        do {
            _ = try await driver.tryScrollIntoViewForTesting(element: cell, visibleBounds: Self.visiblePage)
            Issue.record("Expected an indeterminate outcome")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test @MainActor
    func `partly clipped target confirms once it is fully inside the page`() async throws {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 225, y: 880, width: 119, height: 39),
            actionNames: ["AXScrollToVisible"])
        let driver = ActionInputDriver(observationDelay: {
            cell.frame = CGRect(x: 225, y: 853, width: 119, height: 39)
        })

        let result = try await driver.tryScrollIntoViewForTesting(element: cell, visibleBounds: Self.visiblePage)

        #expect(result.outcome.state == .confirmedChange)
    }

    @Test @MainActor
    func `target without AXScrollToVisible stays unsupported and untouched`() async {
        let cell = ActionInputMockAutomationElement(
            role: "AXCell",
            frame: CGRect(x: 225, y: 1646, width: 119, height: 39),
            actionNames: ["AXShowMenu"])

        do {
            _ = try await ActionInputDriver().tryScrollIntoViewForTesting(
                element: cell, visibleBounds: Self.visiblePage)
            Issue.record("Expected unsupported")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(cell.attemptedActions.isEmpty)
    }
}
