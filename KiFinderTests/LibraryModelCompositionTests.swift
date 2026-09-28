import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 65 composition seam: `AppModel` COMPOSES a separate `LibraryModel` — not an
/// extension, not a duplicated copy of state — reachable at `model.library`, and every
/// library op driven through the `AppModel` facade lands on that SAME single instance.
/// Exercised with a concrete, observable operation (a real library multi-selection),
/// never a trivial boolean forward, and proves the `selectPerson` invariant (item 65
/// assertion 5/9): selecting a person returns the detail pane to Review WITHOUT clearing
/// the library selection.
@Suite("LibraryModel composition (item 65)")
@MainActor
struct LibraryModelCompositionTests {
    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    /// A model with a real `KeptLibrary` holding `count` saved photos (same subject,
    /// distinct content/dates so ordering is deterministic), with `libraryRoot` wired to
    /// where the copies live.
    private func populatedModel(count: Int = 3) async -> (AppModel, [KeptEntry]) {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)

        var entries: [KeptEntry] = []
        for i in 0 ..< count {
            let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG_\(i).jpg")
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.2 * CGFloat(i), exifDate: "2021:07:1\(i) 12:00:00")
            guard case let .saved(entry) = await lib.save(
                originalAt: source, subjectId: "kris", personName: "Kris", score: 0.9
            ) else {
                Issue.record("expected .saved for entry \(i)")
                continue
            }
            entries.append(entry)
        }

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_PROFILE_STORE": store(),
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: lib
        )
        return (model, entries)
    }

    // MARK: - Composition: `model.library` is a real, singular `LibraryModel`

    @Test("AppModel exposes library: LibraryModel; a facade-driven library op is reflected in the SAME LibraryModel instance")
    func facadeOpReflectsInComposedInstance() async throws {
        let (model, _) = await populatedModel()
        // Capture the composed instance BEFORE the op — proves it's never
        // replaced/duplicated by a later library call.
        let library = try #require(model.library)

        model.showLibrary()
        let ids = model.libraryOrderedIDs
        #expect(ids.count == 3)

        // Drive a REAL library multi-selection through the AppModel facade only.
        model.selectLibrary(ids[0])
        model.toggleLibrarySelection(ids[1])

        // Visible identically through BOTH the facade and the composed sub-model — same
        // single instance, not a copy.
        #expect(model.selectedLibraryIDs == [ids[0], ids[1]])
        #expect(model.library.selectedLibraryIDs == [ids[0], ids[1]])
        #expect(model.library === library)
        #expect(model.libraryAnchorID == ids[0])
        #expect(model.library.libraryAnchorID == ids[0])
    }

    // MARK: - selectPerson returns to Review WITHOUT clearing the library selection

    @Test("selectPerson sets libraryBrowseActive false but leaves the library selection untouched, through both the facade and model.library")
    func selectPersonLeavesSelectionIntact() async {
        let (model, _) = await populatedModel()
        let ava = model.addPerson(name: "Ava")
        let bea = model.addPerson(name: "Bea")
        #expect(model.activePersonID == bea.id) // addPerson made Bea active last

        model.showLibrary()
        let ids = model.libraryOrderedIDs
        model.selectLibrary(ids[0])
        model.toggleLibrarySelection(ids[1])
        let selectionBefore = model.selectedLibraryIDs
        #expect(selectionBefore == [ids[0], ids[1]])
        #expect(model.libraryBrowseActive == true)

        // Switch the active person via the facade — a genuine Review action.
        model.selectPerson(id: ava.id)

        // Returns to Review…
        #expect(model.activePersonID == ava.id)
        #expect(model.libraryBrowseActive == false)
        #expect(model.library.libraryBrowseActive == false)
        // …but the library selection is UNCHANGED — selectPerson never routes through the
        // selection-clearing `showReview()`. Verified through BOTH the facade AND the
        // composed `LibraryModel` directly (same instance, same state).
        #expect(model.selectedLibraryIDs == selectionBefore)
        #expect(model.library.selectedLibraryIDs == selectionBefore)
    }
}
