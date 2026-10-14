// Samples real cursor, frontmost app and overlay windows of interest every 200ms as JSON lines.
import AppKit
import CoreGraphics
let out = CommandLine.arguments[1]
let interest = ["sky", "computer use", "peekaboo", "codex", "cua"]
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
setvbuf(stdout, nil, _IONBF, 0)
while true {
    autoreleasepool {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        var wins: [[String: Any]] = []
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                let owner = (w[kCGWindowOwnerName as String] as? String ?? "")
                if interest.contains(where: { owner.lowercased().contains($0) }) {
                    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    wins.append(["owner": owner, "layer": w[kCGWindowLayer as String] ?? 0,
                                 "name": w[kCGWindowName as String] ?? "", "alpha": w[kCGWindowAlpha as String] ?? 1,
                                 "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0])
                }
            }
        }
        let rec: [String: Any] = ["t": Date().timeIntervalSince1970, "cx": Int(loc.x), "cy": Int(loc.y), "front": front, "wins": wins]
        if let d = try? JSONSerialization.data(withJSONObject: rec) { fh.write(d); fh.write("\n".data(using: .utf8)!) }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
