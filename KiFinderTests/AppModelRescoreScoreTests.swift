import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Coverage for item 40: a re-score must refresh the ACTIVE person's personalized
/// score (`subjectScores[active]`, surfaced by `personalized(_:)`) so the tile /
/// inspector never shows a stale confidence — WITHOUT moving the tile (the bucket
/// is left untouched) or disturbing another person's stored score.
///
/// Driven by the deterministic `SampleTriageEngine`, whose `rescoreAll()` echoes
/// each candidate's top-level `score`: seeding an `additionalCandidate` whose
/// top-level `score` (the fresh rescored value) DIFFERS from its stale
/// `subjectScores[active]` gives a fully controlled rescore result. The rescore is
/// driven through the `rescoreNowForTesting()` seam — no debounce wait, no sleeps.
@Suite("App model rescore score refresh")
@MainActor
struct AppModelRescoreScoreTests {
    private let kion = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID

    /// The fresh value `rescoreAll()` returns (the candidate's top-level `score`),
    /// the stale per-subject value it must overwrite, and a second person's score
    /// that must survive untouched.
    private let freshScore = 0.88
    private let staleScore = 0.11
    private let otherPersonScore = 0.42

    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-rescore-score-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// A candidate whose displayed (personalized) score is STALE for Kris: the
    /// top-level `score` (= what the sample engine's `rescoreAll` echoes) is the
    /// fresh value, but `subjectScores[kion]` holds an older, different value that
    /// `personalized(_:)` would surface until the rescore refreshes it. Its bucket
    /// matches its top-level bucket so the rescore surfaces no spurious promotion.
    private func staleScoreCandidate() -> Candidate {
        Candidate(
            id: "rescore-stale",
            photoKey: "sample/rescore-stale.png",
            fileName: "IMG_4040.PNG",
            imageResourceName: "sample-keep-01",
            score: freshScore,
            bucket: .maybe,
            faceBoxes: [CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)],
            selectedFaceIndex: 0,
            matchedSubjectID: kion,
            subjectScores: [kion: staleScore, ava: otherPersonScore],
            subjectBuckets: [kion: .maybe, ava: .maybe],
            selectedFaceIndexBySubject: [kion: 0, ava: 0]
        )
    }

    private func sampleModel() -> AppModel {
        AppModel(
            engine: SampleTriageEngine(additionalCandidates: [staleScoreCandidate()]),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    @Test("rescore refreshes the active person's personalized score from stale to fresh")
    func rescoreRefreshesPersonalizedScore() async throws {
        let model = sampleModel()
        // Before: the personalized (displayed) score is the STALE per-subject value,
        // proving `personalized(_:)` masks the fresh top-level score.
        let before = try #require(model.candidate(for: "rescore-stale"))
        #expect(abs(before.score - staleScore) < 1e-9)
        #expect(before.score != freshScore)

        await model.rescoreNowForTesting()

        let after = try #require(model.candidate(for: "rescore-stale"))
        // The stored per-subject entry AND the displayed score both reflect the fresh
        // rescored value — not the stale prior.
        #expect(try abs(#require(after.subjectScores[kion]) - freshScore) < 1e-9)
        #expect(abs(after.score - freshScore) < 1e-9)
        #expect(after.score != staleScore)
    }

    @Test("rescore does not move the tile — same section before and after")
    func rescoreKeepsSection() async throws {
        let model = sampleModel()
        let sectionBefore = model.state(for: "rescore-stale")
        let bucketBefore = try #require(model.candidate(for: "rescore-stale")).subjectBuckets[kion]

        await model.rescoreNowForTesting()

        let sectionAfter = model.state(for: "rescore-stale")
        let after = try #require(model.candidate(for: "rescore-stale"))
        // The displayed score changed, but the section/bucket are untouched.
        #expect(sectionAfter == sectionBefore)
        #expect(sectionAfter == .maybe)
        #expect(after.subjectBuckets[kion] == bucketBefore)
        #expect(after.subjectBuckets[kion] == .maybe)
    }

    @Test("rescore is per-person — a non-active person's stored score is unchanged")
    func rescoreLeavesOtherPersonScore() async throws {
        let model = sampleModel()
        // Kris is the active person; Ava's stored score must not move.
        await model.rescoreNowForTesting()

        let after = try #require(model.candidate(for: "rescore-stale"))
        #expect(try abs(#require(after.subjectScores[ava]) - otherPersonScore) < 1e-9)
        #expect(after.subjectScores[ava] != freshScore)
    }

    // MARK: - Item 49: scoping to undecided preserves promotions + refresh

    /// An UNDECIDED candidate sitting in Kris's "other" section whose fresh top-level
    /// bucket is `.keep` — a rescore must still surface it as a pending promotion even
    /// though the work is now scoped to undecided photos (it IS undecided).
    private func promotableCandidate() -> Candidate {
        Candidate(
            id: "rescore-promote",
            photoKey: "sample/rescore-promote.png",
            fileName: "IMG_5050.PNG",
            imageResourceName: "sample-keep-01",
            score: 0.95,
            bucket: .keep,
            faceBoxes: [CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)],
            selectedFaceIndex: 0,
            matchedSubjectID: kion,
            subjectScores: [kion: 0.95],
            subjectBuckets: [kion: .other],
            selectedFaceIndexBySubject: [kion: 0]
        )
    }

    @Test("assertion 5: an undecided photo that now scores better is still surfaced + applied")
    func undecidedPromotionStillSurfaces() async throws {
        let model = AppModel(
            engine: SampleTriageEngine(additionalCandidates: [promotableCandidate()]),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
        #expect(model.state(for: "rescore-promote") == .other) // starts in "the rest"

        await model.rescoreNowForTesting()
        // The scoped rescore still surfaces the promotion for the undecided photo…
        #expect(model.pendingPromotions["rescore-promote"] == .keep)

        // …and applying it moves the tile into Kris's keep section.
        model.applyPendingPromotions()
        #expect(model.state(for: "rescore-promote") == .keep)
    }

    @Test("assertion 6: a DECIDED photo is not re-scored — its prior score/section stand")
    func decidedPhotoIsNotRescored() async throws {
        let model = sampleModel()
        // Keep the stale-scored candidate: it's now DECIDED, so the scoped rescore must
        // skip it — its personalized score stays the stale prior (never refreshed).
        model.keep(try #require(model.candidate(for: "rescore-stale")))
        #expect(model.state(for: "rescore-stale") == .keep)

        await model.rescoreNowForTesting()

        let after = try #require(model.candidate(for: "rescore-stale"))
        #expect(try abs(#require(after.subjectScores[kion]) - staleScore) < 1e-9)
        #expect(after.subjectScores[kion] != freshScore) // NOT refreshed — it's decided
        #expect(model.state(for: "rescore-stale") == .keep) // section unchanged
    }

    // MARK: - Item 57: person-switch cancels the in-flight rescore

    @Test("switching the active person cancels an in-flight rescoreTask; existing didSet behaviors (clear pendingPromotions) still hold")
    func rescoreCancelledOnPersonSwitch() async throws {
        let candidateID = "rescore-cancel"
        let gated = GatedRescoreEngine()
        gated.scanCandidates = [
            Candidate(
                id: candidateID,
                photoKey: "key-\(candidateID)",
                fileName: "\(candidateID).jpg",
                imageResourceName: "",
                score: 0.5,
                bucket: .maybe
            ),
        ]
        let model = AppModel(engine: gated, environment: ["KION_PROFILE_STORE": uniqueStore().path])
        let personA = model.addPerson(name: "A")
        let personB = model.addPerson(name: "B")
        model.selectPerson(id: personA.id)
        #expect(model.activePersonID == personA.id)

        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
        #expect(model.candidate(for: candidateID) != nil)

        // Seed an existing promotion banner too, to prove the switch's OTHER
        // established didSet behavior (clearing it) still holds alongside the new
        // cancellation.
        model.seedPendingPromotionForTesting(candidateID, .keep)
        #expect(model.pendingPromotions[candidateID] != nil)

        model.rescoreNow()
        // Deterministic handshake: wait until `rescoreAll` has GENUINELY entered its
        // release-gated suspension — not a fixed yield count that merely "usually"
        // wins the race against the switch below.
        await gated.waitUntilEntered()

        // Switch people WHILE the rescore is provably suspended inside the gate.
        model.selectPerson(id: personB.id)
        #expect(model.activePersonID == personB.id)
        // Existing didSet behavior: promotions surfaced for the old person are
        // dropped immediately, before the gated engine even resumes.
        #expect(model.pendingPromotions.isEmpty)

        // Release the gate — the suspended `rescoreAll` resumes and must observe
        // that its task was cancelled by the switch.
        gated.release()
        // Deterministic drain: await the REAL `rescoreTask` handle directly (it
        // always completes — cancellation only flips `Task.isCancelled` inside it)
        // instead of yield-spinning.
        await model.awaitRescoreTaskForTesting()

        #expect(gated.observedCancellationAtResume == true)
        // Nothing resurrected pendingPromotions for the newly active person either.
        #expect(model.pendingPromotions.isEmpty)
    }
}

/// A `TriageEngine` spy whose `rescoreAll` suspends until `release()` is called (or
/// returns immediately if already released), then records whether ITS task had been
/// cancelled by the time it resumed — the deterministic seam for proving a person
/// switch actually cancels the in-flight `rescoreTask` (item 57), not merely guards
/// against mis-attribution. `scan` yields one final tick carrying `scanCandidates` so
/// a test can seed `AppModel.details` without the sample engine.
@MainActor
private final class GatedRescoreEngine: TriageEngine {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var observedCancellationAtResume = false
    var scanCandidates: [Candidate] = []
    var resultsToReturn: [String: RescoredPhoto] = [:]

    private var gateEntered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    /// Suspends until `rescoreAll` has GENUINELY entered its release-gated
    /// suspension (proven by the fake actually storing its resume continuation) —
    /// not a fixed yield count that merely "usually" wins the race against a
    /// person switch issued right after. Safe to call before OR after `rescoreAll`
    /// itself starts.
    func waitUntilEntered() async {
        if gateEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enteredWaiter = cont
        }
    }

    private func markGateEntered() {
        gateEntered = true
        let waiter = enteredWaiter
        enteredWaiter = nil
        waiter?.resume()
    }

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        let candidates = scanCandidates
        return AsyncStream { continuation in
            continuation.yield(ScanProgress(progress: 1, candidates: candidates, isFinal: true))
            continuation.finish()
        }
    }

    func rescoreAll(onlyPhotoKeys _: Set<String>?) async throws -> [String: RescoredPhoto] {
        if released {
            markGateEntered()
        } else {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                continuation = cont
                // Signal "entered" only AFTER the resume continuation is stored, so
                // a waiter that proceeds past `waitUntilEntered()` can safely call
                // `release()` next without racing it.
                markGateEntered()
            }
        }
        observedCancellationAtResume = Task.isCancelled
        if Task.isCancelled { throw CancellationError() }
        return resultsToReturn
    }

    func enroll(referenceURLs _: [URL]) async throws -> [FaceEmbedding] { [] }

    func recordFeedback(photoKey _: String, label _: KiFinder.FeedbackLabel) async throws {}

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        FaceSelectionResult(score: 0, bucket: .other)
    }

    func export(photoKeys: [String], destination _: ExportDestination) async throws -> Int {
        photoKeys.count
    }

    func export(fileURLs: [URL], destination _: ExportDestination) async throws -> Int {
        fileURLs.count
    }
}
