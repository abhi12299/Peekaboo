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
}

/// An Electron app whose window exposes web content only some probes after manual accessibility was set.
@MainActor
final class FakeElectronApp {
    struct Probe: Equatable {
        let processIdentifier: pid_t
        let windowID: CGWindowID?
    }

    var hasWebContentBeforeEnable = false
    /// Probes after the enable call that still see no web content; nil means it never appears.
    var webContentAfterEnableProbes: Int?
    var enableError: (any Error)?
    private(set) var enableCalls: [pid_t] = []
    private(set) var probes: [Probe] = []
    private(set) var elapsed: Duration = .zero
    private var probesSinceEnable = 0
    private let start = ContinuousClock.now

    init(webContentAfterEnableProbes: Int? = 0) {
        self.webContentAfterEnableProbes = webContentAfterEnableProbes
    }

    func activator() -> ElectronAccessibilityActivator {
        ElectronAccessibilityActivator(
            hasWebContent: { [unowned self] processIdentifier, windowID in
                self.probe(processIdentifier: processIdentifier, windowID: windowID)
            },
            enable: { [unowned self] processIdentifier in
                self.enableCalls.append(processIdentifier)
                if let enableError = self.enableError { throw enableError }
            },
            sleep: { [unowned self] duration in self.elapsed += duration },
            now: { [unowned self] in self.start.advanced(by: self.elapsed) })
    }

    private func probe(processIdentifier: pid_t, windowID: CGWindowID?) -> Bool {
        self.probes.append(Probe(processIdentifier: processIdentifier, windowID: windowID))
        guard !self.enableCalls.isEmpty else { return self.hasWebContentBeforeEnable }
        self.probesSinceEnable += 1
        guard let threshold = self.webContentAfterEnableProbes else { return false }
        return self.probesSinceEnable > threshold
    }
}
