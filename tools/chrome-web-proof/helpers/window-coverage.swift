import CoreGraphics
import Foundation
// List on-screen layer-0 windows above the target window, front to back, with overlap area.
let target = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
func rect(_ w: [String: Any]) -> CGRect { CGRect(dictionaryRepresentation: w[kCGWindowBounds as String] as! CFDictionary)! }
guard let t = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == target }) else { print("target not on screen"); exit(0) }
let tr = rect(t)
for w in list {
  if (w[kCGWindowNumber as String] as? Int) == target { break }
  guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
  let i = rect(w).intersection(tr)
  if !i.isNull, i.width * i.height > 0 { print(w[kCGWindowOwnerName as String] ?? "?", "covers \(Int(100 * i.width * i.height / (tr.width * tr.height)))% of target") }
}
print("target", tr)
