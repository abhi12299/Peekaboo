import CoreGraphics
import Foundation

/// Turns on an Electron app's web accessibility tree and waits until a window exposes it.
///
/// Electron builds the tree for its web contents only after an assistive client sets `AXManualAccessibility`
/// on the application, and Electron 45 applies that request after a 2 s debounce: a read straight after the
/// set still sees only the title-bar buttons (measured: the web area appeared 2.1-2.3 s after the set).
/// `AXEnhancedUserInterface` takes the same Electron code path, so it is never set: it adds nothing here and
/// is known to break window animations and window managers.
@MainActor
final class ElectronAccessibilityActivator {
    enum Outcome: Equatable {
        /// The window exposes web content.
        case ready
        /// The window still exposes no web content after the wait.
        case noWebContent
    }

    typealias WebContentProbe = @MainActor (pid_t, CGWindowID?) -> Bool
    typealias Enabler = @MainActor (pid_t) throws -> Void

    /// How long after the set a window may take to expose its web content: Electron's 2 s debounce plus
    /// the time to build the first tree.
    static let webContentTimeout: Duration = .milliseconds(3500)
    static let pollInterval: Duration = .milliseconds(150)

    private let hasWebContent: WebContentProbe
    private let enable: Enabler
    private let sleep: @MainActor (Duration) async -> Void
    private let now: @MainActor () -> ContinuousClock.Instant

    init(
        hasWebContent: @escaping WebContentProbe,
        enable: @escaping Enabler,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now })
    {
        self.hasWebContent = hasWebContent
        self.enable = enable
        self.sleep = sleep
        self.now = now
    }

    func prepare(
        processIdentifier: pid_t,
        processStartIdentity: UInt64?,
        windowID: CGWindowID?) async -> Outcome
    {
        if self.hasWebContent(processIdentifier, windowID) {
            return .ready
        }
        try? self.enable(processIdentifier)
        let deadline = self.now().advanced(by: Self.webContentTimeout)
        while self.now() < deadline {
            await self.sleep(Self.pollInterval)
            if self.hasWebContent(processIdentifier, windowID) {
                return .ready
            }
        }
        return .noWebContent
    }
}
