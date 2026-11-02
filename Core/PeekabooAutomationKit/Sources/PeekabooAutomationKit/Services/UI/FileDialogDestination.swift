import Foundation
import PeekabooFoundation

/// Where a file-dialog action should leave the panel: a folder to navigate to and a file name to enter.
///
/// Save panels treat a typed `/` as part of the file name, so a full path entered as the name saves a
/// misnamed file in the panel's current folder. The destination is therefore always split into a folder and
/// a bare file name before anything touches the panel.
public struct FileDialogDestination: Equatable, Sendable {
    /// The folder to navigate to, with symlinks resolved (for example `/tmp` becomes `/private/tmp`).
    public let directory: URL?
    /// The bare file name to enter, without any folder part.
    public let filename: String?

    public static func resolve(path: String?, name: String?) throws -> FileDialogDestination {
        var directory = path.map(Self.folderURL)
        var filename = name
        if name == nil, let path, Self.namesFile(path) {
            let expanded = (path as NSString).expandingTildeInPath
            directory = Self.folderURL(for: (expanded as NSString).deletingLastPathComponent)
            filename = (expanded as NSString).lastPathComponent
        }
        if let name, name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            let nameFolder = Self.folderURL(for: (expanded as NSString).deletingLastPathComponent)
            if let directory, directory.path != nameFolder.path {
                throw PeekabooError.invalidInput(
                    "The file name '\(name)' names the folder \(nameFolder.path), but path names " +
                        "\(directory.path). Pass the folder in path and a bare file name in name.")
            }
            directory = nameFolder
            filename = (expanded as NSString).lastPathComponent
        }
        return FileDialogDestination(directory: directory, filename: filename)
    }

    /// An existing folder is a folder; an existing file, or a missing path with an extension, names a file.
    private static func namesFile(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) {
            return !isDirectory.boolValue
        }
        return !(expanded as NSString).pathExtension.isEmpty
    }

    private static func folderURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
