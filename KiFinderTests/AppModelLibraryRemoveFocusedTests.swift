import CoreGraphics
import Foundation
@testable import KiFinder
import Testing

/// Item-26b: the Delete-key removal seam on `AppModel` — `focusedLibraryEntry` and
/// `removeFocusedFromLibrary()`. Exercised over a REAL `KeptLibrary` rooted in a temp
/// directory (NOT a memory prune) so the test can assert the saved file is deleted on
/// disk and dedupe is genuinely re-enabled for the removed content.
@Suite("App model library remove-focused")
@MainActor
struct AppModelLibraryRemoveFocusedTests {
    private let subject = "solo"

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    /// Builds a sample-mode model over a real `KeptLibrary` holding `count` distinct solo
    /// photos (distinct bytes + descending EXIF dates ⇒ a stable display order). Returns
    /// the model, the library, the entries IN DISPLAY ORDER, and their source URLs (kept
    /// alive so a re-save can prove dedupe was re-enabled).
    private func makeModel(count: Int) async -> (AppModel, KeptLibrary, [KeptEntry], [URL]) {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)

        var sources: [URL] = []
        for i in 0 ..< count {
            let source = LibraryFixtures.tempDir("src-\(i)").appendingPathComponent("p\(i).jpg")
            // Distinct red ⇒ distinct bytes (distinct sha); descending EXIF ⇒ p0 newest.
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.1 * CGFloat(i), exifDate: "2021:09:\(String(format: "%02d", 28 - i)) 12:00:00")
            sources.append(source)
            _ = await lib.save(originalAt: source, subjectId: subject, personName: subject, score: 0.9)
        }

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": store(),
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: lib
        )
        model.showLibrary()

        // Map the flattened display order back to entries (display order = the order the
        // grid + the keyboard cursor walk).
        let byID = Dictionary(uniqueKeysWithValues: lib.allEntries.map { ($0.id, $0) })
        let ordered = model.libraryOrderedIDs.compactMap { byID[$0] }
        return (model, lib, ordered, sources)
    }

    /// Lets the off-actor delete (and its re-sync) complete.
    private func drain(_ lib: KeptLibrary) async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
        await lib.flush()
    }

    private func fileExists(_ model: AppModel, _ entry: KeptEntry) -> Bool {
        FileManager.default.fileExists(atPath: model.libraryFileURL(for: entry).path)
    }

    // MARK: - focusedLibraryEntry

    @Test("focusedLibraryEntry maps the focused id to its entry, nil when unfocused")
    func focusedEntryAccessor() async {
        let (model, _, ordered, _) = await makeModel(count: 3)
        #expect(model.focusedLibraryEntry?.id == ordered[0].id)

        model.focusLibrary(ordered[2].id)
        #expect(model.focusedLibraryEntry?.id == ordered[2].id)

        model.libraryFocusedID = nil
        #expect(model.focusedLibraryEntry == nil)
    }

    // MARK: - removeFocusedFromLibrary

    @Test("removing a MIDDLE focused entry deletes the file, drops the id, focuses the NEXT, re-enables dedupe")
    func removeMiddle() async {
        let (model, lib, ordered, sources) = await makeModel(count: 3)
        let middle = ordered[1]
        let next = ordered[2]
        #expect(fileExists(model, middle))

        model.focusLibrary(middle.id)
        model.removeFocusedFromLibrary()

        // Focus lands on the NEXT entry (not the first — a lazy reseat would pick ordered[0]).
        #expect(model.libraryFocusedID == next.id)
        // The id is dropped from the ordered ids immediately.
        #expect(!model.libraryOrderedIDs.contains(middle.id))

        await drain(lib)
        // The saved file is gone from disk after the off-actor delete completes.
        #expect(!fileExists(model, middle))
        #expect(!lib.allEntries.contains { $0.id == middle.id })
        // Focus is still the next entry after the re-sync.
        #expect(model.libraryFocusedID == next.id)

        // Re-saving the SAME bytes for that subject now returns `.saved` — proving the
        // removal re-enabled dedupe (a memory prune would still report `.alreadySaved`).
        let result = await lib.save(originalAt: sources[1], subjectId: subject, personName: subject, score: 0.9)
        guard case .saved = result else {
            Issue.record("expected .saved after real removal, got \(result)")
            return
        }
    }

    @Test("removing the LAST focused entry focuses the new last")
    func removeLast() async {
        let (model, lib, ordered, _) = await makeModel(count: 3)
        let last = ordered[2]
        let newLast = ordered[1]

        model.focusLibrary(last.id)
        model.removeFocusedFromLibrary()

        #expect(model.libraryFocusedID == newLast.id)
        #expect(!model.libraryOrderedIDs.contains(last.id))
        await drain(lib)
        #expect(model.libraryFocusedID == newLast.id)
    }

    @Test("removing the ONLY focused entry yields nil focus")
    func removeOnly() async {
        let (model, lib, ordered, _) = await makeModel(count: 1)
        model.focusLibrary(ordered[0].id)
        model.removeFocusedFromLibrary()

        #expect(model.libraryFocusedID == nil)
        #expect(model.libraryOrderedIDs.isEmpty)
        await drain(lib)
        #expect(model.libraryFocusedID == nil)
    }

    @Test("removeFocusedFromLibrary with no focus is a no-op (order + focus unchanged)")
    func noOpWhenUnfocused() async {
        let (model, lib, ordered, _) = await makeModel(count: 3)
        model.libraryFocusedID = nil
        let before = model.libraryOrderedIDs

        model.removeFocusedFromLibrary()

        #expect(model.libraryFocusedID == nil)
        #expect(model.libraryOrderedIDs == before)
        await drain(lib)
        // Nothing was deleted on disk either.
        #expect(ordered.allSatisfy { fileExists(model, $0) })
        #expect(lib.allEntries.count == 3)
    }
}
