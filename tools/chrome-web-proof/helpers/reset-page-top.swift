import ApplicationServices
import Foundation
// Scroll the test page back so the "Regions" section heading is at the top: AXScrollToVisible on the first AXHeading titled Ops Dashboard.
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
var found: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
  guard found == nil, d < 30 else { return }
  if (attr(e, "AXRole") as? String) == "AXHeading", (attr(e, "AXTitle") as? String) == "Ops Dashboard" { found = e; return }
  for k in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { walk(k, d + 1) }
}
for w in (attr(app, "AXWindows") as? [AXUIElement]) ?? [] { walk(w, 0) }
if let found { print("reset:", AXUIElementPerformAction(found, "AXScrollToVisible" as CFString).rawValue) } else { print("heading not found") }
