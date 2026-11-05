import AppKit
import Darwin
import PeekabooFoundation

/// Entry point for `peekaboo __phantom-cursor-host <owner-pid>`: a hidden, Dock-less renderer bound to one
/// automation process (normally one MCP server, i.e. one agent).
///
/// Lifecycle: a lock file allows one host per owner; the host exits when the owner exits (after letting the
/// cursor rest) or after `idleExit` without requests. While the cursor is at rest it runs no timers.
public enum PhantomCursorHost {
    static let idleExit: TimeInterval = 60
    static let ownerGoneGrace: TimeInterval = PhantomCursorRenderer.Metrics.restAfter + 0.5

    @MainActor
    public static func run(arguments: [String]) -> Never {
        guard let ownerArgument = arguments.first, let owner = pid_t(ownerArgument), owner > 1,
              kill(owner, 0) == 0
        else { exit(EX_USAGE) }

        let lockFD = open(PhantomCursorEndpoint.hostLockPath(owner: owner), O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let renderer = PhantomCursorRenderer()
        let socketPath = PhantomCursorEndpoint.socketPath(owner: owner)
        let lifecycle = Lifecycle(socketPath: socketPath, lockPath: PhantomCursorEndpoint.hostLockPath(owner: owner))
        let server = SocketServer(path: socketPath, renderer: renderer, lifecycle: lifecycle)
        guard server.start() else { exit(EX_UNAVAILABLE) }
        lifecycle.watchOwner(owner)
        lifecycle.noteActivity()

        app.run()
        lifecycle.terminate()
    }

    @MainActor
    final class Lifecycle {
        private let socketPath: String
        private let lockPath: String
        private var idleWork: DispatchWorkItem?
        private var ownerSource: (any DispatchSourceProcess)?
        private var ownerGone = false

        init(socketPath: String, lockPath: String) {
            self.socketPath = socketPath
            self.lockPath = lockPath
        }

        /// Called for every request; postpones the idle exit.
        func noteActivity() {
            self.idleWork?.cancel()
            let delay = self.ownerGone ? PhantomCursorHost.ownerGoneGrace : PhantomCursorHost.idleExit
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.terminate() }
            }
            self.idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        func watchOwner(_ owner: pid_t) {
            let source = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    // A one-shot CLI owner exits right after its click: let the effect finish and rest first.
                    self?.ownerGone = true
                    self?.noteActivity()
                }
            }
            source.resume()
            self.ownerSource = source
        }

        func terminate() -> Never {
            unlink(self.socketPath)
            unlink(self.lockPath)
            exit(0)
        }
    }

    /// Accepts one request per connection on a background queue and hands it to the renderer on main.
    final class SocketServer: @unchecked Sendable {
        private let path: String
        private let renderer: PhantomCursorRenderer
        private let lifecycle: Lifecycle
        private let queue = DispatchQueue(label: "boo.peekaboo.phantom-cursor.io", attributes: .concurrent)
        private var source: (any DispatchSourceRead)?
        private var listenFD: Int32 = -1

        init(path: String, renderer: PhantomCursorRenderer, lifecycle: Lifecycle) {
            self.path = path
            self.renderer = renderer
            self.lifecycle = lifecycle
        }

        func start() -> Bool {
            guard var address = PhantomCursorSocket.address(for: self.path),
                  let fd = PhantomCursorSocket.makeSocket()
            else { return false }
            unlink(self.path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(self.path, 0o600) == 0, listen(fd, 16) == 0 else {
                close(fd)
                return false
            }
            self.listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.resume()
            self.source = source
            return true
        }

        private func acceptPending() {
            let client = accept(self.listenFD, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            PhantomCursorSocket.setTimeouts(fd: client, seconds: 2)
            guard let line = PhantomCursorSocket.readLine(fd: client),
                  let request = try? JSONDecoder().decode(PhantomCursorRequest.self, from: line)
            else {
                close(client)
                return
            }
            let queue = self.queue
            let reply: @Sendable (PhantomCursorReply) -> Void = { response in
                queue.async {
                    if let data = try? JSONEncoder().encode(response) {
                        _ = PhantomCursorSocket.writeLine(data, fd: client)
                    }
                    close(client)
                }
            }
            let renderer = self.renderer
            let lifecycle = self.lifecycle
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lifecycle.noteActivity()
                    renderer.handle(request, reply: reply)
                }
            }
        }
    }
}
