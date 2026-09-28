import Foundation
@testable import KiFinder
import Testing

/// Item-18b assertions 3–5: the pure person→month grouping with deterministic ordering,
/// the person filter, URL resolution, and graceful handling of an entry whose backing
/// file no longer exists (still enumerable with `fileExists == false`).
@Suite("Library browse grouping")
struct LibraryBrowseModelTests {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    private func entry(
        subjectId: String,
        name: String,
        month: String,
        fileName: String,
        captureDate: Date,
        sha: String? = nil
    ) -> KeptEntry {
        KeptEntry(
            sha256: sha ?? "\(subjectId)-\(fileName)",
            subjectId: subjectId,
            personName: name,
            path: "\(name)/\(month)/\(fileName)",
            sourcePath: "/src/\(fileName)",
            score: 0.9,
            captureDate: captureDate,
            savedAt: captureDate,
            fileName: fileName
        )
    }

    /// A fixed multi-person, multi-month set (Bob enrolled before Ava so the
    /// case-insensitive name sort is exercised against insertion order).
    private func fixtureEntries() -> [KeptEntry] {
        [
            // Bob: one month.
            entry(subjectId: "bob", name: "Bob", month: "2021-08", fileName: "IMG_D.jpg", captureDate: date(2021, 8, 1)),
            // Ava 2021-09: two share a captureDate (fileName tiebreak), one earlier date.
            entry(subjectId: "ava", name: "Ava", month: "2021-09", fileName: "IMG_Z.jpg", captureDate: date(2021, 9, 20)),
            entry(subjectId: "ava", name: "Ava", month: "2021-09", fileName: "IMG_A.jpg", captureDate: date(2021, 9, 20)),
            entry(subjectId: "ava", name: "Ava", month: "2021-09", fileName: "IMG_B.jpg", captureDate: date(2021, 9, 10)),
            // Ava 2021-07: a second, older month.
            entry(subjectId: "ava", name: "Ava", month: "2021-07", fileName: "IMG_C.jpg", captureDate: date(2021, 7, 5)),
        ]
    }

    // MARK: - Assertion 3: ordered grouping

    @Test("groups by person (name ci) → month (desc) → photo (captureDate desc, then fileName)")
    func orderedGrouping() {
        let root = URL(fileURLWithPath: "/lib", isDirectory: true)
        let groups = groupLibrary(entries: fixtureEntries(), root: root)

        #expect(groups.map(\.personName) == ["Ava", "Bob"])

        let ava = groups[0]
        #expect(ava.subjectId == "ava")
        #expect(ava.months.map(\.month) == ["2021-09", "2021-07"]) // newest first
        #expect(ava.months[0].items.map(\.entry.fileName) == ["IMG_A.jpg", "IMG_Z.jpg", "IMG_B.jpg"])
        #expect(ava.months[1].items.map(\.entry.fileName) == ["IMG_C.jpg"])

        let bob = groups[1]
        #expect(bob.subjectId == "bob")
        #expect(bob.months.map(\.month) == ["2021-08"])
    }

    @Test("each leaf item resolves its URL as <root>/<entry.path>")
    func urlResolution() {
        let root = URL(fileURLWithPath: "/lib", isDirectory: true)
        let groups = groupLibrary(entries: fixtureEntries(), root: root)
        let bobItem = groups[1].months[0].items[0]
        #expect(bobItem.url == root.appendingPathComponent("Bob/2021-08/IMG_D.jpg"))
    }

    // MARK: - Assertion 4: person filter

    @Test("filter to one subject yields only that person; nil yields everyone")
    func personFilter() {
        let root = URL(fileURLWithPath: "/lib", isDirectory: true)
        let entries = fixtureEntries()

        let avaOnly = groupLibrary(entries: entries, root: root, filter: "ava")
        #expect(avaOnly.map(\.subjectId) == ["ava"])
        #expect(avaOnly[0].photoCount == 4)

        let all = groupLibrary(entries: entries, root: root, filter: nil)
        #expect(Set(all.map(\.subjectId)) == ["ava", "bob"])
        #expect(all.reduce(0) { $0 + $1.photoCount } == entries.count)
    }

    // MARK: - Assertion 5: missing on-disk file is graceful

    @Test("an entry whose file is missing is still enumerable with fileExists == false")
    func missingFileFlag() throws {
        let root = LibraryFixtures.tempDir("root")
        // Create the backing file for ONE entry; leave the other absent.
        let present = entry(subjectId: "ava", name: "Ava", month: "2021-09", fileName: "PRESENT.jpg", captureDate: date(2021, 9, 20))
        let missing = entry(subjectId: "ava", name: "Ava", month: "2021-09", fileName: "GONE.jpg", captureDate: date(2021, 9, 10))
        let presentURL = root.appendingPathComponent(present.path)
        try FileManager.default.createDirectory(at: presentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        LibraryFixtures.writeImage(to: presentURL, red: 0.3)

        let groups = groupLibrary(entries: [present, missing], root: root)
        let items = groups[0].months[0].items
        // Both entries are enumerable (the stale one is NOT silently dropped).
        #expect(items.count == 2)
        let presentItem = try #require(items.first { $0.entry.fileName == "PRESENT.jpg" })
        let missingItem = try #require(items.first { $0.entry.fileName == "GONE.jpg" })
        #expect(presentItem.fileExists)
        #expect(!missingItem.fileExists)
    }
}
