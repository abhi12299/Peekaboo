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

    private static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDialogDestinationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
