import Foundation
@testable import KiFinder
import KionEngine

/// Shared fixtures for item 53's repository-write-transaction coverage
/// (`AppModelRepositoryTransactionTests` + `AppModelDeleteRaceTests`): a thread-safe
/// ordered event log, an engine spy that observes `invalidateStore`/
/// `resumePendingWrite`/`flush` without needing the real ONNX model, and a
/// repository spy that observes (and can selectively fail) each write while
/// delegating reads/writes to a REAL `FileProfileRepository` underneath.

/// Records events in call order from multiple spies (persister-side + repository-
/// side) into ONE shared timeline, so a test can assert the exact interleaving the
/// contract requires (capture → cancel → write → re-schedule).
final class OrderEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    var events: [String] { lock.withLock { _events } }

    func record(_ event: String) {
        lock.withLock { _events.append(event) }
    }

    func reset() {
        lock.withLock { _events.removeAll() }
    }
}

/// A `TriageEngine` that forwards the real, deterministic (model-free)
/// `SampleTriageEngine` behavior for everything EXCEPT the two methods item 53's
/// transaction hinges on: `invalidateStore()` (logged as "cancelPending", returning
/// whatever was armed) and `resumePendingWrite(_:)` (logged as "schedule", replacing
/// what's armed). `flush()` is also logged so the jank-free assertion can prove it's
/// never called on the common delete path. Avoids the real model entirely — item 53
/// never needs it.
final class OrderRecordingEngine: TriageEngine, @unchecked Sendable {
    private let wrapped = SampleTriageEngine()
    let log: OrderEventLog
    private let lock = NSLock()
    private var pending: ProfileStore?
    /// The store handed to the MOST RECENT `resumePendingWrite` call — so a test can
    /// assert whether a restore-on-throw genuinely left it UNCHANGED (vs. a
    /// success-path merge that prunes/upserts an entry).
    private(set) var lastResumedStore: ProfileStore?

    init(log: OrderEventLog, initialPending: ProfileStore? = nil) {
        self.log = log
        pending = initialPending
    }

    /// Directly arms `pending` (bypassing `resumePendingWrite`) so a test can set up
    /// the "already armed" precondition without polluting the event log.
    func armPending(_ store: ProfileStore?) {
        lock.withLock { pending = store }
    }

    func enroll(referenceURLs: [URL]) async throws -> [FaceEmbedding] {
        try await wrapped.enroll(referenceURLs: referenceURLs)
    }

    func scan(albums: [URL]) -> AsyncStream<ScanProgress> {
        wrapped.scan(albums: albums)
    }

    func recordFeedback(photoKey: String, label: KiFinder.FeedbackLabel) async throws {
        try await wrapped.recordFeedback(photoKey: photoKey, label: label)
    }

    func selectFace(photoKey: String, faceIndex: Int) async throws -> FaceSelectionResult {
        try await wrapped.selectFace(photoKey: photoKey, faceIndex: faceIndex)
    }

    func rescoreAll(onlyPhotoKeys: Set<String>?) async throws -> [String: RescoredPhoto] {
        try await wrapped.rescoreAll(onlyPhotoKeys: onlyPhotoKeys)
    }

    func export(photoKeys: [String], destination: ExportDestination) async throws -> Int {
        try await wrapped.export(photoKeys: photoKeys, destination: destination)
    }

    func export(fileURLs: [URL], destination: ExportDestination) async throws -> Int {
        try await wrapped.export(fileURLs: fileURLs, destination: destination)
    }

    @discardableResult
    func invalidateStore() -> ProfileStore? {
        log.record("cancelPending")
        return lock.withLock {
            let snapshot = pending
            pending = nil
            return snapshot
        }
    }

    func resumePendingWrite(_ store: ProfileStore) {
        log.record("schedule")
        lock.withLock {
            pending = store
            lastResumedStore = store
        }
    }

    func flush() async {
        log.record("flush")
    }
}

/// Wraps a real `ProfileRepository` (so reads/writes are genuine + durable),
/// logging each write into the shared `OrderEventLog` and optionally throwing a
/// synthetic failure for a chosen method — so a test can assert BOTH the ordering
/// (capture → cancel → write → re-schedule) and the restore-on-throw behavior.
final class RecordingProfileRepository: ProfileRepository, @unchecked Sendable {
    struct InjectedFailure: Error {}

    private let wrapped: any ProfileRepository
    let log: OrderEventLog
    var throwOnSavePerson = false
    var throwOnDeletePerson = false
    var throwOnSaveProfile = false

    init(wrapping wrapped: any ProfileRepository, log: OrderEventLog) {
        self.wrapped = wrapped
        self.log = log
    }

    func loadRoster() -> [Person] { wrapped.loadRoster() }

    func savePerson(_ person: Person) throws {
        log.record("savePerson")
        if throwOnSavePerson { throw InjectedFailure() }
        try wrapped.savePerson(person)
    }

    func deletePerson(id: String) throws {
        log.record("deletePerson")
        if throwOnDeletePerson { throw InjectedFailure() }
        try wrapped.deletePerson(id: id)
    }

    func loadProfile(subjectId: String) -> ProfileBundle? { wrapped.loadProfile(subjectId: subjectId) }

    func saveProfile(_ bundle: ProfileBundle) throws {
        log.record("saveProfile")
        if throwOnSaveProfile { throw InjectedFailure() }
        try wrapped.saveProfile(bundle)
    }

    func reset() { wrapped.reset() }

    func thumbnailURL(for id: String) -> URL? { wrapped.thumbnailURL(for: id) }

    func saveThumbnail(_ pngData: Data, for id: String) throws -> URL {
        try wrapped.saveThumbnail(pngData, for: id)
    }
}
