import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FileDialogDestinationTests {
    @Test
    func `a full path passed as the name is split into folder and file name`() throws {
        let folder = try Self.makeFolder()
        let destination = try FileDialogDestination.resolve(path: nil, name: folder.path + "/report.txt")
        #expect(destination.directory?.path == folder.resolvingSymlinksInPath().path)
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
        #expect(destination.directory?.path == folder.resolvingSymlinksInPath().path)
        #expect(destination.filename == "report.txt")

        let existing = folder.appendingPathComponent("archive.v2", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let folderOnly = try FileDialogDestination.resolve(path: existing.path, name: nil)
        #expect(folderOnly.directory?.path == existing.resolvingSymlinksInPath().path)
        #expect(folderOnly.filename == nil)
    }

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDialogDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
