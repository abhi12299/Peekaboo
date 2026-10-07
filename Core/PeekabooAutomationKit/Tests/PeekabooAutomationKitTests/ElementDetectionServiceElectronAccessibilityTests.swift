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
        let service = ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: ElementDetectionCache(),
            detachedAXObservationRunner: { request in
                events.entries.append("observe:\(request.processIdentifier)")
                return Self.result(request)
            },
            applicationKindProvider: { _ in .electron },
            electronAccessibilityPreparer: { processIdentifier in
                events.entries.append("prepare:\(processIdentifier)")
            })

        _ = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        let pid = target.processIdentifier
        #expect(events.entries == ["prepare:\(pid)", "observe:\(pid)"])
    }

    @Test(arguments: [WindowRoutedApplicationKind.appKit, .chromium, .catalyst])
    func `non-Electron apps are inspected without the manual accessibility preparer`(
        kind: WindowRoutedApplicationKind) async throws
    {
        let target = try Self.targetApplication()
        let events = EventLog()
        let service = ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: ElementDetectionCache(),
            detachedAXObservationRunner: { request in
                events.entries.append("observe:\(request.processIdentifier)")
                return Self.result(request)
            },
            applicationKindProvider: { _ in kind },
            electronAccessibilityPreparer: { processIdentifier in
                events.entries.append("prepare:\(processIdentifier)")
            })

        _ = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        #expect(events.entries == ["observe:\(target.processIdentifier)"])
    }

    @Test
    func `a rejected manual accessibility attribute does not fail the inspection`() async throws {
        let target = try Self.targetApplication()
        let events = EventLog()
        let service = ElementDetectionService(
            snapshotManager: nil,
            applicationService: nil,
            axTreeCache: ElementDetectionCache(),
            detachedAXObservationRunner: { request in
                events.entries.append("observe:\(request.processIdentifier)")
                return Self.result(request)
            },
            applicationKindProvider: { _ in .electron },
            electronAccessibilityPreparer: { _ in
                events.entries.append("prepare")
                throw ElementDetectionService.ElectronAccessibilityError.attributeRejected(.attributeUnsupported)
            })

        let result = try await service.inspectElements(
            snapshotId: nil,
            windowContext: Self.context(for: target))

        #expect(events.entries == ["prepare", "observe:\(target.processIdentifier)"])
        #expect(result.metadata.windowContext?.applicationProcessId == target.processIdentifier)
    }

    private static func targetApplication() throws -> NSRunningApplication {
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    }

    private static func context(for application: NSRunningApplication) -> WindowContext {
        WindowContext(
            applicationProcessId: application.processIdentifier,
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
