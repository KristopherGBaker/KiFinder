import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 46, bug 3: pressing Return (keep) ALWAYS advances the review cursor to the next
/// still-in-queue photo — even over an ALREADY-kept photo — while the decision itself
/// stays idempotent (no double teach / library-save / feedback-log line). This suite
/// reuses the item-37 spies: `SampleTriageEngine.recordedFeedback` (teach spy), a real
/// `KeptLibrary` wrapped in `SaveCountingLibrary` (save spy), and `KION_FEEDBACK_LOG`
/// (teaching-log probe), gated on the deterministic `flushLibrary()`/`drainFeedback()`
/// seams — no sleeps.
@Suite("App model decide-advance (item 46)")
@MainActor
struct AppModelDecideAdvanceTests {
    private let kion = SampleTriageEngine.primarySubjectID

    private func tempStore() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    private func tempLog() -> URL {
        LibraryFixtures.tempDir("feedback").appendingPathComponent("feedback.log")
    }

    private func realLibrary() -> SaveCountingLibrary {
        SaveCountingLibrary(wrapping: KeptLibrary(
            root: LibraryFixtures.tempDir("root"),
            indexURL: LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        ))
    }

    /// A source-backed candidate (so the keep-hook can actually save it) with no face —
    /// keeping it still teaches (`recordFeedback`) and saves once.
    private func sourceCandidate(id: String, red: CGFloat) -> Candidate {
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("\(id).jpg")
        LibraryFixtures.writeImage(to: source, red: red)
        return LibraryFixtures.candidate(id: id, source: source, fileName: "\(id).jpg")
    }

    /// Sample-mode model (Kris active) with two extra source-backed `.other` candidates
    /// appended (`src-1`, `src-2`) so a keep on `src-1` always has a distinct next id to
    /// advance to and the save spy sees a real source. Returns model + spies.
    private func makeModel() -> (AppModel, SampleTriageEngine, SaveCountingLibrary, URL) {
        let lib = realLibrary()
        let log = tempLog()
        let spy = SampleTriageEngine(additionalCandidates: [
            sourceCandidate(id: "src-1", red: 0.2),
            sourceCandidate(id: "src-2", red: 0.6),
        ])
        let model = AppModel(
            engine: spy,
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": tempStore(),
                "KION_FEEDBACK_LOG": log.path,
            ],
            keptLibrary: lib
        )
        return (model, spy, lib, log)
    }

    /// Counts feedback-log lines that reference `photoKey` (line format `photoKey,label`).
    private func logLineCount(_ url: URL, photoKey: String) -> Int {
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return contents
            .split(separator: "\n")
            .filter { $0.hasPrefix("\(photoKey),") }
            .count
    }

    // MARK: - Assertion 1: Enter advances over an already-kept photo

    @Test("Re-keeping an already-kept photo advances the cursor to queue[index + 1]")
    func reKeepAdvancesOverAlreadyKept() {
        let (model, _, _, _) = makeModel()
        // Resolve `sample-keep-1` to .keep once so it carries a STANDING keep decision.
        model.focusedID = "sample-keep-1"
        model.keepFocused()
        #expect(model.state(for: "sample-keep-1") == .keep)

        // The post-keep advance queue and the expected next id.
        let queue = model.keepCandidates + model.maybeCandidates + model.otherCandidates
        let index = queue.firstIndex(of: "sample-keep-1")
        #expect(index != nil)
        guard let index, index + 1 < queue.count else {
            Issue.record("expected a candidate after sample-keep-1 in the advance queue")
            return
        }
        let expectedNext = queue[index + 1]

        // Re-focus the SAME (already .keep) photo and keep again — it MUST advance.
        // Against the pre-fix code this left focusedID unchanged (== sample-keep-1).
        model.focusedID = "sample-keep-1"
        model.keepFocused()
        #expect(model.focusedID == expectedNext)
        #expect(model.focusedID != "sample-keep-1")
    }

    // MARK: - Assertion 2: the re-keep advance stays decision-idempotent

    @Test("Re-keep advances but does NOT re-teach, re-save, or duplicate the feedback log")
    func reKeepIsDecisionIdempotent() async {
        let (model, spy, lib, log) = makeModel()
        let photoKey = model.candidate(for: "src-1")?.photoKey ?? ""
        #expect(!photoKey.isEmpty)

        // Fresh keep on a source-backed photo: exactly one save + one teach + one log line.
        model.focusedID = "src-1"
        model.keepFocused()
        await model.flushLibrary()
        await model.drainFeedback()
        let savesAfterFirst = lib.saveCallCount
        let feedbackAfterFirst = spy.recordedFeedback.count
        let logLinesAfterFirst = logLineCount(log, photoKey: photoKey)
        #expect(savesAfterFirst == 1)
        #expect(feedbackAfterFirst == 1)
        #expect(logLinesAfterFirst == 1)

        // Re-focus the already-kept photo and keep again.
        model.focusedID = "src-1"
        model.keepFocused()
        await model.flushLibrary()
        await model.drainFeedback()

        // The DECISION is idempotent: no second save, teach, or log line…
        #expect(lib.saveCallCount == savesAfterFirst)
        #expect(spy.recordedFeedback.count == feedbackAfterFirst)
        #expect(logLineCount(log, photoKey: photoKey) == logLinesAfterFirst)
        // …only the cursor advanced away from the re-kept photo.
        #expect(model.focusedID != "src-1")
    }

    // MARK: - Assertion 3: fresh keep behavior preserved (advance + one save/teach; last = no wrap)

    @Test("A fresh keep advances and records exactly one save/teach")
    func freshKeepAdvancesAndRecordsOnce() async {
        let (model, spy, lib, _) = makeModel()
        model.focusedID = "src-1"

        let queue = model.keepCandidates + model.maybeCandidates + model.otherCandidates
        let index = queue.firstIndex(of: "src-1")
        #expect(index != nil)

        model.keepFocused()
        await model.flushLibrary()
        await model.drainFeedback()

        #expect(model.state(for: "src-1") == .keep)
        #expect(model.focusedID != "src-1", "fresh keep advances the cursor")
        #expect(lib.saveCallCount == 1)
        #expect(spy.recordedFeedback.count == 1)
    }

    @Test("Keeping the LAST photo in the advance queue leaves the cursor put (no wrap, no crash)")
    func keepingLastQueuePhotoDoesNotAdvance() {
        // Fresh last-photo keep: no next index, so the cursor holds.
        let freshModel = makeModel().0
        let freshQueue = freshModel.keepCandidates + freshModel.maybeCandidates + freshModel.otherCandidates
        let freshLast = freshQueue[freshQueue.count - 1]
        freshModel.focusedID = freshLast
        freshModel.keepFocused()
        #expect(freshModel.focusedID == freshLast, "fresh keep on the last queue photo does not wrap")

        // Already-kept last-photo keep: still no next index, so the cursor holds.
        // Keeping a `.maybe`/`.other` photo moves it INTO the keep section, which
        // reorders the queue — so the pre-keep "last" id is no longer last once kept.
        // Resolve EVERY queued photo to `.keep` first (they all land in the stable
        // keep section, and `maybe`/`other` drain empty); the queue's last id is then
        // fixed, so re-keeping that already-kept last photo has no next index → the
        // cursor holds. This isolates the true "no wrap past the end" invariant from
        // the section-move reordering.
        let keptModel = makeModel().0
        for id in keptModel.keepCandidates + keptModel.maybeCandidates + keptModel.otherCandidates {
            keptModel.focusedID = id
            keptModel.keepFocused()
        }
        let settledQueue = keptModel.keepCandidates + keptModel.maybeCandidates + keptModel.otherCandidates
        let keptLast = settledQueue[settledQueue.count - 1]
        keptModel.focusedID = keptLast
        keptModel.keepFocused() // re-keep the already-kept LAST photo
        #expect(keptModel.focusedID == keptLast, "re-keep on the last queue photo does not wrap")
    }

    // MARK: - Assertion 4: skip-focused advance is unchanged

    @Test("A fresh skip advances; an already-skipped photo is absent from the queue and does not advance")
    func skipAdvanceUnchanged() {
        let (model, _, _, _) = makeModel()
        let queue = model.keepCandidates + model.maybeCandidates + model.otherCandidates
        let first = queue[0]
        let expectedNext = queue[1]

        // Fresh skip advances to the next photo in the PRE-decision queue.
        model.focusedID = first
        model.skipFocused()
        #expect(model.state(for: first) == .skipped)
        #expect(model.focusedID == expectedNext)

        // The skipped photo has left the advance queue; re-focusing and skipping it again
        // finds no index in the queue, so the cursor stays put (skip flow unchanged).
        model.focusedID = first
        model.skipFocused()
        #expect(model.focusedID == first, "an already-skipped (absent-from-queue) photo does not advance")
    }

    // MARK: - Assertion 5: selectFace behavioral coverage (backs the preview wiring)

    @Test("selectFace re-points the active person's selected face index")
    func selectFaceUpdatesActivePersonFace() throws {
        let (model, _, _, _) = makeModel()
        // `sample-keep-1` carries two detected faces; Kris is the active person.
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        #expect(candidate.faceBoxes.count >= 2)
        #expect(model.activePersonID == kion)

        model.selectFace(candidate, faceIndex: 1)

        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(after.selectedFaceIndex == 1)
        #expect(after.selectedFaceIndexBySubject[kion] == 1)
    }
}
