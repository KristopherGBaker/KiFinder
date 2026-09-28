import Foundation
@testable import KiFinder
import Testing

/// Item-22 assertion 7: `AppModel.renamePerson` runs the library migration through the
/// `KeptLibrarySaving` seam OFF the keypress path (returns + roster/Review state usable
/// before the migration is released), with the right arguments, and refreshes the
/// exposed `libraryGroups` to the new name once the migration lands.
@Suite("App model rename library migration")
@MainActor
struct AppModelRenameLibraryTests {
    private let exif = "2021:07:15 12:00:00"

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    /// Polls the main actor until `condition` holds or a generous budget is spent,
    /// sleeping real wall-clock between checks so the awaited migration (which needs
    /// actual time, not just actor hops) reliably completes under full-suite load
    /// rather than exhausting a fixed yield count.
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 3000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("renamePerson returns + Review usable before migration releases, then groups update")
    func renameOffKeypressThenRefresh() async {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: index)
        let spy = SuspendingRenameSpy(wrapping: library)

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": store(),
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: spy
        )

        // Enroll a person and save one library photo for them.
        let person = model.addPerson(name: "Ava")
        let src = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: src, red: 0.3, exifDate: exif)
        _ = await library.save(originalAt: src, subjectId: person.id, personName: "Ava", score: 0.8)

        model.showLibrary()
        #expect(model.libraryGroups.contains { $0.personName == "Ava" })

        // Capture Review state, then rename.
        let activeBefore = model.activePersonID
        let focusBefore = model.focusedID
        let selectedBefore = model.selectedCandidateID

        model.renamePerson(id: person.id, to: "Eva")

        // BEFORE the migration releases: renamePerson has returned, the roster shows the
        // new name, and Review state is untouched beyond the roster update.
        #expect(model.people.first { $0.id == person.id }?.displayName == "Eva")
        #expect(model.activePersonID == activeBefore)
        #expect(model.focusedID == focusBefore)
        #expect(model.selectedCandidateID == selectedBefore)
        // The migration was invoked with the right id/newName but hasn't completed, so the
        // exposed groups still carry the OLD name.
        await until { spy.renameStarted }
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.subjectId == person.id)
        #expect(spy.calls.first?.newName == "Eva")
        #expect(model.libraryGroups.contains { $0.personName == "Ava" })
        #expect(!model.libraryGroups.contains { $0.personName == "Eva" })

        // Release the migration; the exposed groups now reflect the new personName.
        spy.release()
        await until { model.libraryGroups.contains { $0.personName == "Eva" } }
        #expect(model.libraryGroups.contains { $0.personName == "Eva" })
        #expect(!model.libraryGroups.contains { $0.personName == "Ava" })
    }
}
