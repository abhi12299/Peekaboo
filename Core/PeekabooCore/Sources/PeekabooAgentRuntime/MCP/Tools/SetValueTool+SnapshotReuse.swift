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
/// shows the same elements with the same IDs, roles and frames. Values are ignored. Anything that cannot be checked
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

/// A window's accessibility elements without their values: ID, role and frame (rounded to whole points).
private struct WindowStructure: Equatable {
    private struct Node: Equatable {
        let id: String
        let role: String?
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private let nodes: [Node]

    init(_ elements: DetectedElements) {
        self.nodes = elements.all
            .filter { !$0.isOCRSemanticEvidence && $0.attributes["source"] == nil }
            .map { element in
                Node(
                    id: element.id,
                    role: element.attributes["role"],
                    x: Int(element.bounds.minX.rounded()),
                    y: Int(element.bounds.minY.rounded()),
                    width: Int(element.bounds.width.rounded()),
                    height: Int(element.bounds.height.rounded()))
            }
            .sorted { $0.id < $1.id }
    }

    var isEmpty: Bool {
        self.nodes.isEmpty
    }
}
