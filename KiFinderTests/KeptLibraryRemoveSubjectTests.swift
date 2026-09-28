import Foundation
@testable import KiFinder
import Testing

/// Item-32 assertion 1: `KeptLibrary.removeSubject` deletes EVERY saved copy + index
/// entry for a subject (a missing-on-disk file is tolerated), leaves other subjects'
/// files/entries untouched, re-enables dedupe for the purged subject, and the removal
/// survives flush + a fresh library over the same index (proving the index was rewritten).
@Suite("Kept library remove subject")
struct KeptLibraryRemoveSubjectTests {
    private let exif = "2021:07:15 12:00:00"

    private func requireSaved(_ result: KeptSaveResult) throws -> KeptEntry {
        guard case let .saved(entry) = result else {
            Issue.record("expected .saved, got \(result)")
            throw CancellationError()
        }
        return entry
    }

    @Test("removeSubject purges all of A's files + entries, keeps B, re-enables dedupe, survives reload")
    func removeSubjectPurgesOnlyThatSubject() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: indexURL)

        // THREE distinct files/bytes: two for subject A (A1, A2), one for subject B (B1).
        let a1Src = LibraryFixtures.tempDir("src").appendingPathComponent("A1.jpg")
        let a2Src = LibraryFixtures.tempDir("src").appendingPathComponent("A2.jpg")
        let b1Src = LibraryFixtures.tempDir("src").appendingPathComponent("B1.jpg")
        LibraryFixtures.writeImage(to: a1Src, red: 0.1, exifDate: exif)
        LibraryFixtures.writeImage(to: a2Src, red: 0.4, exifDate: exif)
        LibraryFixtures.writeImage(to: b1Src, red: 0.7, exifDate: exif)

        let a1 = try requireSaved(await library.save(originalAt: a1Src, subjectId: "A", personName: "Ava", score: 0.8))
        let a2 = try requireSaved(await library.save(originalAt: a2Src, subjectId: "A", personName: "Ava", score: 0.7))
        let b1 = try requireSaved(await library.save(originalAt: b1Src, subjectId: "B", personName: "Bea", score: 0.9))

        let a1Dest = root.appendingPathComponent(a1.path)
        let a2Dest = root.appendingPathComponent(a2.path)
        let b1Dest = root.appendingPathComponent(b1.path)
        let b1Bytes = try Data(contentsOf: b1Dest)

        await library.removeSubject("A")
        await library.flush()

        // Both A files gone on disk + both A entries absent; B byte-intact + present.
        #expect(!FileManager.default.fileExists(atPath: a1Dest.path))
        #expect(!FileManager.default.fileExists(atPath: a2Dest.path))
        #expect(!library.allEntries.contains(a1))
        #expect(!library.allEntries.contains(a2))
        #expect(library.allEntries.contains(b1))
        #expect(try Data(contentsOf: b1Dest) == b1Bytes)

        // Persistence pin: a FRESH library over the same index has neither original A
        // entry, but still has B — proving the on-disk index was rewritten, not just memory.
        let reloaded = KeptLibrary(root: root, indexURL: indexURL)
        #expect(!reloaded.allEntries.contains(a1))
        #expect(!reloaded.allEntries.contains(a2))
        #expect(reloaded.allEntries.contains(b1))

        // Dedupe re-enabled for A: re-saving A1's bytes returns .saved.
        let resave = await library.save(originalAt: a1Src, subjectId: "A", personName: "Ava", score: 0.8)
        guard case .saved = resave else {
            Issue.record("expected .saved after removeSubject, got \(resave)")
            return
        }
    }

    @Test("removeSubject tolerates a missing-on-disk copy and still drops the entry")
    func removeSubjectToleratesMissingFile() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: indexURL)
        let src = LibraryFixtures.tempDir("src").appendingPathComponent("A1.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.2, exifDate: exif)

        let entry = try requireSaved(await library.save(originalAt: src, subjectId: "A", personName: "Ava", score: 0.8))
        // Delete the copy out from under the library (a stale entry on disk).
        try FileManager.default.removeItem(at: root.appendingPathComponent(entry.path))

        await library.removeSubject("A")
        #expect(!library.allEntries.contains(entry))
    }
}
