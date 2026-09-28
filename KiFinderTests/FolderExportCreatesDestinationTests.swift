import Foundation
@testable import KiFinder
import Testing

/// Item 76: the folder-export copy path must CREATE a not-yet-existing destination. Under
/// macOS 27 the sandboxed XCUITest runner can no longer pre-create `KION_EXPORT_DEST`, so
/// the app has to — `copyFilesOffMainActor` (the pure off-main copy seam that the real
/// `export(...)` entry point calls) now creates the destination with intermediate
/// directories before copying. This pins that a missing folder is made and the files land.
@Suite("Folder export creates a missing destination")
struct FolderExportCreatesDestinationTests {
    private let fm = FileManager.default

    private func tempDir(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-export-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("exporting into a not-yet-existing folder creates it and copies the files")
    func createsMissingDestination() throws {
        // Two distinct source files under an existing source dir.
        let sourceDir = tempDir("src")
        let a = sourceDir.appendingPathComponent("A.png")
        let b = sourceDir.appendingPathComponent("B.png")
        let aBytes = Data("alpha-\(UUID().uuidString)".utf8)
        let bBytes = Data("bravo-\(UUID().uuidString)".utf8)
        try aBytes.write(to: a)
        try bBytes.write(to: b)

        // A destination that does NOT exist yet (nested, to prove intermediates are made).
        let dest = tempDir("dest-parent").appendingPathComponent("kept/exports", isDirectory: true)
        #expect(!fm.fileExists(atPath: dest.path))

        let count = try LiveTriageEngine.copyFilesOffMainActor(sources: [a, b], directory: dest)

        #expect(count == 2)
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try Data(contentsOf: dest.appendingPathComponent("A.png")) == aBytes)
        #expect(try Data(contentsOf: dest.appendingPathComponent("B.png")) == bBytes)
    }
}
