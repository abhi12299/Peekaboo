import CoreGraphics
import os
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct SpaceWindowMutationDispatcherTests {
    @Test
    func `pre-cancelled move dispatches no CGS unit`() async {
        let mutations = OSAllocatedUnfairLock(initialState: [String]())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { [11] },
                    moveWindow: { _ in mutations.withLock { $0.append("move") } },
                    awaitMemberships: { _ in [11] }))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(mutations.withLock { $0.isEmpty })
    }

    @Test
    func `pre-cancelled Space switch dispatches no CGS unit`() async {
        let didSwitch = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { [22] },
                    activeSpaceID: { 11 },
                    setCurrentSpace: { _ in didSwitch.withLock { $0 = true } },
                    settle: {}))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!didSwitch.withLock { $0 })
    }

    @Test
    func `generation flip before the first CGS dispatch refuses without mutation`() throws {
        let identity = Self.identity()
        var events: [String] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: identity,
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { space in
                        events.append("destination:\(space)")
                        return true
                    },
                    validateIdentity: { candidate in
                        events.append("validate:\(candidate.ownerProcessStartIdentity)")
                        return false
                    },
                    spaceIDsForWindow: {
                        events.append("memberships")
                        return [11]
                    },
                    moveWindow: { _ in events.append("move") },
                    awaitMemberships: { _ in events.append("await"); return [11] }))
            Issue.record("Expected the changed process generation to refuse before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == ["destination:22", "memberships", "validate:1234"])
    }

    @Test
    func `move dispatches one atomic move and confirms the settled exact destination`() throws {
        let identity = Self.identity()
        var memberships: [CGSSpaceID] = [11]
        var events: [String] = []

        let result = try SpaceWindowMutationDispatcher.moveWindow(
            windowID: 4040,
            expectedIdentity: identity,
            targetSpaceID: 22,
            backend: .init(
                destinationExists: { space in
                    events.append("destination:\(space)")
                    return space == 22
                },
                validateIdentity: { candidate in
                    events.append("validate:\(candidate.windowID)")
                    return true
                },
                spaceIDsForWindow: {
                    events.append("memberships:\(memberships)")
                    return memberships
                },
                moveWindow: { space in events.append("move:\(space)") },
                awaitMemberships: { isSettled in
                    // macOS applies the move asynchronously: the first poll still shows the old Space.
                    for snapshot: [CGSSpaceID] in [[11], [22]] {
                        memberships = snapshot
                        events.append("poll:\(snapshot)")
                        if isSettled(snapshot) { break }
                    }
                    return memberships
                }))

        #expect(events == [
            "destination:22",
            "memberships:[11]",
            "validate:4040",
            "destination:22",
            "validate:4040",
            "move:22",
            "poll:[11]",
            "poll:[22]",
            "validate:4040",
        ])
        #expect(result.outcome == .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one))
        #expect(result.targetIdentity?.exactWindow?.identity == identity)
    }

    @Test
    func `move that macOS ignores fails as a suspected no-op that says the window stayed put`() throws {
        var moves: [CGSSpaceID] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { [11] },
                    moveWindow: { moves.append($0) },
                    awaitMemberships: { _ in [11] }))
            Issue.record("Expected an ignored move to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.message.contains("macOS did not move the window"))
            #expect(failure.message.contains("still on Space ID 11"))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(moves == [22])
    }

    @Test
    func `invalid destination refuses before membership reads or CGS dispatch`() throws {
        var events: [String] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in
                        events.append("destination")
                        return false
                    },
                    validateIdentity: { _ in events.append("validate"); return true },
                    spaceIDsForWindow: { events.append("memberships"); return [11] },
                    moveWindow: { _ in events.append("move") },
                    awaitMemberships: { _ in events.append("await"); return [11] }))
            Issue.record("Expected a stale destination Space to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == ["destination"])
    }

    @Test
    func `already exact destination membership is a verified no-op`() throws {
        var mutations: [String] = []
        let result = try SpaceWindowMutationDispatcher.moveWindow(
            windowID: 4040,
            expectedIdentity: Self.identity(),
            targetSpaceID: 22,
            backend: .init(
                destinationExists: { $0 == 22 },
                validateIdentity: { _ in true },
                spaceIDsForWindow: { [22] },
                moveWindow: { _ in mutations.append("move") },
                awaitMemberships: { _ in mutations.append("await"); return [22] }))

        #expect(result.outcome == .confirmedNoChange())
        #expect(mutations.isEmpty)
    }

    @Test
    func `switch generation flip at the CGS boundary refuses without dispatch`() async throws {
        var validations = [true, true, false]
        var events: [String] = []

        do {
            _ = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { _ in events.append("destination"); return true },
                    validateIdentity: { candidate in
                        events.append("validate:\(candidate.ownerProcessStartIdentity)")
                        return validations.removeFirst()
                    },
                    spaceIDsForWindow: { events.append("memberships"); return [22] },
                    activeSpaceID: { events.append("active"); return 11 },
                    setCurrentSpace: { _ in events.append("set") },
                    settle: { events.append("settle") }))
            Issue.record("Expected final generation validation to refuse the switch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == [
            "memberships",
            "active",
            "destination",
            "validate:1234",
            "memberships",
            "validate:1234",
            "active",
            "destination",
            "memberships",
            "validate:1234",
        ])
    }

    @Test
    func `switch membership drift at final CGS boundary refuses without dispatch`() async throws {
        var membershipReads = 0
        var didSwitch = false

        do {
            _ = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { $0 == 22 },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: {
                        membershipReads += 1
                        return membershipReads < 3 ? [22] : [33]
                    },
                    activeSpaceID: { 11 },
                    setCurrentSpace: { _ in didSwitch = true },
                    settle: {}))
            Issue.record("Expected final Space membership drift to refuse the switch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(membershipReads == 3)
        #expect(!didSwitch)
    }

    @Test
    func `switch carries exact identity through the final CGS dispatch boundary`() async throws {
        let identity = Self.identity()
        var validated: [WindowMutationIdentity] = []
        var events: [String] = []

        let result = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
            windowID: 4040,
            expectedIdentity: identity,
            backend: .init(
                destinationExists: { $0 == 22 },
                validateIdentity: { candidate in validated.append(candidate); return true },
                spaceIDsForWindow: { [22] },
                activeSpaceID: { 11 },
                setCurrentSpace: { events.append("set:\($0)") },
                settle: { events.append("settle") }))

        #expect(validated == [identity, identity, identity])
        #expect(events == ["set:22", "settle"])
        #expect(result.outcome == .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one))
        #expect(result.targetIdentity?.exactWindow?.identity == identity)
    }

    @Test
    func `missing exact bounds refuses before backend reads or CGS dispatch`() throws {
        let incomplete = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234)
        var events: [String] = []

        #expect(throws: DesktopActionFailure.self) {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: incomplete,
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in events.append("destination"); return true },
                    validateIdentity: { _ in events.append("validate"); return true },
                    spaceIDsForWindow: { events.append("memberships"); return [] },
                    moveWindow: { _ in events.append("move") },
                    awaitMemberships: { _ in events.append("await"); return [11] }))
        }
        #expect(events.isEmpty)
    }

    private static let targetReceipt = DesktopActionTargetReceipt(
        processIdentifier: 999,
        processStartIdentity: 1234,
        windowID: 4040)

    private static func identity() -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: CGRect(x: 100, y: 100, width: 600, height: 400))
    }
}
