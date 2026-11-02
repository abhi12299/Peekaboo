import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FileDialogDestinationTests {
    @Test
    func `a full path passed as the name is split into folder and file name`() throws {
        let folder = try Self.makeFolder()
        let destination = try FileDialogDestination.resolve(path: nil, name: folder.path + "/report.txt")
        #expect(destination.directory?.path == Self.realPath(folder))
        #expect(destination.filename == "report.txt")
    }

    @Test
    func `a name whose folder disagrees with the path is refused`() throws {
        let first = try Self.makeFolder()
        let second = try Self.makeFolder()
        #expect(throws: PeekabooError.self) {
            try FileDialogDestination.resolve(path: first.path, name: second.path + "/report.txt")
        }
        let same = try FileDialogDestination.resolve(path: first.path, name: first.path + "/report.txt")
        #expect(same.filename == "report.txt")
    }

    @Test
    func `a path to a file with no name splits into folder and file name`() throws {
        let folder = try Self.makeFolder()
        let destination = try FileDialogDestination.resolve(path: folder.path + "/report.txt", name: nil)
        #expect(destination.directory?.path == Self.realPath(folder))
        #expect(destination.filename == "report.txt")

        let existing = folder.appendingPathComponent("archive.v2", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let folderOnly = try FileDialogDestination.resolve(path: existing.path, name: nil)
        #expect(folderOnly.directory?.path == Self.realPath(existing))
        #expect(folderOnly.filename == nil)
    }

    @Test
    func `folders are canonical real paths the way the panel shows them`() throws {
        // The panel's Where menu lists /tmp/x as Macintosh HD > private > tmp > x.
        let folder = URL(fileURLWithPath: "/tmp/FileDialogDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = try FileDialogDestination.resolve(path: folder.path, name: "a.txt")

        #expect(destination.directory?.path == "/private" + folder.path)
    }

    private static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDialogDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
