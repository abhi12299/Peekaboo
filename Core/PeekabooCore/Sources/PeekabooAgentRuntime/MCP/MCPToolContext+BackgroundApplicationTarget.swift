import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

extension MCPToolContext {
    private enum BackgroundSnapshotTargetRequirement {
        case processIdentity
        case exactWindow

        init(toolName: String) {
            self = switch toolName {
            case "action", "set_value": .processIdentity
            default: .exactWindow
            }
        }
    }

    private struct BackgroundExactWindowSelectorKeys {
        let application: String
        let pid: String?
        let title: String
        let index: String
    }

    private struct BackgroundExactWindowSelector {
        let keys: BackgroundExactWindowSelectorKeys
        let selector: InteractionTargetSelector
    }

    @MainActor
    func backgroundTargetRevalidation(
        _ authorization: BackgroundTargetAuthorization,
        toolName: String) async throws -> ToolResponse?
    {
        guard let plan = authorization.targetPlan else { return nil }
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        do {
            let current = try await planner.revalidate(plan.mutationAuthority)
            let application = current.authority.application.application
            return self.executionPolicy.systemSurfaceRejection(
                toolName: toolName,
                applicationBundleIdentifier: application.bundleIdentifier,
                applicationName: application.name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let detail = plan.targetIdentity.exactWindow == nil
                ? "the selected application changed process generation before dispatch"
                : "the selected window changed identity or bounds before dispatch"
            return self.executionPolicy.unresolvedTargetRejection(
                toolName: toolName,
                detail: detail)
        }
    }

    @MainActor
    func backgroundSnapshotTargetPlan(
        toolName: String,
        snapshotID: String,
        mirroredSnapshot: UISnapshot,
        detectionResult: ElementDetectionResult) async throws -> AuthorizedDesktopTargetPlan
    {
        let mirroredReceipt = try mirroredSnapshot.targetReceipt()
        let mirroredIdentity = try mirroredReceipt.requireIdentity()
        if let mirroredName = Self.nonEmpty(mirroredReceipt.applicationName),
           let detectionName = Self.nonEmpty(detectionResult.metadata.windowContext?.applicationName),
           mirroredName.caseInsensitiveCompare(detectionName) != .orderedSame
        {
            throw DesktopTargetIdentityError.snapshotSourceMismatch
        }
        let identity: DesktopTargetIdentity
        switch BackgroundSnapshotTargetRequirement(toolName: toolName) {
        case .processIdentity where mirroredIdentity.exactWindow == nil:
            identity = try SnapshotTargetReceiptPlanner.assembleProcessIdentity(
                snapshotID: snapshotID,
                detectionResult: detectionResult,
                additionalEvidence: [.init(target: mirroredIdentity)],
                applicationName: mirroredReceipt.applicationName).receipt.requireIdentity()
        case .processIdentity, .exactWindow:
            guard mirroredIdentity.exactWindow != nil else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            identity = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotID,
                detectionResult: detectionResult,
                additionalEvidence: [.init(target: mirroredIdentity)],
                applicationName: mirroredReceipt.applicationName).receipt.requireIdentity()
        }
        let authority: DesktopTargetPlanning.ReceiptBoundMutationAuthorityPlan
        do {
            authority = try await self.receiptBoundMutationAuthority(for: identity)
        } catch DesktopTargetIdentityError.contradictoryWindowBounds {
            // Window ID, PID and process generation already agree (they are checked before bounds), so only the
            // live frame differs, e.g. while a just-launched app settles its window. Read it once more before
            // refusing; a frame that still differs is refused as before.
            try await Task.sleep(for: Self.windowFrameSettleDelay)
            do {
                authority = try await self.receiptBoundMutationAuthority(for: identity)
            } catch DesktopTargetIdentityError.contradictoryWindowBounds {
                throw SnapshotWindowFrameChanged(
                    windowID: identity.exactWindow?.identity.windowID,
                    snapshotID: snapshotID)
            }
        }
        return AuthorizedDesktopTargetPlan(mutationAuthority: authority)
    }

    /// The snapshot's window is still the same window of the same process, but its live frame no longer matches.
    struct SnapshotWindowFrameChanged: Error, CustomStringConvertible {
        let windowID: Int?
        let snapshotID: String

        var description: String {
            "window \(self.windowID.map(String.init) ?? "?") moved or resized after snapshot '\(self.snapshotID)' " +
                "was taken; run `see` again and use the new snapshot"
        }
    }

    /// Pause before re-reading a live window frame that disagreed with its snapshot.
    static let windowFrameSettleDelay: Duration = .milliseconds(250)

    @MainActor
    func receiptBoundMutationAuthority(
        for identity: DesktopTargetIdentity) async throws
        -> DesktopTargetPlanning.ReceiptBoundMutationAuthorityPlan
    {
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        return try await planner.bind(identity: identity)
    }

    struct BackgroundApplicationTargetSchema {
        let stringKeys: [String]
        let pidKeys: [String]
        let windowIDKeys: [String]
    }

    struct BackgroundTargetResolutionError: Error {
        let detail: String

        init(_ detail: String) {
            self.detail = detail
        }
    }

    static func backgroundApplicationTargetSchema(toolName: String) -> BackgroundApplicationTargetSchema? {
        // MCP window/space selectors encode a PID as app="PID:<n>"; unlike their CLI adapters they expose no pid key.
        switch toolName {
        case "app":
            BackgroundApplicationTargetSchema(stringKeys: ["name", "bundleId"], pidKeys: [], windowIDKeys: [])
        case "dialog", "paste", "type":
            BackgroundApplicationTargetSchema(
                stringKeys: ["app"],
                pidKeys: ["pid"],
                windowIDKeys: ["window_id"])
        case "window":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: ["window_id"])
        case "menu":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: [])
        case "space":
            BackgroundApplicationTargetSchema(stringKeys: ["app"], pidKeys: [], windowIDKeys: ["window_id"])
        default:
            nil
        }
    }

    /// A background `app launch` of an application that is not running has no process to pin. It is admitted
    /// without a target plan so the application service can cold-launch it without activation; the service
    /// re-checks the running state and falls back to the exact no-op if the app started in the meantime.
    /// The same holds for a launch that delivers documents (`open`) to an app that is not running.
    @MainActor
    func backgroundColdApplicationLaunchAuthorization(
        toolName: String,
        arguments: ToolArguments,
        schema: BackgroundApplicationTargetSchema) async throws -> BackgroundTargetAuthorization?
    {
        guard toolName == "app",
              MCPToolRequestSemantics.isSafeBackgroundApplicationLaunchNoOp(arguments) ||
              MCPToolRequestSemantics.isBackgroundApplicationDocumentOpen(arguments)
        else { return nil }
        let identifiers = try Self.applicationIdentifiers(arguments: arguments, schema: schema)
        guard identifiers.count == 1,
              let identifier = identifiers.first,
              !identifier.uppercased().hasPrefix("PID:"),
              try await !self.applications.isApplicationRunning(identifier: identifier)
        else { return nil }
        if let rejection = self.executionPolicy.systemSurfaceRejection(
            toolName: toolName,
            applicationBundleIdentifier: Self.nonEmpty(arguments.getString("bundleId")),
            applicationName: Self.nonEmpty(arguments.getString("name")))
        {
            return BackgroundTargetAuthorization(arguments: arguments, rejection: rejection, targetPlan: nil)
        }
        return BackgroundTargetAuthorization(arguments: arguments, rejection: nil, targetPlan: nil)
    }

    @MainActor
    func backgroundExactWindowTargetAuthorization(
        toolName: String,
        arguments: ToolArguments) async throws -> BackgroundTargetAuthorization?
    {
        guard let selector = try Self.backgroundExactWindowSelector(
            toolName: toolName,
            arguments: arguments)
        else { return nil }

        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        let authority: DesktopTargetPlanning.MutationAuthorityPlan
        do {
            let automaticSelection: DesktopTargetPlanning.WindowSelectionPolicy =
                toolName == "window" && arguments.getString("action")?.lowercased() == "restore"
                    ? .preferredMutationWindow(.restore)
                    : .preferredMutationWindow(.general)
            authority = try await planner.plan(
                selector: selector.selector,
                requirement: .exactWindow(automaticSelection: automaticSelection))
        } catch {
            throw BackgroundTargetResolutionError(error.localizedDescription)
        }
        guard let windowPlan = authority.window else {
            throw BackgroundTargetResolutionError(
                "background \(toolName) did not resolve one exact window authority")
        }
        let application = authority.application.application
        if let rejection = self.executionPolicy.systemSurfaceRejection(
            toolName: toolName,
            applicationBundleIdentifier: application.bundleIdentifier,
            applicationName: application.name)
        {
            return BackgroundTargetAuthorization(arguments: arguments, rejection: rejection, targetPlan: nil)
        }

        var pinned = Self.argumentsPinnedToProcess(
            arguments,
            toolName: toolName,
            processIdentifier: authority.application.processIdentity.processIdentifier).rawDictionary
        pinned["window_id"] = windowPlan.identity.windowID
        pinned.removeValue(forKey: selector.keys.title)
        pinned.removeValue(forKey: selector.keys.index)
        let boundAuthority = try planner.bind(authority: authority)
        return BackgroundTargetAuthorization(
            arguments: ToolArguments(raw: pinned),
            rejection: nil,
            targetPlan: AuthorizedDesktopTargetPlan(mutationAuthority: boundAuthority))
    }

    private static func backgroundExactWindowSelector(
        toolName: String,
        arguments: ToolArguments) throws -> BackgroundExactWindowSelector?
    {
        guard let keys = self.backgroundExactWindowSelectorKeys(toolName: toolName, arguments: arguments) else {
            return nil
        }
        let applicationSelector = self.strictString(arguments, key: keys.application)
        let titleSelector = self.strictString(arguments, key: keys.title)
        guard !applicationSelector.isInvalid else {
            throw BackgroundTargetResolutionError("app must be a nonempty application identifier")
        }
        guard !titleSelector.isInvalid else {
            throw BackgroundTargetResolutionError("\(keys.title) must be a nonempty window title")
        }

        let pid = try keys.pid.flatMap { try arguments.validatedInt($0) }
        let windowID = try arguments.validatedInt("window_id")
        let windowIndex = try arguments.validatedInt(keys.index)
        let selector = InteractionTargetSelector(
            applicationIdentifier: applicationSelector.value,
            processIdentifier: pid,
            windowID: windowID,
            windowTitle: titleSelector.value,
            windowIndex: windowIndex)
        try self.validateBackgroundInteractionSelector(selector, keys: keys)
        if toolName == "paste", !selector.hasWindowInput {
            return nil
        }
        guard windowID != nil || applicationSelector.value != nil || pid != nil else {
            throw BackgroundTargetResolutionError(
                "background window mutation requires an application or exact window_id owner")
        }
        return BackgroundExactWindowSelector(
            keys: keys,
            selector: selector)
    }

    private static func validateBackgroundInteractionSelector(
        _ selector: InteractionTargetSelector,
        keys: BackgroundExactWindowSelectorKeys) throws
    {
        do {
            try selector.validate(policy: .interaction)
        } catch let error as InteractionTargetSelector.ValidationError {
            let detail = switch error {
            case .applicationAndProcessIdentifier:
                "app and pid are mutually exclusive"
            case .multipleWindowSelectors:
                "window_id, \(keys.title), and \(keys.index) are mutually exclusive"
            case .windowSelectorRequiresApplication:
                "background window mutation requires an application or exact window_id owner"
            case .invalidProcessIdentifier:
                "pid must be a valid positive process identifier"
            case .invalidWindowID:
                "window_id must be a valid positive WindowServer identifier"
            case .invalidWindowIndex:
                "\(keys.index) must be zero or greater"
            case .conflictingProcessIdentifiers,
                 .invalidApplicationProcessIdentifier,
                 .missingTarget,
                 .emptyApplication,
                 .emptyWindowTitle:
                preconditionFailure("Interaction policy does not emit \(error)")
            }
            throw BackgroundTargetResolutionError(detail)
        }
    }

    private static func backgroundExactWindowSelectorKeys(
        toolName: String,
        arguments: ToolArguments) -> BackgroundExactWindowSelectorKeys?
    {
        switch (toolName, arguments.getString("action")?.lowercased()) {
        case let ("window", action?) where action != "list":
            BackgroundExactWindowSelectorKeys(application: "app", pid: nil, title: "title", index: "index")
        case ("space", "move-window"):
            BackgroundExactWindowSelectorKeys(
                application: "app",
                pid: nil,
                title: "window_title",
                index: "window_index")
        case ("paste", _):
            BackgroundExactWindowSelectorKeys(
                application: "app",
                pid: "pid",
                title: "window_title",
                index: "window_index")
        default:
            nil
        }
    }

    static func applicationIdentifiers(
        arguments: ToolArguments,
        schema: BackgroundApplicationTargetSchema) throws -> [String]
    {
        var identifiers: [String] = []
        var stringSelectors: [String] = []
        for key in schema.stringKeys {
            let selector = Self.strictString(arguments, key: key)
            guard !selector.isInvalid else {
                throw BackgroundTargetResolutionError("\(key) must be a nonempty application identifier")
            }
            if let value = selector.value {
                identifiers.append(value)
                stringSelectors.append(value)
            }
        }
        var processIdentifiers: [Int] = []
        for key in schema.pidKeys {
            if let pid = try arguments.validatedInt(key) {
                identifiers.append("PID:\(pid)")
                processIdentifiers.append(pid)
            }
        }
        if schema.stringKeys.count == 1, schema.pidKeys.count == 1 {
            let selector = InteractionTargetSelector(
                applicationIdentifier: stringSelectors.first,
                processIdentifier: processIdentifiers.first)
            try self.validateBackgroundInteractionSelector(
                selector,
                keys: BackgroundExactWindowSelectorKeys(
                    application: schema.stringKeys[0],
                    pid: schema.pidKeys[0],
                    title: "window_title",
                    index: "window_index"))
        }
        return identifiers
    }

    func windowTargetIdentities(
        arguments: ToolArguments,
        keys: [String]) async throws -> [DesktopTargetIdentity]
    {
        var identities: [DesktopTargetIdentity] = []
        for key in keys {
            guard let windowID = try arguments.validatedInt(key) else { continue }
            try Self.validateBackgroundInteractionSelector(
                InteractionTargetSelector(windowID: windowID),
                keys: BackgroundExactWindowSelectorKeys(
                    application: "app",
                    pid: "pid",
                    title: "window_title",
                    index: "window_index"))
            let windows: [ServiceWindowInfo]
            do {
                windows = try await self.windows.listWindows(target: .windowId(windowID))
            } catch {
                throw BackgroundTargetResolutionError("window_id owner could not be resolved before dispatch")
            }
            guard windows.count == 1, let window = windows.first else {
                throw BackgroundTargetResolutionError(
                    "window_id does not identify exactly one window")
            }
            do {
                try identities.append(DesktopTargetIdentity(
                    exactWindow: UIAutomationTarget.ExactWindow(window: window)))
            } catch {
                throw BackgroundTargetResolutionError(
                    "window_id does not identify one generation-pinned exact window with immutable bounds")
            }
        }
        return identities
    }

    @MainActor
    func resolveApplicationAuthorities(
        _ identifiers: [String]) async throws -> [DesktopTargetPlanning.ReceiptBoundMutationAuthorityPlan]
    {
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: self.applications,
            windows: self.windows)
        do {
            var resolved: [DesktopTargetPlanning.ReceiptBoundMutationAuthorityPlan] = []
            var expectedIdentity: ApplicationProcessIdentity?
            for identifier in identifiers {
                let authority = try await planner.plan(
                    selector: InteractionTargetSelector(applicationIdentifier: identifier),
                    expectedProcessIdentity: expectedIdentity)
                expectedIdentity = authority.application.processIdentity
                try resolved.append(planner.bind(authority: authority))
            }
            return resolved
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackgroundTargetResolutionError(
                error.localizedDescription)
        }
    }

    static func validatedProcessIdentity(
        applications: [ServiceApplicationInfo],
        windowProcessIdentities: [ApplicationProcessIdentity]) throws -> ApplicationProcessIdentity
    {
        guard Set(applications.map(\.processIdentifier)).count == 1 else {
            throw BackgroundTargetResolutionError(
                "the supplied application and window selectors identify different owners")
        }
        let identities = applications.compactMap { application -> ApplicationProcessIdentity? in
            guard let processStartIdentity = application.processStartIdentity else { return nil }
            return ApplicationProcessIdentity(
                processIdentifier: application.processIdentifier,
                processStartIdentity: processStartIdentity)
        }
        guard identities.count == applications.count,
              let identity = identities.first,
              identities.allSatisfy({ $0 == identity }),
              windowProcessIdentities.allSatisfy({ $0 == identity })
        else {
            throw BackgroundTargetResolutionError(
                "the selected owner has no stable process-generation receipt")
        }
        return identity
    }

    static func argumentsPinnedToProcess(
        _ arguments: ToolArguments,
        toolName: String,
        processIdentifier: Int32) -> ToolArguments
    {
        var pinned = arguments.rawDictionary
        switch toolName {
        case "app":
            pinned["name"] = "PID:\(processIdentifier)"
            pinned.removeValue(forKey: "bundleId")
        case "dialog", "paste", "type":
            pinned["pid"] = Int(processIdentifier)
            pinned.removeValue(forKey: "app")
        case "menu", "space", "window":
            pinned["app"] = "PID:\(processIdentifier)"
        default:
            break
        }
        return ToolArguments(raw: pinned)
    }
}
