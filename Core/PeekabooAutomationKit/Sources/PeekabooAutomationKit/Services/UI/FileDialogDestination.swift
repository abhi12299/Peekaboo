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
        var directoryPath = path
        var filename = name
        if let name, name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            directoryPath = (expanded as NSString).deletingLastPathComponent
            filename = (expanded as NSString).lastPathComponent
        }
        let directory = directoryPath.map { path in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }
        return FileDialogDestination(directory: directory, filename: filename)
    }
}
