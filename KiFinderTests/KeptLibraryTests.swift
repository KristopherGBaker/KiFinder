import Foundation
@testable import KiFinder
import Testing

/// Item-18a assertions 2–5 + 8a: `KeptLibrary` save layout (path + byte-equal copy),
/// per-person hash dedupe, filename de-collision, the metadata index (content +
/// persistence + observable coalescing), and graceful missing-source handling.
@Suite("Kept library store")
struct KeptLibraryTests {
    /// EXIF date that should land copies under the `2021-07` month folder.
    private let exifJuly2021 = "2021:07:15 12:00:00"

    private func makeLibrary(root: URL? = nil, index: URL? = nil, writer: (any KeptIndexWriting)? = nil) -> KeptLibrary {
        let r = root ?? LibraryFixtures.tempDir("root")
        let i = index ?? LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        return KeptLibrary(root: r, indexURL: i, indexWriter: writer)
    }

    // MARK: - Save layout (assertion 2)

    @Test("save copies the original to <root>/<person>/<YYYY-MM>/<file> byte-for-byte")
    func saveLayoutAndBytes() async throws {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG_1842.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.3, exifDate: exifJuly2021)

        let result = await library.save(originalAt: source, subjectId: "kris", personName: "Ava Smith", score: 0.88)
        let entry = try requireSaved(result)

        let expectedDest = root
            .appendingPathComponent("Ava Smith", isDirectory: true)
            .appendingPathComponent("2021-07", isDirectory: true)
            .appendingPathComponent("IMG_1842.jpg")
        #expect(FileManager.default.fileExists(atPath: expectedDest.path))
        #expect(entry.path == "Ava Smith/2021-07/IMG_1842.jpg")
        #expect(entry.fileName == "IMG_1842.jpg")

        let sourceBytes = try Data(contentsOf: source)
        let copiedBytes = try Data(contentsOf: expectedDest)
        #expect(sourceBytes == copiedBytes)
    }

    @Test("a name with path separators is sanitized to a safe folder")
    func sanitizesPersonFolder() {
        #expect(KeptLibrary.sanitized("a/b:c") == "a-b-c")
        #expect(KeptLibrary.sanitized("..hidden") == "hidden")
        #expect(KeptLibrary.sanitized("   ") == "Unknown")
        #expect(KeptLibrary.sanitized("") == "Unknown")
        // Path separators become safe dashes (still non-empty / filesystem-safe).
        #expect(KeptLibrary.sanitized("/") == "-")
    }

    @Test("month falls back to file modification date when there is no EXIF date")
    func monthFallsBackToModificationDate() async throws {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("nodate.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.6, exifDate: nil)
        // Pin a known modification date well inside a month.
        let pinned = try #require(ISO8601DateFormatter().date(from: "2019-03-10T12:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: source.path)

        let entry = try requireSaved(await library.save(originalAt: source, subjectId: "k", personName: "Ann", score: 0.5))
        #expect(entry.path == "Ann/2019-03/nodate.jpg")
    }

    // MARK: - Dedupe (assertion 3)

    @Test("same content twice for one subject ⇒ alreadySaved, one file; second subject ⇒ separate copy")
    func perPersonHashDedupe() async throws {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.42, exifDate: exifJuly2021)

        let first = try requireSaved(await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.9))
        let second = await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.9)
        guard case let .alreadySaved(existing) = second else {
            Issue.record("expected .alreadySaved, got \(second)")
            return
        }
        #expect(existing == first)

        // One file under that person's month folder.
        let krisMonth = root.appendingPathComponent("Kris/2021-07", isDirectory: true)
        let krisFiles = try FileManager.default.contentsOfDirectory(atPath: krisMonth.path)
        #expect(krisFiles.count == 1)

        // A different subject saving the same content gets its OWN copy.
        let third = try requireSaved(await library.save(originalAt: source, subjectId: "ava", personName: "Ava", score: 0.8))
        let avaDest = root.appendingPathComponent("Ava/2021-07/IMG.jpg")
        #expect(FileManager.default.fileExists(atPath: avaDest.path))
        #expect(third.subjectId == "ava")
    }

    // MARK: - De-collision (assertion 4)

    @Test("distinct content sharing a filename both persist with distinct bytes")
    func deCollisionKeepsBoth() async throws {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        let dirA = LibraryFixtures.tempDir("a")
        let dirB = LibraryFixtures.tempDir("b")
        let sourceA = dirA.appendingPathComponent("IMG.jpg")
        let sourceB = dirB.appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: sourceA, red: 0.1, exifDate: exifJuly2021)
        LibraryFixtures.writeImage(to: sourceB, red: 0.9, exifDate: exifJuly2021)

        let a = try requireSaved(await library.save(originalAt: sourceA, subjectId: "kris", personName: "Kris", score: 0.9))
        let b = try requireSaved(await library.save(originalAt: sourceB, subjectId: "kris", personName: "Kris", score: 0.9))

        #expect(a.fileName == "IMG.jpg")
        #expect(b.fileName == "IMG-2.jpg") // de-collided
        let folder = root.appendingPathComponent("Kris/2021-07", isDirectory: true)
        let bytesA = try Data(contentsOf: folder.appendingPathComponent("IMG.jpg"))
        let bytesB = try Data(contentsOf: folder.appendingPathComponent("IMG-2.jpg"))
        #expect(bytesA != bytesB)
        #expect(try Data(contentsOf: sourceA) == bytesA)
        #expect(try Data(contentsOf: sourceB) == bytesB)
    }

    // MARK: - Missing source (assertion 8a)

    @Test("a non-existent source returns .sourceMissing and writes nothing")
    func missingSource() async {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        let missing = root.appendingPathComponent("does-not-exist.jpg")

        let result = await library.save(originalAt: missing, subjectId: "kris", personName: "Kris", score: 0.5)
        #expect(result == .sourceMissing)
        #expect(library.allEntries.isEmpty)
        // No person folder was created.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Kris").path))
    }

    @Test("an existing but undecodable / non-image source writes nothing (no copy, no orphan entry)")
    func undecodableSourceWritesNothing() async throws {
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root)
        // A real file that exists but is NOT a decodable image.
        let bogus = LibraryFixtures.tempDir("src").appendingPathComponent("notes.jpg")
        try Data("this is not an image".utf8).write(to: bogus)

        let result = await library.save(originalAt: bogus, subjectId: "kris", personName: "Kris", score: 0.5)
        await library.flush()
        #expect(result != .sourceMissing)
        if case .saved = result { Issue.record("undecodable source must not be .saved") }
        #expect(library.allEntries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Kris").path))
    }

    // MARK: - Index content + persistence (assertion 5a)

    @Test("save + flush writes the entry; a fresh library reloads it and dedupe survives")
    func indexPersistsAndReloads() async throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = makeLibrary(root: root, index: indexURL)
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.5, exifDate: exifJuly2021)

        let saved = try requireSaved(await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.77))
        await library.flush()

        // On-disk index contains the entry.
        let onDisk = loadKeptIndex(from: indexURL)
        #expect(onDisk.contains(saved))

        // A fresh library over the same index reloads it…
        let reloaded = KeptLibrary(root: root, indexURL: indexURL)
        #expect(reloaded.allEntries.contains(saved))
        // …and the dedupe check survives the reload.
        let again = await reloaded.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.77)
        guard case .alreadySaved = again else {
            Issue.record("expected .alreadySaved after reload, got \(again)")
            return
        }
    }

    // MARK: - Coalescing is observable (assertion 5b)

    @Test("N rapid saves schedule N updates with 0 writes before flush, then exactly one write")
    func coalescedIndexWrites() async {
        let spy = SpyKeptIndexWriter()
        let root = LibraryFixtures.tempDir("root")
        let library = makeLibrary(root: root, writer: spy)

        let n = 5
        for i in 0 ..< n {
            let source = LibraryFixtures.tempDir("src-\(i)").appendingPathComponent("IMG\(i).jpg")
            LibraryFixtures.writeImage(to: source, red: CGFloat(i) / CGFloat(n), exifDate: exifJuly2021)
            _ = await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: Double(i))
        }

        // Each distinct save scheduled an update; NOTHING materialized yet.
        #expect(spy.scheduledCount == n)
        #expect(spy.materializedWrites == 0)

        await library.flush()
        // Exactly one write, carrying the full latest index.
        #expect(spy.materializedWrites == 1)
        #expect(spy.lastWritten.count == n)
    }

    // MARK: - Quarantine notice (item 57, assertion 4)

    @Test("a corrupt index surfaces a plain-language notice once; a second library over the same index sees nothing to report")
    func keptIndexQuarantine_noticeOnceThenSilent() throws {
        let root = LibraryFixtures.tempDir("root")
        let indexURL = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        try Data("not json {{{".utf8).write(to: indexURL)

        let library = KeptLibrary(root: root, indexURL: indexURL)
        let notice = try #require(library.quarantineNotice)
        // Plain language naming what was set aside — no implementation jargon.
        #expect(notice.localizedCaseInsensitiveContains("photo"))
        #expect(!notice.localizedCaseInsensitiveContains("json"))
        #expect(!notice.localizedCaseInsensitiveContains("decode"))
        #expect(library.allEntries.isEmpty)

        // A fresh library over the SAME index — the corrupt bytes are gone (moved
        // aside), so nothing is left to quarantine and the notice stays nil.
        let reopened = KeptLibrary(root: root, indexURL: indexURL)
        #expect(reopened.quarantineNotice == nil)
    }

    // MARK: - Helpers

    private func requireSaved(_ result: KeptSaveResult) throws -> KeptEntry {
        guard case let .saved(entry) = result else {
            Issue.record("expected .saved, got \(result)")
            throw CancellationError()
        }
        return entry
    }
}
