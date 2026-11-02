import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundFileDialogNavigatorTests {
    @Test
    func `saving into the current folder names the file and saves without opening the Where menu`() async throws {
        let tree = try TemporaryFolderTree(["start"])
        defer { tree.remove() }
        let panel = FakeSavePanel(directory: tree.url("start"))

        let report = try await BackgroundFileDialogNavigator(panel: panel).run(
            FileDialogDestination(directory: tree.url("start"), filename: "q3.txt"))

        #expect(panel.savedURL?.path == tree.url("start").appendingPathComponent("q3.txt").path)
        #expect(report.savedPath == panel.savedURL?.path)
        #expect(!panel.events.contains("menu.open"))
    }
}
