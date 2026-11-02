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
}
