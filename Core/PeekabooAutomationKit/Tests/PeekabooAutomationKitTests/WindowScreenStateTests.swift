import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct WindowScreenStateTests {
    private let spaces = SpaceVisibility(visibleSpaceIDs: [6], orderedSpaceIDs: [7, 6, 5, 4])

    private func window(
        isOnScreen: Bool = true,
        isOffScreen: Bool = false,
        isMinimized: Bool = false,
        spaceID: UInt64? = 6) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: 42,
            title: "Remote Panel",
            bounds: CGRect(x: 300, y: 490, width: 420, height: 192),
            isMinimized: isMinimized,
            spaceID: spaceID,
            isOffScreen: isOffScreen,
            isOnScreen: isOnScreen)
    }

    /// The benchmark's `window list` called an off-Space window ON-SCREEN because the label read only geometry.
    @Test
    func `a window on a Space no display shows is labelled with that Space, not ON-SCREEN`() {
        let state = WindowScreenState.of(self.window(isOnScreen: false, spaceID: 5), spaces: self.spaces)

        #expect(state == .otherSpace(.otherSpace(spaceID: 5, spaceNumber: 3)))
        #expect(state.label == "ON ANOTHER SPACE: Space 3 (ID 5)")
        #expect(state.metadataValue == "other_space")
    }

    @Test
    func `visible, minimized and off-screen windows keep distinct labels`() {
        #expect(WindowScreenState.of(self.window(), spaces: self.spaces).label == "ON-SCREEN")
        #expect(WindowScreenState.of(
            self.window(isOnScreen: false, isMinimized: true, spaceID: 5), spaces: self.spaces).label == "MINIMIZED")
        // Not on screen although its Space is visible: hidden or ordered out.
        #expect(WindowScreenState.of(self.window(isOnScreen: false), spaces: self.spaces).label == "OFF-SCREEN")
        #expect(WindowScreenState.of(self.window(isOffScreen: true), spaces: self.spaces).label == "OFF-SCREEN")
        // Without Space information the old geometry answer stands.
        #expect(WindowScreenState.of(self.window(isOnScreen: false, spaceID: nil), spaces: self.spaces).label ==
            "OFF-SCREEN")
    }
}
