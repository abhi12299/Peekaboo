import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundPositionalClickRouterTests {
    @Test
    func `single left click with no pressable element is posted to the exact window`() async throws {
        let log = RouterLog()
        log.hitTestCandidates = [PositionalMockElement(role: "AXGroup", frame: Fixture.bounds)]

        _ = try await log.router().click(at: Fixture.point, button: .left, count: 1, target: Fixture.target())

        #expect(log.pointerEvents.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        for event in log.pointerEvents {
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 9001)
            #expect(event.getIntegerValueField(CGEventField(rawValue: 51)!) == 100)
        }
    }

    @Test
    func `window-routed single left click runs between the focus record plus priming click and undo`() async throws {
        let log = RouterLog()

        _ = try await log.router().click(at: Fixture.point, button: .left, count: 1, target: Fixture.target())

        #expect(log.steps == [
            .record(.focus),
            .priming(.leftMouseDown),
            .priming(.leftMouseUp),
            .pointer(.mouseMoved),
            .pointer(.leftMouseDown),
            .pointer(.leftMouseUp),
            .record(.undo),
        ])
    }

    @Test
    func `pressable element is pressed through accessibility with no focus session or pointer events`() async throws {
        let log = RouterLog()
        let button = PositionalMockElement(
            role: "AXButton",
            frame: CGRect(x: 380, y: 290, width: 40, height: 20),
            supportedActions: [AXActionNames.kAXPressAction])
        log.hitTestCandidates = [button]

        let outcome = try await log.router().click(
            at: Fixture.point, button: .left, count: 1, target: Fixture.target())

        #expect(button.performedActions == [AXActionNames.kAXPressAction])
        #expect(outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(log.steps.isEmpty)
    }

    @Test
    func `kill switch still routes the click to the window but opens no focus session`() async throws {
        let log = RouterLog()
        log.environment = ["PEEKABOO_BACKGROUND_FOCUS_RECORD": "0"]

        _ = try await log.router().click(at: Fixture.point, button: .left, count: 1, target: Fixture.target())

        #expect(log.steps == [.pointer(.mouseMoved), .pointer(.leftMouseDown), .pointer(.leftMouseUp)])
    }

    @Test
    func `left double click runs inside the focus session so text views take the selection`() async throws {
        let log = RouterLog()

        _ = try await log.router().click(at: Fixture.point, button: .left, count: 2, target: Fixture.target())

        #expect(log.steps.first == .record(.focus))
        #expect(log.steps.last == .record(.undo))
        #expect(log.steps.filter { $0 == .pointer(.leftMouseDown) }.count == 2)
    }

    @Test
    func `right click keeps the plain window route without a focus session`() async throws {
        let log = RouterLog()

        _ = try await log.router().click(at: Fixture.point, button: .right, count: 1, target: Fixture.target())

        #expect(log.steps == [.pointer(.mouseMoved), .pointer(.rightMouseDown), .pointer(.rightMouseUp)])
    }

    @Test
    func `window-routed click reports dispatched but unverified window-targeted delivery`() async throws {
        let log = RouterLog()

        let outcome = try await log.router().click(
            at: Fixture.point, button: .left, count: 1, target: Fixture.target())

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(!outcome.isConfirmed)
    }
}

private enum Fixture {
    static let bounds = CGRect(x: 200, y: 150, width: 500, height: 400)
    static let point = CGPoint(x: 400, y: 300)
    static let identity = WindowMutationIdentity(
        windowID: 100, ownerProcessIdentifier: 9001, ownerProcessStartIdentity: 800)

    static func target() throws -> UIAutomationTarget.ExactWindow {
        try UIAutomationTarget.ExactWindow(identity: self.identity, bounds: self.bounds)
    }
}

@MainActor
private final class RouterLog {
    enum Step: Equatable {
        case record(BackgroundWindowActivationDriver.RecordKind)
        case priming(CGEventType)
        case pointer(CGEventType)
    }

    var hitTestCandidates: [any AutomationElementRepresenting] = []
    var environment: [String: String] = [:]
    var steps: [Step] = []
    var pointerEvents: [CGEvent] = []

    func router() -> BackgroundPositionalClickRouter {
        BackgroundPositionalClickRouter(
            hitTest: { _, _ in self.hitTestCandidates },
            isAccessibilityTrusted: { true },
            validateWindowIdentity: { _, _ in true },
            pointerDriver: self.pointerDriver(),
            focusSession: BackgroundFocusSession(
                postRecord: { _, kind in self.steps.append(.record(kind)) },
                postPrimingEvent: { event, _ in self.steps.append(.priming(event.type)) },
                sleep: { _ in },
                readEnvironment: { self.environment[$0] }))
    }

    private func pointerDriver() -> WindowRoutedPointerDriver {
        WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, point in
                .init(identity: Fixture.identity, bounds: Fixture.bounds, screenPoint: point)
            },
            routeIsCurrent: { _ in true },
            processGenerationIsCurrent: { _ in true },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { event, _ in
                self.pointerEvents.append(event)
                self.steps.append(.pointer(event.type))
            },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in })
    }
}
