// Prints on-screen windows for an owner name: id, pid, layer, bounds.
import CoreGraphics
let name = CommandLine.arguments[1]
for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [] where (w[kCGWindowOwnerName as String] as? String) == name {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print(w[kCGWindowNumber as String]!, w[kCGWindowOwnerPID as String]!, w[kCGWindowLayer as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!, w[kCGWindowIsOnscreen as String] ?? 0)
}
