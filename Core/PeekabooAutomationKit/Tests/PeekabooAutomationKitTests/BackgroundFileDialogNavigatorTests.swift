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
            Issue.record("expected the run to stop \(panel.events)")
        } catch let error as BackgroundFileDialogError {
            #expect(error.kind == .folderUnreachable, "\(panel.events) \(error)")
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

    @Test
    func `the file list may fill in after the folder changes`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports/inner"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .list)
        panel.listReloadLookups = 3

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("run/exports/inner"), filename: "q3.txt"))

        #expect(report.savedPath == tree.url("run/exports/inner").appendingPathComponent("q3.txt").path)
    }

    @Test
    func `a selection the panel takes only on a later try still opens the folder`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .column)
        panel.ignoredSelections = 2

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("run/exports"), filename: "q3.txt"))

        #expect(report.savedPath == tree.url("run/exports").appendingPathComponent("q3.txt").path)
    }

    @Test
    func `a destination inside a hidden folder is refused before the panel changes`() async throws {
        // Open and Save panels do not list hidden folders such as /private or dot-folders, so they can't be
        // opened from the file list.
        let tree = try TemporaryFolderTree(["a/start", "b/.hidden/target"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("a/start"), mode: .icon)

        do {
            _ = try await BackgroundFileDialogNavigator(panel: panel).run(
                FileDialogDestination(directory: tree.url("b/.hidden/target"), filename: "q3.txt"))
            Issue.record("expected a refusal")
        } catch let error as BackgroundFileDialogError {
            #expect(error.kind == .folderUnreachable)
            #expect(!error.changedPanel)
            #expect(error.message.contains(".hidden"))
        }
        #expect(!panel.events.contains { $0.hasPrefix("menu.choose") || $0.hasPrefix("name") })
        #expect(panel.directory.path == tree.url("a/start").path)
    }

    @Test(arguments: [FakeSavePanel.Mode.icon, .column])
    func `a child folder with its parent's name is opened, not mistaken for the parent`(
        mode: FakeSavePanel.Mode) async throws
    {
        let tree = try TemporaryFolderTree(["x/rep/rep"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("x/rep"), mode: mode)

        let report = try await BackgroundFileDialogNavigator(panel: panel, timeout: .milliseconds(300)).run(
            FileDialogDestination(directory: tree.url("x/rep/rep"), filename: "q3.txt"))

        #expect(report.savedPath == tree.url("x/rep/rep").appendingPathComponent("q3.txt").path)
        #expect(panel.savedURL?.path == report.savedPath)
    }

    @Test
    func `a folder-only save reports the path from the panel's own name`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/exports"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), name: "report.txt")

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("run/exports"), filename: nil))

        #expect(report.savedPath == tree.url("run/exports").appendingPathComponent("report.txt").path)
        #expect(panel.savedURL?.path == report.savedPath)
    }

    @Test
    func `a name-only save reports the path in the panel's current folder`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("run/decoy"))

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: nil, filename: "q3.txt"))

        #expect(report.savedPath == tree.url("run/decoy").appendingPathComponent("q3.txt").path)
        #expect(panel.savedURL?.path == report.savedPath)
        #expect(!panel.events.contains { $0.hasPrefix("menu.choose") })
    }

    @Test
    func `an Open panel goes to the folder, selects the file and opens it`() async throws {
        let tree = try TemporaryFolderTree(["run/decoy", "run/docs"])
        defer { tree.remove() }
        let file = tree.url("run/docs").appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let panel = FakeSavePanel(directory: tree.url("run/decoy"), mode: .list)
        panel.isOpenPanel = true

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("run/docs"), filename: "notes.txt"))

        #expect(panel.openedURL?.path == file.path)
        #expect(report.openedPath == file.path)
        #expect(report.savedPath == nil)
        #expect(!panel.events.contains { $0.hasPrefix("name") })
    }
}
