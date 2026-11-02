import ApplicationServices
import Foundation

/// `FileDialogPanelSurface` over a live NSOpenPanel/NSSavePanel accessibility tree.
///
/// On macOS 27 every Open and Save panel is served by `com.apple.appkit.xpc.openAndSavePanelService`, and its
/// tree is reachable through the host app's window (sheet) or panel. Every call here is an accessibility
/// read, an attribute write or an AX action: AXPress on the Where popup, its menu items and the default button;
/// AXSelected/AXSelectedChildren on file-list entries; AXValue on the name field and on scroll bars. None of
/// them activated the host app in testing. AXOpen on a file-list entry did activate it and is never used.
@MainActor
final class AXFileDialogPanelSurface: FileDialogPanelSurface {
    private enum Identifier {
        static let wherePopup = "where popup"
        static let nameField = "saveAsNameTextField"
        static let defaultButton = "OKButton"
    }

    private let panel: AXUIElement
    private var openMenuItems: [AXUIElement] = []
    private var openMenu: AXUIElement?
    private let maximumNodes = 6000

    init(panel: AXUIElement) {
        self.panel = panel
    }

    // MARK: Where popup

    func currentFolderName() throws -> String? {
        guard let popup = self.firstDescendant(where: { self.identifier($0) == Identifier.wherePopup }) else {
            return nil
        }
        return self.stringValue(popup, kAXValueAttribute)
    }

    func openLocationMenu() throws -> [String] {
        guard let popup = self.firstDescendant(where: { self.identifier($0) == Identifier.wherePopup }) else {
            throw AXFileDialogPanelSurfaceError("The panel has no Where popup (collapse or expand it and retry).")
        }
        try self.perform(kAXPressAction, on: popup, what: "open the Where popup")
        var menu: AXUIElement?
        for _ in 0..<40 {
            menu = self.children(popup).first { self.role($0) == kAXMenuRole }
            if menu != nil { break }
            usleep(25000)
        }
        guard let menu else {
            throw AXFileDialogPanelSurfaceError("The Where popup did not expose its menu.")
        }
        // Location items run from the current folder up to the computer and end at the first separator.
        let items = self.children(menu).filter { self.role($0) == kAXMenuItemRole }
        var locations: [AXUIElement] = []
        for item in items {
            let title = self.stringValue(item, kAXTitleAttribute) ?? ""
            if title.isEmpty { break }
            locations.append(item)
        }
        self.openMenu = menu
        self.openMenuItems = locations
        return locations.map { self.stringValue($0, kAXTitleAttribute) ?? "" }
    }

    func chooseLocationMenuItem(at index: Int) throws {
        guard self.openMenuItems.indices.contains(index) else {
            try self.cancelLocationMenu()
            throw AXFileDialogPanelSurfaceError("The Where menu has no location at position \(index).")
        }
        let item = self.openMenuItems[index]
        self.openMenu = nil
        self.openMenuItems = []
        try self.perform(kAXPressAction, on: item, what: "choose a Where location")
    }

    func cancelLocationMenu() throws {
        defer {
            self.openMenu = nil
            self.openMenuItems = []
        }
        guard let menu = self.openMenu else { return }
        try self.perform(kAXCancelAction, on: menu, what: "close the Where menu")
    }

    // MARK: File list

    func item(atPath path: String) throws -> FileDialogPanelItem? {
        let wanted = Self.normalized(path)
        if let found = self.fileListEntry(matching: wanted) {
            return found.item
        }
        // Icon view only realizes the visible items: step through each scrollable file list and look again.
        for scrollBar in self.fileListScrollBars() {
            for step in 0...20 {
                _ = AXUIElementSetAttributeValue(
                    scrollBar, kAXValueAttribute as CFString, NSNumber(value: Double(step) / 20.0))
                if let found = self.fileListEntry(matching: wanted) {
                    return found.item
                }
            }
        }
        return nil
    }

    func select(_ item: FileDialogPanelItem) throws -> Bool {
        guard let entry = self.fileListEntry(matching: Self.normalized(item.path)) else { return false }
        if let row = self.ancestor(of: entry.element, where: { self.role($0) == kAXRowRole }) {
            guard AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
            else { return false }
            return (self.attribute(row, kAXSelectedAttribute) as? Bool) == true
        }
        guard let (container, child) = self.selectableChild(containing: entry.element) else { return false }
        guard AXUIElementSetAttributeValue(
            container, kAXSelectedChildrenAttribute as CFString, [child] as CFArray) == .success
        else { return false }
        let selected = (self.attribute(container, kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
        return (selected.count == 1 && CFEqual(selected[0], child)) ||
            (self.attribute(entry.element, kAXSelectedAttribute) as? Bool) == true
    }

    // MARK: Name and buttons

    func filename() throws -> String? {
        self.nameField().flatMap { self.stringValue($0, kAXValueAttribute) }
    }

    func setFilename(_ name: String) throws {
        guard let field = self.nameField() else {
            throw AXFileDialogPanelSurfaceError("The panel has no Save As name field.")
        }
        let status = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFString)
        guard status == .success else {
            throw AXFileDialogPanelSurfaceError("Setting the Save As name failed (AXError \(status.rawValue)).")
        }
    }

    func pressDefaultButton() throws {
        let button = self.firstDescendant(where: { self.identifier($0) == Identifier.defaultButton })
            ?? self.elementAttribute(self.panel, kAXDefaultButtonAttribute)
        guard let button else {
            throw AXFileDialogPanelSurfaceError("The panel has no default (Save/Open) button.")
        }
        try self.perform(kAXPressAction, on: button, what: "press the panel's default button")
    }

    func isPanelOpen() throws -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(self.panel, kAXRoleAttribute as CFString, &value)
        return status == .success
    }

    // MARK: - Tree helpers

    private struct Entry {
        let element: AXUIElement
        let item: FileDialogPanelItem
    }

    private func nameField() -> AXUIElement? {
        self.firstDescendant(where: { self.identifier($0) == Identifier.nameField })
    }

    /// File-list entries carry their file as AXURL (a file reference URL); the sidebar's entries do not.
    private func fileListEntry(matching path: String) -> Entry? {
        var match: Entry?
        self.walk { element in
            guard let url = self.attribute(element, kAXURLAttribute) as? URL,
                  let resolved = (url as NSURL).filePathURL,
                  Self.normalized(resolved.path) == path
            else { return true }
            let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            match = Entry(element: element, item: FileDialogPanelItem(path: path, isDirectory: isDirectory))
            return false
        }
        return match
    }

    /// The vertical scroll bars of scroll areas that hold file-list entries.
    private func fileListScrollBars() -> [AXUIElement] {
        var bars: [AXUIElement] = []
        self.walk { element in
            guard self.role(element) == kAXScrollAreaRole,
                  let bar = self.elementAttribute(element, kAXVerticalScrollBarAttribute),
                  self.containsFileEntry(element)
            else { return true }
            bars.append(bar)
            return true
        }
        return bars
    }

    private func containsFileEntry(_ root: AXUIElement) -> Bool {
        var found = false
        self.walk(from: root) { element in
            if self.attribute(element, kAXURLAttribute) is URL {
                found = true
                return false
            }
            return true
        }
        return found
    }

    /// The child of a list-like container that holds `element`, for AXSelectedChildren selection.
    private func selectableChild(containing element: AXUIElement) -> (AXUIElement, AXUIElement)? {
        var child = element
        var parent = self.parent(of: element)
        while let current = parent {
            if [kAXListRole, kAXOutlineRole, kAXTableRole].contains(self.role(current) ?? "") {
                // Icon view nests items in an AXSectionList; only the enclosing collection takes a selection.
                if self.stringValue(current, kAXSubroleAttribute) == "AXSectionList",
                   let collection = self.parent(of: current),
                   self.role(collection) == kAXListRole
                {
                    return (collection, child)
                }
                return (current, child)
            }
            if CFEqual(current, self.panel) { return nil }
            child = current
            parent = self.parent(of: current)
        }
        return nil
    }

    private func ancestor(of element: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var current = self.parent(of: element)
        while let node = current, !CFEqual(node, self.panel) {
            if matches(node) { return node }
            current = self.parent(of: node)
        }
        return nil
    }

    private func firstDescendant(where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var found: AXUIElement?
        self.walk { element in
            if matches(element) {
                found = element
                return false
            }
            return true
        }
        return found
    }

    /// Depth-first walk from the panel; `visit` returns false to stop.
    private func walk(from root: AXUIElement? = nil, _ visit: (AXUIElement) -> Bool) {
        var stack = [root ?? self.panel]
        var count = 0
        while let element = stack.popLast(), count < self.maximumNodes {
            count += 1
            guard visit(element) else { return }
            stack.append(contentsOf: self.children(element).reversed())
        }
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (self.attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        self.elementAttribute(element, kAXParentAttribute)
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = self.attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private func role(_ element: AXUIElement) -> String? {
        self.stringValue(element, kAXRoleAttribute)
    }

    private func identifier(_ element: AXUIElement) -> String? {
        self.stringValue(element, kAXIdentifierAttribute)
    }

    private func stringValue(_ element: AXUIElement, _ name: String) -> String? {
        self.attribute(element, name) as? String
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func perform(_ action: String, on element: AXUIElement, what: String) throws {
        let status = AXUIElementPerformAction(element, action as CFString)
        guard status == .success else {
            throw AXFileDialogPanelSurfaceError("Could not \(what) (AXError \(status.rawValue)).")
        }
    }

    private static func normalized(_ path: String) -> String {
        FileDialogDestination.canonicalPath(path)
    }
}

struct AXFileDialogPanelSurfaceError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}
