import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 53, assertion 5: EVERY repository-write path (`addPerson`, `renamePerson`,
/// `deletePerson`, enrollment completion) runs the SAME ordered transaction —
/// capture → `cancelPending()` → repository write → re-schedule — never just the
/// roster-only paths passing vacuously because nothing was ever pending. Each test
/// arms a pending snapshot up front (so a no-op capture can't hide behind "there
/// was nothing to cancel anyway"), then asserts the EXACT event sequence a
/// persister + repository spy observed. A THROWING repository proves the captured
/// snapshot is restored (re-scheduled) UNCHANGED rather than silently dropped.
@Suite("Repository-write transaction order (item 53)")
@MainActor
struct AppModelRepositoryTransactionTests {
    private func uniqueStore(_ tag: String = "order") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-\(tag)-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func uniqueLibraryRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-order-lib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A one-subject `ProfileStore`, standing in for "some OTHER person's pending
    /// feedback" already armed on the persister before the op under test runs.
    private func armedStore(subject: String = "B") -> ProfileStore {
        var store = ProfileStore(modelId: FileProfileRepository.modelId, modelVersion: FileProfileRepository.modelVersion)
        store[subject] = ProfileBundle(
            subjectId: subject,
            references: [FaceEmbedding([1, 2, 3])],
            threshold: 0.45,
            modelId: FileProfileRepository.modelId,
            modelVersion: FileProfileRepository.modelVersion
        )
        return store
    }

    private func makeModel(
        storeURL: URL,
        repository: RecordingProfileRepository,
        engine: OrderRecordingEngine
    ) -> AppModel {
        AppModel(
            engine: engine,
            environment: [
                "KION_PROFILE_STORE": storeURL.path,
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": uniqueLibraryRoot().path,
            ],
            profileRepository: repository
        )
    }

    // MARK: - addPerson

    @Test("addPerson: capture -> cancelPending -> savePerson -> re-schedule (roster-only write still reschedules)")
    func addPersonOrder() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let engine = OrderRecordingEngine(log: log, initialPending: armedStore())
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        log.reset()

        _ = model.addPerson(name: "Ava")

        #expect(log.events == ["cancelPending", "savePerson", "schedule"])
        #expect(model.rosterError == nil)
    }

    @Test("addPerson: repository throw restores the captured snapshot UNCHANGED and surfaces an error")
    func addPersonThrowRestores() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        repo.throwOnSavePerson = true
        let armed = armedStore()
        let engine = OrderRecordingEngine(log: log, initialPending: armed)
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        log.reset()

        _ = model.addPerson(name: "Ava")

        #expect(log.events == ["cancelPending", "savePerson", "schedule"])
        #expect(engine.lastResumedStore == armed) // restored UNCHANGED, not dropped
        #expect(model.rosterError != nil)
        #expect(model.people.isEmpty) // no phantom person
    }

    // MARK: - renamePerson

    @Test("renamePerson: capture -> cancelPending -> savePerson -> re-schedule (roster-only write still reschedules)")
    func renamePersonOrder() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let engine = OrderRecordingEngine(log: log)
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        let ava = model.addPerson(name: "Ava")
        engine.armPending(armedStore())
        log.reset()

        model.renamePerson(id: ava.id, to: "Ava B.")

        #expect(log.events == ["cancelPending", "savePerson", "schedule"])
        #expect(model.rosterError == nil)
        #expect(model.people.first { $0.id == ava.id }?.displayName == "Ava B.")
    }

    @Test("renamePerson: repository throw restores the captured snapshot UNCHANGED, keeps the OLD name, surfaces an error")
    func renamePersonThrowRestores() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let engine = OrderRecordingEngine(log: log)
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        let ava = model.addPerson(name: "Ava")
        let armed = armedStore()
        engine.armPending(armed)
        log.reset()
        repo.throwOnSavePerson = true

        model.renamePerson(id: ava.id, to: "Ava B.")

        #expect(log.events == ["cancelPending", "savePerson", "schedule"])
        #expect(engine.lastResumedStore == armed)
        #expect(model.rosterError != nil)
        #expect(model.people.first { $0.id == ava.id }?.displayName == "Ava") // OLD name
    }

    // MARK: - deletePerson

    @Test("deletePerson: capture -> cancelPending -> deletePerson -> re-schedule (pruned)")
    func deletePersonOrder() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let engine = OrderRecordingEngine(log: log)
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        let ava = model.addPerson(name: "Ava")
        engine.armPending(armedStore())
        log.reset()

        model.deletePerson(id: ava.id)

        #expect(log.events == ["cancelPending", "deletePerson", "schedule"])
        #expect(model.rosterError == nil)
        // The re-scheduled snapshot is the ARMED one, pruned of the deleted id (a
        // no-op prune here since "Ava" was never a key in the standalone armed
        // fixture — the crux's actual prune is proven end-to-end in
        // `AppModelDeleteRaceTests`). What matters here is the ORDER, plus that a
        // reschedule genuinely happened with a non-nil snapshot.
        #expect(engine.lastResumedStore != nil)
    }

    @Test("deletePerson: repository throw restores the captured snapshot UNCHANGED and surfaces an error, no roster mutation")
    func deletePersonThrowRestores() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let engine = OrderRecordingEngine(log: log)
        let model = makeModel(storeURL: storeURL, repository: repo, engine: engine)
        let ava = model.addPerson(name: "Ava")
        let armed = armedStore()
        engine.armPending(armed)
        log.reset()
        repo.throwOnDeletePerson = true

        model.deletePerson(id: ava.id)

        #expect(log.events == ["cancelPending", "deletePerson", "schedule"])
        #expect(engine.lastResumedStore == armed) // restored UNCHANGED — no prune ran
        #expect(model.rosterError != nil)
        #expect(model.people.contains { $0.id == ava.id }) // NOT deleted
    }

    // MARK: - Enrollment completion

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeValidReferences(_ count: Int) throws -> [URL] {
        let dir = uniqueLibraryRoot()
        let source = Self.repoRoot().appendingPathComponent("Tests/Fixtures/face_a.jpg")
        return try (0 ..< count).map { index in
            let dest = dir.appendingPathComponent("ref-\(index).jpg")
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        }
    }

    @Test("Enrollment completion: capture -> cancelPending -> saveProfile -> re-schedule, THEN the same for savePerson")
    func enrollmentCompletionOrder() async throws {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        let armed = armedStore()
        let engine = OrderRecordingEngine(log: log, initialPending: armed)
        let refs = try makeValidReferences(5)

        let enrollment = EnrollmentModel(
            engine: engine,
            repository: repo,
            subjectId: "C",
            initialName: "Cleo",
            testReferencePaths: refs,
            onComplete: { _ in }
        )
        enrollment.addTestReferences()
        log.reset()

        await enrollment.enroll()

        #expect(enrollment.errorMessage == nil)
        // Two writes (saveProfile, then savePerson) — EACH wrapped in its own
        // capture/cancel/write/reschedule transaction (so the roster-only second
        // write can't pass vacuously either).
        #expect(log.events == ["cancelPending", "saveProfile", "schedule", "cancelPending", "savePerson", "schedule"])
    }

    @Test("Enrollment completion: saveProfile throw restores the captured snapshot UNCHANGED and surfaces errorMessage")
    func enrollmentCompletionThrowRestores() async throws {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        repo.throwOnSaveProfile = true
        let armed = armedStore()
        let engine = OrderRecordingEngine(log: log, initialPending: armed)
        let refs = try makeValidReferences(5)

        let enrollment = EnrollmentModel(
            engine: engine,
            repository: repo,
            subjectId: "C",
            initialName: "Cleo",
            testReferencePaths: refs,
            onComplete: { _ in Issue.record("onComplete must not fire on a failed enrollment") }
        )
        enrollment.addTestReferences()
        log.reset()

        await enrollment.enroll()

        #expect(log.events == ["cancelPending", "saveProfile", "schedule"])
        #expect(engine.lastResumedStore == armed) // restored UNCHANGED
        #expect(enrollment.errorMessage != nil)
    }
}

/// Item 53, assertion 6: the common ("nothing pending") delete path is jank-free —
/// `cancelPending()` runs, but `flush()` is NEVER awaited, so `deletePerson` cannot
/// block the main thread for the debounce window. `deletePerson`'s signature is
/// itself non-`async` (calling it with no `await` compiles), which the spy's
/// missing "flush" event corroborates.
@Suite("Delete is jank-free on the common path (item 53)")
@MainActor
struct AppModelDeleteJankFreeTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-jankfree-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func uniqueLibraryRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-jankfree-lib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Nothing pending: deletePerson hits cancelPending() but never awaits flush()")
    func nothingPendingDeleteNeverFlushes() {
        let log = OrderEventLog()
        let storeURL = uniqueStore()
        let repo = RecordingProfileRepository(wrapping: FileProfileRepository(storeURL: storeURL), log: log)
        // No `initialPending` — the common case: nothing armed on the persister.
        let engine = OrderRecordingEngine(log: log, initialPending: nil)
        let model = AppModel(
            engine: engine,
            environment: [
                "KION_PROFILE_STORE": storeURL.path,
                "KION_RESET": "1",
                "KION_LIBRARY_ROOT": uniqueLibraryRoot().path,
            ],
            profileRepository: repo
        )
        let ava = model.addPerson(name: "Ava")
        log.reset()

        // Non-`async` call: the compiler itself proves this can't suspend on flush.
        model.deletePerson(id: ava.id)

        // cancelPending() ran; nothing was pending, so no reschedule; `flush()` was
        // never invoked (no debounce-length wait on the common path).
        #expect(log.events == ["cancelPending", "deletePerson"])
        #expect(!log.events.contains("flush"))
    }
}
