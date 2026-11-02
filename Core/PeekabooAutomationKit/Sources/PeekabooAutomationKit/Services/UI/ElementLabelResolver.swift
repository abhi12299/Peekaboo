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
    private static func isTextContainerRole(_ role: String) -> Bool {
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
