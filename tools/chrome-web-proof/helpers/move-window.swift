import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!; var p = CGPoint(x: Double(CommandLine.arguments[2])!, y: Double(CommandLine.arguments[3])!)
let app = AXUIElementCreateApplication(pid)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &v)
for w in (v as? [AXUIElement]) ?? [] { var t: CFTypeRef?; AXUIElementCopyAttributeValue(w, "AXTitle" as CFString, &t)
  if (t as? String)?.contains("Peekaboo Web Proof") == true { print("move:", AXUIElementSetAttributeValue(w, "AXPosition" as CFString, AXValueCreate(.cgPoint, &p)!).rawValue) } }
