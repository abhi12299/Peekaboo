import CoreGraphics
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

/// The benchmark saw "window 7387 moved or resized … now 18,517 375×363" for a window that had not moved: it was
/// on another Space. The refusal must name that cause and what works instead.
struct MCPSnapshotWindowSpaceMessageTests {
    @Test
    func `a frame change on a window now on a hidden Space names the Space instead of a move`() {
        let error = MCPToolContext.SnapshotWindowFrameChanged(
            windowID: 7387,
            snapshotID: "ps1_abc",
            capturedBounds: CGRect(x: 1530, y: 517, width: 375, height: 363),
            liveBounds: CGRect(x: 18, y: 517, width: 375, height: 363),
            liveIsOnScreen: false,
            spacePlacement: .otherSpace(spaceID: 5, spaceNumber: 3))

        #expect(error.description.contains("window 7387 is now on Space 3 (ID 5), which no display shows"))
        #expect(error.description.contains("it did not necessarily move"))
        #expect(error.description.contains("run `see` on the window again"))
        #expect(!error.description.contains("moved or resized"))
    }

    @Test
    func `a frame change on a visible window still reads as a move`() {
        let error = MCPToolContext.SnapshotWindowFrameChanged(
            windowID: 42,
            snapshotID: "ps1_abc",
            capturedBounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            liveBounds: CGRect(x: 0, y: 40, width: 10, height: 10),
            liveIsOnScreen: true,
            spacePlacement: nil)

        #expect(error.description.hasPrefix("window 42 moved or resized after snapshot 'ps1_abc' was taken"))
    }
}
