import Foundation

@_spi(Testing) public struct ElementLabelInfo: Sendable {
    public let role: String
    public let label: String?
    public let title: String?
    public let value: String?
    public let roleDescription: String?
    public let description: String?
    public let identifier: String?
    public let placeholder: String?

    public init(
        role: String,
        label: String?,
        title: String?,
        value: String?,
        roleDescription: String?,
        description: String?,
        identifier: String?,
        placeholder: String?)
    {
        self.role = role
        self.label = label
        self.title = title
        self.value = value
        self.roleDescription = roleDescription
        self.description = description
        self.identifier = identifier
        self.placeholder = placeholder
    }
}

@_spi(Testing) public enum ElementLabelResolver {
    @_spi(Testing) public static func resolve(
        info: ElementLabelInfo,
        childTexts: [String],
        identifierCleaner: (String) -> String)
        -> String?
    {
        if self.isTextContainerRole(info.role) {
            return self.textContainerLabel(info: info, childTexts: childTexts)
        }

        let baseLabel = ElementLabelResolver.firstNonGeneric(
            candidates: [
                info.label,
                info.title,
                info.description,
                info.placeholder,
                info.value,
                info.roleDescription,
            ])

        guard info.role.lowercased() == "axbutton" else {
            return baseLabel
        }

        if let baseLabel {
            return baseLabel
        }

        if let child = childTexts.compactMap(ElementLabelResolver.normalize).first {
            return child
        }

        if let identifier = info.identifier,
           let normalized = ElementLabelResolver.normalize(identifier)
        {
            return identifierCleaner(normalized)
        }

        return nil
    }

    @_spi(Testing) public static func needsChildTexts(info: ElementLabelInfo) -> Bool {
        if self.isTextContainerRole(info.role) {
            return self.ownTextContainerLabel(info: info) == nil
        }
        guard info.role.lowercased() == "axbutton" else {
            return false
        }

        let baseLabel = ElementLabelResolver.firstNonGeneric(
            candidates: [
                info.label,
                info.title,
                info.description,
                info.placeholder,
                info.value,
                info.roleDescription,
            ])
        guard baseLabel == nil else {
            return false
        }

        return true
    }

    /// Table cells carry no text of their own; their content lives in static-text descendants.
    /// Chromium clips those descendants to the viewport, so below the fold the cell is the only
    /// published node that can hold the text.
    static func isTextContainerRole(_ role: String) -> Bool {
        role.lowercased() == "axcell"
    }

    /// A cell's role description ("cell") names the role, not the content, so it never labels the cell.
    private static func ownTextContainerLabel(info: ElementLabelInfo) -> String? {
        self.firstNonGeneric(candidates: [info.label, info.title, info.description, info.value])
    }

    private static func textContainerLabel(info: ElementLabelInfo, childTexts: [String]) -> String? {
        if let ownLabel = self.ownTextContainerLabel(info: info) {
            return ownLabel
        }
        let texts = childTexts.compactMap(self.normalize)
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private static func firstNonGeneric(candidates: [String?]) -> String? {
        for candidate in candidates {
            if let normalized = self.normalize(candidate), normalized.lowercased() != "button" {
                return normalized
            }
        }
        return nil
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The role and text of one descendant considered for a parent's label.
@_spi(Testing) public struct AXTextualNode: Sendable, Equatable {
    public let role: String
    public let text: String?

    public init(role: String, text: String?) {
        self.role = role
        self.text = text
    }

    /// The first candidate with visible characters. Chromium answers AXTitle "" (not unsupported) on
    /// static text whose words are in AXValue, so an empty string must not end the search.
    public static func firstNonBlank(_ candidates: [String?]) -> String? {
        candidates.lazy
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension ElementLabelResolver {
    /// Descendant roles whose text may label an unlabeled button.
    private static let buttonChildTextRoles: Set<String> = [
        "axstatictext", "axtext", "axbutton", "axlink", "axdescription", "axunknown",
    ]
    /// Descendant roles whose text labels a cell. Static text only, so a cell holding a control
    /// is not named after the control.
    private static let textContainerChildTextRoles: Set<String> = ["axstatictext"]

    /// Every role whose text any parent may borrow. Readers use it to skip text reads for other roles.
    @_spi(Testing) public static let childTextRoles: Set<String> =
        buttonChildTextRoles.union(textContainerChildTextRoles)

    /// Descendants examined per label. A label needs a few words, not the subtree: a cell holding a
    /// large widget and no text must not turn into a second tree walk.
    @_spi(Testing) public static let childTextNodeBudget = 64

    /// Collects up to `limit` texts from the descendants of `root`, depth-first and at most `maxDepth`
    /// levels down, from the roles that may label a node with `parentRole`.
    ///
    /// Frames are deliberately not consulted: a descendant Chromium clipped out of the viewport still
    /// carries its text. The walk reads each node once, examines at most `childTextNodeBudget` nodes,
    /// and stops as soon as `shouldContinue` says so (the caller's deadline).
    @_spi(Testing) public static func childTexts<Node: Hashable>(
        of root: Node,
        parentRole: String,
        maxDepth: Int = 3,
        limit: Int = 4,
        children: (Node) -> [Node],
        textualNode: (Node) -> AXTextualNode?,
        shouldContinue: () -> Bool = { true }) -> [String]
    {
        let roles = self.isTextContainerRole(parentRole)
            ? self.textContainerChildTextRoles
            : self.buttonChildTextRoles
        var results: [String] = []
        var seen: Set<Node> = [root]
        func canContinue() -> Bool {
            results.count < limit && seen.count <= self.childTextNodeBudget && !Task.isCancelled && shouldContinue()
        }
        func visit(_ node: Node, depth: Int) {
            guard depth < maxDepth, canContinue() else { return }
            for child in children(node) {
                guard canContinue() else { return }
                guard seen.insert(child).inserted else { continue }
                if let textual = textualNode(child),
                   roles.contains(textual.role.lowercased()),
                   let text = self.normalize(textual.text)
                {
                    results.append(text)
                }
                guard results.count < limit else { return }
                visit(child, depth: depth + 1)
                guard results.count < limit else { return }
            }
        }
        visit(root, depth: 0)
        return results
    }
}
