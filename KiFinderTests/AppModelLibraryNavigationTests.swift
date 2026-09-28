import Foundation
@testable import KiFinder
import Testing

/// Item-26a: the Library browse grid's OWN focus / arrow-navigation / in-place-preview
/// model on `AppModel` (`libraryOrderedIDs`, `libraryFocusedID`, `moveLibrary*`,
/// `libraryPreviewActive` + toggle/open/close, `focusLibrary`), kept SEPARATE from the
/// review grid's `focusedID` / `isPreviewPresented`.
@Suite("App model library navigation")
@MainActor
struct AppModelLibraryNavigationTests {
    // MARK: - Fixtures

    /// A `KeptLibrarySaving` that simply replays a FIXED list of entries — lets a test
    /// pin the exact `libraryGroups` (hence `libraryOrderedIDs`) without touching disk.
    private final class FixedEntriesLibrary: KeptLibrarySaving, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [KeptEntry]

        init(_ entries: [KeptEntry]) {
            self.entries = entries
        }

        var allEntries: [KeptEntry] {
            lock.withLock { entries }
        }

        func save(originalAt _: URL, subjectId _: String, personName _: String, score _: Double) async -> KeptSaveResult {
            .failed
        }

        func isSaved(sourcePath _: String, subjectId _: String) -> Bool {
            false
        }

        func remove(_ entry: KeptEntry) async -> Bool {
            lock.withLock { entries.removeAll { $0.id == entry.id } }
            return true
        }

        func flush() async {}
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        c.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func entry(
        sha: String,
        subjectId: String,
        personName: String,
        fileName: String,
        captureDate: Date
    ) -> KeptEntry {
        KeptEntry(
            sha256: sha,
            subjectId: subjectId,
            personName: personName,
            path: "\(personName)/\(KeptLibrary.monthFolder(for: captureDate))/\(fileName)",
            sourcePath: "/src/\(fileName)",
            score: 0.9,
            captureDate: captureDate,
            savedAt: Date(),
            fileName: fileName
        )
    }

    /// Builds a sample-mode model whose injected library replays `entries`.
    private func makeModel(_ entries: [KeptEntry], columns: Int = 3) -> AppModel {
        let root = LibraryFixtures.tempDir("nav-root")
        return AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path,
                "KION_LIBRARY_ROOT": root.path,
                "KION_REVIEW_COLUMNS": String(columns),
            ],
            keptLibrary: FixedEntriesLibrary(entries)
        )
    }

    // MARK: - 1. Flattened order + focus

    @Test("libraryOrderedIDs is person ci → month desc → captureDate desc → fileName, with focus seeded to first")
    func orderedIDsAndInitialFocus() {
        // alice (lowercase) vs Bob: an ASCII sort would put "Bob" (0x42) before
        // "alice" (0x61); case-insensitive puts alice first — proving ci person order.
        let aliceID = "s-alice", bobID = "s-bob"
        // alice / 2021-09: two distinct capture dates (newer first).
        let a1 = entry(sha: "a1", subjectId: aliceID, personName: "alice", fileName: "b.jpg", captureDate: date(2021, 9, 20))
        let a2 = entry(sha: "a2", subjectId: aliceID, personName: "alice", fileName: "a.jpg", captureDate: date(2021, 9, 10))
        // alice / 2021-03: SAME capture date, fileName tie-break (k before m).
        let a3 = entry(sha: "a3", subjectId: aliceID, personName: "alice", fileName: "m.jpg", captureDate: date(2021, 3, 15))
        let a4 = entry(sha: "a4", subjectId: aliceID, personName: "alice", fileName: "k.jpg", captureDate: date(2021, 3, 15))
        // Bob / 2021-06.
        let b1 = entry(sha: "b1", subjectId: bobID, personName: "Bob", fileName: "z.jpg", captureDate: date(2021, 6, 15))

        // Supplied INTENTIONALLY unsorted: Bob first, alice months interleaved + the
        // same-date pair reversed.
        let model = makeModel([b1, a3, a1, a4, a2])
        model.showLibrary()

        // alice (ci) before Bob; months 09 then 03; within 09 captureDate desc (a1,a2);
        // within 03 fileName asc tie-break (a4="k" before a3="m"); then Bob's b1.
        #expect(model.libraryOrderedIDs == [a1.id, a2.id, a4.id, a3.id, b1.id])
        #expect(model.libraryFocusedID == model.libraryOrderedIDs.first)
        #expect(model.libraryFocusedID == a1.id)
    }

    @Test("empty library ⇒ nil focus; filter change re-seats focus")
    func emptyAndFilterReseat() {
        let aliceID = "s-alice", bobID = "s-bob"
        let a1 = entry(sha: "a1", subjectId: aliceID, personName: "alice", fileName: "a.jpg", captureDate: date(2021, 9, 20))
        let b1 = entry(sha: "b1", subjectId: bobID, personName: "Bob", fileName: "z.jpg", captureDate: date(2021, 6, 15))

        let empty = makeModel([])
        empty.showLibrary()
        #expect(empty.libraryOrderedIDs.isEmpty)
        #expect(empty.libraryFocusedID == nil)

        let model = makeModel([a1, b1])
        model.showLibrary()
        #expect(model.libraryFocusedID == a1.id)
        // Filtering to Bob re-seats focus onto Bob's first entry.
        model.setLibraryFilter(bobID)
        #expect(model.libraryOrderedIDs == [b1.id])
        #expect(model.libraryFocusedID == b1.id)
        // Back to everyone re-seats to the global first.
        model.setLibraryFilter(nil)
        #expect(model.libraryFocusedID == a1.id)
    }

    @Test("libraryFocusedID only ever holds an id in libraryOrderedIDs")
    func focusAlwaysValid() {
        let a1 = entry(sha: "a1", subjectId: "s", personName: "Sam", fileName: "a.jpg", captureDate: date(2021, 9, 20))
        let model = makeModel([a1])
        model.showLibrary()
        // An unknown id is rejected.
        model.focusLibrary("not-an-id")
        #expect(model.libraryFocusedID == a1.id)
    }

    // MARK: - 2. Arrow navigation

    /// Six entries (one person/month, descending capture dates) over a 2-column grid:
    /// ordered indices 0…5 form three full rows of 2, so Up/Down (∓2) land on a
    /// DIFFERENT entry than Left/Right (∓1).
    private func navModel() -> (AppModel, [String]) {
        var entries: [KeptEntry] = []
        for i in 0 ..< 6 {
            entries.append(entry(
                sha: "n\(i)",
                subjectId: "solo",
                personName: "Solo",
                fileName: "p\(i).jpg",
                // Descending capture dates ⇒ p0 newest ⇒ index 0; unique days.
                captureDate: date(2021, 9, 28 - i)
            ))
        }
        let model = makeModel(entries, columns: 2)
        model.showLibrary()
        return (model, model.libraryOrderedIDs)
    }

    @Test("Left/Right move by ∓1, Up/Down by ∓columnCount, all clamped (no wrap)")
    func arrowNavigation() {
        let (model, ids) = navModel()
        #expect(ids.count == 6)
        #expect(model.libraryFocusedID == ids[0])

        // Right by one.
        model.moveLibraryRight()
        #expect(model.libraryFocusedID == ids[1])
        // Down by columnCount (2) — a DIFFERENT entry than Left/Right's ∓1.
        model.moveLibraryDown()
        #expect(model.libraryFocusedID == ids[3])
        // Left by one.
        model.moveLibraryLeft()
        #expect(model.libraryFocusedID == ids[2])
        // Up by columnCount back to ids[0].
        model.moveLibraryUp()
        #expect(model.libraryFocusedID == ids[0])

        // Clamp at the first entry: Left and Up do not wrap.
        model.moveLibraryLeft()
        #expect(model.libraryFocusedID == ids[0])
        model.moveLibraryUp()
        #expect(model.libraryFocusedID == ids[0])

        // Walk to the last and clamp there: Right and Down do not wrap past the end.
        for _ in 0 ..< 10 {
            model.moveLibraryRight()
        }
        #expect(model.libraryFocusedID == ids[5])
        model.moveLibraryRight()
        #expect(model.libraryFocusedID == ids[5])
        model.moveLibraryDown()
        #expect(model.libraryFocusedID == ids[5])
    }

    // MARK: - 3 & 4. Preview toggle + click-does-not-open

    @Test("libraryPreviewActive defaults false; toggle/open/close target the focused entry")
    func previewToggle() {
        let a1 = entry(sha: "a1", subjectId: "s", personName: "Sam", fileName: "a.jpg", captureDate: date(2021, 9, 20))
        let model = makeModel([a1])
        model.showLibrary()

        #expect(!model.libraryPreviewActive)
        model.toggleLibraryPreview()
        #expect(model.libraryPreviewActive)
        model.toggleLibraryPreview()
        #expect(!model.libraryPreviewActive)
        model.openLibraryPreview()
        #expect(model.libraryPreviewActive)
        model.closeLibraryPreview()
        #expect(!model.libraryPreviewActive)
    }

    @Test("toggling the preview with no focus / empty library is a safe no-op")
    func previewNoOpWhenEmpty() {
        let model = makeModel([])
        model.showLibrary()
        #expect(model.libraryFocusedID == nil)
        model.toggleLibraryPreview()
        #expect(!model.libraryPreviewActive)
        model.openLibraryPreview()
        #expect(!model.libraryPreviewActive)
    }

    @Test("click focuses a cell and does NOT auto-open the preview")
    func clickFocusesWithoutOpening() {
        let a1 = entry(sha: "a1", subjectId: "s", personName: "Sam", fileName: "a.jpg", captureDate: date(2021, 9, 20))
        let a2 = entry(sha: "a2", subjectId: "s", personName: "Sam", fileName: "b.jpg", captureDate: date(2021, 9, 10))
        let model = makeModel([a1, a2])
        model.showLibrary()
        #expect(model.libraryFocusedID == a1.id)

        model.focusLibrary(a2.id)
        #expect(model.libraryFocusedID == a2.id)
        #expect(!model.libraryPreviewActive)
    }

    // MARK: - 6. Review state untouched

    @Test("navigating/previewing the Library leaves all review state unchanged")
    func reviewUntouchedByLibrary() throws {
        let a1 = entry(sha: "a1", subjectId: "s-alice", personName: "alice", fileName: "a.jpg", captureDate: date(2021, 9, 20))
        let a2 = entry(sha: "a2", subjectId: "s-alice", personName: "alice", fileName: "b.jpg", captureDate: date(2021, 9, 10))
        let model = makeModel([a1, a2])

        // Establish a known review state.
        let firstID = try #require(model.focusedID)
        let candidate = try #require(model.candidate(for: firstID))
        model.skip(candidate) // a decision
        #expect(model.state(for: firstID) == .skipped)
        model.toggleSelection(firstID) // a multi-selection
        model.openPreview() // a known preview state
        #expect(model.isPreviewPresented)

        let reviewFocus = model.focusedID
        let reviewPreview = model.isPreviewPresented
        let reviewSelection = model.selectedPhotoIDs
        let reviewActive = model.activePersonID
        let reviewSelectedCandidate = model.selectedCandidateID

        // Enter the Library and exercise its own focus/nav/preview.
        model.showLibrary()
        model.moveLibraryRight()
        model.toggleLibraryPreview()
        #expect(model.libraryPreviewActive)
        model.showReview()

        // None of the review values moved.
        #expect(model.focusedID == reviewFocus)
        #expect(model.isPreviewPresented == reviewPreview)
        #expect(model.selectedPhotoIDs == reviewSelection)
        #expect(model.activePersonID == reviewActive)
        #expect(model.selectedCandidateID == reviewSelectedCandidate)
        #expect(model.state(for: firstID) == .skipped)
    }
}
