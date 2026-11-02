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

/// Why a background file-dialog run stopped.
public struct BackgroundFileDialogError: Error, LocalizedError, Equatable {
    public enum Kind: Equatable, Sendable {
        /// The requested folder can't be reached through the panel's own controls.
        case folderUnreachable
        /// The panel did not confirm a selection, so the default button was not pressed.
        case selectionNotConfirmed
        /// The panel is not where it must be before saving.
        case wrongFolder
        /// The panel closed (saved) while a folder was being opened.
        case closedDuringNavigation
        /// The panel stayed open after the final default-button press.
        case panelStillOpen
    }

    public let kind: Kind
    public let message: String
    /// Whether the panel was changed before the run stopped (a folder or name may have changed).
    public let changedPanel: Bool

    public var errorDescription: String? {
        self.message
    }
}

/// Drives a file panel to a destination through accessibility only.
///
/// Navigation never types a path. The Where popup lists the current folder's ancestors, so the run first
/// moves up to the deepest ancestor shared with the destination, then opens each remaining folder from the
/// file list: in icon and list view a folder opens when it is selected and the default button is pressed, in
/// column view selecting it is enough. The default button is pressed only after the panel confirms the
/// selection, so a failed selection can never save into the wrong folder.
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
        if let directory = destination.directory {
            try await self.navigate(to: directory, steps: &steps)
        }
        try self.panel.pressDefaultButton()
        steps.append("default_button")
        try await self.waitUntil { try !self.panel.isPanelOpen() }
        let savedPath = destination.directory.flatMap { directory in
            destination.filename.map { directory.appendingPathComponent($0).path }
        }
        return BackgroundFileDialogReport(savedPath: savedPath, steps: steps)
    }

    // MARK: - Navigation

    private func navigate(to directory: URL, steps: inout [String]) async throws {
        let chain = Self.folderChain(to: directory)
        let names = chain.map(Self.displayName)
        let titles = try self.panel.openLocationMenu()
        guard let volumeIndex = titles.firstIndex(of: names[0]) else {
            try self.panel.cancelLocationMenu()
            throw self.failure(
                .folderUnreachable,
                "The panel's Where menu does not list the volume '\(names[0])' that holds \(directory.path).",
                changed: !steps.isEmpty)
        }
        let currentNames = Array(titles[0...volumeIndex].reversed())
        let shared = zip(currentNames, names).prefix { $0 == $1 }.count
        if shared == currentNames.count {
            try self.panel.cancelLocationMenu()
        } else {
            try self.panel.chooseLocationMenuItem(at: volumeIndex - (shared - 1))
            steps.append("where:\(names[shared - 1])")
        }
        for folder in chain[shared...] {
            try await self.open(folder, steps: &steps)
        }
    }

    private func open(_ folder: URL, steps: inout [String]) async throws {
        let name = Self.displayName(folder)
        guard let item = try self.panel.item(atPath: folder.path), item.isDirectory else {
            throw self.failure(
                .folderUnreachable,
                "The panel's file list does not show the folder \(folder.path).",
                changed: true)
        }
        guard try self.panel.select(item) else {
            throw self.failure(
                .selectionNotConfirmed,
                "The panel did not confirm the selection of \(folder.path); the default button was not pressed.",
                changed: true)
        }
        if try self.panel.currentFolderName() == name {
            steps.append("select:\(name)")
            return
        }
        try self.panel.pressDefaultButton()
        try await self.waitUntil {
            try !self.panel.isPanelOpen() || self.panel.currentFolderName() == name
        }
        guard try self.panel.isPanelOpen() else {
            throw self.failure(
                .closedDuringNavigation,
                "The panel closed while opening \(folder.path); it may have saved into the previous folder.",
                changed: true)
        }
        steps.append("open:\(name)")
    }

    // MARK: - Helpers

    /// The folders from the volume root down to `directory`, the way the panel's Where menu presents them.
    static func folderChain(to directory: URL) -> [URL] {
        let components = directory.standardizedFileURL.pathComponents
        let rootDepth = components.count > 2 && components[1] == "Volumes" ? 3 : 1
        var chain: [URL] = []
        var url = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(rootDepth))))
        chain.append(url)
        for component in components.dropFirst(rootDepth) {
            url.appendPathComponent(component, isDirectory: true)
            chain.append(url)
        }
        return chain
    }

    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    private func failure(
        _ kind: BackgroundFileDialogError.Kind,
        _ message: String,
        changed: Bool) -> BackgroundFileDialogError
    {
        BackgroundFileDialogError(kind: kind, message: message, changedPanel: changed)
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
