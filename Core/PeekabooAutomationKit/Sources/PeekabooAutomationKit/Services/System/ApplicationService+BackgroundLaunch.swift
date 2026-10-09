import AppKit
import Foundation
import PeekabooFoundation

/// Only existing local documents are delivered to an application without activation. Web and custom-scheme
/// URLs can make the receiving app (or a browser) activate, and a plain directory is not a document. Document
/// packages such as `.rtfd` are directories on disk and stay allowed.
public enum BackgroundDocumentOpenPolicy {
    /// Throws before any dispatch, naming the first unusable target.
    public static func validate(_ urls: [URL]) throws {
        for url in urls {
            guard url.isFileURL else {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "Background delivery of \(url.absoluteString) is refused before dispatch: only existing " +
                        "local files can be opened without activating the app.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw PeekabooError.invalidInput("Document to open does not exist: \(url.path)")
            }
            if isDirectory.boolValue,
               (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
            {
                throw PeekabooError.invalidInput("Document to open is a directory, not a file: \(url.path)")
            }
        }
    }
}

@MainActor
extension ApplicationService {
    /// The application URL to cold-launch in the background, or nil when the request must take the
    /// already-running no-op path (or be refused by it).
    func coldBackgroundLaunchURL(_ launch: PreparedApplicationLaunch) -> URL? {
        guard launch.allowsColdBackgroundLaunch,
              !launch.activates,
              launch.openURLs.isEmpty,
              !launch.createsNewInstance,
              launch.requestedRunningApplicationIdentity == nil,
              let applicationURL = launch.applicationURL
        else {
            return nil
        }
        let isRunning = self.runningApplicationsForURLProvider(applicationURL).contains { application in
            !application.isTerminated && Self.application(application, matches: applicationURL)
        }
        return isRunning ? nil : applicationURL
    }

    /// The application URL that should receive the request's documents without activation, or nil when the
    /// request is not a background document open. Unlike the plain cold launch this also applies when the
    /// application is already running: the documents are delivered to the running instance.
    func backgroundDocumentOpenURL(_ launch: PreparedApplicationLaunch) -> URL? {
        guard launch.allowsColdBackgroundLaunch,
              !launch.activates,
              !launch.openURLs.isEmpty,
              !launch.createsNewInstance
        else {
            return nil
        }
        return launch.applicationURL
    }

    /// Deliver the request's documents to the application without activating it. A PID-selected request is
    /// pinned to that process generation: it is refused before dispatch when the process is gone, and fails
    /// after dispatch when LaunchServices delivered to another process.
    func performBackgroundDocumentOpen(
        _ launch: PreparedApplicationLaunch,
        applicationURL: URL) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try BackgroundDocumentOpenPolicy.validate(launch.openURLs)
        if let requestedIdentity = launch.requestedRunningApplicationIdentity {
            let runningApplications = self.runningApplicationsForURLProvider(applicationURL).filter { application in
                !application.isTerminated && Self.application(application, matches: applicationURL)
            }
            guard self.selectRunningApplication(runningApplications, requestedIdentity: requestedIdentity) != nil
            else {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "The PID-selected application stopped or changed process generation before its documents " +
                        "were opened.")
            }
        }
        return try await self.performColdBackgroundLaunch(launch, applicationURL: applicationURL)
    }

    func performColdBackgroundLaunch(
        _ launch: PreparedApplicationLaunch,
        applicationURL: URL) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if launch.disablesRunningApplicationSubstitution {
            config.allowsRunningApplicationSubstitution = false
        }

        // Same ownership rule as the foreground launch: once LaunchServices starts opening the app, keep the
        // native operation until it returns a PID.
        try Self.checkApplicationDispatchCancellation(operation: "Launch application")
        let previousFrontmostProcessIdentifier = self.frontmostProcessIdentifierProvider()
        let openTask = Task { @MainActor in
            try Task.checkCancellation()
            self.logger.debug("Launching app in the background from URL: \(applicationURL.path)")
            return try await self.applicationOpenHandler(applicationURL, launch.openURLs, config)
        }
        let runningApp: NSRunningApplication
        do {
            runningApp = try await openTask.value
        } catch {
            throw Self.uncertainDispatchFailure(
                operation: "Launch application",
                mode: .background,
                error: error)
        }

        var acceptedNativeDispatchCount = 1
        do {
            let launchProcessIdentity = try self.captureLaunchProcessIdentity(runningApp)
            if let requestedIdentity = launch.requestedRunningApplicationIdentity,
               launchProcessIdentity != requestedIdentity
            {
                throw PeekabooError.commandFailed(
                    "LaunchServices delivered the documents to a different process than the PID-selected application")
            }
            try await self.waitUntilReadyIfNeeded(
                runningApp,
                requested: launch.waitUntilReady,
                expectedIdentity: launchProcessIdentity)
            try await self.waitForWindowIfNeeded(
                runningApp,
                requested: launch.waitForWindow,
                expectedIdentity: launchProcessIdentity)
            try await self.handBackForegroundAfterBackgroundLaunch(
                launchedProcessIdentifier: runningApp.processIdentifier,
                previousFrontmostProcessIdentifier: previousFrontmostProcessIdentifier,
                recordAcceptedHandBack: { acceptedNativeDispatchCount += 1 })

            let application = self.createApplicationInfo(from: runningApp)
            guard application.processIdentity == launchProcessIdentity else {
                throw PeekabooError.commandFailed(
                    "Launched application process generation changed before its receipt could be returned")
            }
            let boundApplication = try await self.bindSelectorResolution(application, launch: launch)
            return DesktopActionResult(
                payload: boundApplication,
                outcome: .confirmedChange(
                    delivery: Self.applicationDelivery(mode: .background),
                    unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedNativeDispatchCount) ?? .one))
        } catch {
            throw Self.postDispatchFailure(
                operation: "Launch application",
                mode: .background,
                error: error,
                unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedNativeDispatchCount) ?? .one)
        }
    }

    /// Some apps activate themselves while starting even when LaunchServices was told not to activate them
    /// (Chrome took the foreground twice within 1.3 s in testing). For a bounded window after launch, poll the
    /// frontmost process and re-activate the app the user had in front whenever the launched app takes it.
    /// Each accepted re-activation is counted as a dispatched unit of the launch.
    private func handBackForegroundAfterBackgroundLaunch(
        launchedProcessIdentifier: pid_t,
        previousFrontmostProcessIdentifier: pid_t?,
        recordAcceptedHandBack: () -> Void) async throws
    {
        guard let previousFrontmostProcessIdentifier,
              previousFrontmostProcessIdentifier != launchedProcessIdentifier
        else {
            return
        }
        var elapsed = Duration.zero
        while elapsed < self.backgroundLaunchHandBackWindow {
            try await self.applicationActivationSleepHandler(self.backgroundLaunchHandBackPollInterval)
            elapsed += self.backgroundLaunchHandBackPollInterval
            guard self.frontmostProcessIdentifierProvider() == launchedProcessIdentifier else { continue }
            guard let previousApplication = NSRunningApplication(
                processIdentifier: previousFrontmostProcessIdentifier),
                !previousApplication.isTerminated
            else {
                return
            }
            if self.applicationActivationHandler(previousApplication) {
                recordAcceptedHandBack()
            } else {
                self.logger.warning(
                    "Background launch could not hand the foreground back to PID \(previousFrontmostProcessIdentifier)")
            }
        }
    }
}
