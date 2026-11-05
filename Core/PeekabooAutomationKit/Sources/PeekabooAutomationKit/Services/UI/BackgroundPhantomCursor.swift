import CoreGraphics
import Foundation
import PeekabooFoundation

/// Opt-in phantom cursor for background (PID-routed) pointer delivery.
///
/// With `PEEKABOO_PHANTOM_CURSOR=1`, this process starts its own renderer on demand and drives an agent
/// cursor to each background click target before the click is dispatched, then plays the click effect.
/// The real pointer never moves; overlays ignore the mouse and never activate.
enum BackgroundPhantomCursor {
    /// Upper bound on how long a click waits for the cursor to arrive (travel itself is at most 320 ms).
    static let arrivalTimeout: TimeInterval = 0.9
    /// The very first request also pays for starting the renderer.
    static let firstArrivalTimeout: TimeInterval = 2.0

    static var isEnabled: Bool {
        PhantomCursorEndpoint.isEnabled()
    }

    private static let started = StartedFlag()

    /// Travels to `point` and returns once the cursor has arrived (bounded).
    static func travel(to point: CGPoint, target: CGRect?) async {
        guard self.isEnabled else { return }
        let timeout = self.started.value ? self.arrivalTimeout : self.firstArrivalTimeout
        let arrived = await PhantomCursorClient.send(
            PhantomCursorRequest(kind: .move, point: point, target: target, label: PhantomCursorEndpoint.label()),
            timeout: timeout,
            spawnIfNeeded: true)
        if arrived { self.started.set() }
    }

    /// Plays the click effect at `point`; does not wait for it.
    static func click(at point: CGPoint, type: ClickType) async {
        guard self.isEnabled else { return }
        let click: PhantomCursorRequest.Click = switch type {
        case .double: .double
        case .right: .right
        default: .single
        }
        await PhantomCursorClient.send(
            PhantomCursorRequest(kind: .click, point: point, click: click, label: PhantomCursorEndpoint.label()),
            timeout: 0.25,
            spawnIfNeeded: true)
    }

    /// Hides the cursor while the real pointer is driven in the foreground. Never starts a renderer.
    static func hide() async {
        guard self.isEnabled else { return }
        await PhantomCursorClient.send(PhantomCursorRequest(kind: .hide), timeout: 0.1, spawnIfNeeded: false)
    }

    private final class StartedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.flag
        }

        func set() {
            self.lock.lock()
            self.flag = true
            self.lock.unlock()
        }
    }
}
