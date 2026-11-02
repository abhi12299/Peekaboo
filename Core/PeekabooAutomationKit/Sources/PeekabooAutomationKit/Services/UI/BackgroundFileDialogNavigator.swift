import Foundation
import PeekabooFoundation

/// One entry in a file panel's file list.
public struct FileDialogPanelItem: Equatable, Sendable {
    /// The item's resolved file-system path.
    public let path: String
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

/// The parts of an Open or Save panel that background navigation uses. Every call must work through
/// accessibility alone: no key events, no pointer events and no activation of the panel's app.
@MainActor
public protocol FileDialogPanelSurface: AnyObject {
    /// The display name of the panel's current folder (the Where popup's value).
    func currentFolderName() throws -> String?
    /// Opens the Where popup and returns its location titles: the current folder first, then each ancestor up
    /// to the volume, then the computer. The menu stays open until an item is chosen or the menu is cancelled.
    func openLocationMenu() throws -> [String]
    func chooseLocationMenuItem(at index: Int) throws
    func cancelLocationMenu() throws
    /// The file-list entry for `path`, revealing it first if the list only realizes visible items.
    func item(atPath path: String) throws -> FileDialogPanelItem?
    /// Selects one file-list entry. Returns true only when the panel reports the entry as selected.
    func select(_ item: FileDialogPanelItem) throws -> Bool
    func filename() throws -> String?
    func setFilename(_ name: String) throws
    /// Presses the panel's default button (Save or Open) through accessibility.
    func pressDefaultButton() throws
    func isPanelOpen() throws -> Bool
}

/// What a background file-dialog run did.
public struct BackgroundFileDialogReport: Equatable, Sendable {
    public let savedPath: String?
    public let steps: [String]
}

/// Drives a file panel to a destination through accessibility only.
@MainActor
public struct BackgroundFileDialogNavigator {
    private let panel: any FileDialogPanelSurface
    private let timeout: Duration
    private let pollInterval: Duration

    public init(
        panel: any FileDialogPanelSurface,
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(50))
    {
        self.panel = panel
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    public func run(_ destination: FileDialogDestination) async throws -> BackgroundFileDialogReport {
        var steps: [String] = []
        if let filename = destination.filename {
            try self.panel.setFilename(filename)
            steps.append("name")
        }
        try self.panel.pressDefaultButton()
        steps.append("default_button")
        try await self.waitUntil { try !self.panel.isPanelOpen() }
        let savedPath = destination.directory.flatMap { directory in
            destination.filename.map { directory.appendingPathComponent($0).path }
        }
        return BackgroundFileDialogReport(savedPath: savedPath, steps: steps)
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws {
        var elapsed = Duration.zero
        while try !condition() {
            guard elapsed < self.timeout else { return }
            try await Task.sleep(for: self.pollInterval)
            elapsed += self.pollInterval
        }
    }
}
