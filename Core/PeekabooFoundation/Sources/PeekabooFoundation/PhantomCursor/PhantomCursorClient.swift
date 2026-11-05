import CoreGraphics
import Darwin
import Foundation

/// Talks to this process's phantom cursor renderer, starting it on demand.
///
/// The renderer is a hidden child process (`peekaboo __phantom-cursor-host <pid>`) bound to this process:
/// it exits when this process exits or after a short idle period, and is started again transparently on the
/// next request. Every call is bounded by its timeout and never throws; a missing renderer only means no cursor.
public enum PhantomCursorClient {
    private static let state = SpawnState()

    /// Sends `request` and waits for the reply, at most `timeout` seconds in total.
    /// - Parameter spawnIfNeeded: start the renderer when none is listening (move/click); hide/ping never spawn.
    @discardableResult
    public static func send(
        _ request: PhantomCursorRequest,
        timeout: TimeInterval,
        spawnIfNeeded: Bool) async -> Bool
    {
        await Task.detached(priority: .userInitiated) {
            self.sendBlocking(request, timeout: timeout, spawnIfNeeded: spawnIfNeeded)
        }.value
    }

    static func sendBlocking(_ request: PhantomCursorRequest, timeout: TimeInterval, spawnIfNeeded: Bool) -> Bool {
        let owner = getpid()
        let path = PhantomCursorEndpoint.socketPath(owner: owner)
        let deadline = Date().addingTimeInterval(timeout)

        var fd = PhantomCursorSocket.connect(path: path)
        if fd == nil {
            guard spawnIfNeeded, self.spawnHost(owner: owner) else { return false }
            while fd == nil, Date() < deadline {
                usleep(15000)
                fd = PhantomCursorSocket.connect(path: path)
            }
        }
        guard let fd else { return false }
        defer { close(fd) }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, let payload = try? JSONEncoder().encode(request) else { return false }
        PhantomCursorSocket.setTimeouts(fd: fd, seconds: remaining)
        guard PhantomCursorSocket.writeLine(payload, fd: fd),
              let line = PhantomCursorSocket.readLine(fd: fd),
              let reply = try? JSONDecoder().decode(PhantomCursorReply.self, from: line)
        else { return false }
        return reply.ok
    }

    /// Starts the renderer host unless one was started moments ago (the host itself enforces a single
    /// instance per owner through a lock file, so a racing duplicate exits immediately).
    private static func spawnHost(owner: pid_t) -> Bool {
        guard self.state.claimSpawn() else { return true }
        guard let executable = self.hostExecutablePath() else { return false }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session so terminal signals aimed at the MCP server's group do not hit the renderer; no
        // inherited descriptors so the MCP stdio pipes are never held open by the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let arguments = [executable, PhantomCursorEndpoint.hostArgument, String(owner)]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0)=\($1)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { return false }
        // Reap the child when it exits so it never lingers as a zombie under a long-lived MCP server.
        let child = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(child, &status, 0)
        }
        return true
    }

    static func hostExecutablePath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[PhantomCursorEndpoint.hostPathVariable], !override.isEmpty {
            return override
        }
        guard let path = Bundle.main.executablePath,
              URL(fileURLWithPath: path).lastPathComponent == "peekaboo"
        else { return nil }
        return path
    }

    private final class SpawnState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSpawn = Date.distantPast

        /// Allows one spawn per 2 seconds; concurrent callers poll the socket instead of spawning again.
        func claimSpawn() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            let now = Date()
            guard now.timeIntervalSince(self.lastSpawn) > 2 else { return false }
            self.lastSpawn = now
            return true
        }
    }
}
