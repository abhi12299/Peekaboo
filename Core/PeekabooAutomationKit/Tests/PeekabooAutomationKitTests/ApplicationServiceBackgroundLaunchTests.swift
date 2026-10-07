import AppKit
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceBackgroundLaunchTests {
    @Test
    @MainActor
    func `cold background launch opens through LaunchServices without activating`() async throws {
        let recorder = ApplicationOpenRecorder()
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(recorder.runningApplication.processIdentifier))
        var activationRequests = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [] },
            applicationActivationHandler: { _ in
                activationRequests += 1
                return true
            },
            frontmostProcessIdentifierProvider: { nil },
            applicationActivationSleepHandler: { _ in },
            processStartIdentityProvider: { _ in processStartIdentity })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            allowsColdBackgroundLaunch: true))

        let call = try #require(recorder.calls.first)
        #expect(recorder.calls.count == 1)
        #expect(!call.activates)
        #expect(activationRequests == 0)
        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .background))
        #expect(result.payload.processIdentifier == recorder.runningApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `cold background launch hands the foreground back when the launched app takes it`() async throws {
        let recorder = ApplicationOpenRecorder()
        let launchedPID = recorder.runningApplication.processIdentifier
        let previous = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != launchedPID && $0.processIdentifier > 0 && !$0.isTerminated
        })
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(launchedPID))
        let frontmost = AutomationTestLockedValue<pid_t?>(previous.processIdentifier)
        var activatedPIDs: [pid_t] = []
        var slept: Duration = .zero
        let service = ApplicationService(
            applicationOpenHandler: { applicationURL, openURLs, configuration in
                let application = try await recorder.open(
                    applicationURL: applicationURL,
                    openURLs: openURLs,
                    configuration: configuration)
                frontmost.value = launchedPID
                return application
            },
            runningApplicationsForURLProvider: { _ in [] },
            applicationActivationHandler: { application in
                activatedPIDs.append(application.processIdentifier)
                frontmost.value = application.processIdentifier
                return true
            },
            frontmostProcessIdentifierProvider: { frontmost.value },
            applicationActivationSleepHandler: { slept += $0 },
            processStartIdentityProvider: { _ in processStartIdentity },
            backgroundLaunchHandBackWindow: .milliseconds(200),
            backgroundLaunchHandBackPollInterval: .milliseconds(25))

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            allowsColdBackgroundLaunch: true))

        #expect(activatedPIDs == [previous.processIdentifier])
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .init(2)))
        #expect(slept >= .milliseconds(200))
    }

    @Test
    @MainActor
    func `cold background launch hands the foreground back again when the app takes it twice`() async throws {
        let recorder = ApplicationOpenRecorder()
        let launchedPID = recorder.runningApplication.processIdentifier
        let previous = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != launchedPID && $0.processIdentifier > 0 && !$0.isTerminated
        })
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(launchedPID))
        let frontmost = AutomationTestLockedValue<pid_t?>(previous.processIdentifier)
        var activatedPIDs: [pid_t] = []
        var polls = 0
        let service = ApplicationService(
            applicationOpenHandler: { applicationURL, openURLs, configuration in
                let application = try await recorder.open(
                    applicationURL: applicationURL,
                    openURLs: openURLs,
                    configuration: configuration)
                frontmost.value = launchedPID
                return application
            },
            runningApplicationsForURLProvider: { _ in [] },
            applicationActivationHandler: { application in
                activatedPIDs.append(application.processIdentifier)
                frontmost.value = application.processIdentifier
                return true
            },
            frontmostProcessIdentifierProvider: { frontmost.value },
            applicationActivationSleepHandler: { _ in
                polls += 1
                if polls == 5 {
                    // The launched app grabs the foreground a second time later in the window.
                    frontmost.value = launchedPID
                }
            },
            processStartIdentityProvider: { _ in processStartIdentity },
            backgroundLaunchHandBackWindow: .milliseconds(200),
            backgroundLaunchHandBackPollInterval: .milliseconds(25))

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            allowsColdBackgroundLaunch: true))

        #expect(activatedPIDs == [previous.processIdentifier, previous.processIdentifier])
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .init(3)))
        #expect(polls == 8)
    }

    @Test(arguments: [true, false])
    @MainActor
    func `cold background launch does not hand back to itself or to no previous app`(
        previousWasLaunchedApp: Bool) async throws
    {
        let recorder = ApplicationOpenRecorder()
        let launchedPID = recorder.runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(launchedPID))
        let frontmost = AutomationTestLockedValue<pid_t?>(previousWasLaunchedApp ? launchedPID : nil)
        var activationRequests = 0
        let service = ApplicationService(
            applicationOpenHandler: { applicationURL, openURLs, configuration in
                let application = try await recorder.open(
                    applicationURL: applicationURL,
                    openURLs: openURLs,
                    configuration: configuration)
                frontmost.value = launchedPID
                return application
            },
            runningApplicationsForURLProvider: { _ in [] },
            applicationActivationHandler: { _ in
                activationRequests += 1
                return true
            },
            frontmostProcessIdentifierProvider: { frontmost.value },
            applicationActivationSleepHandler: { _ in },
            processStartIdentityProvider: { _ in processStartIdentity },
            backgroundLaunchHandBackWindow: .milliseconds(200),
            backgroundLaunchHandBackPollInterval: .milliseconds(25))

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            allowsColdBackgroundLaunch: true))

        #expect(activationRequests == 0)
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
    }

    @Test
    @MainActor
    func `cold background launch opt-in keeps the already-running no-op without dispatch`() async throws {
        let recorder = ApplicationOpenRecorder()
        let frontmostReads = AutomationTestLockedValue(0)
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            frontmostProcessIdentifierProvider: {
                frontmostReads.withValue { $0 += 1 }
                return nil
            })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            allowsColdBackgroundLaunch: true))

        #expect(recorder.calls.isEmpty)
        #expect(frontmostReads.value == 0)
        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.payload.processIdentifier == recorder.runningApplication.processIdentifier)
    }
}
