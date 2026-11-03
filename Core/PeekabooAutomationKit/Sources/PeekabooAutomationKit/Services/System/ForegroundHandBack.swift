import AppKit
import Darwin
import Foundation

/// What a background operation did about its target app taking the front.
public struct ForegroundHandBackReport: Codable, Equatable, Sendable {
    /// Accepted re-activations of the app the user had in front.
    public let handBacks: Int
    /// The app that took the front.
    public let targetProcessIdentifier: pid_t
    /// The app the front was handed back to.
    public let restoredProcessIdentifier: pid_t

    public init(handBacks: Int, targetProcessIdentifier: pid_t, restoredProcessIdentifier: pid_t) {
        self.handBacks = handBacks
        self.targetProcessIdentifier = targetProcessIdentifier
        self.restoredProcessIdentifier = restoredProcessIdentifier
    }
}

/// Hands the front back to the app the user had in front when a background operation's target app takes it.
///
/// Some apps activate themselves although nothing asked them to: Chrome while it launches, and an AppKit app
/// that shows a modal sheet after one of its menus was opened through accessibility (BenchFixture's Submit…
/// alert after its Category pop-up). Peekaboo cannot stop that from outside the process, so it re-activates
/// the previous front app as soon as it sees the target in front, and reports each accepted re-activation.
@MainActor
struct ForegroundHandBack {
    enum Activation {
        case accepted
        case refused
        /// The app to hand back to is no longer running.
        case gone
    }

    let frontmostProcessIdentifier: @MainActor () -> pid_t?
    let activate: @MainActor (pid_t) -> Activation
    let sleep: @MainActor (Duration) async throws -> Void

    init(
        frontmostProcessIdentifier: @escaping @MainActor () -> pid_t?,
        activate: @escaping @MainActor (pid_t) -> Activation,
        sleep: @escaping @MainActor (Duration) async throws -> Void)
    {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.activate = activate
        self.sleep = sleep
    }

    /// Watches the front process for `window` and hands the front back whenever `target` holds it. With
    /// `checkFirst`, the first check happens before any wait, for an activation that already happened during
    /// a synchronous accessibility press. Returns nil when nothing was handed back.
    func watch(
        target: pid_t,
        previousFrontmost: pid_t?,
        window: Duration,
        pollInterval: Duration,
        checkFirst: Bool,
        onRefused: (pid_t) -> Void = { _ in }) async throws -> ForegroundHandBackReport?
    {
        guard let previousFrontmost, previousFrontmost != target else { return nil }
        var handBacks = 0
        var elapsed = Duration.zero
        var waits = !checkFirst
        watching: while true {
            if waits {
                guard elapsed < window else { break }
                try await self.sleep(pollInterval)
                elapsed += pollInterval
            }
            waits = true
            guard self.frontmostProcessIdentifier() == target else { continue }
            switch self.activate(previousFrontmost) {
            case .accepted:
                handBacks += 1
            case .refused:
                onRefused(previousFrontmost)
            case .gone:
                break watching
            }
        }
        guard handBacks > 0 else { return nil }
        return ForegroundHandBackReport(
            handBacks: handBacks,
            targetProcessIdentifier: target,
            restoredProcessIdentifier: previousFrontmost)
    }
}

extension ForegroundHandBack {
    /// Reads the WindowServer's front process and re-activates the previous app with a plain activation, which
    /// restores its key window without reordering its other windows.
    static var live: ForegroundHandBack {
        ForegroundHandBack(
            frontmostProcessIdentifier: LiveFrontProcess.processIdentifier,
            activate: { processIdentifier in
                guard let application = NSRunningApplication(processIdentifier: processIdentifier),
                      !application.isTerminated
                else {
                    return .gone
                }
                return application.activate() ? .accepted : .refused
            },
            sleep: { try await Task.sleep(for: $0) })
    }
}

/// The front process as the WindowServer has it now.
///
/// `NSWorkspace.frontmostApplication` follows the WindowServer through notifications on the run loop, so right
/// after a synchronous accessibility press it can still name the previous app (about 50 ms in testing). SkyLight
/// answers at once; NSWorkspace is the fallback when the private call is unavailable.
@MainActor
enum LiveFrontProcess {
    private typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessPID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32

    private static let functions: (GetFrontProcess, GetProcessPID)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let applicationServices = dlopen(
                  "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                  RTLD_LAZY),
              let front = dlsym(skyLight, "_SLPSGetFrontProcess"),
              let pid = dlsym(applicationServices, "GetProcessPID")
        else {
            return nil
        }
        return (unsafeBitCast(front, to: GetFrontProcess.self), unsafeBitCast(pid, to: GetProcessPID.self))
    }()

    static func processIdentifier() -> pid_t? {
        if let (getFrontProcess, getProcessPID) = self.functions {
            var serialNumber: [UInt32] = [0, 0]
            var processIdentifier: pid_t = 0
            if serialNumber.withUnsafeMutableBytes({ getFrontProcess($0.baseAddress!) }) == 0,
               serialNumber.withUnsafeBytes({ getProcessPID($0.baseAddress!, &processIdentifier) }) == 0,
               processIdentifier > 0
            {
                return processIdentifier
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
