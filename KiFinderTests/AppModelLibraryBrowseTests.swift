import Foundation
@testable import KiFinder
import Testing

/// Item-18b assertion 6: the `AppModel` browse seam — the detail-mode flag, the exposed
/// grouped data for the current filter, `removeFromLibrary`, and that entering the
/// Library never disturbs Review state (active person, decisions, selection, focus).
@Suite("App model library browse")
@MainActor
struct AppModelLibraryBrowseTests {
    private let kion = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID
    private let exif = "2021:07:15 12:00:00"

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    /// Builds a model in sample mode whose injected library already holds one saved
    /// photo for Kris and one for Ava (root wired through `KION_LIBRARY_ROOT` so the
    /// model's `libraryRoot` resolves to the same place the copies live).
    private func populatedModel() async -> (AppModel, KeptLibrary, KeptEntry, KeptEntry) {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)

        let kionSource = LibraryFixtures.tempDir("k").appendingPathComponent("KION.jpg")
        let avaSource = LibraryFixtures.tempDir("a").appendingPathComponent("AVA.jpg")
        LibraryFixtures.writeImage(to: kionSource, red: 0.2, exifDate: exif)
        LibraryFixtures.writeImage(to: avaSource, red: 0.8, exifDate: exif)
        let kionEntry = requireSaved(await lib.save(originalAt: kionSource, subjectId: kion, personName: kion, score: 0.9))
        let avaEntry = requireSaved(await lib.save(originalAt: avaSource, subjectId: ava, personName: ava, score: 0.7))

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": store(),
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: lib
        )
        return (model, lib, kionEntry, avaEntry)
    }

    private func requireSaved(_ result: KeptSaveResult) -> KeptEntry {
        guard case let .saved(entry) = result else {
            Issue.record("expected .saved, got \(result)")
            return KeptEntry(sha256: "", subjectId: "", personName: "", path: "", sourcePath: "", score: 0, captureDate: Date(), savedAt: Date(), fileName: "")
        }
        return entry
    }

    private func allItems(_ model: AppModel) -> [LibraryPhotoItem] {
        model.libraryGroups.flatMap { $0.months.flatMap(\.items) }
    }

    private func drain() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    // MARK: - Detail mode flag

    @Test("showLibrary / showReview flip the browse flag (Review by default)")
    func toggleBrowseMode() async {
        let (model, _, _, _) = await populatedModel()
        #expect(!model.libraryBrowseActive)
        model.showLibrary()
        #expect(model.libraryBrowseActive)
        model.showReview()
        #expect(!model.libraryBrowseActive)
    }

    // MARK: - Exposed groups + remove

    @Test("entering the Library exposes every person's saved photos")
    func exposesGroups() async {
        let (model, _, kionEntry, avaEntry) = await populatedModel()
        model.showLibrary()
        let ids = Set(allItems(model).map(\.entry.id))
        #expect(ids.contains(kionEntry.id))
        #expect(ids.contains(avaEntry.id))
        #expect(model.libraryGroups.count == 2)
    }

    @Test("removeFromLibrary drops the entry from the exposed groups")
    func removeDropsFromGroups() async {
        let (model, _, kionEntry, _) = await populatedModel()
        model.showLibrary()
        #expect(allItems(model).contains { $0.entry.id == kionEntry.id })

        model.removeFromLibrary(kionEntry)
        // Optimistic update: the entry is gone from the exposed groups immediately.
        #expect(!allItems(model).contains { $0.entry.id == kionEntry.id })

        // …and stays gone after the off-actor delete + re-sync completes.
        await drain()
        #expect(!allItems(model).contains { $0.entry.id == kionEntry.id })
    }

    @Test("switching the filter changes the exposed groups")
    func filterChangesGroups() async {
        let (model, _, _, avaEntry) = await populatedModel()
        model.showLibrary()
        #expect(model.libraryGroups.count == 2)

        model.setLibraryFilter(ava)
        #expect(model.libraryGroups.map(\.subjectId) == [ava])
        #expect(allItems(model).allSatisfy { $0.entry.subjectId == ava })
        #expect(allItems(model).contains { $0.entry.id == avaEntry.id })

        model.setLibraryFilter(nil)
        #expect(model.libraryGroups.count == 2)
    }

    @Test("libraryFileURL resolves <root>/<entry.path>")
    func fileURL() async {
        let (model, _, kionEntry, _) = await populatedModel()
        #expect(model.libraryFileURL(for: kionEntry) == model.libraryRoot.appendingPathComponent(kionEntry.path))
    }

    // MARK: - Review state is untouched

    @Test("entering the Library leaves active person, decision, focus, and selection intact")
    func reviewStateUntouched() async throws {
        let (model, _, _, _) = await populatedModel()

        let firstID = try #require(model.focusedID)
        let candidate = try #require(model.candidate(for: firstID))
        model.skip(candidate)
        #expect(model.state(for: firstID) == .skipped)

        let activeBefore = model.activePersonID
        let focusBefore = model.focusedID
        let selectedBefore = model.selectedCandidateID

        model.showLibrary()

        #expect(model.libraryBrowseActive)
        #expect(model.activePersonID == activeBefore)
        #expect(model.focusedID == focusBefore)
        #expect(model.selectedCandidateID == selectedBefore)
        #expect(model.state(for: firstID) == .skipped)
    }
}
