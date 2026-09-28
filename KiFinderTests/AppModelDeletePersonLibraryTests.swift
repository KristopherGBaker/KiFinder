import Foundation
@testable import KiFinder
import Testing

/// Item-32 assertion 2: `AppModel.deletePerson` purges the deleted subject's saved
/// photos AND clears ONLY the library browse state that referenced them — the deleted
/// person's selected ids leave `selectedLibraryIDs` (other people's survive),
/// `libraryFocusedID` drops if it pointed at the deleted person, and
/// `libraryFilterSubjectID` resets to `nil`. The state clearing is synchronous (no
/// yield); the on-disk purge lands through the existing keep-save drain (`flushLibrary`).
@Suite("App model delete person library purge")
@MainActor
struct AppModelDeletePersonLibraryTests {
    private let exif = "2021:07:15 12:00:00"

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    @Test("deletePerson clears referencing state synchronously, then purges entries on drain")
    func deletePersonPurgesLibraryAndClearsState() async {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let library = KeptLibrary(root: root, indexURL: index)

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": store(),
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: library
        )

        // Two enrolled people; Ava (deleted) has TWO saved photos, Bea (kept) has one.
        let ava = model.addPerson(name: "Ava")
        let bea = model.addPerson(name: "Bea")
        let a1Src = LibraryFixtures.tempDir("src").appendingPathComponent("A1.jpg")
        let a2Src = LibraryFixtures.tempDir("src").appendingPathComponent("A2.jpg")
        let b1Src = LibraryFixtures.tempDir("src").appendingPathComponent("B1.jpg")
        LibraryFixtures.writeImage(to: a1Src, red: 0.1, exifDate: exif)
        LibraryFixtures.writeImage(to: a2Src, red: 0.4, exifDate: exif)
        LibraryFixtures.writeImage(to: b1Src, red: 0.7, exifDate: exif)

        guard case let .saved(a1) = await library.save(originalAt: a1Src, subjectId: ava.id, personName: "Ava", score: 0.8),
              case .saved = await library.save(originalAt: a2Src, subjectId: ava.id, personName: "Ava", score: 0.7),
              case let .saved(b1) = await library.save(originalAt: b1Src, subjectId: bea.id, personName: "Bea", score: 0.9)
        else {
            Issue.record("expected three saved entries")
            return
        }

        // Browse state references the deleted person: filter on Ava, focus on an Ava photo,
        // and a selection spanning BOTH people. (Set the selection/focus AFTER the filter,
        // since setLibraryFilter clears the selection.)
        model.showLibrary()
        model.setLibraryFilter(ava.id)
        model.selectedLibraryIDs = [a1.id, b1.id]
        model.libraryFocusedID = a1.id

        #expect(model.libraryGroups.contains { $0.subjectId == ava.id })

        model.deletePerson(id: ava.id)

        // Synchronous (no yield): only the deleted person's referencing state is cleared.
        #expect(!model.selectedLibraryIDs.contains(a1.id))
        #expect(model.selectedLibraryIDs.contains(b1.id))
        #expect(model.libraryFocusedID != a1.id)
        #expect(model.libraryFilterSubjectID == nil)

        // Roster regression: Ava gone, Bea remains, active re-seated off the deleted id.
        #expect(!model.people.contains { $0.id == ava.id })
        #expect(model.people.contains { $0.id == bea.id })
        #expect(model.activePersonID != ava.id)

        // After the existing drain, the purge has landed: Ava's entries are gone from both
        // the index and the exposed groups; Bea's survive.
        await model.flushLibrary()

        #expect(!library.allEntries.contains(a1))
        #expect(library.allEntries.contains(b1))
        #expect(!model.libraryGroups.contains { $0.subjectId == ava.id })
        #expect(model.libraryGroups.contains { $0.subjectId == bea.id })
    }
}

/// A `SkipRecording` spy that records `removeSubject` purges (default no-op otherwise),
/// so a delete test can prove the deleted subject's persistent skips are purged.
private final class RemoveRecordingSkipStore: SkipRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [String] = []
    var removedSubjects: [String] { lock.withLock { _removed } }

    func isSkipped(sourcePath _: String, subjectId _: String) -> Bool { false }
    func recordSkip(sourcePath _: String, subjectId _: String) {}
    func clearSkip(sourcePath _: String, subjectId _: String) {}
    func removeSubject(_ subjectId: String) { lock.withLock { _removed.append(subjectId) } }
    func flush() async {}
}

/// A `KeptLibrarySaving` spy that records `removeSubject` purges, so a delete test can
/// prove the deleted subject's saved-copy purge is scheduled off the main path.
private final class RemoveRecordingKeptLibrary: KeptLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [String] = []
    var removedSubjects: [String] { lock.withLock { _removed } }
    var allEntries: [KeptEntry] { [] }

    func save(originalAt _: URL, subjectId _: String, personName _: String, score _: Double) async -> KeptSaveResult {
        .sourceMissing
    }

    func isSaved(sourcePath _: String, subjectId _: String) -> Bool { false }
    func remove(_: KeptEntry) async -> Bool { false }
    func removeSubject(_ subjectId: String) async { lock.withLock { _removed.append(subjectId) } }
    func flush() async {}
}

/// Item 51: deleting the LAST remaining person must not strand the user on an empty
/// Review (or in Library browse) — it returns the detail pane to Review if the Library
/// was open and presents enrollment for a brand-new person. Deleting a person while
/// others remain keeps today's behavior (fallback, no sheet, no forced Review return).
@Suite("App model delete last person re-opens enrollment")
@MainActor
struct AppModelDeleteLastPersonTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-delete-last-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// A real `AppModel` on a fresh isolated store (per-instance isolated `UserDefaults`
    /// via the constructor default) with an empty reset roster.
    private func makeModel(extraEnv: [String: String] = [:]) -> AppModel {
        var environment = ["KION_PROFILE_STORE": uniqueStore().path, "KION_RESET": "1"]
        environment.merge(extraEnv) { _, new in new }
        return AppModel(engine: SampleTriageEngine(), environment: environment)
    }

    // MARK: - Assertions 1 & 2: last-person delete presents fresh enrollment

    @Test("Deleting the sole person presents enrollment for a brand-new person")
    func lastPersonDeletePresentsFreshEnrollment() throws {
        let model = makeModel()
        let solo = model.addPerson(name: "Ava")
        #expect(model.people.count == 1)

        model.deletePerson(id: solo.id)

        // Assertion 1: roster empty, no active person, enrollment sheet up.
        #expect(model.people.isEmpty)
        #expect(model.activePersonID == nil)
        #expect(model.isEnrollmentPresented)
        let enrollment = try #require(model.enrollmentModel)

        // Assertion 2: fresh identity — a new UUID id (not the purged one), empty prefill.
        #expect(enrollment.subjectId != solo.id)
        #expect(UUID(uuidString: enrollment.subjectId) != nil)
        #expect(enrollment.displayName == "")
    }

    // MARK: - Assertion 3: negative multi-person remaining

    @Test("Deleting one of several people does NOT present enrollment and falls back")
    func multiPersonDeleteNoEnrollment() {
        let model = makeModel()
        let ava = model.addPerson(name: "Ava")
        let bea = model.addPerson(name: "Bea")
        #expect(model.activePersonID == bea.id)

        model.deletePerson(id: bea.id)

        #expect(!model.isEnrollmentPresented)
        #expect(model.enrollmentModel == nil)
        #expect(model.activePersonID == ava.id)
        #expect(model.people.count == 1)
    }

    // MARK: - Assertion 4: last-person delete returns from Library to Review

    @Test("Deleting the sole person returns from Library to Review and presents enrollment")
    func lastPersonDeleteReturnsFromLibrary() {
        let model = makeModel()
        let solo = model.addPerson(name: "Ava")
        model.showLibrary()
        model.selectedLibraryIDs = ["entry-a", "entry-b"]
        #expect(model.libraryBrowseActive == true)

        model.deletePerson(id: solo.id)

        #expect(model.libraryBrowseActive == false)
        #expect(model.selectedLibraryIDs.isEmpty)
        #expect(model.isEnrollmentPresented)
    }

    // MARK: - Assertion 5: library-browse negative (others remain)

    @Test("Deleting one of several people while in Library keeps Library active, no sheet")
    func multiPersonDeleteKeepsLibraryActive() {
        let model = makeModel()
        _ = model.addPerson(name: "Ava")
        let bea = model.addPerson(name: "Bea")
        model.showLibrary()
        #expect(model.libraryBrowseActive == true)

        model.deletePerson(id: bea.id)

        #expect(model.libraryBrowseActive == true)
        #expect(!model.isEnrollmentPresented)
        #expect(model.enrollmentModel == nil)
    }

    // MARK: - Assertion 6: no re-present loop

    @Test("Dismissing the auto-presented enrollment stays dismissed; add-person re-presents")
    func noRePresentLoop() {
        let model = makeModel()
        let solo = model.addPerson(name: "Ava")
        model.deletePerson(id: solo.id)
        #expect(model.isEnrollmentPresented)

        model.dismissEnrollment()
        #expect(!model.isEnrollmentPresented)
        #expect(model.enrollmentModel == nil)
        // Nothing re-presents on its own after dismissal (no roster-emptying delete).
        #expect(!model.isEnrollmentPresented)

        // Enrollment stays reachable via the existing add-person path.
        model.beginAddPerson()
        #expect(model.isEnrollmentPresented)
        #expect(model.enrollmentModel != nil)
    }

    // MARK: - Assertion 7: persistence — the delete really hit disk

    @Test("Last-person delete persists an empty roster to disk")
    func lastPersonDeletePersistsEmptyRoster() {
        let store = uniqueStore()
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": store.path, "KION_RESET": "1"]
        )
        let solo = model.addPerson(name: "Ava")

        model.deletePerson(id: solo.id)

        // A fresh repository reading the same store agrees the roster is empty.
        #expect(FileProfileRepository(storeURL: store).loadRoster().isEmpty)
    }

    // MARK: - Assertion 8: purge side effects preserved on the last-person path

    @Test("Last-person delete still purges skips and schedules the library purge")
    func lastPersonDeletePurgesSideEffects() async {
        let skipSpy = RemoveRecordingSkipStore()
        let keptSpy = RemoveRecordingKeptLibrary()
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_RESET": "1"],
            keptLibrary: keptSpy,
            skipStore: skipSpy
        )
        let solo = model.addPerson(name: "Ava")

        model.deletePerson(id: solo.id)

        // Skip purge is synchronous.
        #expect(skipSpy.removedSubjects.contains(solo.id))
        // The library purge is scheduled off the main path — drain to land it.
        await model.flushLibrary()
        #expect(keptSpy.removedSubjects.contains(solo.id))
        // And the enrollment sheet is still presented alongside the purges.
        #expect(model.isEnrollmentPresented)
    }

    // MARK: - Assertion 9: the model-download onboarding gate is unaffected

    @Test("Last-person delete never trips the model-download onboarding gate")
    func lastPersonDeleteLeavesOnboardingGateUnchanged() throws {
        // A valid model override → the gate is down before we touch the roster. (Pattern
        // of OnboardingGateTests.overrideSkipsOnboarding.)
        let modelDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-delete-last-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let override = modelDir.appendingPathComponent("model.onnx")
        try Data([1, 2, 3]).write(to: override)
        let appSupport = modelDir.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_PROFILE_STORE": uniqueStore().path,
                "KION_RESET": "1",
                "KION_MODEL_PATH": override.path,
            ],
            modelLocations: ModelLocations(appSupportRoot: appSupport)
        )
        let solo = model.addPerson(name: "Ava")
        #expect(model.needsOnboarding == false)

        model.deletePerson(id: solo.id)

        // The delete presents the enrollment SHEET, never the model-download gate.
        #expect(model.needsOnboarding == false)
        #expect(model.isEnrollmentPresented)
    }
}
