import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 57 regression coverage: three independent data-integrity defects, each
/// proven with ONLY production API that already exists on `main` (existing
/// loaders/stores, engine-spy injection, `apply`/`runScan`, `isKeptWithoutMatch`) so
/// this file compiles unmodified against `main` and its 6 tests fail there — proving
/// each fix targets a real current defect, not a seam that only exists post-fix.
///
/// 1. `rosterQuarantine_corruptFilePreserved` / `keptIndexQuarantine_corruptFilePreserved`
///    / `skipStoreQuarantine_corruptFilePreserved`: an undecodable data file is
///    destroyed on `main` (the next write silently overwrites it) instead of being
///    preserved as evidence.
/// 2. `faceSelectionRace_lateResultNeverWritesToNewPerson` /
///    `rescoreRace_lateResultNeverWritesToNewPerson`: on `main`, `applyFaceSelection`
///    and `rescoreAndSurface` read `activePersonID` AFTER their `await`, so a person
///    switch mid-flight writes the old subject's result onto the NEW person.
/// 3. `rescanClearsKeptWithoutMatchAndPromotions`: on `main`, `apply(_:)` clears
///    `decisions` but not `keptWithoutMatch`/`pendingPromotions`, so re-scanning the
///    same album (stable source-path ids) leaves stale badges/banners behind.
@Suite("Data integrity regressions (item 57)")
@MainActor
struct DataIntegrityRegressionTests {
    /// Polls the main actor until `condition` holds (or a generous budget elapses),
    /// sleeping real wall-clock between checks so an already-triggered, suspension-free
    /// async tail on the main actor runs to completion. This replaces brittle fixed-count
    /// `Task.yield()` drains, whose "2 yields" could be too few under full-suite load —
    /// waiting for the observable landing (A's own result) is exactly what proves the
    /// late result completed and lets the "never lands on B" checks be non-vacuous.
    private func until(_ condition: @MainActor () -> Bool, iterations: Int = 3000) async {
        for _ in 0 ..< iterations where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Fixtures

    private func uniqueDir(_ tag: String = "kion-di") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueStorePath() -> String {
        uniqueDir("kion-di-store").appendingPathComponent("store.json").path
    }

    // MARK: - 1a: roster quarantine (assertion 1)

    @Test("a corrupt roster is preserved at a *.corrupt-* sibling instead of being destroyed")
    func rosterQuarantine_corruptFilePreserved() throws {
        let dir = uniqueDir()
        let rosterURL = dir.appendingPathComponent("people-roster.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: rosterURL)

        let repo = FileProfileRepository(storeURL: dir.appendingPathComponent("store.json"))
        let people = repo.loadRoster()
        // Self-heal preserved: no embedding store on disk ⇒ an empty migrated roster.
        #expect(people.isEmpty)

        // The exact garbage bytes must survive at a `.corrupt-*` sibling — never
        // silently destroyed by the migration's rewrite.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let quarantinedName = try #require(siblings.first { $0.hasPrefix("people-roster.json.corrupt-") })
        let quarantinedURL = dir.appendingPathComponent(quarantinedName)
        #expect(try Data(contentsOf: quarantinedURL) == garbage)

        // A subsequent roster write does not delete/alter the quarantined file.
        try repo.savePerson(Person(id: "p1", displayName: "Ava"))
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(try Data(contentsOf: quarantinedURL) == garbage)
    }

    // MARK: - 1b: kept-index quarantine (assertion 2)

    @Test("a corrupt kept-photo index is preserved at a *.corrupt-* sibling instead of being destroyed")
    func keptIndexQuarantine_corruptFilePreserved() async throws {
        let root = uniqueDir("kion-di-root")
        let indexDir = uniqueDir("kion-di-index")
        let indexURL = indexDir.appendingPathComponent("library-index.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: indexURL)

        let library = KeptLibrary(root: root, indexURL: indexURL)
        #expect(library.allEntries.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: indexDir.path)
        let quarantinedName = try #require(siblings.first { $0.hasPrefix("library-index.json.corrupt-") })
        let quarantinedURL = indexDir.appendingPathComponent(quarantinedName)
        #expect(try Data(contentsOf: quarantinedURL) == garbage)

        // A subsequent keep + flush() writes a fresh index without touching the
        // quarantined sibling.
        let source = indexDir.appendingPathComponent("photo.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: nil)
        let result = await library.save(originalAt: source, subjectId: "kris", personName: "Kris", score: 0.9)
        guard case .saved = result else {
            Issue.record("expected .saved, got \(result)")
            return
        }
        await library.flush()

        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(try Data(contentsOf: quarantinedURL) == garbage)
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
    }

    // MARK: - 1c: skip-store quarantine (assertion 3)

    @Test("a corrupt skip store is preserved at a *.corrupt-* sibling instead of being destroyed")
    func skipStoreQuarantine_corruptFilePreserved() async throws {
        let dir = uniqueDir()
        let fileURL = dir.appendingPathComponent("skipped-index.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: fileURL)

        let store = SkipStore(fileURL: fileURL)
        #expect(!store.isSkipped(sourcePath: "/anything", subjectId: "kris"))

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let quarantinedName = try #require(siblings.first { $0.hasPrefix("skipped-index.json.corrupt-") })
        let quarantinedURL = dir.appendingPathComponent(quarantinedName)
        #expect(try Data(contentsOf: quarantinedURL) == garbage)

        // A subsequent skip + flush() leaves the quarantined file intact.
        store.recordSkip(sourcePath: "/some/photo.jpg", subjectId: "kris")
        await store.flush()

        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
        #expect(try Data(contentsOf: quarantinedURL) == garbage)
    }

    // MARK: - 2a: face-selection race (assertion 7)

    @Test("a face-selection result started under person A never lands on person B after a mid-flight switch")
    func faceSelectionRace_lateResultNeverWritesToNewPerson() async throws {
        let candidateID = "face-race"
        let engine = RaceSpyEngine()
        engine.scanCandidates = [
            Candidate(
                id: candidateID,
                photoKey: "key-\(candidateID)",
                fileName: "\(candidateID).jpg",
                imageResourceName: "",
                score: 0.5,
                bucket: .maybe,
                faceBoxes: [
                    CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                ]
            ),
        ]
        engine.faceSelectionResult = FaceSelectionResult(score: 0.95, bucket: .keep)

        let model = AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStorePath()])
        let personA = model.addPerson(name: "A")
        let personB = model.addPerson(name: "B")
        model.selectPerson(id: personA.id)
        #expect(model.activePersonID == personA.id)

        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
        let before = try #require(model.candidate(for: candidateID))
        #expect(before.subjectBuckets[personB.id] == nil)

        model.selectFace(before, faceIndex: 1)
        // Deterministic handshake: wait until the engine call has GENUINELY entered
        // its release-gated suspension — not a fixed yield count that merely
        // "usually" wins the race against the switch below.
        await engine.waitUntilFaceSelectionEntered()

        // Switch to B WHILE the engine call is provably suspended in the gate.
        model.selectPerson(id: personB.id)
        #expect(model.activePersonID == personB.id)

        engine.releaseFaceSelection()
        // Wait for the just-released, suspension-free tail (`selectFace` →
        // `applyFaceSelection`) to actually land on the CAPTURED subject A. This file is
        // main-API-only so it can't await `AppModel`'s fire-and-forget Task directly;
        // polling for A's own landing (instead of a fixed 2 yields) is deterministic
        // under load and makes the "never lands on B" checks below non-vacuous.
        await until { model.candidate(for: candidateID)?.subjectBuckets[personA.id] != nil }

        let after = try #require(model.candidate(for: candidateID))
        // The async work DID complete and land somewhere — proves the drain above
        // actually waited long enough (a too-short drain would make the "B is
        // untouched" checks below pass VACUOUSLY, before the engine's result had a
        // chance to land anywhere at all). Per item 57, a late result is applied to
        // the CAPTURED subject (A) — never dropped silently, and never to B.
        #expect(after.subjectBuckets[personA.id] == .keep)
        // B must never receive A's late-arriving result.
        #expect(after.subjectBuckets[personB.id] == nil)
        #expect(after.subjectScores[personB.id] == nil)
    }

    // MARK: - 2b: rescore race (assertion 8)

    @Test("a rescore result started under person A never lands on person B's subjectScores/pendingPromotions after a mid-flight switch")
    func rescoreRace_lateResultNeverWritesToNewPerson() async throws {
        let candidateID = "rescore-race"
        let engine = RaceSpyEngine()
        engine.scanCandidates = [
            Candidate(
                id: candidateID,
                photoKey: "key-\(candidateID)",
                fileName: "\(candidateID).jpg",
                imageResourceName: "",
                score: 0.5,
                bucket: .other
            ),
        ]
        engine.rescoreResults = ["key-\(candidateID)": RescoredPhoto(score: 0.99, bucket: .keep, selectedFaceIndex: nil)]

        let model = AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStorePath()])
        let personA = model.addPerson(name: "A")
        let personB = model.addPerson(name: "B")
        model.selectPerson(id: personA.id)

        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
        let before = try #require(model.candidate(for: candidateID))
        #expect(before.subjectScores[personB.id] == nil)

        model.rescoreNow()
        // Deterministic handshake: wait until `rescoreAll` has GENUINELY entered its
        // release-gated suspension — not a fixed yield count.
        await engine.waitUntilRescoreEntered()

        // Switch to B WHILE the rescore is provably suspended in the gate.
        model.selectPerson(id: personB.id)
        #expect(model.activePersonID == personB.id)

        engine.releaseRescore()
        // Wait for the just-released rescore tail (`rescoreAll` → the rest of
        // `rescoreAndSurface`) to land on the CAPTURED subject A. The person switch
        // above cleared the `rescoreTask` handle, so this can't await it directly the
        // way `rescoreCancelledOnPersonSwitch` does; polling for A's own landing
        // (instead of a fixed 2 yields) is deterministic under load.
        await until { model.candidate(for: candidateID)?.subjectScores[personA.id] != nil }

        let after = try #require(model.candidate(for: candidateID))
        // The async work DID complete and land somewhere — proves the drain above
        // actually waited long enough (a too-short drain would make the "B is
        // untouched" check below pass VACUOUSLY, before the engine's result had a
        // chance to land anywhere at all). Per item 57, a late result is applied to
        // the CAPTURED subject's (A's) own `subjectScores` entry — never dropped
        // silently, and never to B.
        #expect(try abs(#require(after.subjectScores[personA.id]) - 0.99) < 1e-9)
        #expect(after.subjectScores[personB.id] == nil)
        #expect(model.pendingPromotions.isEmpty)
    }

    // MARK: - 3: re-scan staleness (assertion 10)

    @Test("re-scanning the same album clears a stale keep-without-match badge and any pending promotion")
    func rescanClearsKeptWithoutMatchAndPromotions() async throws {
        let candidateID = "rescan-stale"
        let source = uniqueDir().appendingPathComponent("photo.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: nil)
        let noFaceCandidate = Candidate(
            id: candidateID,
            photoKey: "key-\(candidateID)",
            fileName: "photo.jpg",
            imageResourceName: "",
            score: 0.1,
            bucket: .other,
            sourceURL: source
        )
        let spy = ScanOnlySpyEngine()
        spy.scanCandidates = [noFaceCandidate]

        let model = AppModel(
            engine: spy,
            environment: ["KION_PROFILE_STORE": uniqueStorePath()],
            keptLibrary: KeptLibrary(
                root: uniqueDir("kion-di-root"),
                indexURL: uniqueDir("kion-di-index").appendingPathComponent("library-index.json")
            )
        )
        let person = model.addPerson(name: "A")
        model.selectPerson(id: person.id)

        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
        model.focusedID = candidateID
        model.keepWithoutMatchFocused()
        #expect(model.isKeptWithoutMatch(candidateID) == true)

        // Also seed a pending promotion directly (a deterministic test seam already
        // on `main`) so both stale-state clears are exercised in one re-scan.
        model.seedPendingPromotionForTesting(candidateID, .keep)
        #expect(model.pendingPromotions[candidateID] != nil)

        // Re-scan the SAME album — candidate ids are stable source paths, so the
        // same id reappears.
        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])

        #expect(model.isKeptWithoutMatch(candidateID) == false)
        #expect(model.pendingPromotions.isEmpty)
    }
}

/// A `TriageEngine` spy whose `scan` yields one final tick carrying `scanCandidates`,
/// and whose `selectFace`/`rescoreAll` each suspend on their OWN gate until
/// `releaseFaceSelection()`/`releaseRescore()` is called (or return immediately if
/// already released) — the deterministic seam for the two person-switch race tests.
/// Uses only the `TriageEngine` protocol, unchanged on `main`.
@MainActor
private final class RaceSpyEngine: TriageEngine {
    var scanCandidates: [Candidate] = []
    var faceSelectionResult = FaceSelectionResult(score: 0, bucket: .other)
    var rescoreResults: [String: RescoredPhoto] = [:]

    private var faceContinuation: CheckedContinuation<Void, Never>?
    private var faceReleased = false
    private var faceGateEntered = false
    private var faceEnteredWaiter: CheckedContinuation<Void, Never>?

    private var rescoreContinuation: CheckedContinuation<Void, Never>?
    private var rescoreReleased = false
    private var rescoreGateEntered = false
    private var rescoreEnteredWaiter: CheckedContinuation<Void, Never>?

    func releaseFaceSelection() {
        faceReleased = true
        let pending = faceContinuation
        faceContinuation = nil
        pending?.resume()
    }

    func releaseRescore() {
        rescoreReleased = true
        let pending = rescoreContinuation
        rescoreContinuation = nil
        pending?.resume()
    }

    /// Suspends until `selectFace` has GENUINELY entered its release-gated
    /// suspension (proven by the fake actually storing its resume continuation) —
    /// not a fixed yield count that merely "usually" wins the race. Safe to call
    /// before OR after `selectFace` itself starts: if the gate was already entered
    /// (or the call already released), returns immediately instead of hanging.
    func waitUntilFaceSelectionEntered() async {
        if faceGateEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            faceEnteredWaiter = cont
        }
    }

    /// Mirrors `waitUntilFaceSelectionEntered()` for `rescoreAll`.
    func waitUntilRescoreEntered() async {
        if rescoreGateEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            rescoreEnteredWaiter = cont
        }
    }

    private func markFaceGateEntered() {
        faceGateEntered = true
        let waiter = faceEnteredWaiter
        faceEnteredWaiter = nil
        waiter?.resume()
    }

    private func markRescoreGateEntered() {
        rescoreGateEntered = true
        let waiter = rescoreEnteredWaiter
        rescoreEnteredWaiter = nil
        waiter?.resume()
    }

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        let candidates = scanCandidates
        return AsyncStream { continuation in
            continuation.yield(ScanProgress(progress: 1, candidates: candidates, isFinal: true))
            continuation.finish()
        }
    }

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        if faceReleased {
            markFaceGateEntered()
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                faceContinuation = cont
                // Signal "entered" only AFTER the resume continuation is stored, so
                // a waiter that proceeds past `waitUntilFaceSelectionEntered()` can
                // safely call `releaseFaceSelection()` next without racing it.
                markFaceGateEntered()
            }
        }
        return faceSelectionResult
    }

    func rescoreAll(onlyPhotoKeys _: Set<String>?) async throws -> [String: RescoredPhoto] {
        if rescoreReleased {
            markRescoreGateEntered()
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                rescoreContinuation = cont
                markRescoreGateEntered()
            }
        }
        return rescoreResults
    }

    func enroll(referenceURLs _: [URL]) async throws -> [FaceEmbedding] { [] }

    func recordFeedback(photoKey _: String, label _: KiFinder.FeedbackLabel) async throws {}

    func export(photoKeys: [String], destination _: ExportDestination) async throws -> Int {
        photoKeys.count
    }

    func export(fileURLs: [URL], destination _: ExportDestination) async throws -> Int {
        fileURLs.count
    }
}

/// A minimal `TriageEngine` spy whose `scan` yields one final tick carrying
/// `scanCandidates` — no gating, used by the re-scan staleness test to drive TWO
/// scans over the same candidate set. Uses only the `TriageEngine` protocol,
/// unchanged on `main`.
@MainActor
private final class ScanOnlySpyEngine: TriageEngine {
    var scanCandidates: [Candidate] = []

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        let candidates = scanCandidates
        return AsyncStream { continuation in
            continuation.yield(ScanProgress(progress: 1, candidates: candidates, isFinal: true))
            continuation.finish()
        }
    }

    func enroll(referenceURLs _: [URL]) async throws -> [FaceEmbedding] { [] }

    func recordFeedback(photoKey _: String, label _: KiFinder.FeedbackLabel) async throws {}

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        FaceSelectionResult(score: 0, bucket: .other)
    }

    func rescoreAll(onlyPhotoKeys _: Set<String>?) async throws -> [String: RescoredPhoto] { [:] }

    func export(photoKeys: [String], destination _: ExportDestination) async throws -> Int {
        photoKeys.count
    }

    func export(fileURLs: [URL], destination _: ExportDestination) async throws -> Int {
        fileURLs.count
    }
}
