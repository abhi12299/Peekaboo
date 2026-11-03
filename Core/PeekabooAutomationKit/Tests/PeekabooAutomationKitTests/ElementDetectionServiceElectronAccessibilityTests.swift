import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ElementDetectionServiceElectronAccessibilityTests {
    @Test
    func `Electron app gets manual accessibility once before the observation runner`() async throws {
        let target = try Self.targetApplication()
        let events = EventLog()
        let fake = FakeElectronApp(webContentAfterEnableProbes: 0)
        let service = Self.service(kind: .electron, fake: fake, events: events)

        _ = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        let pid = target.processIdentifier
        #expect(fake.enableCalls == [pid])
        #expect(events.entries == ["observe:\(pid)"])
    }

    @Test(arguments: [WindowRoutedApplicationKind.appKit, .chromium, .catalyst])
    func `non-Electron apps are inspected without the manual accessibility preparer`(
        kind: WindowRoutedApplicationKind) async throws
    {
        let target = try Self.targetApplication()
        let events = EventLog()
        let fake = FakeElectronApp()
        let service = Self.service(kind: kind, fake: fake, events: events)

        _ = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        #expect(fake.enableCalls.isEmpty)
        #expect(fake.probes.isEmpty)
        #expect(events.entries == ["observe:\(target.processIdentifier)"])
    }

    @Test
    func `a rejected manual accessibility attribute does not fail the inspection`() async throws {
        let target = try Self.targetApplication()
        let events = EventLog()
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        fake.enableError = ElementDetectionService.ElectronAccessibilityError.attributeRejected(.attributeUnsupported)
        let service = Self.service(kind: .electron, fake: fake, events: events)

        let result = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        #expect(fake.enableCalls == [target.processIdentifier])
        #expect(events.entries == ["observe:\(target.processIdentifier)"])
        #expect(result.metadata.windowContext?.applicationProcessId == target.processIdentifier)
    }

    @Test
    func `an off-Space Electron window that never built its web content fails with the reason and the ways out`()
        async throws
    {
        let target = try Self.targetApplication()
        let events = EventLog()
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        let service = Self.service(
            kind: .electron,
            fake: fake,
            events: events,
            placement: .otherSpace(spaceID: 5, spaceNumber: 3))

        let windowID = try Self.windowID(of: target)

        let error = await #expect(throws: PeekabooError.self) {
            _ = try await service.inspectElements(
                snapshotId: nil,
                windowContext: Self.context(for: target, windowID: windowID))
        }

        let message = error?.localizedDescription ?? ""
        #expect(message.contains("window \(windowID)"))
        #expect(message.contains("Space 3 (ID 5)"))
        #expect(message.contains("AXManualAccessibility"))
        #expect(message.contains("`space move-window`"))
        #expect(message.contains("`app launch`"))
        #expect(events.entries.isEmpty)
    }

    @Test
    func `an Electron window on a visible Space without web content is still inspected`() async throws {
        let target = try Self.targetApplication()
        let events = EventLog()
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        let service = Self.service(kind: .electron, fake: fake, events: events, placement: .visibleSpace)

        _ = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target, windowID: Self.windowID(of: target)))

        #expect(events.entries == ["observe:\(target.processIdentifier)"])
    }

    private static func service(
        kind: WindowRoutedApplicationKind,
        fake: FakeElectronApp,
        events: EventLog,
        placement: WindowSpacePlacement = .visibleSpace) -> ElementDetectionService
    {
        ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: ElementDetectionCache(),
            detachedAXObservationRunner: { request in
                events.entries.append("observe:\(request.processIdentifier)")
                return Self.result(request)
            },
            applicationKindProvider: { _ in kind },
            electronAccessibilityActivator: fake.activator(),
            windowPlacementProvider: { _ in placement })
    }

    private static func targetApplication() throws -> NSRunningApplication {
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    }

    /// Any window the target owns, so the service's ownership check accepts it.
    private static func windowID(of application: NSRunningApplication) throws -> CGWindowID {
        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == application.processIdentifier }
        return try #require(owned?[kCGWindowNumber as String] as? CGWindowID)
    }

    private static func context(
        for application: NSRunningApplication,
        windowID: CGWindowID? = nil) -> WindowContext
    {
        WindowContext(
            applicationProcessId: application.processIdentifier,
            windowID: windowID.map(Int.init),
            includeMenuBarElements: false,
            traversalBudget: nil,
            requiresFreshAccessibilityTree: true)
    }

    private nonisolated static func result(_ request: DetachedAXObservationRequest) -> DetachedAXObservationResult {
        DetachedAXObservationResult(
            elements: [],
            windowID: request.windowID,
            windowTitle: "Injected fixture",
            windowBounds: request.expectedWindowBounds,
            isDialog: false,
            truncationInfo: nil)
    }
}

@MainActor
private final class EventLog {
    var entries: [String] = []
}
