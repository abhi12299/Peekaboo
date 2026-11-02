import Foundation
@testable import PeekabooAutomationKit

/// A Save panel model over a real temporary folder tree. It reproduces what the macOS 27 Open and Save Panel
/// Service did when driven through accessibility (BenchFixture probe, 2026-11-02):
/// - the Where popup lists the current folder, its ancestors up to the volume, then the computer;
/// - in icon and list view, selecting a folder and pressing the default button opens that folder;
/// - in column view, selecting a folder makes it the destination at once;
/// - the default button is disabled while the name field is empty;
/// - pressing it with no folder selected saves `directory/name` and closes the panel.
@MainActor
final class FakeSavePanel: FileDialogPanelSurface {
    enum Mode { case icon, list, column }

    static let computerName = "Test Mac"

    var directory: URL {
        didSet { self.lookupsSinceFolderChange = 0 }
    }

    var name: String
    var mode: Mode
    private(set) var savedURL: URL?
    private(set) var isOpen = true
    private(set) var events: [String] = []
    private var selected: URL?
    private var menuOpen = false
    /// Items the panel refuses to select (selection silently does nothing).
    var unselectablePaths: Set<String> = []
    /// How many selections are ignored before the panel takes one (a column that is still loading).
    var ignoredSelections = 0
    /// Items the list does not expose at all.
    var hiddenPaths: Set<String> = []
    /// How many file-list lookups return nothing after the folder changes (the list reloads asynchronously).
    var listReloadLookups = 0
    private var lookupsSinceFolderChange = 0
    /// When true, pressing the default button with a folder selected does nothing.
    var ignoresFolderOpen = false
    /// When true, the final save leaves the panel open (as a "Replace?" alert would).
    var staysOpenOnSave = false
    /// When set, the name field ignores writes and keeps this value.
    var lockedName: String?

    init(directory: URL, name: String = "Untitled.txt", mode: Mode = .icon) {
        self.directory = directory
        self.name = name
        self.mode = mode
    }

    private var ancestors: [URL] {
        var chain: [URL] = []
        var current = self.directory
        while true {
            chain.append(current)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return chain
    }

    func currentFolderName() throws -> String? {
        FileManager.default.displayName(atPath: self.directory.path)
    }

    func openLocationMenu() throws -> [String] {
        self.events.append("menu.open")
        self.menuOpen = true
        return self.ancestors.map { FileManager.default.displayName(atPath: $0.path) } + [Self.computerName]
    }

    func chooseLocationMenuItem(at index: Int) throws {
        precondition(self.menuOpen)
        self.menuOpen = false
        let ancestors = self.ancestors
        guard index < ancestors.count else { throw FakePanelError.unsupported }
        self.events.append("menu.choose \(index)")
        self.directory = ancestors[index]
        self.selected = nil
    }

    func cancelLocationMenu() throws {
        self.menuOpen = false
        self.events.append("menu.cancel")
    }

    func item(atPath path: String) throws -> FileDialogPanelItem? {
        guard !self.hiddenPaths.contains(path) else { return nil }
        self.lookupsSinceFolderChange += 1
        guard self.lookupsSinceFolderChange > self.listReloadLookups else { return nil }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard url.deletingLastPathComponent().path == self.directory.path,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return nil }
        return FileDialogPanelItem(path: path, isDirectory: isDirectory.boolValue)
    }

    func select(_ item: FileDialogPanelItem) throws -> Bool {
        self.events.append("select \(URL(fileURLWithPath: item.path).lastPathComponent)")
        guard !self.unselectablePaths.contains(item.path) else { return false }
        if self.ignoredSelections > 0 {
            self.ignoredSelections -= 1
            return false
        }
        if self.mode == .column, item.isDirectory {
            self.directory = URL(fileURLWithPath: item.path)
            self.selected = nil
        } else {
            self.selected = URL(fileURLWithPath: item.path)
        }
        return true
    }

    func filename() throws -> String? {
        self.name
    }

    func setFilename(_ name: String) throws {
        self.events.append("name \(name)")
        self.name = self.lockedName ?? name
    }

    func pressDefaultButton() throws {
        self.events.append("press default")
        guard !self.name.isEmpty else { return }
        if let selected = self.selected, (try? selected.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if self.ignoresFolderOpen { return }
            self.directory = selected
            self.selected = nil
            return
        }
        if self.staysOpenOnSave { return }
        let url = self.directory.appendingPathComponent(self.name)
        FileManager.default.createFile(atPath: url.path, contents: Data("saved".utf8))
        self.savedURL = url
        self.isOpen = false
    }

    func isPanelOpen() throws -> Bool {
        self.isOpen
    }

    enum FakePanelError: Error { case unsupported }
}

/// A private folder tree under the temporary directory, removed by the caller.
struct TemporaryFolderTree {
    let root: URL

    init(_ relativeFolders: [String]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-dialog-tree-\(UUID().uuidString)", isDirectory: true)
        for folder in relativeFolders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Real path, as the panel shows it: /var/folders/... is /private/var/folders/...
        guard let resolved = realpath(root.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        self.root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func url(_ relative: String) -> URL {
        self.root.appendingPathComponent(relative, isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
