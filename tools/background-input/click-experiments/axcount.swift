// usage: axcount <pid> [set-manual|set-enhanced]  — counts AX elements under the app (depth-first, capped) and lists web roles.
import ApplicationServices
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
if CommandLine.arguments.count > 2 {
    let arg = CommandLine.arguments[2]
    let attr = arg.hasSuffix("manual") ? "AXManualAccessibility" : "AXEnhancedUserInterface"
    let on = !arg.hasPrefix("unset")
    print("\(on ? "set" : "unset") \(attr) rc=\(AXUIElementSetAttributeValue(app, attr as CFString, on ? kCFBooleanTrue : kCFBooleanFalse).rawValue)")
    usleep(1_500_000)
}
var count = 0, web = 0, buttons = 0
var roles: [String: Int] = [:]
func walk(_ e: AXUIElement, _ depth: Int) {
    if count > 5000 || depth > 60 { return }
    count += 1
    var r: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &r)
    let role = (r as? String) ?? "?"; roles[role, default: 0] += 1
    if role == "AXWebArea" { web += 1 }
    var kids: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
    for k in (kids as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
}
walk(app, 0)
print("elements=\(count) webAreas=\(web) roles=\(roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key):\($0.value)" }.joined(separator: " "))")
