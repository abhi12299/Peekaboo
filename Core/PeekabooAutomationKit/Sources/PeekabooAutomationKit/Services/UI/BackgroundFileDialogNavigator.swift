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
    /// Save panels: where the file was saved (nil when the panel's folder could not be mapped to a path).
    public let savedPath: String?
    /// Open panels: the file or folder the panel was confirmed with.
    public let openedPath: String?
    public let steps: [String]

    public init(savedPath: String?, openedPath: String? = nil, steps: [String]) {
        self.savedPath = savedPath
        self.openedPath = openedPath
        self.steps = steps
    }
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
        /// The name field does not hold the requested file name.
        case nameNotTaken
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
        // An Open panel has no name field; its file is selected in the list instead.
        let isSavePanel = try self.panel.filename() != nil
        // Plan before changing anything: a folder the panel can't reach is refused with the panel untouched.
        let plan = try destination.directory.map { try self.plan(to: $0) }
        if isSavePanel, let filename = destination.filename {
            try self.panel.setFilename(filename)
            steps.append("name")
        }
        if let plan, let directory = destination.directory {
            try await self.navigate(plan, steps: &steps)
            try self.requireCurrentFolder(directory)
        }
        // Report where the file goes even when the request left the folder or the name to the panel.
        let folder = try destination.directory ?? self.currentDirectory()
        var openedPath: String?
        if isSavePanel {
            if let filename = destination.filename {
                let current = try self.panel.filename()
                guard current == filename else {
                    throw self.failure(
                        .nameNotTaken,
                        "The panel's name field shows '\(current ?? "")' instead of '\(filename)'; nothing was saved.",
                        changed: true)
                }
            }
        } else if let filename = destination.filename {
            let file = try self.folderOrThrow(folder, for: filename).appendingPathComponent(filename)
            try await self.selectEntry(file)
            steps.append("select:\(filename)")
            openedPath = file.path
        } else {
            openedPath = folder?.path
        }
        let savedName = isSavePanel ? try destination.filename ?? self.panel.filename() : nil
        try self.panel.pressDefaultButton()
        steps.append("default_button")
        try await self.waitUntil { try !self.panel.isPanelOpen() }
        guard try !self.panel.isPanelOpen() else {
            throw self.failure(
                .panelStillOpen,
                "The panel is still open after its default button was pressed; it may be showing a " +
                    "confirmation such as Replace. Inspect it with dialog list.",
                changed: true)
        }
        let savedPath = folder.flatMap { directory in
            savedName.flatMap { $0.isEmpty ? nil : directory.appendingPathComponent($0).path }
        }
        return BackgroundFileDialogReport(savedPath: savedPath, openedPath: openedPath, steps: steps)
    }

    private func folderOrThrow(_ folder: URL?, for filename: String) throws -> URL {
        guard let folder else {
            throw self.failure(
                .folderUnreachable,
                "The Open panel's current folder could not be mapped to a path; pass path to choose \(filename).",
                changed: false)
        }
        return folder
    }

    /// Selects one file-list entry, retrying while the list reloads; throws when the panel never confirms it.
    private func selectEntry(_ url: URL) async throws {
        var selected = false
        try await self.waitUntil {
            if let item = try self.panel.item(atPath: url.path) {
                selected = try self.panel.select(item)
            }
            return selected
        }
        guard selected else {
            throw self.failure(
                .selectionNotConfirmed,
                "The panel did not show or confirm the selection of \(url.path); the default button was not pressed.",
                changed: true)
        }
    }

    // MARK: - Navigation

    private struct Plan {
        let chain: [URL]
        let names: [String]
        /// Index of the Where-menu location to choose, or nil when the panel is already on the way down.
        let menuIndex: Int?
        let shared: Int
    }

    /// Reads the Where menu (leaving it open when a location must be chosen) and works out the moves.
    private func plan(to directory: URL) throws -> Plan {
        let chain = Self.folderChain(to: directory)
        let names = chain.map(Self.displayName)
        let titles = try self.panel.openLocationMenu()
        guard let volumeIndex = titles.firstIndex(of: names[0]) else {
            try self.panel.cancelLocationMenu()
            throw self.failure(
                .folderUnreachable,
                "The panel's Where menu does not list the volume '\(names[0])' that holds \(directory.path).",
                changed: false)
        }
        let currentNames = Array(titles[0...volumeIndex].reversed())
        let shared = zip(currentNames, names).prefix { $0 == $1 }.count
        if let hidden = chain[shared...].first(where: Self.isHidden) {
            try self.panel.cancelLocationMenu()
            throw self.failure(
                .folderUnreachable,
                "\(directory.path) is inside the hidden folder \(hidden.path), which Open and Save panels don't " +
                    "list. Choose a folder outside it; nothing was changed.",
                changed: false)
        }
        if shared == currentNames.count {
            try self.panel.cancelLocationMenu()
            return Plan(chain: chain, names: names, menuIndex: nil, shared: shared)
        }
        return Plan(chain: chain, names: names, menuIndex: volumeIndex - (shared - 1), shared: shared)
    }

    private func navigate(_ plan: Plan, steps: inout [String]) async throws {
        if let menuIndex = plan.menuIndex {
            try self.panel.chooseLocationMenuItem(at: menuIndex)
            let name = plan.names[plan.shared - 1]
            try await self.waitUntil { try self.panel.currentFolderName() == name }
            try self.requireCurrentFolder(plan.chain[plan.shared - 1])
            steps.append("where:\(name)")
        }
        for folder in plan.chain[plan.shared...] {
            try await self.open(folder, steps: &steps)
        }
    }

    private func open(_ folder: URL, steps: inout [String]) async throws {
        let name = Self.displayName(folder)
        // The file list reloads asynchronously after the folder changes.
        var found = try self.panel.item(atPath: folder.path)
        try await self.waitUntil {
            if found == nil { found = try self.panel.item(atPath: folder.path) }
            return found != nil
        }
        guard let item = found, item.isDirectory else {
            throw self.failure(
                .folderUnreachable,
                "The panel's file list does not show the folder \(folder.path).",
                changed: true)
        }
        // A column that has just appeared may ignore the first selection; look the entry up again and retry.
        var selected = try self.panel.select(item)
        try await self.waitUntil {
            if !selected, let current = try self.panel.item(atPath: folder.path), current.isDirectory {
                selected = try self.panel.select(current)
            }
            return selected
        }
        guard selected else {
            throw self.failure(
                .selectionNotConfirmed,
                "The panel did not confirm the selection of \(folder.path); the default button was not pressed.",
                changed: true)
        }
        if try self.panelIsAt(folder) {
            steps.append("select:\(name)")
            return
        }
        try self.panel.pressDefaultButton()
        if Self.sharesNameWithParent(folder) {
            // The Where value can't show the move; the folder's own entry leaves the list once it is open.
            try await self.waitUntil {
                try !self.panel.isPanelOpen() || self.panel.item(atPath: folder.path) == nil
            }
        } else {
            try await self.waitUntil {
                try !self.panel.isPanelOpen() || self.panel.currentFolderName() == name
            }
        }
        guard try self.panel.isPanelOpen() else {
            throw self.failure(
                .closedDuringNavigation,
                "The panel closed while opening \(folder.path); it may have saved into the previous folder.",
                changed: true)
        }
        try self.requireCurrentFolder(folder)
        steps.append("open:\(name)")
    }

    // MARK: - Helpers

    /// The panel's current folder as a path, rebuilt from the Where menu's titles by matching display names one
    /// level at a time from the volume root. Nil when a title matches no folder.
    private func currentDirectory() throws -> URL? {
        let titles = try self.panel.openLocationMenu()
        try self.panel.cancelLocationMenu()
        let fileManager = FileManager.default
        var roots: [(index: Int, url: URL)] = []
        if let index = titles.firstIndex(of: Self.displayName(URL(fileURLWithPath: "/"))) {
            roots.append((index, URL(fileURLWithPath: "/")))
        }
        for (index, title) in titles.enumerated() {
            let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(title, isDirectory: true)
            if fileManager.fileExists(atPath: volume.path) { roots.append((index, volume)) }
        }
        guard let root = roots.min(by: { $0.index < $1.index }) else { return nil }
        var current = root.url
        for title in titles[0..<root.index].reversed() {
            let children = (try? fileManager.contentsOfDirectory(
                at: current, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            guard let child = children.first(where: { child in
                (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true &&
                    Self.displayName(child) == title
            }) else { return nil }
            current = URL(fileURLWithPath: child.path, isDirectory: true)
        }
        return current
    }

    /// Whether the panel shows `folder`. The Where value is a display name; when the folder and its parent share
    /// it, the Where menu's full ancestry decides (one brief menu).
    private func panelIsAt(_ folder: URL) throws -> Bool {
        guard try self.panel.currentFolderName() == Self.displayName(folder) else { return false }
        guard Self.sharesNameWithParent(folder) else { return true }
        let titles = try self.panel.openLocationMenu()
        try self.panel.cancelLocationMenu()
        let names = Self.folderChain(to: folder).map(Self.displayName)
        guard let volumeIndex = titles.firstIndex(of: names[0]) else { return false }
        return Array(titles[0...volumeIndex].reversed()) == names
    }

    static func sharesNameWithParent(_ folder: URL) -> Bool {
        folder.path != "/" && self.displayName(folder) == self.displayName(folder.deletingLastPathComponent())
    }

    private func requireCurrentFolder(_ folder: URL) throws {
        let current = try self.panel.currentFolderName()
        guard try self.panelIsAt(folder) else {
            throw self.failure(
                .wrongFolder,
                "The panel shows the folder '\(current ?? "unknown")' instead of \(folder.path); nothing was saved.",
                changed: true)
        }
    }

    /// The folders from the volume root down to `directory`, the way the panel's Where menu presents them.
    static func folderChain(to directory: URL) -> [URL] {
        // Not standardizedFileURL: it rewrites /private/var to /var, but the panel shows the real path.
        let components = (directory.path as NSString).pathComponents
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

    static func isHidden(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".") ||
            (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
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
