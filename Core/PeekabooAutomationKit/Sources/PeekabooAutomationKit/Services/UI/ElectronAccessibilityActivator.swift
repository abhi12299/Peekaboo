import CoreGraphics
import Foundation

/// What an Electron app's window holds, as accessibility shows it.
enum ElectronWindowContent: Equatable {
    /// The window exposes its web content (an `AXWebArea`).
    case webContent
    /// A Chromium-hosted window (its views carry `ChromeAXNodeId`) that has no web area yet: the tree is off,
    /// still being built, or the window has never rendered.
    case chromiumHostWithoutWebContent
    /// A native window with no Chromium content at all, such as a message box or an Open/Save panel.
    case native
    /// The window could not be found or read in time.
    case unknown
}

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
        /// The window exposes web content, or is a native window that has none to wait for.
        case ready
        /// The window still exposes no web content after the wait.
        case noWebContent
    }

    typealias WindowContentProbe = @MainActor (pid_t, CGWindowID?) -> ElectronWindowContent
    typealias Enabler = @MainActor (pid_t) throws -> Void

    /// How long after the set a window may take to expose its web content: Electron's 2 s debounce plus
    /// the time to build the first tree.
    nonisolated static let webContentTimeout: Duration = .milliseconds(3500)
    /// How long a window first seen after the app's tree was turned on may take to expose its web content,
    /// such as a window the app opens later.
    nonisolated static let newWindowGrace: Duration = .milliseconds(1500)
    static let pollInterval: Duration = .milliseconds(150)

    /// What one process generation has been through: when the attribute was set and which windows were seen
    /// exposing web content. Electron keeps the tree on for the life of the process.
    private struct ProcessState {
        let processStartIdentity: UInt64?
        var request = Request.notSent
        var readyWindowIDs: Set<CGWindowID?> = []
        /// When each window was first seen without web content.
        var pendingSince: [CGWindowID?: ContinuousClock.Instant] = [:]
    }

    private enum Request {
        case notSent
        case sent(at: ContinuousClock.Instant)
        /// The app does not know the attribute, so no tree is coming for it.
        case unsupported
    }

    private var states: [pid_t: ProcessState] = [:]
    private let windowContent: WindowContentProbe
    private let enable: Enabler
    private let sleep: @MainActor (Duration) async -> Void
    private let now: @MainActor () -> ContinuousClock.Instant

    init(
        windowContent: @escaping WindowContentProbe,
        enable: @escaping Enabler,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now })
    {
        self.windowContent = windowContent
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
        switch self.windowContent(processIdentifier, windowID) {
        case .webContent, .native:
            self.markReady(processIdentifier, processStartIdentity, windowID)
            return .ready
        case .unknown:
            // Without evidence about the window, turn the tree on for later reads but neither wait nor refuse.
            self.sendRequestIfNeeded(processIdentifier, processStartIdentity)
            return .ready
        case .chromiumHostWithoutWebContent:
            break
        }
        let firstSeen = self.state(processIdentifier, processStartIdentity).pendingSince[windowID] ?? self.now()
        self.states[processIdentifier]?.pendingSince[windowID] = firstSeen
        // Set once per process generation: every set restarts Electron's debounce. Recorded before waiting so
        // a concurrent read of the same app does not set it again.
        self.sendRequestIfNeeded(processIdentifier, processStartIdentity)
        guard case let .sent(enabledAt) = self.states[processIdentifier]?.request else { return .noWebContent }
        // The app's first window waits out Electron's debounce; a window first seen later gets a short grace.
        let deadline = max(
            enabledAt.advanced(by: Self.webContentTimeout),
            firstSeen.advanced(by: Self.newWindowGrace))
        while self.now() < deadline {
            await self.sleep(Self.pollInterval)
            let content = self.windowContent(processIdentifier, windowID)
            if content == .webContent || content == .native {
                self.markReady(processIdentifier, processStartIdentity, windowID)
                return .ready
            }
        }
        return .noWebContent
    }

    private func sendRequestIfNeeded(_ processIdentifier: pid_t, _ processStartIdentity: UInt64?) {
        if case .notSent = self.state(processIdentifier, processStartIdentity).request {
            self.states[processIdentifier]?.request = self.sendRequest(processIdentifier)
        }
    }

    private func sendRequest(_ processIdentifier: pid_t) -> Request {
        let sentAt = self.now()
        do {
            try self.enable(processIdentifier)
        } catch let ElementDetectionService.ElectronAccessibilityError.attributeRejected(error)
            where error != .cannotComplete
        {
            return .unsupported
        } catch {
            // A busy app that timed out the request may still apply it, so it is waited for.
        }
        return .sent(at: sentAt)
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
