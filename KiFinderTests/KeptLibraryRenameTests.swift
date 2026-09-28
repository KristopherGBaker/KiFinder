import Foundation
@testable import KiFinder
import Testing

/// Item-22 assertions 1–6 & 8: `KeptLibrary.renameSubject` migrates a renamed subject's
/// saved copies + index entries to the new display name (per-entry move + index rewrite),
/// never disturbs other subjects, preserves dedupe, tolerates missing files, de-collides
/// destination clashes, is safe when the sanitized folder is unchanged, and persists.
@Suite("Kept library rename")
struct KeptLibraryRenameTests {
    private let julyExif = "2021:07:15 12:00:00"
    private let augExif = "2021:08:20 09:30:00"

    private func requireSaved(_ result: KeptSaveResult) throws -> KeptEntry {
        guard case let .saved(entry) = result else {
            Issue.record("expected .saved, got \(result)")
            throw CancellationError()
        }
        return entry
    }

    private func makeLibrary() -> (KeptLibrary, root: URL, index: URL) {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        return (KeptLibrary(root: root, indexURL: index), root, index)
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func entry(_ library: KeptLibrary, subjectId: String, sha: String) -> KeptEntry? {
        library.allEntries.first { $0.subjectId == subjectId && $0.sha256 == sha }
    }

    // MARK: - Assertion 1

    @Test("renameSubject moves files + rewrites entries across multiple months")
    func renameMovesAcrossMonths() async throws {
        let (library, root, _) = makeLibrary()
        let julySrc = LibraryFixtures.tempDir("s").appendingPathComponent("JULY.jpg")
        let augSrc = LibraryFixtures.tempDir("s").appendingPathComponent("AUG.jpg")
        LibraryFixtures.writeImage(to: julySrc, red: 0.2, exifDate: julyExif)
        LibraryFixtures.writeImage(to: augSrc, red: 0.7, exifDate: augExif)

        let july = try requireSaved(await library.save(originalAt: julySrc, subjectId: "p1", personName: "Ava", score: 0.8))
        let aug = try requireSaved(await library.save(originalAt: augSrc, subjectId: "p1", personName: "Ava", score: 0.9))
        #expect(exists(root, july.path))
        #expect(exists(root, aug.path))

        await library.renameSubject("p1", to: "Eva")

        // Old per-subject files are gone.
        #expect(!exists(root, july.path))
        #expect(!exists(root, aug.path))

        for sha in [july.sha256, aug.sha256] {
            let migrated = try #require(entry(library, subjectId: "p1", sha: sha))
            #expect(migrated.personName == "Eva")
            #expect(migrated.path.hasPrefix("Eva/"))
            #expect(exists(root, migrated.path))
        }
        // Months are preserved from the original paths.
        let julyMigrated = try #require(entry(library, subjectId: "p1", sha: july.sha256))
        let augMigrated = try #require(entry(library, subjectId: "p1", sha: aug.sha256))
        #expect(julyMigrated.path == "Eva/2021-07/\(julyMigrated.fileName)")
        #expect(augMigrated.path == "Eva/2021-08/\(augMigrated.fileName)")
    }

    @Test("month falls back to captureDate when the path has no usable month segment")
    func renameDerivesMonthFromCaptureDate() async throws {
        let (library, root, index) = makeLibrary()
        let src = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.3, exifDate: julyExif)
        let saved = try requireSaved(await library.save(originalAt: src, subjectId: "p1", personName: "Ava", score: 0.8))
        await library.flush()

        // Rewrite the persisted entry's path so its middle segment is NOT a valid YYYY-MM,
        // and move the on-disk file to match — so the move has a real source at the bogus
        // path. A fresh library reloads this genuinely-bogus state.
        let bogusPath = "Ava/not-a-month/\(saved.fileName)"
        let bogusFolder = root.appendingPathComponent("Ava").appendingPathComponent("not-a-month", isDirectory: true)
        try FileManager.default.createDirectory(at: bogusFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(saved.path),
                                         to: bogusFolder.appendingPathComponent(saved.fileName))
        try rewritePath(in: index, sha: saved.sha256, to: bogusPath)
        let reloaded = KeptLibrary(root: root, indexURL: index)
        #expect(reloaded.allEntries.first { $0.sha256 == saved.sha256 }?.path == bogusPath)

        await reloaded.renameSubject("p1", to: "Eva")

        let migrated = try #require(entry(reloaded, subjectId: "p1", sha: saved.sha256))
        // The path month is unusable ⇒ captureDate (July EXIF) decides ⇒ 2021-07.
        #expect(migrated.path == "Eva/2021-07/\(migrated.fileName)")
        #expect(exists(root, migrated.path))
    }

    /// Rewrites the persisted index so the entry with `sha` carries `path` (used to pin
    /// an unusable month segment deterministically).
    private func rewritePath(in index: URL, sha: String, to path: String) throws {
        var entries = loadKeptIndex(from: index)
        guard let i = entries.firstIndex(where: { $0.sha256 == sha }) else { return }
        entries[i].path = path
        let data = try JSONEncoder().encode(entries)
        try data.write(to: index, options: .atomic)
    }

    // MARK: - Assertion 2

    @Test("renaming subject A leaves subject B (sharing the old folder) untouched")
    func renameDoesNotTouchOtherSubject() async throws {
        let (library, root, _) = makeLibrary()
        let aSrc = LibraryFixtures.tempDir("s").appendingPathComponent("A.jpg")
        let bSrc = LibraryFixtures.tempDir("s").appendingPathComponent("B.jpg")
        LibraryFixtures.writeImage(to: aSrc, red: 0.2, exifDate: julyExif)
        LibraryFixtures.writeImage(to: bSrc, red: 0.9, exifDate: julyExif)

        // Both saved under the SAME display name ⇒ same sanitized folder "Ava".
        let a = try requireSaved(await library.save(originalAt: aSrc, subjectId: "pA", personName: "Ava", score: 0.8))
        let b = try requireSaved(await library.save(originalAt: bSrc, subjectId: "pB", personName: "Ava", score: 0.8))
        let bBytesBefore = try Data(contentsOf: root.appendingPathComponent(b.path))

        await library.renameSubject("pA", to: "Eva")

        // B is unmoved + byte-identical + still under the old folder.
        let bAfter = try #require(entry(library, subjectId: "pB", sha: b.sha256))
        #expect(bAfter.path == b.path)
        #expect(bAfter.personName == "Ava")
        #expect(exists(root, b.path))
        #expect(try Data(contentsOf: root.appendingPathComponent(b.path)) == bBytesBefore)

        // A did move.
        let aAfter = try #require(entry(library, subjectId: "pA", sha: a.sha256))
        #expect(aAfter.personName == "Eva")
        #expect(aAfter.path.hasPrefix("Eva/"))
    }

    // MARK: - Assertion 3

    @Test("dedupe survives rename: save → alreadySaved → rename → save ⇒ alreadySaved")
    func renamePreservesDedupe() async throws {
        let (library, _, _) = makeLibrary()
        let src = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.4, exifDate: julyExif)

        _ = try requireSaved(await library.save(originalAt: src, subjectId: "p1", personName: "Ava", score: 0.8))
        if case .alreadySaved = await library.save(originalAt: src, subjectId: "p1", personName: "Ava", score: 0.8) {} else {
            Issue.record("expected alreadySaved before rename")
        }

        await library.renameSubject("p1", to: "Eva")

        let after = await library.save(originalAt: src, subjectId: "p1", personName: "Eva", score: 0.8)
        guard case let .alreadySaved(entry) = after else {
            Issue.record("expected alreadySaved after rename, got \(after)")
            return
        }
        #expect(entry.personName == "Eva")
    }

    // MARK: - Assertion 4

    @Test("a missing-on-disk file is still rewritten without crashing")
    func renameToleratesMissingFile() async throws {
        let (library, root, _) = makeLibrary()
        let src = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.4, exifDate: julyExif)
        let saved = try requireSaved(await library.save(originalAt: src, subjectId: "p1", personName: "Ava", score: 0.8))

        // Delete the backing copy out from under the library.
        try FileManager.default.removeItem(at: root.appendingPathComponent(saved.path))

        await library.renameSubject("p1", to: "Eva")

        let after = try #require(entry(library, subjectId: "p1", sha: saved.sha256))
        #expect(after.personName == "Eva")
        #expect(after.path.hasPrefix("Eva/"))
        // The file still does not exist (nothing was conjured).
        #expect(!exists(root, after.path))
    }

    @Test("a missing-on-disk file never ADOPTS an unrelated file already at the destination")
    func renameMissingFileDoesNotAdoptDestination() async throws {
        let (library, root, _) = makeLibrary()
        // p1 "Ava" saves IMG.jpg, then its backing copy is deleted (missing source).
        let avaSrc = LibraryFixtures.tempDir("a").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: avaSrc, red: 0.2, exifDate: julyExif)
        let avaEntry = try requireSaved(await library.save(originalAt: avaSrc, subjectId: "p1", personName: "Ava", score: 0.8))
        try FileManager.default.removeItem(at: root.appendingPathComponent(avaEntry.path))

        // A DIFFERENT person "Eva" (p2) already has a DIFFERENT-content IMG.jpg in the
        // same month — so `Eva/<month>/IMG.jpg` is occupied by unrelated bytes.
        let evaSrc = LibraryFixtures.tempDir("e").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: evaSrc, red: 0.9, exifDate: julyExif)
        let evaEntry = try requireSaved(await library.save(originalAt: evaSrc, subjectId: "p2", personName: "Eva", score: 0.8))
        let evaBytesBefore = try Data(contentsOf: root.appendingPathComponent(evaEntry.path))

        // Rename Ava → Eva. Ava's missing entry must NOT adopt Eva's existing file.
        await library.renameSubject("p1", to: "Eva")

        let movedAva = try #require(entry(library, subjectId: "p1", sha: avaEntry.sha256))
        #expect(movedAva.personName == "Eva")
        #expect(movedAva.path.hasPrefix("Eva/"))
        // De-collided away from Eva's real file, and still missing on disk (fileExists false).
        #expect(movedAva.path != evaEntry.path)
        #expect(!exists(root, movedAva.path))
        // Eva's real file is untouched (still present, same bytes).
        #expect(exists(root, evaEntry.path))
        #expect(try Data(contentsOf: root.appendingPathComponent(evaEntry.path)) == evaBytesBefore)
    }

    // MARK: - Assertion 5

    @Test("destination collision de-collides; both files survive with distinct bytes")
    func renameDeCollidesDestination() async throws {
        let (library, root, _) = makeLibrary()
        // Pre-existing photo for "Eva" with the SAME filename, different bytes.
        let evaSrc = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: evaSrc, red: 0.95, exifDate: julyExif)
        let evaEntry = try requireSaved(await library.save(originalAt: evaSrc, subjectId: "pEva", personName: "Eva", score: 0.8))
        let evaBytes = try Data(contentsOf: root.appendingPathComponent(evaEntry.path))

        // Ava's photo, same filename "IMG.jpg", different bytes, July.
        let avaSrc = LibraryFixtures.tempDir("s2").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: avaSrc, red: 0.1, exifDate: julyExif)
        let avaEntry = try requireSaved(await library.save(originalAt: avaSrc, subjectId: "pAva", personName: "Ava", score: 0.8))
        let avaBytes = try Data(contentsOf: root.appendingPathComponent(avaEntry.path))

        await library.renameSubject("pAva", to: "Eva")

        let migrated = try #require(entry(library, subjectId: "pAva", sha: avaEntry.sha256))
        // De-collided (not the plain IMG.jpg slot that Eva already holds).
        #expect(migrated.path != evaEntry.path)
        #expect(migrated.path.hasPrefix("Eva/2021-07/"))
        // Both files survive with their original distinct bytes.
        #expect(try Data(contentsOf: root.appendingPathComponent(evaEntry.path)) == evaBytes)
        #expect(try Data(contentsOf: root.appendingPathComponent(migrated.path)) == avaBytes)
    }

    // MARK: - Assertion 6

    @Test("same-sanitized-folder rename keeps the file and updates personName")
    func renameSameSanitizedFolder() async throws {
        // Two distinct display strings that sanitize to the same folder: the sanitizer
        // trims surrounding whitespace and strips leading dots.
        let oldName = "Ava"
        let newName = " .Ava "
        #expect(oldName != newName)
        #expect(KeptLibrary.sanitized(oldName) == KeptLibrary.sanitized(newName))

        let (library, root, _) = makeLibrary()
        let src = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.4, exifDate: julyExif)
        let saved = try requireSaved(await library.save(originalAt: src, subjectId: "p1", personName: oldName, score: 0.8))
        let bytesBefore = try Data(contentsOf: root.appendingPathComponent(saved.path))

        await library.renameSubject("p1", to: newName)

        let after = try #require(entry(library, subjectId: "p1", sha: saved.sha256))
        // No file lost; path unchanged (same sanitized folder + month + name).
        #expect(exists(root, after.path))
        #expect(after.path == saved.path)
        #expect(try Data(contentsOf: root.appendingPathComponent(after.path)) == bytesBefore)
        // personName reflects the new display string.
        #expect(after.personName == newName)
    }

    // MARK: - Assertion 8

    @Test("rename persists: flush + fresh library reloads the new name/path")
    func renamePersists() async throws {
        let (library, root, index) = makeLibrary()
        let src = LibraryFixtures.tempDir("s").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.4, exifDate: julyExif)
        let saved = try requireSaved(await library.save(originalAt: src, subjectId: "p1", personName: "Ava", score: 0.8))

        await library.renameSubject("p1", to: "Eva")
        await library.flush()

        let reloaded = KeptLibrary(root: root, indexURL: index)
        let after = try #require(reloaded.allEntries.first { $0.subjectId == "p1" && $0.sha256 == saved.sha256 })
        #expect(after.personName == "Eva")
        #expect(after.path.hasPrefix("Eva/"))
        #expect(exists(root, after.path))
    }
}
