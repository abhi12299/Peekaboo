import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundFocusSessionTests {
    @Test
    func `focus record and priming click precede the action and the undo record follows it`() async throws {
        let recorder = Recorder()
        let target = try Self.target()
        let result = try await recorder.session().perform(target: target) {
            recorder.steps.append(.action)
            return 7
        }
        #expect(result == 7)
        #expect(recorder.steps == [
            .record(windowID: 100, kind: .focus),
            .pointer(.leftMouseDown),
            .pointer(.leftMouseUp),
            .action,
            .record(windowID: 100, kind: .undo),
        ])
    }

    @Test
    func `priming click lands outside the window's top-left corner and is routed to the exact window`() async throws {
        let recorder = Recorder()
        try await recorder.session().perform(target: Self.target()) {}
        #expect(recorder.events.map(\.event.type) == [.leftMouseDown, .leftMouseUp])
        for (event, pid) in recorder.events {
            #expect(pid == 9001)
            #expect(event.location == CGPoint(x: 190, y: 140))
            #expect(event.getIntegerValueField(CGEventField(rawValue: 51)!) == 100)
        }
    }

    @Test
    func `undo record is still sent when the action throws and the action error propagates unchanged`() async throws {
        let recorder = Recorder()
        let actionFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .completionUnknown, unitCount: .one, message: "Hotkey delivery was interrupted.")
        do {
            try await recorder.session().perform(target: Self.target()) { throw actionFailure }
            Issue.record("Expected the action failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure == actionFailure)
        }
        #expect(recorder.steps.last == .record(windowID: 100, kind: .undo))
    }

    @Test
    func `kill switch runs only the action with no records and no priming click`() async throws {
        let recorder = Recorder(environment: ["PEEKABOO_BACKGROUND_FOCUS_RECORD": "0"])
        let result = try await recorder.session().perform(target: Self.target()) {
            recorder.steps.append(.action)
            return "done"
        }
        #expect(result == "done")
        #expect(recorder.steps == [.action])
    }

    @Test
    func `focus record failure skips the action and refuses as safe to retry`() async throws {
        let recorder = Recorder()
        recorder.focusRecordError = PeekabooError.operationError(message: "SkyLight record rejected")
        do {
            try await recorder.session().perform(target: Self.target()) { recorder.steps.append(.action) }
            Issue.record("Expected a preparation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.message.contains("Background focus preparation failed"))
            #expect(failure.causeDescription == recorder.focusRecordError?.localizedDescription)
        }
        #expect(recorder.steps.isEmpty)
    }

    @Test
    func `uncertain focus record delivery is undone before refusing`() async throws {
        let recorder = Recorder()
        recorder.focusRecordError = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown, unitCount: .one, message: "uncertain record")
        do {
            try await recorder.session().perform(target: Self.target()) { recorder.steps.append(.action) }
            Issue.record("Expected a preparation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(recorder.steps == [.record(windowID: 100, kind: .undo)])
    }

    @Test
    func `focus record refusal keeps its specific reason`() async throws {
        let recorder = Recorder()
        recorder.focusRecordError = DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported, message: "Target-only background window activation is unavailable.")
        do {
            try await recorder.session().perform(target: Self.target()) { recorder.steps.append(.action) }
            Issue.record("Expected a preparation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.message.contains("Background focus preparation failed"))
        }
        #expect(recorder.steps.isEmpty)
    }

    @Test
    func `undo record failure does not turn a completed action into a failure`() async throws {
        let recorder = Recorder()
        recorder.undoRecordError = PeekabooError.snapshotStale("window closed during the action")
        let result = try await recorder.session().perform(target: Self.target()) { 42 }
        #expect(result == 42)
    }

    @Test
    func `session pauses after each step so the target handles it before the next`() async throws {
        let recorder = Recorder(recordsPauses: true)
        try await recorder.session().perform(target: Self.target()) { recorder.steps.append(.action) }
        #expect(recorder.steps == [
            .record(windowID: 100, kind: .focus), .pause,
            .pointer(.leftMouseDown), .pause,
            .pointer(.leftMouseUp), .pause,
            .action, .pause,
            .record(windowID: 100, kind: .undo),
        ])
    }

    private static func target() throws -> UIAutomationTarget.ExactWindow {
        try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 100, ownerProcessIdentifier: 9001, ownerProcessStartIdentity: 800),
            bounds: CGRect(x: 200, y: 150, width: 500, height: 400))
    }
}

@MainActor
private final class Recorder {
    enum Step: Equatable {
        case record(windowID: Int, kind: BackgroundWindowActivationDriver.RecordKind)
        case pointer(CGEventType)
        case action
        case pause
    }

    var steps: [Step] = []
    var events: [(event: CGEvent, pid: pid_t)] = []
    let environment: [String: String]
    let recordsPauses: Bool
    var focusRecordError: (any Error)?
    var undoRecordError: (any Error)?

    init(environment: [String: String] = [:], recordsPauses: Bool = false) {
        self.environment = environment
        self.recordsPauses = recordsPauses
    }

    func session() -> BackgroundFocusSession {
        BackgroundFocusSession(
            postRecord: { target, kind in
                if let error = kind == .focus ? self.focusRecordError : self.undoRecordError {
                    throw error
                }
                self.steps.append(.record(windowID: target.identity.windowID, kind: kind))
            },
            postPrimingEvent: { event, pid in
                self.steps.append(.pointer(event.type))
                self.events.append((event, pid))
            },
            sleep: { duration in
                if self.recordsPauses, duration > .zero {
                    self.steps.append(.pause)
                }
            },
            readEnvironment: { self.environment[$0] })
    }
}
