import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooAutomationKit

/// Measured with an Electron window on another Space: the screenshot kept the frame from when the window left
/// the Space (13 minutes old), and the element list kept an old clock value and the old tab selection. An AppKit
/// window there captured fresh text. `see` must say when its result may be stale.
@MainActor
struct OffSpaceCaptureWarningTests {
    @Test(arguments: [WindowRoutedApplicationKind.chromium, .electron])
    func `a Chromium window on another Space is flagged as possibly stale, pixels and elements`(
        kind: WindowRoutedApplicationKind)
    {
        let warning = OffSpaceCapturePolicy.warning(kind: kind, placement: .otherSpace(spaceID: 5, spaceNumber: 3))

        let text = try? #require(warning)
        // Shared prefix with pb-chrome-web's covered-window warning, so `see` prints both the same way.
        #expect(text?.hasPrefix("Screenshot may be stale: this window is on Space 3 (ID 5), which no display shows.")
            == true)
        #expect(text?.contains("accessibility elements may be out of date too") == true)
        #expect(text?.contains("still reach") == true)
    }

    @Test
    func `visible Chromium windows and off-Space AppKit windows get no off-Space warning`() {
        #expect(OffSpaceCapturePolicy.warning(kind: .electron, placement: .visibleSpace) == nil)
        #expect(OffSpaceCapturePolicy.warning(kind: .electron, placement: .unknown) == nil)
        #expect(OffSpaceCapturePolicy.warning(
            kind: .appKit, placement: .otherSpace(spaceID: 5, spaceNumber: 3)) == nil)
    }

    @Test
    func `a window observation carries the off-Space warning`() async throws {
        let app = ServiceApplicationInfo(processIdentifier: 123, bundleIdentifier: "com.example.fixture", name: "Fixture")
        let window = ServiceWindowInfo(windowID: 8793, title: "Offspace", bounds: CGRect(x: 200, y: 120, width: 900, height: 640))
        let capture = CaptureResult(
            imageData: Data([9]),
            metadata: CaptureMetadata(size: window.bounds.size, mode: .window, applicationInfo: app, windowInfo: window))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: capture),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        var asked: [(pid_t, CGWindowID)] = []
        service.offSpaceWindowCaptureWarning = { pid, windowID in
            asked.append((pid, windowID))
            return "off-Space warning"
        }

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))

        #expect(result.diagnostics.warnings.contains("off-Space warning"))
        #expect(asked.map(\.0) == [123])
        #expect(asked.map(\.1) == [8793])
    }
}
