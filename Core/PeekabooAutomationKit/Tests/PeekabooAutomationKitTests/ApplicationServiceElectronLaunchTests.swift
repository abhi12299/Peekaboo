import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

/// Electron does not render a window on a Space no display shows, so its accessibility tree never appears
/// there. Started with `--disable-backgrounding-occluded-windows` it keeps rendering such a window (measured
/// with an Electron 45 test app: the tree built and kept updating on a hidden Space).
@Suite(.serialized)
@MainActor
struct ApplicationServiceElectronLaunchTests {
    @Test
    func `cold background launch of an Electron app keeps its hidden windows rendering and accessible`() async throws {
        let bundle = try FakeApplicationBundle(info: ["ElectronAsarIntegrity": ["Resources/app.asar": [:]]])
        defer { bundle.remove() }
        let recorder = ApplicationOpenRecorder()

        // The recorder hands back Finder, so only the dispatched configuration is checked.
        _ = try? await Self.service(recorder: recorder).launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: bundle.url.path,
            allowsColdBackgroundLaunch: true))

        let call = try #require(recorder.calls.first)
        #expect(call.arguments == ["--disable-backgrounding-occluded-windows", "--force-renderer-accessibility"])
    }

    @Test
    func `cold background launch of a native app passes no arguments`() async throws {
        let bundle = try FakeApplicationBundle(info: [:])
        defer { bundle.remove() }
        let recorder = ApplicationOpenRecorder()

        // The recorder hands back Finder, so only the dispatched configuration is checked.
        _ = try? await Self.service(recorder: recorder).launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: bundle.url.path,
            allowsColdBackgroundLaunch: true))

        let call = try #require(recorder.calls.first)
        #expect(call.arguments.isEmpty)
    }

    private static func service(recorder: ApplicationOpenRecorder) throws -> ApplicationService {
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(recorder.runningApplication.processIdentifier))
        return ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [] },
            frontmostProcessIdentifierProvider: { nil },
            applicationActivationSleepHandler: { _ in },
            processStartIdentityProvider: { _ in processStartIdentity })
    }
}

/// A minimal `.app` folder with the given Info.plist entries, for classification by bundle contents.
struct FakeApplicationBundle {
    let url: URL

    init(info: [String: Any], frameworks: [String] = []) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-fake-app-\(UUID().uuidString)")
        self.url = root.appendingPathComponent("Fake.app")
        let contents = self.url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"),
            withIntermediateDirectories: true)
        for framework in frameworks {
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("Frameworks/\(framework)"),
                withIntermediateDirectories: true)
        }
        var plist = info
        plist["CFBundleIdentifier"] = "boo.peekaboo.tests.fake-\(UUID().uuidString)"
        plist["CFBundleExecutable"] = "Fake"
        plist["CFBundlePackageType"] = "APPL"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.url.deletingLastPathComponent())
    }
}
