import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundWindowActivationDriverTests {
    @Test
    func `target-only record names one exact window and no front-process operation`() {
        let record = BackgroundWindowActivationDriver.eventRecord(windowID: 0x1234_5678)
        #expect(record.count == 0xF8)
        #expect(record[0x04] == 0xF8)
        #expect(record[0x08] == 0x0D)
        #expect(record[0x8A] == 1)
        #expect(Array(record[0x3C..<0x40]) == [0x78, 0x56, 0x34, 0x12])
        let populated: Set = [0x04, 0x08, 0x8A, 0x3C, 0x3D, 0x3E, 0x3F]
        #expect(record.indices.allSatisfy { populated.contains($0) || record[$0] == 0 })
    }

    @Test
    func `undo record differs from the focus record only in its kind byte`() {
        let focus = BackgroundWindowActivationDriver.eventRecord(windowID: 0x1234_5678, kind: .focus)
        let undo = BackgroundWindowActivationDriver.eventRecord(windowID: 0x1234_5678, kind: .undo)
        #expect(undo[0x8A] == 0x02)
        #expect(focus[0x8A] == 0x01)
        #expect(undo.count == focus.count)
        #expect(undo.indices.filter { undo[$0] != focus[$0] } == [0x8A])
    }

    @Test
    func `a focus refusal names the captured and live values that differ`() throws {
        let live = Self.live(bounds: CGRect(x: 200, y: 150, width: 500, height: 422), isOnScreen: false)

        let detail = BackgroundWindowActivationDriver.liveTargetMismatch(
            try Self.target(),
            kind: .focus,
            live: live,
            liveProcessStartIdentity: 800)

        #expect(detail == "window 100 bounds: captured 200,150 500×400, now 200,150 500×422; on screen: no")
    }

    @Test
    func `the live check admits the captured visible window and an undo for a moved or hidden one`() throws {
        let target = try Self.target()
        let mismatch = { (kind: BackgroundWindowActivationDriver.RecordKind, live: SystemWindowIdentity) in
            BackgroundWindowActivationDriver.liveTargetMismatch(
                target, kind: kind, live: live, liveProcessStartIdentity: 800)
        }

        #expect(mismatch(.focus, Self.live()) == nil)
        let movedHidden = Self.live(
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10), layer: 3, alpha: 0, isOnScreen: false)
        #expect(mismatch(.undo, movedHidden) == nil)
    }

    @Test
    func `the live check refuses what it refused before the diagnostics`() throws {
        let capturedTarget = try Self.target()
        func mismatch(
            _ kind: BackgroundWindowActivationDriver.RecordKind = .focus,
            target: UIAutomationTarget.ExactWindow? = nil,
            live: SystemWindowIdentity? = Self.live(),
            generation: UInt64? = 800) -> String?
        {
            BackgroundWindowActivationDriver.liveTargetMismatch(
                target ?? capturedTarget, kind: kind, live: live, liveProcessStartIdentity: generation)
        }

        #expect(mismatch(live: nil) == "window 100 is no longer listed")
        #expect(mismatch(.undo, live: Self.live(ownerProcessIdentifier: 9002)) ==
            "window 100 owner pid: captured 9001, now 9002")
        #expect(mismatch(.undo, generation: 801) == "window 100 generation: captured 800, now 801")
        #expect(mismatch(.undo, generation: nil) == "window 100 generation: captured 800, now none")
        #expect(mismatch(live: Self.live(layer: 3)) == "window 100 layer: now 3, normal 0")
        #expect(mismatch(live: Self.live(alpha: 0)) == "window 100 alpha: now 0.0")
        let receiptless = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 100,
                ownerProcessIdentifier: 9001,
                ownerProcessStartIdentity: 800),
            bounds: Self.capturedBounds)
        #expect(mismatch(target: receiptless) ==
            "window 100 receipt bounds: captured none, now 200,150 500×400")
    }

    private static let capturedBounds = CGRect(x: 200, y: 150, width: 500, height: 400)

    private static func target() throws -> UIAutomationTarget.ExactWindow {
        try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 100,
                ownerProcessIdentifier: 9001,
                ownerProcessStartIdentity: 800,
                capturedBounds: self.capturedBounds),
            bounds: self.capturedBounds)
    }

    private static func live(
        ownerProcessIdentifier: pid_t = 9001,
        bounds: CGRect = capturedBounds,
        layer: Int = 0,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true) -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 100,
            ownerProcessIdentifier: ownerProcessIdentifier,
            title: "Untitled",
            bounds: bounds,
            layer: layer,
            alpha: alpha,
            isOnScreen: isOnScreen,
            sharingState: .readOnly)
    }
}
