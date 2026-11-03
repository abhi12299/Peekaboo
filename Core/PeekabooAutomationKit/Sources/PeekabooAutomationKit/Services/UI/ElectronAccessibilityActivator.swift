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

    /// What one process generation has been through: when the attribute was set and which windows were seen
    /// exposing web content. Electron keeps the tree on for the life of the process.
    private struct ProcessState {
        let processStartIdentity: UInt64?
        var enabledAt: ContinuousClock.Instant?
        var readyWindowIDs: Set<CGWindowID?> = []
    }

    private var states: [pid_t: ProcessState] = [:]
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
        if self.state(processIdentifier, processStartIdentity).readyWindowIDs.contains(windowID) {
            return .ready
        }
        if self.hasWebContent(processIdentifier, windowID) {
            self.markReady(processIdentifier, processStartIdentity, windowID)
            return .ready
        }
        // Set once per process generation: every set restarts Electron's debounce. Recorded before waiting so
        // a concurrent read of the same app does not set it again.
        let enabledAt = self.state(processIdentifier, processStartIdentity).enabledAt ?? {
            try? self.enable(processIdentifier)
            let enabledAt = self.now()
            self.states[processIdentifier]?.enabledAt = enabledAt
            return enabledAt
        }()
        let deadline = enabledAt.advanced(by: Self.webContentTimeout)
        while self.now() < deadline {
            await self.sleep(Self.pollInterval)
            if self.hasWebContent(processIdentifier, windowID) {
                self.markReady(processIdentifier, processStartIdentity, windowID)
                return .ready
            }
        }
        return .noWebContent
    }

    /// The recorded state of this process generation; a new generation of the PID starts over.
    private func state(_ processIdentifier: pid_t, _ processStartIdentity: UInt64?) -> ProcessState {
        if let state = self.states[processIdentifier], state.processStartIdentity == processStartIdentity {
            return state
        }
        let state = ProcessState(processStartIdentity: processStartIdentity)
        self.states[processIdentifier] = state
        return state
    }

    private func markReady(_ processIdentifier: pid_t, _ processStartIdentity: UInt64?, _ windowID: CGWindowID?) {
        _ = self.state(processIdentifier, processStartIdentity)
        self.states[processIdentifier]?.readyWindowIDs.insert(windowID)
    }
}
