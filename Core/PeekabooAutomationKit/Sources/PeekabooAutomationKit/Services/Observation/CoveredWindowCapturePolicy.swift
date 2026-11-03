import AppKit
import CoreGraphics
import Foundation

/// Observation warnings that change how a screenshot must be read. They share one prefix so `see`
/// can show them in the text an agent reads; other warnings stay in metadata only.
public enum StaleCaptureWarnings {
    public static let prefix = "Screenshot may be stale: "

    public static func select(_ warnings: [String]) -> [String] {
        warnings.filter { $0.hasPrefix(self.prefix) }
    }
}

/// Warns when a screenshot of a Chromium-based window is likely stale.
///
/// Chromium stops painting a window that other windows cover completely; macOS reports it occluded.
/// ScreenCaptureKit then returns the last painted frame while the accessibility tree keeps changing,
/// so a page that scrolled or switched tabs still shows its old pixels. Peekaboo cannot make the
/// window repaint without raising it, so it says so instead.
@_spi(Testing) public enum CoveredWindowCapturePolicy {
    /// Stale-capture warnings share the "Screenshot may be stale: " prefix (agreed with the off-Space
    /// warning) and then name the reason.
    public static let staleCaptureWarning = StaleCaptureWarnings.prefix +
        "this Chromium-based window is completely covered by other windows " +
        "and is not repainting. Its accessibility elements are current; the pixels refresh once any part " +
        "of the window is uncovered."

    /// Whether the visible part of `window` (its intersection with the displays) lies entirely under
    /// the union of `covering` windows. All rectangles use global top-left display coordinates.
    public static func isFullyCovered(_ window: CGRect, by covering: [CGRect], displays: [CGRect]) -> Bool {
        var uncovered = displays.map { $0.intersection(window) }.filter { !$0.isNull && !$0.isEmpty }
        guard !uncovered.isEmpty else { return false }
        for cover in covering where !cover.isNull && !cover.isEmpty {
            uncovered = uncovered.flatMap { self.subtract(cover, from: $0) }
            if uncovered.isEmpty { return true }
        }
        return uncovered.isEmpty
    }

    static func warning(kind: WindowRoutedApplicationKind, isFullyCovered: Bool) -> String? {
        guard isFullyCovered, kind == .chromium || kind == .electron else { return nil }
        return self.staleCaptureWarning
    }

    /// The live check for an on-screen window: normal-level, non-transparent windows above it.
    /// Off-screen windows (minimized, another Space) are left to the capture path's own diagnostics.
    @MainActor
    public static func liveWarning(processIdentifier: pid_t, windowID: CGWindowID) -> String? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        let kind = WindowRoutedApplicationClassifier.kind(of: application)
        guard kind == .chromium || kind == .electron else { return nil }
        return self.warning(kind: kind, isFullyCovered: self.liveIsFullyCovered(windowID: windowID))
    }

    /// Whether an on-screen window lies entirely under normal-level, non-transparent windows above it.
    @MainActor
    static func liveIsFullyCovered(windowID: CGWindowID) -> Bool {
        guard let targetInfo = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)
            as? [[String: Any]])?.first,
            targetInfo[kCGWindowIsOnscreen as String] as? Bool == true,
            let target = self.bounds(of: targetInfo)
        else { return false }
        let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], windowID) as? [[String: Any]]) ?? []
        let covering = above.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            return self.bounds(of: info)
        }
        return self.isFullyCovered(target, by: covering, displays: self.activeDisplayBounds())
    }

    private static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(cover)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        let pieces = [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
        ]
        return pieces.filter { $0.width > 0 && $0.height > 0 }
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] else { return nil }
        // swiftlint:disable:next force_cast
        return CGRect(dictionaryRepresentation: dictionary as! CFDictionary)
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}

extension DesktopObservationService {
    func coveredWindowWarning(for capture: CaptureResult) -> String? {
        guard capture.metadata.mode == .window,
              let processIdentifier = capture.metadata.applicationInfo?.processIdentifier,
              let rawWindowID = capture.metadata.windowInfo?.windowID,
              let windowID = CGWindowID(exactly: rawWindowID)
        else { return nil }
        return self.coveredWindowCaptureWarning(processIdentifier, windowID)
    }
}
