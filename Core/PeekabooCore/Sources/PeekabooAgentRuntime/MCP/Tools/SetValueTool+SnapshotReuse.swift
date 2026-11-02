import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation

/// Decides whether a `set_value` left its snapshot usable for later element actions (for example the next steps of a
/// `batch`).
///
/// Writing a value usually changes only that value. A write can still reshape the window (a choice that reveals more
/// fields, a combo box that opens a list), so the snapshot is reused only when an AX-only re-read of the same window
/// shows the same elements with the same roles and frames. Values are ignored. Anything that cannot be checked
/// keeps the snapshot stale.
enum MCPSetValueSnapshotReuse {
    @MainActor
    static func keepsSnapshotReusable(
        outcome: DesktopActionOutcome?,
        snapshotID: String,
        context: MCPToolContext) async -> Bool
    {
        guard let outcome else { return false }
        switch outcome.state {
        case .confirmedNoChange:
            // Nothing was written.
            return outcome.dispatchState == .none
        case .confirmedChange:
            guard outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background) else { return false }
        default:
            return false
        }
        guard let captured = try? await context.snapshots.getDetectionResult(snapshotId: snapshotID),
              let window = captured.metadata.windowContext,
              window.windowID != nil,
              window.shouldFocusWebContent != true,
              let reread = try? await context.automation.inspectAccessibilityTree(
                  windowContext: self.freshReadContext(window))
        else { return false }
        let before = WindowStructure(captured.elements)
        return !before.isEmpty && before == WindowStructure(reread.elements)
    }

    /// The captured window, read again without the AX tree cache and without the menu bar.
    private static func freshReadContext(_ window: WindowContext) -> WindowContext {
        WindowContext(
            applicationName: window.applicationName,
            applicationBundleId: window.applicationBundleId,
            applicationBundlePath: window.applicationBundlePath,
            applicationExecutablePath: window.applicationExecutablePath,
            applicationProcessId: window.applicationProcessId,
            applicationProcessStartIdentity: window.applicationProcessStartIdentity,
            windowTitle: window.windowTitle,
            windowID: window.windowID,
            windowBounds: window.windowBounds,
            windowMutationIdentity: window.windowMutationIdentity,
            focusedElement: window.focusedElement,
            shouldFocusWebContent: false,
            includeMenuBarElements: false,
            traversalBudget: window.traversalBudget,
            requiresFreshAccessibilityTree: true,
            accessibilityTimeoutSeconds: window.accessibilityTimeoutSeconds,
            allowApplicationScopedAccessibilityFallback: window.allowApplicationScopedAccessibilityFallback)
    }
}

/// A window's accessibility elements without their values or IDs: each element's role and frame (rounded to whole
/// points). IDs are positional, so a read that skips or adds one element renumbers the rest; later steps resolve their
/// IDs through the stored snapshot and match the live element by role and frame, so those are what must not change.
/// Pure containers (non-actionable groups such as the full-screen button's hover group) come and go between reads and
/// are left out.
private struct WindowStructure: Equatable {
    private struct Node: Comparable {
        let role: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        static func < (lhs: Node, rhs: Node) -> Bool {
            (lhs.role, lhs.x, lhs.y, lhs.width, lhs.height) < (rhs.role, rhs.x, rhs.y, rhs.width, rhs.height)
        }
    }

    private let nodes: [Node]

    init(_ elements: DetectedElements) {
        self.nodes = elements.all
            .filter { !$0.isOCRSemanticEvidence && $0.attributes["source"] == nil }
            .filter { $0.attributes["role"] != "AXGroup" || $0.isActionable }
            .map { element in
                Node(
                    role: element.attributes["role"] ?? element.type.rawValue,
                    x: Int(element.bounds.minX.rounded()),
                    y: Int(element.bounds.minY.rounded()),
                    width: Int(element.bounds.width.rounded()),
                    height: Int(element.bounds.height.rounded()))
            }
            .sorted()
    }

    var isEmpty: Bool {
        self.nodes.isEmpty
    }
}
