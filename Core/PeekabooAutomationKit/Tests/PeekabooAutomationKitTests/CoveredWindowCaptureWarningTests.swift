import CoreGraphics
import Foundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

/// Chromium stops painting a window that other windows cover completely. ScreenCaptureKit then returns
/// the last painted frame while the accessibility tree keeps moving. Live, Chrome 156 behind a
/// maximized terminal: four captures across a scroll were byte-identical; with 89 pt of the window
/// uncovered the capture showed the new state.
struct CoveredWindowCaptureWarningTests {
    private static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let chrome = CGRect(x: 200, y: 93, width: 1000, height: 800)

    @Test
    func `a maximized window above covers the Chrome window completely`() {
        #expect(CoveredWindowCapturePolicy.isFullyCovered(
            Self.chrome,
            by: [CGRect(x: 0, y: 33, width: 1512, height: 860)],
            displays: [Self.display]))
    }

    @Test
    func `two windows that tile the target together cover it`() {
        #expect(CoveredWindowCapturePolicy.isFullyCovered(
            Self.chrome,
            by: [
                CGRect(x: 0, y: 0, width: 700, height: 982),
                CGRect(x: 700, y: 0, width: 812, height: 982),
            ],
            displays: [Self.display]))
    }

    @Test
    func `an uncovered strip keeps the window painting`() {
        #expect(!CoveredWindowCapturePolicy.isFullyCovered(
            CGRect(x: 200, y: 850, width: 1000, height: 800),
            by: [CGRect(x: 0, y: 33, width: 1512, height: 860)],
            displays: [Self.display]))
    }

    @Test
    func `the part of a window beyond every display does not count as visible`() {
        #expect(CoveredWindowCapturePolicy.isFullyCovered(
            CGRect(x: 1200, y: 93, width: 1000, height: 800),
            by: [CGRect(x: 0, y: 33, width: 1512, height: 900)],
            displays: [Self.display]))
    }

    @Test
    func `only Chromium-based apps get the stale capture warning`() {
        #expect(CoveredWindowCapturePolicy.warning(kind: .chromium, isFullyCovered: true) != nil)
        #expect(CoveredWindowCapturePolicy.warning(kind: .electron, isFullyCovered: true) != nil)
        #expect(CoveredWindowCapturePolicy.warning(kind: .appKit, isFullyCovered: true) == nil)
        #expect(CoveredWindowCapturePolicy.warning(kind: .chromium, isFullyCovered: false) == nil)
    }
}
