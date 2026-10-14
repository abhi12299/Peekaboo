// usage: axunset <pid> — sets AXManualAccessibility=false and exits without querying anything else.
import ApplicationServices
let app = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
print("unset rc=\(AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse).rawValue)")
