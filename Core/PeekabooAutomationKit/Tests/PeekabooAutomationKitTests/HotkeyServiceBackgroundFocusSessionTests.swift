import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct HotkeyServiceBackgroundFocusSessionTests {
    @Test
    func `exact-window hotkey keys run between the focus record plus priming click and the undo record`() async throws {
        let log = FocusSessionLog()
        let result = try await log.service().hotkey(
            keys: "cmd,s",
            holdDuration: 50,
            automationTarget: Self.target())
        #expect(log.steps == [
            .record(.focus),
            .priming(.leftMouseDown),
            .priming(.leftMouseUp),
            .key(.flagsChanged),
            .key(.keyDown),
            .key(.keyUp),
            .key(.flagsChanged),
            .record(.undo),
        ])
        #expect(result.outcome?.state == .dispatchedUnverified)
    }

    @Test
    func `exact-window hotkey key events name the target window as well as its process`() async throws {
        let log = FocusSessionLog()
        _ = try await log.service().hotkey(keys: "cmd,s", holdDuration: 50, automationTarget: Self.target())
        #expect(log.keyEvents.count == 4)
        for event in log.keyEvents {
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(getpid()))
            #expect(event.getIntegerValueField(CGEventField(rawValue: 51)!) == 100)
        }
    }

    @Test
    func `window that holds its app's keyboard focus only after the focus session receives the hotkey`() async throws {
        let log = FocusSessionLog()
        let result = try await log.automation().hotkeyWithOutcome(
            keys: "cmd,s",
            holdDuration: 50,
            expectedWindowIdentity: Self.identity,
            expectedWindowBounds: Self.bounds)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(log.steps.filter { if case .key = $0 { true } else { false } }.count == 4)
        #expect(log.steps.last == .record(.undo))
    }

    @Test
    func `kill switch restores the keyboard focus refusal for a window that is not key`() async throws {
        let log = FocusSessionLog()
        log.environment = ["PEEKABOO_BACKGROUND_FOCUS_RECORD": "0"]
        do {
            _ = try await log.automation().hotkeyWithOutcome(
                keys: "cmd,s",
                holdDuration: 50,
                expectedWindowIdentity: Self.identity,
                expectedWindowBounds: Self.bounds)
            Issue.record("Expected the keyboard focus refusal")
        } catch let PeekabooError.invalidInput(message) {
            #expect(message.contains(BackgroundKeyboardFocusRemediation.message))
        }
        #expect(log.steps.isEmpty)
    }

    @Test(arguments: ["cmd,w", "cmd,q", "cmd,h", "cmd,m"])
    func `lifecycle shortcuts stay refused before any focus record or key`(keys: String) async throws {
        let log = FocusSessionLog()
        await #expect(throws: PeekabooError.self) {
            try await log.service().hotkey(keys: keys, holdDuration: 50, automationTarget: Self.target())
        }
        #expect(log.steps.isEmpty)
    }

    @Test
    func `prepared paste keeps its own window preparation and opens no focus session`() async throws {
        let log = FocusSessionLog()
        var preparations = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in log.steps.append(.key(event.type)) },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { 11 },
            holdSleeper: { _ in },
            heldInterEventDelay: {},
            backgroundWindowPreparer: { _, validate in
                try validate()
                preparations += 1
                return .dispatchedUnverified(
                    delivery: .init(mechanism: .composite, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(4))
            },
            backgroundFocusSession: log.session())
        let result = try await service.hotkey(
            keys: "cmd,v",
            holdDuration: 50,
            automationTarget: Self.target(focusedElement: true),
            clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
            prepareBackgroundWindow: true)
        #expect(preparations == 1)
        #expect(log.steps == [.key(.flagsChanged), .key(.keyDown), .key(.keyUp), .key(.flagsChanged)])
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 8)
    }

    static let bounds = CGRect(x: 200, y: 150, width: 500, height: 400)
    static let identity = WindowMutationIdentity(
        windowID: 100, ownerProcessIdentifier: getpid(), ownerProcessStartIdentity: 800)

    static func target(focusedElement: Bool = false) throws -> UIAutomationTarget {
        try .exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 100, ownerProcessIdentifier: getpid(), ownerProcessStartIdentity: 800),
            bounds: CGRect(x: 200, y: 150, width: 500, height: 400),
            focusedElement: focusedElement
                ? FocusedElementIdentity(
                    processIdentifier: getpid(),
                    windowID: 100,
                    role: "AXTextArea",
                    frame: CGRect(x: 200, y: 182, width: 500, height: 368))
                : nil))
    }
}

@MainActor
final class FocusSessionLog {
    enum Step: Equatable {
        case record(BackgroundWindowActivationDriver.RecordKind)
        case priming(CGEventType)
        case key(CGEventType)
    }

    var steps: [Step] = []
    var keyEvents: [CGEvent] = []
    var environment: [String: String] = [:]

    var focused: Bool {
        self.steps.contains(.record(.focus))
    }

    func session() -> BackgroundFocusSession {
        BackgroundFocusSession(
            postRecord: { _, kind in
                self.steps.append(.record(kind))
                self.onRecord(kind)
            },
            postPrimingEvent: { event, _ in self.steps.append(.priming(event.type)) },
            sleep: { _ in },
            readEnvironment: { self.environment[$0] })
    }

    func service(
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor()) -> HotkeyService
    {
        HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in
                self.steps.append(.key(event.type))
                self.keyEvents.append(event)
            },
            processStartIdentityProvider: { _ in 800 },
            holdSleeper: { _ in },
            heldInterEventDelay: {},
            desktopOperationExecutor: desktopOperationExecutor,
            backgroundFocusSession: self.session())
    }

    /// The window becomes its app's key window, with focus inside it, only once the focus record lands.
    func automation() -> UIAutomationService {
        let windowID = HotkeyServiceBackgroundFocusSessionTests.identity.windowID
        let focusState = LockedFocusState()
        let service = UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            hotkeyServiceFactory: { context in
                self.service(desktopOperationExecutor: context.desktopOperationExecutor)
            },
            exactWindowFocusReader: { pid in
                ExactWindowFocusSnapshot(
                    processIdentifier: pid,
                    windowID: focusState.focused ? windowID : windowID + 1,
                    frame: CGRect(x: 250, y: 200, width: 100, height: 30))
            },
            exactKeyWindowReader: { pid in
                ExactKeyWindowSnapshot(
                    processIdentifier: pid,
                    windowID: focusState.focused ? windowID : windowID + 1,
                    isSheet: false,
                    hasAttachedSheet: false)
            },
            exactWindowIdentityValidator: { _, _ in true },
            processStartIdentityProvider: { _ in 800 })
        self.onRecord = { focusState.focused = $0 == .focus }
        return service
    }

    private var onRecord: (BackgroundWindowActivationDriver.RecordKind) -> Void = { _ in }
}

private final class LockedFocusState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFocused = false

    var focused: Bool {
        get { self.lock.withLock { self.storedFocused } }
        set { self.lock.withLock { self.storedFocused = newValue } }
    }
}
