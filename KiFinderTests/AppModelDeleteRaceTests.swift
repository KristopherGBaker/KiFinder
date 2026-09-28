import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 53's core coverage: a REAL `CoalescingProfileStoreWriter` over a temp
/// `KION_PROFILE_STORE`, wired through a REAL `LiveTriageEngine` + `AppModel`, so
/// the delete-vs-coalesced-write race is proven against genuine disk I/O — not a
/// spy standing in for either. Two tiers, both required:
///   1. `deleteIsDurableAgainstPendingWrite`/the crux/rename tests use a 30s
///      debounce so the timer never fires spontaneously — these prove the far
///      more common case (delete happens well before any write is even attempted)
///      settles via (a) the call has RETURNED, (b) [no separate async task exists
///      for the prune+reschedule step in this design — it runs synchronously
///      inside the transaction, spy-verified in `AppModelDeleteJankFreeTests`],
///      (c) `await` the real writer's `flush()`. No sleeps, no polling.
///   2. `deleteIsDurableAgainstInFlightEncode` forces the SPECIFIC residual race a
///      generation-bump alone cannot close: a write that has ALREADY passed its
///      generation check and started encoding when the cancel runs. It uses
///      `CoalescingProfileStoreWriter`'s test-only `beforeEncodeForTesting`/
///      `beforeCancelLockForTesting` hooks plus a `DispatchSemaphore` + a
///      `CheckedContinuation` (never a bare semaphore `.wait()` in the `async`
///      test body itself — Swift 6 forbids that) to force that EXACT
///      interleaving deterministically — no sleeps, no polling, no timing
///      guesswork.
@Suite("Delete-vs-coalesced-write race (item 53)")
@MainActor
struct AppModelDeleteRaceTests {
    private static let modelId = FileProfileRepository.modelId
    private static let modelVersion = FileProfileRepository.modelVersion

    private func uniqueDir(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-race-\(tag)-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueStoreURL(_ tag: String) -> URL {
        uniqueDir(tag).appendingPathComponent("store.json")
    }

    /// A 512-float embedding seeded from `seed` so each exemplar is distinct and
    /// identifiable in the resulting profile.
    private func embedding(seed: Float) -> FaceEmbedding {
        FaceEmbedding((0 ..< 512).map { seed + Float($0) * 0.001 })
    }

    private func bundle(_ subjectId: String, seed: Float) -> ProfileBundle {
        ProfileBundle(
            subjectId: subjectId,
            references: [embedding(seed: seed)],
            threshold: 0.45,
            modelId: Self.modelId,
            modelVersion: Self.modelVersion
        )
    }

    /// Seeds the roster + embedding store on disk for `subjects`, via a REAL
    /// `FileProfileRepository` over `storeURL` — genuine bytes on disk, not a
    /// synthesized in-memory fixture standing in for them.
    private func seedDisk(storeURL: URL, subjects: [(id: String, seed: Float)]) throws {
        let repo = FileProfileRepository(storeURL: storeURL)
        for subject in subjects {
            try repo.savePerson(Person(id: subject.id, displayName: subject.id))
            try repo.saveProfile(bundle(subject.id, seed: subject.seed))
        }
    }

    /// A manifest with one photo per (key, embedding) pair, so `recordFeedback`
    /// has something real to teach.
    private func manifest(photos: [(key: String, embedding: FaceEmbedding)]) -> Manifest {
        var manifest = Manifest(modelId: Self.modelId, modelVersion: Self.modelVersion)
        for photo in photos {
            manifest[photo.key] = BestFace(
                embedding: photo.embedding,
                qualityMetrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 0.4),
                subjectResults: [:]
            )
        }
        return manifest
    }

    /// A real `LiveTriageEngine` wired to a real `CoalescingProfileStoreWriter`
    /// (long debounce so it never fires spontaneously mid-test — settling is
    /// always via an explicit `flush()`), preloaded (via the existing
    /// `loadForTesting` seam) with an in-memory store MIRRORING what's on disk.
    private func makeEngine(
        storeURL: URL,
        subjectId: String,
        store: ProfileStore,
        manifest: Manifest
    ) -> LiveTriageEngine {
        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: subjectId,
            modelId: Self.modelId,
            modelVersion: Self.modelVersion,
            persister: CoalescingProfileStoreWriter(storeURL: storeURL, debounce: .seconds(30))
        )
        engine.loadForTesting(store: store, manifest: manifest)
        return engine
    }

    private func decodeDisk(_ storeURL: URL) throws -> ProfileStore {
        try ProfileStore.load(from: storeURL, expectingModelId: Self.modelId, expectingModelVersion: Self.modelVersion)
    }

    // MARK: - Assertions 1 & 2: the race (delete before any write is attempted)

    @Test("deletePerson(A) is durable against a pending coalesced write armed just before it (item 53 race)")
    func deleteIsDurableAgainstPendingWrite() async throws {
        let storeURL = uniqueStoreURL("basic")
        try seedDisk(storeURL: storeURL, subjects: [(id: "A", seed: 1), (id: "B", seed: 2)])

        let engine = makeEngine(
            storeURL: storeURL,
            subjectId: "A",
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pA1", embedding(seed: 50))])
        )
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path]
        )
        #expect(model.people.map(\.id).sorted() == ["A", "B"])

        // Arm a pending write (the WHOLE store, including A's bundle) through the
        // engine's REAL feedback path — this is the "keep a photo" that schedules a
        // pre-delete snapshot.
        try await engine.recordFeedback(photoKey: "pA1", label: .confirm)

        // Delete A BEFORE the (30s) debounce ever has a chance to fire.
        model.deletePerson(id: "A")
        // (a) `deletePerson` is non-`async` — by the time we reach this line, it has
        // unconditionally already RETURNED.
        #expect(!model.people.contains { $0.id == "A" })

        // (b) There is no separate async "post-delete re-persist task" to drain in
        // this design: `deletePerson` runs the whole capture → cancelPending() →
        // repository delete → prune → re-schedule transaction SYNCHRONOUSLY inside
        // its own call frame (`TriageEngine.writingThroughRepository`), which is
        // exactly what assertion 6 requires (no awaited flush on the delete path
        // itself) — spy-verified in `AppModelDeleteJankFreeTests`. So step (b) is a
        // deliberate no-op here; the only real async settle point is (c).
        await engine.flush()

        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] == nil) // NOT resurrected
        #expect(disk["B"] != nil) // survivor untouched
    }

    // MARK: - The residual race: a write ALREADY encoding when the cancel runs

    /// This is the specific interleaving a bare generation bump cannot close: a
    /// write that has already passed its generation check and is (or is about to
    /// be) mid-`encode` when `deletePerson`'s `cancelPending()` runs concurrently.
    /// A generation bump only stops writes that haven't STARTED yet — it can't
    /// un-write bytes a write already committed (or is about to commit) to disk.
    ///
    /// Forced deterministically (no sleeps/polling/"eventually") via
    /// `CoalescingProfileStoreWriter`'s test-only hooks:
    ///   1. `writer.fireForTesting()` runs the write's REAL critical section on a
    ///      background thread, bypassing the debounce timer.
    ///   2. `beforeEncodeForTesting` fires WHILE the write still holds the
    ///      writer's internal lock, immediately after it captured+cleared
    ///      `pending` and immediately before `encode(to:)` — the exact window the
    ///      bug lived in when the lock was released before encoding. Swift 6
    ///      forbids calling `DispatchSemaphore.wait()` directly in an `async`
    ///      function body (it's `noasync`, precisely to stop blocking the
    ///      cooperative thread pool), so the ONLY `.wait()` in this test runs
    ///      HERE — on the writer's own background queue, a plain synchronous
    ///      context, where blocking is safe. It resumes a `CheckedContinuation`
    ///      the async test body is awaiting (so the test learns the write has
    ///      reached this point without ever blocking itself), then blocks until
    ///      told to proceed.
    ///   3. Once the continuation resumes, the test (now knowing the write is
    ///      paused right there) calls `deletePerson(A)` SYNCHRONOUSLY on the main
    ///      actor. Its `cancelPending()` fires `beforeCancelLockForTesting`
    ///      (signaling the paused write to unpause) BEFORE attempting to acquire
    ///      the SAME (plain `NSLock`, not `noasync`-restricted) lock the paused
    ///      write holds — so `cancelPending()` blocks until that write (encode
    ///      included) has FULLY finished.
    ///   4. Only once `cancelPending()` unblocks (and returns `nil`, since the
    ///      write already cleared `pending`) does `deletePerson`'s own
    ///      `repository.deletePerson` run — reading disk FRESH, which by now
    ///      reflects the write that just landed, so it correctly strips A back out.
    /// This is the fix (item 53's residual race): holding the writer's lock across
    /// the encode, not just the capture, is what makes this self-heal regardless
    /// of which side "wins" the race — see `CoalescingProfileStoreWriter.
    /// writeAndClearPending`'s doc comment for the full invariant.
    @Test("A write already mid-encode when deletePerson's cancel runs cannot resurrect A (item 53 residual race)")
    func deleteIsDurableAgainstInFlightEncode() async throws {
        let storeURL = uniqueStoreURL("inflight")
        try seedDisk(storeURL: storeURL, subjects: [(id: "A", seed: 1), (id: "B", seed: 2)])

        let writer = CoalescingProfileStoreWriter(storeURL: storeURL, debounce: .seconds(30))
        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: "A",
            modelId: Self.modelId,
            modelVersion: Self.modelVersion,
            persister: writer
        )
        engine.loadForTesting(
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pA1", embedding(seed: 50))])
        )
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path]
        )

        // Arm a pending write of the WHOLE (pre-delete) store through the engine's
        // real feedback path.
        try await engine.recordFeedback(photoKey: "pA1", label: .confirm)

        let releaseWrite = DispatchSemaphore(value: 0)

        // Forces the write's real critical section to run NOW, on a background
        // thread, bypassing the 30s debounce timer entirely — and suspends until
        // it signals it has reached the exact point right after clearing
        // `pending`, immediately before `encode`, STILL HOLDING the writer's lock.
        await withCheckedContinuation { continuation in
            writer.beforeEncodeForTesting = {
                continuation.resume()
                releaseWrite.wait()
            }
            writer.beforeCancelLockForTesting = {
                releaseWrite.signal()
            }
            Task.detached(priority: .userInitiated) {
                writer.fireForTesting()
            }
        }

        // Runs synchronously on the main actor. Its `cancelPending()` releases the
        // paused write (so it can finish encoding) and then blocks on the SAME
        // lock until that encode has fully landed, before concluding "nothing was
        // pending" and running the repository delete against a fresh disk read.
        model.deletePerson(id: "A")
        #expect(!model.people.contains { $0.id == "A" })

        await engine.flush() // nothing left pending; harmless.

        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] == nil) // NOT resurrected by the write that raced the delete
        #expect(disk["B"] != nil)
    }

    // MARK: - Assertion 3: the crux — surviving feedback delta

    @Test("Deleting A preserves B's NEW pending feedback (crux): B's delta survives, A never resurrects")
    func deletePreservesSurvivorsPendingFeedback() async throws {
        let storeURL = uniqueStoreURL("crux")
        try seedDisk(storeURL: storeURL, subjects: [(id: "A", seed: 1), (id: "B", seed: 2)])

        // Baseline: B's bundle on disk BEFORE any new feedback.
        let baseline = try #require(try decodeDisk(storeURL)["B"])
        let newExemplar = embedding(seed: 999)
        #expect(!baseline.confirmedPositives.contains(newExemplar))

        let engine = makeEngine(
            storeURL: storeURL,
            subjectId: "B",
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pB1", newExemplar)])
        )
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path]
        )

        // Teach B the NEW exemplar — armed in the pre-delete snapshot, verifiably
        // absent from the baseline recorded above.
        try await engine.recordFeedback(photoKey: "pB1", label: .confirm)
        let armed = try #require(engine.workingStore?["B"])
        #expect(armed.confirmedPositives.contains(newExemplar))

        model.deletePerson(id: "A")
        #expect(!model.people.contains { $0.id == "A" }) // (a) returned, roster updated
        // (b) no separate task in this design (see comment in the previous test).
        await engine.flush() // (c)

        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] == nil) // A never resurrected
        let survivor = try #require(disk["B"])
        // The delta: present now, absent in the baseline — a pre-existing B bundle
        // alone could never mask a genuinely lost pending feedback.
        #expect(survivor.confirmedPositives.contains(newExemplar))
        #expect(!baseline.confirmedPositives.contains(newExemplar))
    }

    // MARK: - Assertion 4: rename durability

    @Test("renamePerson survives a pending coalesced write armed just before it — no stale-snapshot clobber")
    func renameIsDurableAgainstPendingWrite() async throws {
        let storeURL = uniqueStoreURL("rename")
        try seedDisk(storeURL: storeURL, subjects: [(id: "A", seed: 1)])

        let engine = makeEngine(
            storeURL: storeURL,
            subjectId: "A",
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pA1", embedding(seed: 50))])
        )
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path]
        )

        try await engine.recordFeedback(photoKey: "pA1", label: .confirm)
        model.renamePerson(id: "A", to: "Renamed A")
        await engine.flush()

        // Roster (a separate sidecar file) shows the new name…
        #expect(FileProfileRepository(storeURL: storeURL).loadRoster().first { $0.id == "A" }?.displayName == "Renamed A")
        // …and the embedding store still has A's bundle, untouched by any stale
        // pre-rename snapshot racing the roster write (they're different files, but
        // the transaction still ran uniformly and didn't corrupt either).
        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] != nil)
        #expect(disk["A"]?.confirmedPositives.contains(embedding(seed: 50)) == true)
    }

    // MARK: - Enrollment durability (addressing the removal of the old flush()-before-write)

    /// `EnrollmentModel.enroll()` used to call `await engine.flush()` before its
    /// repository write; that's now replaced by the SAME capture→cancel→write→
    /// merge→reschedule transaction every other repository-write path uses. This
    /// test drives that EXACT transaction with a REAL `LiveTriageEngine` +
    /// `CoalescingProfileStoreWriter` (proving the actual persister mechanics), only
    /// substituting `engine.enroll(referenceURLs:)`'s embedding computation — the
    /// one step that needs the real ONNX model, which item 53 doesn't exercise —
    /// with a fixed embedding, exactly mirroring what `EnrollmentModel.enroll()`
    /// does with the result.
    @Test("Enrolling A while B has pending feedback loses nothing: A lands, B's pending feedback survives")
    func enrollmentTransactionPreservesSurvivorsPendingFeedback() async throws {
        let storeURL = uniqueStoreURL("enroll")
        try seedDisk(storeURL: storeURL, subjects: [(id: "B", seed: 2)])

        let newExemplar = embedding(seed: 999)
        let engine = makeEngine(
            storeURL: storeURL,
            subjectId: "B",
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pB1", newExemplar)])
        )
        let repository = FileProfileRepository(storeURL: storeURL)

        // Arm B's pending feedback (not yet on disk).
        try await engine.recordFeedback(photoKey: "pB1", label: .confirm)

        // The exact transaction `EnrollmentModel.enroll()` runs for its first write.
        let bundleA = bundle("A", seed: 42)
        try engine.writingThroughRepository(merging: { store in store.profiles["A"] = bundleA }) {
            try repository.saveProfile(bundleA)
        }
        try engine.writingThroughRepository {
            try repository.savePerson(Person(id: "A", displayName: "Ava"))
        }

        await engine.flush()

        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] == bundleA) // the enrollment landed, not lost
        #expect(disk["B"]?.confirmedPositives.contains(newExemplar) == true) // not dropped
        #expect(Set(repository.loadRoster().map(\.id)) == ["A", "B"])
    }

    @Test("Enrolling A then immediately deleting A is durable, and does not disturb B's pending feedback")
    func enrollThenImmediatelyDeleteIsDurable() async throws {
        let storeURL = uniqueStoreURL("enroll-delete")
        try seedDisk(storeURL: storeURL, subjects: [(id: "B", seed: 2)])

        let newExemplar = embedding(seed: 999)
        let engine = makeEngine(
            storeURL: storeURL,
            subjectId: "B",
            store: try decodeDisk(storeURL),
            manifest: manifest(photos: [("pB1", newExemplar)])
        )
        let repository = FileProfileRepository(storeURL: storeURL)
        try await engine.recordFeedback(photoKey: "pB1", label: .confirm)

        let bundleA = bundle("A", seed: 42)
        try engine.writingThroughRepository(merging: { store in store.profiles["A"] = bundleA }) {
            try repository.saveProfile(bundleA)
        }
        try engine.writingThroughRepository {
            try repository.savePerson(Person(id: "A", displayName: "Ava"))
        }

        // Immediately delete A through a real `AppModel` wired to the SAME engine +
        // repository — before anything above has been explicitly flushed.
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path],
            profileRepository: repository
        )
        model.deletePerson(id: "A")
        await engine.flush()

        let disk = try decodeDisk(storeURL)
        #expect(disk["A"] == nil) // deleted, not resurrected by the enrollment's own reschedule
        #expect(disk["B"]?.confirmedPositives.contains(newExemplar) == true) // survived BOTH transactions
    }

    @Test("Switching the active person right after enrolling A never loses A's just-enrolled bundle")
    func switchingAfterEnrollDoesNotLoseEnrollment() throws {
        let storeURL = uniqueStoreURL("enroll-switch")
        try seedDisk(storeURL: storeURL, subjects: [(id: "B", seed: 2)])

        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: "B",
            modelId: Self.modelId,
            modelVersion: Self.modelVersion,
            persister: CoalescingProfileStoreWriter(storeURL: storeURL, debounce: .seconds(30))
        )
        let repository = FileProfileRepository(storeURL: storeURL)
        let bundleA = bundle("A", seed: 42)
        try engine.writingThroughRepository(merging: { store in store.profiles["A"] = bundleA }) {
            try repository.saveProfile(bundleA)
        }
        try engine.writingThroughRepository {
            try repository.savePerson(Person(id: "A", displayName: "Ava"))
        }

        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": storeURL.path, "KION_LIBRARY_ROOT": uniqueDir("lib").path],
            profileRepository: repository
        )
        model.selectPerson(id: "B")
        #expect(model.activePersonID == "B")

        // `saveProfile` writes synchronously — A's bundle is already durable, no
        // flush needed to observe it (and switching people touches neither the
        // engine's store nor the persister).
        #expect(try decodeDisk(storeURL)["A"] == bundleA)
    }
}
