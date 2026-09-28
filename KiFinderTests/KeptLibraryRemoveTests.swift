import Foundation
@testable import KiFinder
import Testing

/// Item-18b assertions 1–2: `KeptLibrary.remove` deletes the saved copy + index entry
/// (a missing-on-disk file still removes the entry), the removal survives flush+reload,
/// and removing an entry re-enables a future re-save of the same bytes for that subject.
@Suite("Kept library remove")
struct KeptLibraryRemoveTests {
    private let exifJuly2021 = "2021:07:15 12:00:00"

    private func requireSaved(_ result: KeptSaveResult) throws -> KeptEntry {
        guard case let .saved(entry) = result else {
            Issue.record("expected .saved, got \(result)")
            throw CancellationError()
        }
        return entry
    }

    // MARK: - Assertion 1

    @Test("remove deletes the file + index entry; flush+reload does not bring it back")
    func removeDeletesFileAndEntry() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: indexURL)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.5, exifDate: exifJuly2021)

        let entry = try requireSaved(await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.8))
        let dest = root.appendingPathComponent(entry.path)
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let ok = await library.remove(entry)
        await library.flush()
        #expect(ok)
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!library.allEntries.contains(entry))

        // A fresh library over the same index does NOT reload the removed entry.
        let reloaded = KeptLibrary(root: root, indexURL: indexURL)
        #expect(!reloaded.allEntries.contains(entry))
        #expect(reloaded.allEntries.isEmpty)
    }

    @Test("removing an entry whose file is already gone still drops the index entry")
    func removeMissingFileStillRemovesEntry() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: indexURL)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.5, exifDate: exifJuly2021)

        let entry = try requireSaved(await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.8))
        // Delete the copy out from under the library (a stale entry).
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))

        let ok = await library.remove(entry)
        #expect(ok)
        #expect(!library.allEntries.contains(entry))
    }

    // MARK: - Assertion 2

    @Test("remove re-enables dedupe: save → alreadySaved → remove → save ⇒ .saved")
    func removeReEnablesDedupe() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: indexURL)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.5, exifDate: exifJuly2021)

        let first = try requireSaved(await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.8))
        let second = await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.8)
        guard case .alreadySaved = second else {
            Issue.record("expected .alreadySaved, got \(second)")
            return
        }

        let ok = await library.remove(first)
        #expect(ok)

        // The hash is gone from this subject's index, so the same bytes save afresh.
        let third = await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.8)
        guard case .saved = third else {
            Issue.record("expected .saved after remove, got \(third)")
            return
        }
    }
}
