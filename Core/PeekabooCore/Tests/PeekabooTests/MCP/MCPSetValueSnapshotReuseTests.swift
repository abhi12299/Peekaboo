import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

/// A `set_value` that leaves the window's structure as it was keeps its snapshot usable for later steps of a batch.
@MainActor
struct MCPSetValueSnapshotReuseTests {
    private static let reusableKey = MCPToolResponseMetadataProjector.snapshotReusableForElementClicksKey

    private static func element(_ id: String, _ role: String, y: CGFloat, value: String? = nil) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .textField,
            value: value,
            bounds: CGRect(x: 150, y: y, width: 140, height: 26),
            attributes: ["role": role])
    }

    private static let form = [
        Self.element("elem_0", "AXTextField", y: 20, value: "1"),
        Self.element("elem_1", "AXDateTimeArea", y: 64, value: "2026-11-01"),
        Self.element("elem_2", "AXComboBox", y: 108, value: "USD"),
    ]

    /// A form snapshot whose window, re-read after the write, holds `after`.
    private static func fixture(after: [DetectedElement]) async throws -> MCPSnapshotMutationTestFixture {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background)))
        let stored = try #require(try await fixture.storage.getDetectionResult(snapshotId: fixture.snapshotID))
        try await fixture.storage.storeDetectionResult(
            snapshotId: fixture.snapshotID,
            result: ElementDetectionResult(
                snapshotId: fixture.snapshotID,
                screenshotPath: stored.screenshotPath,
                elements: DetectedElements(other: Self.form),
                metadata: stored.metadata))
        fixture.automation.accessibilityTree = ElementDetectionResult(
            snapshotId: "reread",
            screenshotPath: "",
            elements: DetectedElements(other: after),
            metadata: stored.metadata)
        return fixture
    }

    private static func setValue(_ fixture: MCPSnapshotMutationTestFixture) async throws -> ToolResponse {
        try await fixture.context.execute(
            tool: SetValueTool(context: fixture.context),
            arguments: ToolArguments(raw: ["on": "T1", "value": "EUR", "snapshot": fixture.snapshotID]))
    }

    @Test
    func `a value write that leaves the window's structure unchanged keeps the snapshot reusable`() async throws {
        let unchanged = [
            Self.element("elem_0", "AXTextField", y: 20, value: "1"),
            Self.element("elem_1", "AXDateTimeArea", y: 64, value: "2026-11-01"),
            Self.element("elem_2", "AXComboBox", y: 108, value: "EUR"),
        ]
        let fixture = try await Self.fixture(after: unchanged)

        let response = try await Self.setValue(fixture)

        #expect(!response.isError)
        #expect(fixture.automation.setValueCalls == 1)
        #expect(response.meta?.objectValue?[Self.reusableKey] == .bool(true))
    }

    @Test(arguments: ["added", "moved", "role"])
    func `a value write that reshapes the window leaves the snapshot stale`(change: String) async throws {
        var after = Self.form
        switch change {
        case "added": after.append(Self.element("elem_3", "AXTextField", y: 152))
        case "moved": after[1] = Self.element("elem_1", "AXDateTimeArea", y: 90)
        default: after[2] = Self.element("elem_2", "AXPopUpButton", y: 108)
        }
        let fixture = try await Self.fixture(after: after)

        let response = try await Self.setValue(fixture)

        #expect(!response.isError)
        #expect(fixture.automation.accessibilityTreeReads == 1)
        #expect(response.meta?.objectValue?[Self.reusableKey] == nil)
    }

    @Test
    func `a window that cannot be read again leaves the snapshot stale`() async throws {
        let fixture = try await Self.fixture(after: Self.form)
        fixture.automation.accessibilityTree = nil

        let response = try await Self.setValue(fixture)

        #expect(!response.isError)
        #expect(response.meta?.objectValue?[Self.reusableKey] == nil)
    }

    @Test
    func `a batch of value writes that keep the window's structure runs to the end`() async throws {
        let fixture = try await Self.fixture(after: Self.form)

        let response = try await fixture.context.execute(
            tool: BatchTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID,
                "observe_after": false,
                "steps": [
                    ["tool": "set_value", "args": ["on": "T1", "value": "34"]],
                    ["tool": "set_value", "args": ["on": "T1", "value": "2027-03-15"]],
                    ["tool": "set_value", "args": ["on": "T1", "value": "EUR"]],
                ],
            ]))

        #expect(!response.isError, "\(Self.text(response))")
        #expect(fixture.automation.setValueCalls == 3)
        #expect(Self.text(response).contains("Ran all 3 steps."))
    }

    @Test
    func `a batch stops after a value write that reshapes the window`() async throws {
        let fixture = try await Self.fixture(after: Self.form + [Self.element("elem_3", "AXTextField", y: 152)])

        let response = try await fixture.context.execute(
            tool: BatchTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": fixture.snapshotID,
                "steps": [
                    ["tool": "set_value", "args": ["on": "T1", "value": "34"]],
                    ["tool": "set_value", "args": ["on": "T1", "value": "EUR"]],
                ],
            ]))

        #expect(response.isError)
        #expect(fixture.automation.setValueCalls == 1)
        #expect(Self.text(response).contains("is stale after step 1 (set_value)"))
    }

    private static func text(_ response: ToolResponse) -> String {
        response.content.compactMap { content -> String? in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}
