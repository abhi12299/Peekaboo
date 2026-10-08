import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ExactWindowDragFocusSessionTests {
    @Test
    func `left drag runs between the focus record with priming click and the undo record`() async throws {
        let log = DragLog()

        let result = try await log.lifecycle().drag(request: DragFixture.request(), boundTo: nil)

        #expect(log.steps == [
            .record(.focus), .priming(.leftMouseDown), .priming(.leftMouseUp),
            .pointer(.mouseMoved), .pointer(.leftMouseDown),
            .pointer(.leftMouseDragged), .pointer(.leftMouseDragged), .pointer(.leftMouseDragged),
            .pointer(.leftMouseUp),
            .record(.undo),
        ])
        #expect(result.outcome?.state == .dispatchedUnverified)
    }

    @Test
    func `drag failing midway sends the undo record after the cleanup mouse up`() async throws {
        let log = DragLog()
        let samples = SampleCounter()
        let lifecycle = log.lifecycle(dragSleeper: { _ in
            if samples.next() == 2 { throw PeekabooError.operationError(message: "sample failed") }
        })

        do {
            _ = try await lifecycle.drag(request: DragFixture.request(), boundTo: nil)
            Issue.record("Expected the drag to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 4)
        }

        #expect(log.steps == [
            .record(.focus), .priming(.leftMouseDown), .priming(.leftMouseUp),
            .pointer(.mouseMoved), .pointer(.leftMouseDown), .pointer(.leftMouseDragged),
            .pointer(.leftMouseUp),
            .record(.undo),
        ])
    }

    @Test
    func `right drag keeps the plain route without a focus session`() async throws {
        let log = DragLog()

        let result = try await log.lifecycle().drag(request: DragFixture.request(button: .right), boundTo: nil)

        #expect(log.steps == [
            .pointer(.mouseMoved), .pointer(.rightMouseDown),
            .pointer(.rightMouseDragged), .pointer(.rightMouseDragged), .pointer(.rightMouseDragged),
            .pointer(.rightMouseUp),
        ])
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 6)
    }

    @Test
    func `cancelled drag sends the undo record after the cleanup mouse up`() async throws {
        let log = DragLog()
        let gate = DragGate()
        let lifecycle = log.lifecycle(dragSleeper: { _ in await gate.wait() })
        let task = Task { try await lifecycle.drag(request: DragFixture.request(), boundTo: nil) }
        while !gate.hasWaiter {
            await Task.yield()
        }

        task.cancel()
        gate.open()
        await #expect(throws: DesktopActionFailure.self) { _ = try await task.value }

        #expect(log.steps == [
            .record(.focus), .priming(.leftMouseDown), .priming(.leftMouseUp),
            .pointer(.mouseMoved), .pointer(.leftMouseDown), .pointer(.leftMouseUp),
            .record(.undo),
        ])
    }

    @Test
    func `kill switch dispatches the drag with no session records`() async throws {
        let log = DragLog()
        log.environment[BackgroundFocusSessionSwitch.environmentKey] = "0"

        let result = try await log.lifecycle().drag(request: DragFixture.request(), boundTo: nil)

        #expect(log.steps == [
            .pointer(.mouseMoved), .pointer(.leftMouseDown),
            .pointer(.leftMouseDragged), .pointer(.leftMouseDragged), .pointer(.leftMouseDragged),
            .pointer(.leftMouseUp),
        ])
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 6)
    }

    @Test
    func `session records and priming events are not counted as drag units`() async throws {
        let log = DragLog()
        let request = try DragFixture.request()

        let result = try await log.lifecycle().drag(request: request, boundTo: nil)

        #expect(log.steps.count == 10)
        #expect(request.dispatchedUnitCount == 6)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 6)
    }

    @Test
    func `stale receipt refuses before any focus record or pointer event`() async throws {
        let log = DragLog()

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await log.lifecycle().drag(request: DragFixture.request(), boundTo: nil) {
                throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable, message: "Stale capture")
            }
        }

        #expect(log.steps.isEmpty)
    }

    @Test
    func `failed focus record refuses the drag before any pointer event`() async throws {
        let log = DragLog()
        log.focusRecordFails = true

        do {
            _ = try await log.lifecycle().drag(request: DragFixture.request(), boundTo: nil)
            Issue.record("Expected the drag to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.projection.retrySafe == true)
        }

        #expect(log.steps.isEmpty)
    }
}

private enum DragFixture {
    static let bounds = CGRect(x: 200, y: 150, width: 500, height: 400)
    static let from = CGPoint(x: 300, y: 250)
    static let identity = WindowMutationIdentity(
        windowID: 100,
        ownerProcessIdentifier: 9001,
        ownerProcessStartIdentity: 800,
        capturedBounds: bounds)

    static func request(button: ExactWindowHeldPointerButton = .left) throws -> ExactWindowDragRequest {
        try ExactWindowDragRequest(
            snapshotID: "ps1_0123456789abcdef0123456789abcdef",
            target: UIAutomationTarget.ExactWindow(identity: self.identity, bounds: self.bounds),
            from: self.from,
            to: CGPoint(x: 360, y: 280),
            durationMilliseconds: 90,
            steps: 3,
            button: button)
    }
}

@MainActor
private final class DragLog {
    enum Step: Equatable {
        case record(BackgroundWindowActivationDriver.RecordKind)
        case priming(CGEventType)
        case pointer(CGEventType)
    }

    var environment: [String: String] = [:]
    var steps: [Step] = []
    var focusRecordFails = false

    func lifecycle(
        dragSleeper: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in })
        -> ExactWindowHeldPointerLifecycle
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-focus-session-tests-\(UUID().uuidString)", isDirectory: true)
        return ExactWindowHeldPointerLifecycle(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            pointerDriver: self.pointerDriver(),
            processStartIdentityProvider: { _ in DragFixture.identity.ownerProcessStartIdentity },
            watchdogSleeper: { try await Task.sleep(for: .milliseconds(2)) },
            dragSleeper: dragSleeper,
            backgroundFocusSession: BackgroundFocusSession(
                postRecord: { _, kind in
                    if self.focusRecordFails, kind == .focus {
                        throw PeekabooError.operationError(message: "focus record failed")
                    }
                    self.steps.append(.record(kind))
                },
                postPrimingEvent: { event, _ in self.steps.append(.priming(event.type)) },
                sleep: { _ in },
                readEnvironment: { self.environment[$0] }))
    }

    private func pointerDriver() -> WindowRoutedPointerDriver {
        WindowRoutedPointerDriver(
            hasPostEventAccess: { true },
            resolveRoute: { _, _, point in
                .init(identity: DragFixture.identity, bounds: DragFixture.bounds, screenPoint: point)
            },
            routeIsCurrent: { _ in true },
            processGenerationIsCurrent: { _ in true },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in true },
            postPublic: { event, _ in self.steps.append(.pointer(event.type)) },
            resolveTransport: { _ in .publicCGEvent },
            applicationIsVisible: { _ in true },
            windowIsVisible: { _ in true },
            sleep: { _ in })
    }
}

@MainActor
private final class SampleCounter {
    private var count = 0

    func next() -> Int {
        self.count += 1
        return self.count
    }
}

@MainActor
private final class DragGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasWaiter: Bool {
        !self.waiters.isEmpty
    }

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
