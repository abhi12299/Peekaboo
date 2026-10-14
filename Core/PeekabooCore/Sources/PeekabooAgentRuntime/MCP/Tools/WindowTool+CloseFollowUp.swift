import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// One line after a successful `window close` saying whether the app now shows a dialog or sheet, so the
/// caller does not need a `dialog list` or `window list` just to check.
struct WindowCloseDialogFollowUp {
    let line: String
    let dialogPresent: Value
}

extension WindowTool {
    /// Read-only and cheap (no screenshot): the same targeted dialog read `dialog list` uses for an app.
    @MainActor
    func dialogFollowUpAfterClose(
        ownerProcessIdentifier: Int32,
        appName: String?) async -> WindowCloseDialogFollowUp
    {
        do {
            let selector = try DialogTargetSelector(processIdentifier: ownerProcessIdentifier)
            let elements = try await self.context.dialogs.listDialogElements(target: selector)
            let info = elements.dialogInfo
            let kind = info.role == "AXSheet" || info.subrole == "AXSheet" ? "sheet" : "dialog"
            let name = [info.title, elements.staticTexts.first ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let named = name.map { " '\($0)'" } ?? ""
            let owner = elements.resolvedTarget?.applicationName
                ?? appName.flatMap { $0.hasPrefix("PID:") ? nil : $0 }
                ?? "The app"
            return WindowCloseDialogFollowUp(
                line: "\(owner) now shows a \(kind)\(named); answer it with `dialog`.",
                dialogPresent: .bool(true))
        } catch where DialogAbsence.isNoDialogOpen(error) {
            return WindowCloseDialogFollowUp(line: "No dialog or sheet is open.", dialogPresent: .bool(false))
        } catch {
            return WindowCloseDialogFollowUp(
                line: "Could not check for a dialog or sheet; use `dialog list` if unsure.",
                dialogPresent: .null)
        }
    }
}
