import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Coverage for item 15: keep/skip is instant. The live engine holds the working
/// `ProfileStore` in memory, mutates it in place for confirm/reject, and schedules
/// the write off the main actor through an injectable coalescing seam — it never
/// reloads/encodes the store inline per decision. Proven deterministically with a
/// fake writer (no real timing) over N distinct photo keys covering both confirm and
/// reject for the active subject.
@Suite("Feedback persistence (item 15)")
@MainActor
struct FeedbackPersistenceTests {
    /// A fake coalescing writer with no real timing. `schedule` stashes the latest
    /// snapshot (most-recent-wins); an actual "write" only materializes on a manual
    /// `fireDebounce()` tick or on `flush()`, so a burst of N schedules collapses to
    /// one coalesced write. `blockWrites` models a write that never materializes.
    final class FakeProfileStoreWriter: ProfileStorePersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: ProfileStore?
        private(set) var scheduleCount = 0
        private(set) var writeCount = 0
        private(set) var captured: ProfileStore?
        var blockWrites = false

        func schedule(_ store: ProfileStore) {
            lock.lock()
            defer { lock.unlock() }
            scheduleCount += 1
            pending = store
        }

        /// Models the debounce firing: collapse the pending snapshot into one write.
        func fireDebounce() {
            materialize()
        }

        func flush() async {
            materialize()
        }

        private func materialize() {
            lock.lock()
            defer { lock.unlock() }
            guard !blockWrites, let store = pending else { return }
            pending = nil
            writeCount += 1
            captured = store
        }

        func cancelPending() -> ProfileStore? {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = pending
            pending = nil
            return snapshot
        }
    }

    // MARK: - Fixtures

    private static let modelId = "test-model"
    private static let modelVersion = "test-version"
    private static let subjectId = "Kris"
    private static let otherSubjectId = "Ava"

    private func tempStoreURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-feedback-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// A 512-float embedding seeded from `seed` so each photo's exemplar is distinct
    /// and identifiable in the resulting profile.
    private func embedding(seed: Float) -> FaceEmbedding {
        FaceEmbedding((0 ..< 512).map { seed + Float($0) * 0.001 })
    }

    private func profile(_ subjectId: String) -> ProfileBundle {
        ProfileBundle(
            subjectId: subjectId,
            references: [embedding(seed: 1)],
            threshold: 0.45,
            modelId: Self.modelId,
            modelVersion: Self.modelVersion
        )
    }

    private func store(subjects: [String]) -> ProfileStore {
        var store = ProfileStore(modelId: Self.modelId, modelVersion: Self.modelVersion)
        for subject in subjects {
            store[subject] = profile(subject)
        }
        return store
    }

    /// A fixture of `count` distinct photo keys, each a manifest entry carrying a
    /// distinct 512-float embedding, plus the chosen feedback label per photo.
    private func manifest(
        photos: [(key: String, embedding: FaceEmbedding)]
    ) -> Manifest {
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

    private func makeEngine(
        storeURL: URL,
        persister: ProfileStorePersisting
    ) -> LiveTriageEngine {
        LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: Self.subjectId,
            modelId: Self.modelId,
            modelVersion: Self.modelVersion,
            persister: persister
        )
    }

    // MARK: - Assertion 1: non-blocking

    @Test("recordFeedback records the decision and returns even when the write blocks forever")
    func recordFeedbackReturnsWhenWriteBlocks() async throws {
        let writer = FakeProfileStoreWriter()
        writer.blockWrites = true // the actual persistence never materializes
        let engine = makeEngine(storeURL: tempStoreURL(), persister: writer)
        let positive = embedding(seed: 10)
        engine.loadForTesting(
            store: store(subjects: [Self.subjectId]),
            manifest: manifest(photos: [("p1", positive)])
        )

        // Returns promptly (no inline encode/file write to await) and records the
        // decision into the in-memory store.
        try await engine.recordFeedback(photoKey: "p1", label: .confirm)

        #expect(writer.scheduleCount == 1)
        #expect(writer.writeCount == 0) // write never happened, yet we returned
        let confirmed = try #require(engine.workingStore?[Self.subjectId]?.confirmedPositives)
        #expect(confirmed.contains(positive))
    }

    // MARK: - Assertion 6: coalescing + correctness via the injected seam

    @Test("N rapid decisions coalesce to ONE write, land on the correct subject, and flush persists in-memory")
    func coalescedDecisionsAreCorrect() async throws {
        let writer = FakeProfileStoreWriter()
        let storeURL = tempStoreURL()
        // No store on disk — proves (d) decisions never reload from disk: a reload
        // from this non-existent path would fail and drop the decision.
        let engine = makeEngine(storeURL: storeURL, persister: writer)

        // N distinct photos, alternating confirm / reject for the active subject.
        let n = 8
        let photos = (0 ..< n).map { (key: "p\($0)", embedding: embedding(seed: Float(100 + $0))) }
        let labels: [KiFinder.FeedbackLabel] = (0 ..< n).map { $0.isMultiple(of: 2) ? .confirm : .reject }
        engine.loadForTesting(
            store: store(subjects: [Self.subjectId, Self.otherSubjectId]),
            manifest: manifest(photos: photos)
        )

        // (a) N rapid calls → N schedules, but ZERO writes so far (coalesced).
        for (photo, label) in zip(photos, labels) {
            try await engine.recordFeedback(photoKey: photo.key, label: label)
        }
        #expect(writer.scheduleCount == n)
        #expect(writer.writeCount == 0)

        // The debounce fires once for the whole burst → exactly ONE coalesced write.
        writer.fireDebounce()
        #expect(writer.writeCount == 1)

        // (b) Exemplars landed on the CORRECT subject: confirms → positives, rejects
        // → negatives, all on `subjectId`; the other subject is untouched.
        let working = try #require(engine.workingStore)
        let subject = try #require(working[Self.subjectId])
        for (photo, label) in zip(photos, labels) {
            switch label {
            case .confirm:
                #expect(subject.confirmedPositives.contains(photo.embedding))
                #expect(!subject.negatives.contains(photo.embedding))
            case .reject:
                #expect(subject.negatives.contains(photo.embedding))
                #expect(!subject.confirmedPositives.contains(photo.embedding))
            }
        }
        let other = try #require(working[Self.otherSubjectId])
        #expect(other.confirmedPositives.isEmpty)
        #expect(other.negatives.isEmpty)

        // (c) flush persists the pending write; afterward persisted == in-memory.
        try await engine.recordFeedback(photoKey: "p0", label: .confirm) // idempotent re-confirm
        await engine.flush()
        let persisted = try #require(writer.captured)
        #expect(persisted == working)

        // (d) No reload-from-disk between decisions: the on-disk path never existed,
        // yet every decision succeeded against the in-memory store.
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test("flush writes the latest store; persisted equals in-memory")
    func flushPersistsLatest() async throws {
        let writer = FakeProfileStoreWriter()
        let engine = makeEngine(storeURL: tempStoreURL(), persister: writer)
        let e1 = embedding(seed: 200)
        let e2 = embedding(seed: 300)
        engine.loadForTesting(
            store: store(subjects: [Self.subjectId]),
            manifest: manifest(photos: [("p1", e1), ("p2", e2)])
        )

        try await engine.recordFeedback(photoKey: "p1", label: .confirm)
        try await engine.recordFeedback(photoKey: "p2", label: .reject)
        await engine.flush()

        let persisted = try #require(writer.captured)
        #expect(persisted == engine.workingStore)
        #expect(persisted[Self.subjectId]?.confirmedPositives.contains(e1) == true)
        #expect(persisted[Self.subjectId]?.negatives.contains(e2) == true)
    }

    // MARK: - Idempotency + reversibility (assertion 4)

    @Test("Keep then skip on the same photo teaches both exemplars (reversible)")
    func keepThenSkipTeachesBoth() async throws {
        let writer = FakeProfileStoreWriter()
        let engine = makeEngine(storeURL: tempStoreURL(), persister: writer)
        let e = embedding(seed: 400)
        engine.loadForTesting(
            store: store(subjects: [Self.subjectId]),
            manifest: manifest(photos: [("p1", e)])
        )

        try await engine.recordFeedback(photoKey: "p1", label: .confirm)
        #expect(engine.workingStore?[Self.subjectId]?.confirmedPositives.contains(e) == true)

        try await engine.recordFeedback(photoKey: "p1", label: .reject)
        let subject = try #require(engine.workingStore?[Self.subjectId])
        // The skip teaches a negative; the prior positive is retained (the engine
        // appends; the AppModel-level decision nets to skipped).
        #expect(subject.negatives.contains(e))
    }
}

/// Coverage for the production coalescing writer: it writes OFF the main actor,
/// `flush()` performs the pending write (most-recent-wins), and the persisted bytes
/// round-trip to the scheduled store. (The "exactly one write" coalescing is proven
/// at the engine seam in `FeedbackPersistenceTests`.)
@Suite("Coalescing profile store writer")
struct CoalescingProfileStoreWriterTests {
    private func tempStoreURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-writer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func store(_ positives: Int) -> ProfileStore {
        var store = ProfileStore(modelId: "m", modelVersion: "v")
        store["s"] = ProfileBundle(
            subjectId: "s",
            references: [FaceEmbedding([1, 2, 3])],
            confirmedPositives: (0 ..< positives).map { FaceEmbedding([Float($0)]) },
            threshold: 0.4,
            modelId: "m",
            modelVersion: "v"
        )
        return store
    }

    @Test("flush writes the most-recently-scheduled store to disk")
    func flushWritesLatest() async throws {
        let url = tempStoreURL()
        let writer = CoalescingProfileStoreWriter(storeURL: url, debounce: .seconds(60))
        // Schedule several snapshots rapidly; the last one wins.
        for i in 1 ... 5 {
            writer.schedule(store(i))
        }
        await writer.flush()

        let decoded = try ProfileStore.load(from: url, expectingModelId: "m", expectingModelVersion: "v")
        #expect(decoded == store(5))
        #expect(decoded["s"]?.confirmedPositives.count == 5)
    }

    @Test("flush with nothing pending is a harmless no-op")
    func flushNoPendingIsNoOp() async {
        let url = tempStoreURL()
        let writer = CoalescingProfileStoreWriter(storeURL: url)
        await writer.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Item 53's residual race: cancelPending() vs. an already-in-flight write

    /// A write that has ALREADY passed its generation check and started encoding
    /// cannot be stopped by bumping the generation (that write no longer consults
    /// it). The fix holds the writer's lock across the WHOLE capture-then-encode,
    /// so `cancelPending()` either runs strictly before that write starts, or
    /// blocks until it — encode included — has fully landed on disk.
    ///
    /// Forced deterministically (no sleeps/polling) via the `beforeEncodeForTesting`/
    /// `beforeCancelLockForTesting` test hooks. Swift 6 forbids calling
    /// `DispatchSemaphore.wait()` directly inside an `async` function body (it's
    /// `noasync`, to stop exactly this footgun — blocking the cooperative thread
    /// pool), so the ONLY `.wait()` in this test runs inside `beforeEncodeForTesting`,
    /// which executes on the writer's own background queue — a plain synchronous
    /// context, not `async` — where blocking is safe and is precisely the pause we
    /// need. The async test body itself never blocks: it `await`s a
    /// `withCheckedContinuation` that the paused write resumes right as it reaches
    /// that pause point, then calls the plain (non-`async`) `cancelPending()`,
    /// whose internal `NSLock` wait is not `noasync`-restricted.
    @Test("cancelPending() cannot observe 'nothing pending' while a write it raced is still landing on disk")
    func cancelPendingIsOrderedAgainstAnInFlightWrite() async throws {
        let url = tempStoreURL()
        let writer = CoalescingProfileStoreWriter(storeURL: url, debounce: .seconds(30))
        writer.schedule(store(3))

        let releaseWrite = DispatchSemaphore(value: 0)

        // Forces the write's real critical section to run NOW (bypassing the 30s
        // debounce) on a background thread, and suspends until it signals it has
        // reached the exact point right after clearing `pending`, immediately
        // before `encode` — STILL HOLDING the writer's internal lock.
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

        // Releases the paused write, then blocks (via a plain `NSLock`, not a
        // `noasync`-restricted API) until that write's `encode` has FULLY
        // completed before returning.
        let captured = writer.cancelPending()
        #expect(captured == nil) // the write already consumed `pending`

        // By the time `cancelPending()` returned, the write's effect was ALREADY
        // on disk — no flush, no sleep, no poll needed to observe it.
        let decoded = try ProfileStore.load(from: url, expectingModelId: "m", expectingModelVersion: "v")
        #expect(decoded == store(3))
    }
}

/// Coverage for item 57's skip-store quarantine notice, homed here alongside the
/// rest of the persistence-decode coverage (see `KeptLibraryTests`/
/// `ProfileRepositoryTests` for the roster/kept-index siblings).
@Suite("Skip store quarantine notice")
struct SkipStoreQuarantineTests {
    private func tempFileURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-skip-quarantine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("skipped-index.json")
    }

    @Test("a corrupt skip store surfaces a plain-language notice once; a second store over the same file sees nothing to report")
    func skipStoreQuarantine_noticeOnceThenSilent() throws {
        let fileURL = tempFileURL()
        try Data("not json {{{".utf8).write(to: fileURL)

        let store = SkipStore(fileURL: fileURL)
        let notice = try #require(store.quarantineNotice)
        // Plain language naming what was set aside — no implementation jargon.
        #expect(notice.localizedCaseInsensitiveContains("skip"))
        #expect(!notice.localizedCaseInsensitiveContains("json"))
        #expect(!notice.localizedCaseInsensitiveContains("decode"))
        #expect(!store.isSkipped(sourcePath: "/anything", subjectId: "kris"))

        // A fresh store over the SAME file — the corrupt bytes are gone (moved
        // aside), so nothing is left to quarantine and the notice stays nil.
        let reopened = SkipStore(fileURL: fileURL)
        #expect(reopened.quarantineNotice == nil)
    }
}
