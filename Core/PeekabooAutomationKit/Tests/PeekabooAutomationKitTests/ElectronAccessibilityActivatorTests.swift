import CoreGraphics
import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ElectronAccessibilityActivatorTests {
    @Test
    func `first read sets manual accessibility once and waits until the window exposes web content`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: 3)
        let activator = fake.activator()

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(outcome == .ready)
        #expect(fake.enableCalls == [42])
        #expect(fake.probes.allSatisfy { $0 == FakeElectronApp.Probe(processIdentifier: 42, windowID: 9) })
        #expect(fake.elapsed > .zero)
        #expect(fake.elapsed < ElectronAccessibilityActivator.webContentTimeout)
    }

    @Test
    func `a window that already exposes web content is read without setting anything or waiting`() async {
        let fake = FakeElectronApp()
        fake.hasWebContentBeforeEnable = true
        let activator = fake.activator()

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(outcome == .ready)
        #expect(fake.enableCalls.isEmpty)
        #expect(fake.elapsed == .zero)
    }

    @Test
    func `later reads of the same process neither set the attribute again nor probe a ready window`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: 1)
        let activator = fake.activator()

        _ = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)
        let probesAfterFirstRead = fake.probes.count
        let elapsedAfterFirstRead = fake.elapsed
        let second = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(second == .ready)
        #expect(fake.enableCalls == [42])
        #expect(fake.probes.count == probesAfterFirstRead)
        #expect(fake.elapsed == elapsedAfterFirstRead)
    }

    @Test
    func `a window that never exposes web content costs one bounded wait per process`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        let activator = fake.activator()

        let first = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)
        let elapsedAfterFirstRead = fake.elapsed
        let second = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(first == .noWebContent)
        #expect(second == .noWebContent)
        #expect(elapsedAfterFirstRead >= ElectronAccessibilityActivator.webContentTimeout)
        #expect(elapsedAfterFirstRead < ElectronAccessibilityActivator.webContentTimeout + .seconds(1))
        #expect(fake.elapsed == elapsedAfterFirstRead)
        #expect(fake.enableCalls == [42])
    }

    @Test
    func `a window opened after the first wait ran out gets its own short wait`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        let activator = fake.activator()
        _ = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)
        fake.webContentAfterEnableProbes = fake.probesSinceEnable + 2
        let elapsedBefore = fake.elapsed

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 10)

        #expect(outcome == .ready)
        #expect(fake.enableCalls == [42])
        #expect(fake.elapsed > elapsedBefore)
        #expect(fake.elapsed - elapsedBefore <= ElectronAccessibilityActivator.newWindowGrace)
    }

    @Test
    func `a native window of an Electron app is ready without setting anything or waiting`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        fake.nativeWindowIDs = [9]
        let activator = fake.activator()

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(outcome == .ready)
        #expect(fake.enableCalls.isEmpty)
        #expect(fake.elapsed == .zero)
    }

    @Test
    func `a window that cannot be read turns the tree on but is neither waited for nor cached`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        fake.unreadableWindowIDs = [9]
        let activator = fake.activator()

        let first = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)
        let second = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(first == .ready)
        #expect(second == .ready)
        #expect(fake.enableCalls == [42])
        #expect(fake.elapsed == .zero)
        #expect(fake.probes.count == 2)
    }

    @Test
    func `a relaunched app with a reused PID is set again`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        let activator = fake.activator()

        _ = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)
        _ = await activator.prepare(processIdentifier: 42, processStartIdentity: 8, windowID: 9)

        #expect(fake.enableCalls == [42, 42])
    }

    @Test
    func `an attribute the app does not support is not waited for`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: nil)
        fake.enableError = ElementDetectionService.ElectronAccessibilityError.attributeRejected(.attributeUnsupported)
        let activator = fake.activator()

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(outcome == .noWebContent)
        #expect(fake.elapsed == .zero)
    }

    @Test
    func `a set that timed out on a busy app is still waited for`() async {
        let fake = FakeElectronApp(webContentAfterEnableProbes: 2)
        fake.enableError = ElementDetectionService.ElectronAccessibilityError.attributeRejected(.cannotComplete)
        let activator = fake.activator()

        let outcome = await activator.prepare(processIdentifier: 42, processStartIdentity: 7, windowID: 9)

        #expect(outcome == .ready)
    }
}

/// An Electron app whose window exposes web content only some probes after manual accessibility was set.
@MainActor
final class FakeElectronApp {
    struct Probe: Equatable {
        let processIdentifier: pid_t
        let windowID: CGWindowID?
    }

    var hasWebContentBeforeEnable = false
    /// Windows that hold no Chromium content at all (native message boxes, Open/Save panels).
    var nativeWindowIDs: Set<CGWindowID?> = []
    /// Windows the probe cannot find or read in time.
    var unreadableWindowIDs: Set<CGWindowID?> = []
    /// Probes after the enable call that still see no web content; nil means it never appears.
    var webContentAfterEnableProbes: Int?
    var enableError: (any Error)?
    private(set) var enableCalls: [pid_t] = []
    private(set) var probes: [Probe] = []
    private(set) var elapsed: Duration = .zero
    private(set) var probesSinceEnable = 0
    private let start = ContinuousClock.now

    init(webContentAfterEnableProbes: Int? = 0) {
        self.webContentAfterEnableProbes = webContentAfterEnableProbes
    }

    func activator() -> ElectronAccessibilityActivator {
        ElectronAccessibilityActivator(
            windowContent: { [unowned self] processIdentifier, windowID in
                self.probe(processIdentifier: processIdentifier, windowID: windowID)
            },
            enable: { [unowned self] processIdentifier in
                self.enableCalls.append(processIdentifier)
                if let enableError = self.enableError { throw enableError }
            },
            sleep: { [unowned self] duration in self.elapsed += duration },
            now: { [unowned self] in self.start.advanced(by: self.elapsed) })
    }

    private func probe(processIdentifier: pid_t, windowID: CGWindowID?) -> ElectronWindowContent {
        self.probes.append(Probe(processIdentifier: processIdentifier, windowID: windowID))
        if self.nativeWindowIDs.contains(windowID) { return .native }
        if self.unreadableWindowIDs.contains(windowID) { return .unknown }
        guard !self.enableCalls.isEmpty else {
            return self.hasWebContentBeforeEnable ? .webContent : .chromiumHostWithoutWebContent
        }
        self.probesSinceEnable += 1
        guard let threshold = self.webContentAfterEnableProbes, self.probesSinceEnable > threshold else {
            return .chromiumHostWithoutWebContent
        }
        return .webContent
    }
}
