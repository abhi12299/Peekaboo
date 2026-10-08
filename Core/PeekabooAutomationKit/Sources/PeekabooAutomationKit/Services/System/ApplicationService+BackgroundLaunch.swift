import AppKit
import Foundation
import PeekabooFoundation

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
            return try await self.applicationOpenHandler(applicationURL, [], config)
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
