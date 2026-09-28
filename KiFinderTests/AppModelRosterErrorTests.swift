import Foundation
@testable import KiFinder
import Testing

/// Item 53, assertions 7-9: a roster/store write failure in `addPerson`/
/// `renamePerson`/`deletePerson` surfaces through the SAME channel `exportError`
/// uses (a user-visible message + a "Try Again" retry, wired to a root-view alert —
/// see `KiFinderRootView`'s `rosterError` alert), rather than the old `try?`
/// silently no-op'ing. A failure never performs a "success-only" mutation, and a
/// retry re-attempts the exact failed operation once per invocation.
@Suite("Roster write failure surfaces a user-visible error with retry (item 53)")
@MainActor
struct AppModelRosterErrorTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-roster-error-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func uniqueLibraryRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-roster-error-lib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepo(_ storeURL: URL) -> RecordingProfileRepository {
        RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: OrderEventLog())
    }

    private func makeModel(
        storeURL: URL,
        repository: RecordingProfileRepository,
        keptLibrary: (any KeptLibrarySaving)? = nil,
        skipStore: (any SkipRecording)? = nil
    ) -> AppModel {
        AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_PROFILE_STORE": storeURL.path,
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": uniqueLibraryRoot().path,
            ],
            keptLibrary: keptLibrary,
            skipStore: skipStore,
            profileRepository: repository
        )
    }

    // MARK: - addPerson

    @Test("addPerson: throwing repository leaves people/activePersonID unchanged (no phantom person) and surfaces rosterError; retry heals")
    func addPersonFailureThenRetryHeals() {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        repo.throwOnSavePerson = true
        let model = makeModel(storeURL: storeURL, repository: repo)
        let activeBefore = model.activePersonID

        _ = model.addPerson(name: "Ava")

        #expect(model.people.isEmpty) // no phantom person
        #expect(model.activePersonID == activeBefore)
        #expect(model.rosterError != nil)

        repo.throwOnSavePerson = false
        model.retryRoster()

        #expect(model.rosterError == nil)
        #expect(model.people.count == 1)
        #expect(model.people.first?.displayName == "Ava")
        #expect(model.activePersonID == model.people.first?.id)
        // The write really landed.
        #expect(FileProfileRepository(storeURL: storeURL).loadRoster().contains { $0.displayName == "Ava" })
    }

    @Test("addPerson: retry re-attempts once; a still-throwing repository re-surfaces the error")
    func addPersonRetryStillThrowingReSurfaces() {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        repo.throwOnSavePerson = true
        let model = makeModel(storeURL: storeURL, repository: repo)

        _ = model.addPerson(name: "Ava")
        #expect(model.rosterError != nil)

        model.retryRoster() // still throwing
        #expect(model.rosterError != nil) // re-surfaced, not silently cleared
        #expect(model.people.isEmpty)
    }

    // MARK: - renamePerson

    @Test("renamePerson: throwing repository shows the OLD name and surfaces rosterError; retry heals")
    func renamePersonFailureThenRetryHeals() {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        let model = makeModel(storeURL: storeURL, repository: repo)
        let ava = model.addPerson(name: "Ava") // succeeds — repo not yet throwing

        repo.throwOnSavePerson = true
        model.renamePerson(id: ava.id, to: "Ava B.")

        #expect(model.people.first { $0.id == ava.id }?.displayName == "Ava") // OLD name
        #expect(model.rosterError != nil)

        repo.throwOnSavePerson = false
        model.retryRoster()

        #expect(model.rosterError == nil)
        #expect(model.people.first { $0.id == ava.id }?.displayName == "Ava B.")
    }

    @Test("renamePerson failure launches NO library-migration task")
    func renamePersonFailureLaunchesNoMigration() async {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        let librarySpy = RenameRecordingKeptLibrary()
        let model = makeModel(storeURL: storeURL, repository: repo, keptLibrary: librarySpy)
        let ava = model.addPerson(name: "Ava")

        repo.throwOnSavePerson = true
        model.renamePerson(id: ava.id, to: "Ava B.")

        // Give any errantly-spawned Task a chance to run before asserting absence.
        await Task.yield()
        await Task.yield()
        #expect(librarySpy.renamedSubjects.isEmpty)
    }

    // MARK: - deletePerson

    @Test("deletePerson: throwing repository leaves roster, skip store, and browse/selection state fully intact; surfaces rosterError; retry heals")
    func deletePersonFailureLeavesStateIntactThenRetryHeals() async {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        let keptSpy = FailureTestKeptLibrarySpy()
        let skipSpy = FailureTestSkipStoreSpy()
        let model = makeModel(storeURL: storeURL, repository: repo, keptLibrary: keptSpy, skipStore: skipSpy)
        let ava = model.addPerson(name: "Ava")
        _ = model.addPerson(name: "Bea")

        model.showLibrary()
        // Filter FIRST — `setLibraryFilter` clears the selection, so setting it
        // afterward would (correctly) wipe these back out regardless of delete.
        model.setLibraryFilter(ava.id)
        model.selectedLibraryIDs = ["entry-x"]
        model.libraryFocusedID = "entry-x"
        let activeBefore = model.activePersonID

        repo.throwOnDeletePerson = true
        model.deletePerson(id: ava.id)

        // Failure ⇒ no success-only mutation, across EVERY side effect.
        #expect(model.people.contains { $0.id == ava.id })
        #expect(model.activePersonID == activeBefore)
        #expect(model.rosterError != nil)
        #expect(model.selectedLibraryIDs == ["entry-x"])
        #expect(model.libraryFocusedID == "entry-x")
        #expect(model.libraryFilterSubjectID == ava.id)
        #expect(model.libraryBrowseActive == true)
        #expect(skipSpy.removedSubjects.isEmpty) // un-purged
        await model.flushLibrary()
        #expect(keptSpy.removedSubjects.isEmpty) // no purge task was ever scheduled
        #expect(!model.isEnrollmentPresented)

        repo.throwOnDeletePerson = false
        model.retryRoster()

        #expect(model.rosterError == nil)
        #expect(!model.people.contains { $0.id == ava.id })
        #expect(skipSpy.removedSubjects.contains(ava.id))
        await model.flushLibrary()
        #expect(keptSpy.removedSubjects.contains(ava.id))
    }

    @Test("deletePerson failure on the SOLE remaining person does NOT re-open enrollment")
    func deletePersonFailureSoleDoesNotReopenEnrollment() {
        let storeURL = uniqueStore()
        let repo = makeRepo(storeURL)
        let model = makeModel(storeURL: storeURL, repository: repo)
        let ava = model.addPerson(name: "Ava")
        #expect(model.people.count == 1)

        repo.throwOnDeletePerson = true
        model.deletePerson(id: ava.id)

        #expect(model.people.contains { $0.id == ava.id })
        #expect(!model.isEnrollmentPresented)
        #expect(model.rosterError != nil)
    }
}

// MARK: - Test doubles

/// A `KeptLibrarySaving` spy that records `renameSubject` calls — proves a failed
/// rename never launches the library-migration task.
private final class RenameRecordingKeptLibrary: KeptLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var _renamed: [String] = []
    var renamedSubjects: [String] { lock.withLock { _renamed } }
    var allEntries: [KeptEntry] { [] }

    func save(originalAt _: URL, subjectId _: String, personName _: String, score _: Double) async -> KeptSaveResult {
        .sourceMissing
    }

    func isSaved(sourcePath _: String, subjectId _: String) -> Bool { false }
    func remove(_: KeptEntry) async -> Bool { false }
    func renameSubject(_ subjectId: String, to _: String) async { lock.withLock { _renamed.append(subjectId) } }
    func flush() async {}
}

/// A `KeptLibrarySaving` spy that records `removeSubject` purges, so a delete
/// FAILURE test can prove no purge was ever scheduled.
private final class FailureTestKeptLibrarySpy: KeptLibrarySaving, @unchecked Sendable {
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

/// A `SkipRecording` spy that records `removeSubject` purges, so a delete FAILURE
/// test can prove the skip store was never purged.
private final class FailureTestSkipStoreSpy: SkipRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [String] = []
    var removedSubjects: [String] { lock.withLock { _removed } }

    func isSkipped(sourcePath _: String, subjectId _: String) -> Bool { false }
    func recordSkip(sourcePath _: String, subjectId _: String) {}
    func clearSkip(sourcePath _: String, subjectId _: String) {}
    func removeSubject(_ subjectId: String) { lock.withLock { _removed.append(subjectId) } }
    func flush() async {}
}
