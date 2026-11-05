import CoreGraphics
import Darwin
import Foundation

/// Wire format and endpoints for the phantom cursor renderer.
///
/// Each automation process (typically one MCP server per agent) owns at most one renderer: a hidden
/// child process of the same `peekaboo` binary that draws an agent cursor without moving the real
/// pointer. Requests are one JSON line per connection over a per-owner Unix socket; the renderer
/// answers with one JSON line. All coordinates are global display coordinates (top-left origin).
public struct PhantomCursorRequest: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Travel to `point`; the reply is sent once the cursor has arrived.
        case move
        /// Play the click effect at `point` (travelling there first if needed). Replies immediately.
        case click
        /// Hide the cursor, for example while the real pointer is driven in the foreground.
        case hide
        case ping
    }

    public enum Click: String, Codable, Sendable {
        case single
        case double
        case right
    }

    public var kind: Kind
    public var x: Double?
    public var y: Double?
    public var target: PhantomCursorRect?
    public var click: Click?
    public var label: String?

    public init(
        kind: Kind,
        point: CGPoint? = nil,
        target: CGRect? = nil,
        click: Click? = nil,
        label: String? = nil)
    {
        self.kind = kind
        self.x = point.map { Double($0.x) }
        self.y = point.map { Double($0.y) }
        self.target = target.map(PhantomCursorRect.init)
        self.click = click
        self.label = label
    }

    public var point: CGPoint? {
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}

public struct PhantomCursorRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    public var cgRect: CGRect {
        CGRect(x: self.x, y: self.y, width: self.width, height: self.height)
    }
}

public struct PhantomCursorReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var detail: String?

    public init(ok: Bool, detail: String? = nil) {
        self.ok = ok
        self.detail = detail
    }
}

public enum PhantomCursorEndpoint {
    /// Bumped when the wire format changes so an old renderer is never reused by a newer client.
    public static let protocolVersion = 1
    /// argv[1] that turns the `peekaboo` binary into a renderer host; argv[2] is the owner PID.
    public static let hostArgument = "__phantom-cursor-host"
    /// Title shared by every renderer window, so captures can exclude them.
    public static let windowTitle = "Peekaboo Phantom Cursor"

    public static let enableVariable = "PEEKABOO_PHANTOM_CURSOR"
    public static let labelVariable = "PEEKABOO_PHANTOM_CURSOR_LABEL"
    public static let hostPathVariable = "PEEKABOO_PHANTOM_CURSOR_HOST"

    public static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[self.enableVariable]?.lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }

    public static func label(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let label = environment[self.labelVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty
        else { return nil }
        return String(label.prefix(48))
    }

    /// Per-user temporary directory; short enough for `sun_path`.
    static var directory: String {
        let path = NSTemporaryDirectory()
        return path.hasSuffix("/") ? path : path + "/"
    }

    public static func socketPath(owner: pid_t) -> String {
        "\(self.directory)peekaboo-cursor-v\(self.protocolVersion)-\(owner).sock"
    }

    public static func hostLockPath(owner: pid_t) -> String {
        "\(self.directory)peekaboo-cursor-v\(self.protocolVersion)-\(owner).lock"
    }

    /// On-screen window IDs of every live renderer window (all owners). Empty when none exist, which is the
    /// common case, so capture paths only pay for exclusion while a cursor is actually on screen.
    public static func liveOverlayWindowIDs() -> Set<CGWindowID> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var ids = Set<CGWindowID>()
        for window in windows where (window[kCGWindowName as String] as? String) == self.windowTitle {
            if let number = window[kCGWindowNumber as String] as? NSNumber {
                ids.insert(number.uint32Value)
            }
        }
        return ids
    }
}

/// Minimal blocking Unix-socket helpers shared by the client and the renderer host.
public enum PhantomCursorSocket {
    public static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    public static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to `path`; returns nil quickly when nothing is listening.
    public static func connect(path: String) -> Int32? {
        guard var address = self.address(for: path), let fd = self.makeSocket() else { return nil }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    public static func setTimeouts(fd: Int32, seconds: TimeInterval) {
        let clamped = max(seconds, 0.01)
        var value = timeval(
            tv_sec: Int(clamped),
            tv_usec: Int32((clamped - floor(clamped)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    public static func writeLine(_ data: Data, fd: Int32) -> Bool {
        var payload = data
        payload.append(0x0A)
        return payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if written < 0, errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads up to the first newline (bounded at 16 KiB) or until the socket timeout fires.
    public static func readLine(fd: Int32, limit: Int = 16 * 1024) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while buffer.count < limit {
            let count = read(fd, &byte, 1)
            if count == 1 {
                if byte == 0x0A { return buffer }
                buffer.append(byte)
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return buffer.isEmpty ? nil : buffer
            }
        }
        return buffer
    }
}
