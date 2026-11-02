import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundFileDialogNavigatorTests {
    @Test
    func `saving into the current folder names the file and saves without choosing a Where location`() async throws {
        let tree = try TemporaryFolderTree(["start"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("start"))

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("start"), filename: "q3.txt"))

        #expect(panel.savedURL?.path == tree.url("start").appendingPathComponent("q3.txt").path)
        #expect(report.savedPath == panel.savedURL?.path)
        #expect(!panel.events.contains { $0.hasPrefix("menu.choose") })
    }

    @Test
    func `a sibling folder is reached through the Where menu and then opened from the file list`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .icon)

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("run/exports"), filename: "q3.txt"))

        let expected = tree.url("run/exports").appendingPathComponent("q3.txt").path
        #expect(panel.savedURL?.path == expected)
        #expect(report.savedPath == expected)
        #expect(panel.events.contains("menu.choose 1"))
    }

    @Test(arguments: [FakeSavePanel.Mode.icon, .list, .column])
    func `nested folders below a shared ancestor are opened one level at a time`(
        mode: FakeSavePanel.Mode) async throws
    {
        let tree = try TemporaryFolderTree(["a/decoy", "a/b/c/d"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("a/decoy"), mode: mode)

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("a/b/c/d"), filename: "deep.txt"))

        #expect(panel.savedURL?.path == tree.url("a/b/c/d").appendingPathComponent("deep.txt").path)
        #expect(report.steps.filter { $0.hasPrefix("open:") || $0.hasPrefix("select:") }.count == 3)
    }

    @Test
    func `an unconfirmed selection stops before the default button can save into the wrong folder`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .icon)
        panel.unselectablePaths = [tree.url("run/exports").path]

        await #expect(throws: BackgroundFileDialogError.self) {
            try await BackgroundFileDialogNavigator(panel: panel).run(
                FileDialogDestination(directory: tree.url("run/exports"), filename: "q3.txt"))
        }
        #expect(panel.savedURL == nil)
        #expect(panel.isOpen)
        #expect(!panel.events.contains("press default"))
    }

    @Test
    func `a folder missing from the file list is reported without saving`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .list)
        panel.hiddenPaths = [tree.url("run/exports").path]

        do {
            _ = try await BackgroundFileDialogNavigator(panel: panel).run(
                FileDialogDestination(directory: tree.url("run/exports"), filename: "q3.txt"))
            Issue.record("expected the run to stop")
        } catch let error as BackgroundFileDialogError {
            #expect(error.kind == .folderUnreachable)
            #expect(error.message.contains(tree.url("run/exports").path))
        }
        #expect(panel.savedURL == nil)
    }

    @Test
    func `a folder that does not open stops the run instead of saving in the wrong folder`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .icon)
        panel.ignoresFolderOpen = true

        do {
            _ = try await BackgroundFileDialogNavigator(panel: panel, timeout: .milliseconds(200)).run(
                FileDialogDestination(directory: tree.url("run/exports"), filename: "q3.txt"))
            Issue.record("expected the run to stop")
        } catch let error as BackgroundFileDialogError {
            #expect(error.kind == .wrongFolder)
        }
        #expect(panel.savedURL == nil)
        #expect(panel.isOpen)
    }

    @Test
    func `a name the panel did not take is refused before saving`() async throws {
        let tree = try TemporaryFolderTree(["start"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("start"))
        panel.lockedName = "Untitled.txt"

        await #expect(throws: BackgroundFileDialogError.self) {
            try await BackgroundFileDialogNavigator(panel: panel).run(
                FileDialogDestination(directory: tree.url("start"), filename: "q3.txt"))
        }
        #expect(!panel.events.contains("press default"))
    }

    @Test
    func `a panel that stays open after saving is reported, not claimed as saved`() async throws {
        let tree = try TemporaryFolderTree(["start"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("start"))
        panel.staysOpenOnSave = true

        do {
            _ = try await BackgroundFileDialogNavigator(panel: panel, timeout: .milliseconds(200)).run(
                FileDialogDestination(directory: tree.url("start"), filename: "q3.txt"))
            Issue.record("expected the run to stop")
        } catch let error as BackgroundFileDialogError {
            #expect(error.kind == .panelStillOpen)
            #expect(error.changedPanel)
        }
    }
}
