import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    static let backgroundFileDialogDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    /// Resolves the exact file panel and drives it through accessibility only. See
    /// `BackgroundFileDialogNavigator` for the navigation rules.
    func handleBackgroundFileDialog(_ request: DialogFileExecutionRequest) async throws -> DialogActionResult {
        try await self.runDialogOperation(scope: .global, access: .write) {
            // One discovery walk: column view makes each walk slow, and navigation re-checks the panel itself.
            let resolution = try await self.resolveFileDialogElementResolution(
                target: request.target,
                revalidate: false)
            let surface = AXFileDialogPanelSurface(panel: resolution.element.underlyingElement)
            return try await self.executeBackgroundFileDialog(request, resolution: resolution, surface: surface)
        }
    }

    func executeBackgroundFileDialog(
        _ request: DialogFileExecutionRequest,
        resolution: FileDialogElementResolution,
        surface: any FileDialogPanelSurface) async throws -> DialogActionResult
    {
        let target = resolution.target
        let destination = try Self.backgroundFileDestination(request, target: target)
        let startedAt = Date()
        let report: BackgroundFileDialogReport
        do {
            report = try await BackgroundFileDialogNavigator(panel: surface).run(destination)
        } catch let error as BackgroundFileDialogError {
            throw Self.backgroundFileDialogFailure(
                message: error.message,
                changedPanel: error.changedPanel,
                target: target)
        } catch let error as AXFileDialogPanelSurfaceError {
            throw Self.backgroundFileDialogFailure(message: error.message, changedPanel: true, target: target)
        }

        var details = Self.dialogTargetDetails(target).merging([
            "dialog_identifier": resolution.dialogIdentifier,
            "found_via": resolution.foundVia,
            "delivery": "background_accessibility",
            "path_navigation_method": report.steps.joined(separator: ","),
            "button_clicked": "default",
        ]) { _, new in new }
        if let directory = destination.directory {
            details["path"] = directory.path
        }
        if let filename = destination.filename {
            details["filename"] = filename
        }
        if let savedPath = report.savedPath {
            guard await Self.waitForSavedFile(savedPath, notBefore: startedAt) else {
                throw DesktopActionFailure.indeterminate(
                    delivery: Self.backgroundFileDialogDelivery,
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "The panel closed, but \(savedPath) did not appear.",
                    hint: "Check where the app saved the file before retrying.")
                    .attributed(to: target.actionTargetReceipt)
            }
            details["saved_path"] = savedPath
            details["saved_path_verified"] = "true"
        }

        return DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: details,
            outcome: .confirmedChange(
                delivery: Self.backgroundFileDialogDelivery,
                unitCount: DesktopActionOutcome.DispatchUnitCount(report.steps.count) ?? .one),
            targetReceipt: target.actionTargetReceipt,
            targetWindowIdentity: target.identity,
            targetWindowBounds: target.bounds,
            focusedElement: nil,
            resolvedTarget: resolution.resolvedTarget)
    }

    private static func backgroundFileDestination(
        _ request: DialogFileExecutionRequest,
        target: UIAutomationTarget.ExactWindow) throws -> FileDialogDestination
    {
        func refusal(_ message: String, _ hint: String) -> DesktopActionFailure {
            DesktopActionFailure.preDispatchRefusal(reason: .invalidRequest, message: message, hint: hint)
                .attributed(to: target.actionTargetReceipt)
        }
        if let button = request.actionButton?.trimmingCharacters(in: .whitespacesAndNewlines),
           !button.isEmpty, button.lowercased() != "default"
        {
            throw refusal(
                "Background file dialogs press only the default (Save/Open) button, not '\(button)'.",
                "Omit select, or use dialog click for other buttons.")
        }
        let destination: FileDialogDestination
        do {
            destination = try FileDialogDestination.resolve(path: request.path, name: request.filename)
        } catch {
            throw refusal(error.localizedDescription, "Pass the folder in path and a bare file name in name.")
        }
        if let directory = destination.directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw refusal(
                    "The folder \(directory.path) does not exist.",
                    "Create the folder first, or pass an existing one.")
            }
        }
        return destination
    }

    private static func backgroundFileDialogFailure(
        message: String,
        changedPanel: Bool,
        target: UIAutomationTarget.ExactWindow) -> DesktopActionFailure
    {
        let failure: DesktopActionFailure = if changedPanel {
            .indeterminate(
                delivery: self.backgroundFileDialogDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: message,
                hint: "Run dialog list to see the panel's current folder and name before retrying.")
        } else {
            .preDispatchRefusal(
                reason: .targetUnavailable,
                message: message,
                hint: "Run dialog list to see the panel before retrying.")
        }
        return failure.attributed(to: target.actionTargetReceipt)
    }

    private static func waitForSavedFile(_ path: String, notBefore startedAt: Date) async -> Bool {
        for _ in 0..<60 {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let modified = attributes[.modificationDate] as? Date,
               modified >= startedAt.addingTimeInterval(-2)
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
