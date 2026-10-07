import CoreGraphics
import Foundation
import PeekabooFoundation

/// Makes one exact background window key for its owner around a single input action, then undoes it.
@MainActor
struct BackgroundFocusSession {
    typealias RecordPoster = @MainActor (
        _ target: UIAutomationTarget.ExactWindow,
        _ kind: BackgroundWindowActivationDriver.RecordKind) throws -> Void
    typealias PrimingEventPoster = @MainActor (_ event: CGEvent, _ pid: pid_t) -> Void
    typealias Sleeper = @MainActor (_ duration: Duration) async -> Void
    typealias EnvironmentReader = @MainActor (_ name: String) -> String?

    /// Set to `0` to skip the focus record, priming click, and undo record (the action still runs).
    static let killSwitchEnvironmentKey = "PEEKABOO_BACKGROUND_FOCUS_RECORD"

    private let postRecord: RecordPoster
    private let postPrimingEvent: PrimingEventPoster
    private let sleep: Sleeper
    private let readEnvironment: EnvironmentReader

    init(
        postRecord: @escaping RecordPoster = { target, kind in
            _ = try BackgroundWindowActivationDriver.prepare(target, kind: kind)
        },
        postPrimingEvent: @escaping PrimingEventPoster = { event, pid in event.postToPid(pid) },
        sleep: @escaping Sleeper = { duration in
            // Non-cancellable, so a cancelled request still spaces the priming down/up and lets
            // queued action events land before the undo record.
            _ = await Task.detached {
                try? await Task.sleep(for: duration)
            }.value
        },
        readEnvironment: @escaping EnvironmentReader = { ProcessInfo.processInfo.environment[$0] })
    {
        self.postRecord = postRecord
        self.postPrimingEvent = postPrimingEvent
        self.sleep = sleep
        self.readEnvironment = readEnvironment
    }

    func perform<T>(
        target: UIAutomationTarget.ExactWindow,
        action: @MainActor () async throws -> T) async throws -> T
    {
        guard self.readEnvironment(Self.killSwitchEnvironmentKey) != "0" else {
            return try await action()
        }
        do {
            try self.postRecord(target, .focus)
        } catch {
            // A record that may have been delivered could have left the window key; revert it.
            if (error as? DesktopActionFailure)?.outcome.state == .indeterminate {
                try? self.postRecord(target, .undo)
            }
            throw Self.preparationRefusal(error)
        }
        await self.sleep(.milliseconds(50))
        await self.postPrimingClick(target: target)

        let result: Result<T, any Error>
        do {
            result = try await .success(action())
        } catch {
            result = .failure(error)
        }
        // Let the action's queued events reach the window while it is still key.
        await self.sleep(.milliseconds(200))
        // Best effort: the action already ran, so an undo failure must not replace its result or error.
        try? self.postRecord(target, .undo)
        return try result.get()
    }

    /// The action never ran, so the caller may retry the whole request.
    private static func preparationRefusal(_ error: any Error) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: (error as? DesktopActionFailure)?.outcome.refusalReason ?? .targetUnavailable,
            message: "Background focus preparation failed, so the action was not dispatched; " +
                "it is safe to retry.",
            hint: "Observe the target window again before retrying.",
            causeDescription: error.localizedDescription)
    }

    /// A left click just outside the window's top-left corner, so it makes the window key without
    /// landing on a control, the title bar, or the window background (which could start a window drag).
    /// Field 51 names the window; without it AppKit sees window number 0 and drops the event.
    private func postPrimingClick(target: UIAutomationTarget.ExactWindow) async {
        let point = CGPoint(x: target.bounds.minX - 10, y: target.bounds.minY - 10)
        let pid = target.identity.ownerProcessIdentifier
        // Both halves are built before either is posted, so a mouse-down is never left unpaired.
        guard let down = Self.primingEvent(.leftMouseDown, at: point, target: target),
              let up = Self.primingEvent(.leftMouseUp, at: point, target: target)
        else { return }
        self.postPrimingEvent(down, pid)
        await self.sleep(.milliseconds(60))
        self.postPrimingEvent(up, pid)
        await self.sleep(.milliseconds(200))
    }

    private static func primingEvent(
        _ type: CGEventType,
        at point: CGPoint,
        target: UIAutomationTarget.ExactWindow) -> CGEvent?
    {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left),
            let windowField = CGEventField(rawValue: 51)
        else { return nil }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.identity.ownerProcessIdentifier))
        event.setIntegerValueField(windowField, value: Int64(target.identity.windowID))
        return event
    }
}
