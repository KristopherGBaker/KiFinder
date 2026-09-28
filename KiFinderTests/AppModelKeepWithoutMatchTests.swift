import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 37: keep a photo into a person's library/export WITHOUT selecting a face or
/// teaching the engine. The `SampleTriageEngine` doubles as the feedback spy
/// (`recordedFeedback` counts every `recordFeedback`), a real `KeptLibrary` is the save
/// spy (`allEntries`), and `KION_FEEDBACK_LOG` is the teaching-log probe. The model
/// tests gate the spy assertions on the deterministic `drainFeedback()` seam — no sleeps.
@Suite("App model keep without a match (item 37)")
@MainActor
struct AppModelKeepWithoutMatchTests {
    private let kion = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID
    private let exif = "2021:07:15 12:00:00"

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

    /// A source-backed candidate with NO detectable face (`faceBoxes == []`,
    /// `selectedFaceIndex == nil`) — the real no-face case keep-without-match exists for.
    private func noFaceCandidate(id: String, red: CGFloat) -> Candidate {
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("\(id).jpg")
        LibraryFixtures.writeImage(to: source, red: red, exifDate: exif)
        return LibraryFixtures.candidate(id: id, source: source, fileName: "\(id).jpg")
    }

    /// Builds a sample-mode model whose review carries two extra no-face candidates
    /// (`noface-1` then `noface-2`, both `.other` for Kris) appended after the sample
    /// set — so a keep-without-match on `noface-1` always has a distinct next id to
    /// advance to. Returns the model, the sample/feedback spy engine, the save-spy
    /// library, and the feedback-log URL.
    private func makeModel() -> (AppModel, SampleTriageEngine, SaveCountingLibrary, URL) {
        let lib = realLibrary()
        let log = tempLog()
        let spy = SampleTriageEngine(additionalCandidates: [
            noFaceCandidate(id: "noface-1", red: 0.2),
            noFaceCandidate(id: "noface-2", red: 0.6),
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

    private func logContents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Assertion 1: keeps without teaching

    @Test("keep-without-match keeps into library/export without teaching, on the no-face case")
    func keepsWithoutTeaching() async throws {
        let (model, spy, lib, log) = makeModel()
        model.focusedID = "noface-1"

        // Precondition: the focused candidate has no selectable face.
        let before = try #require(model.candidate(for: "noface-1"))
        #expect(before.faceBoxes.isEmpty)
        #expect(before.selectedFaceIndex == nil)

        // Deterministically seed a pending promotion (NOT a timed rescore) and confirm it.
        model.seedPendingPromotionForTesting("noface-1", .maybe)
        #expect(model.pendingPromotions["noface-1"] != nil)
        #expect(model.pendingPromotionCount == 1)

        model.keepWithoutMatchFocused()
        await model.flushLibrary()
        await model.drainFeedback()

        // (a) decision is .keep and it joins the kept/export set…
        #expect(model.state(for: "noface-1") == .keep)
        #expect(model.keepCandidates.contains("noface-1"))
        // (b) ZERO engine teaching and NO feedback-log line for this photo…
        #expect(spy.recordedFeedback.isEmpty)
        #expect(!logContents(log).contains("lib/noface-1.jpg"))
        // (c) flagged kept-without-match…
        #expect(model.isKeptWithoutMatch("noface-1"))
        // (d) pending promotion cleared…
        #expect(model.pendingPromotions["noface-1"] == nil)
        // …the library save was invoked exactly once (spy counts invocations, so this is
        // independent of KeptLibrary's byte-hash dedupe)…
        #expect(lib.saveCallCount == 1)
        #expect(lib.allEntries.filter { $0.subjectId == kion }.count == 1)
        // …and the candidate's face state is UNTOUCHED (no manual face added).
        let after = try #require(model.candidate(for: "noface-1"))
        #expect(after.faceBoxes.isEmpty)
        #expect(after.selectedFaceIndex == nil)
        #expect(model.manualFaceIndex(for: after) == nil)
    }

    @Test("contrast: a normal keep on a face-backed candidate teaches exactly once")
    func normalKeepTeachesOnce() async {
        let (model, spy, _, log) = makeModel()
        model.focusedID = "sample-keep-1" // a face-backed sample candidate (Kris's keep)

        model.keepFocused()
        await model.drainFeedback()

        #expect(spy.recordedFeedback.count == 1)
        #expect(spy.recordedFeedback.first?.1 == .confirm)
        #expect(logContents(log).contains("sample/fern-window.png"))
        #expect(!model.isKeptWithoutMatch("sample-keep-1"))
    }

    // MARK: - Assertion 2: per-person scoped flag

    @Test("isKeptWithoutMatch is per-person scoped")
    func perPersonScoping() async {
        let (model, _, _, _) = makeModel()
        model.focusedID = "noface-1"
        model.keepWithoutMatchFocused()
        await model.flushLibrary()

        // True for the active person (Kris)…
        #expect(model.isKeptWithoutMatch("noface-1"))
        // …false for a normal keep…
        model.focusedID = "sample-keep-1"
        model.keepFocused()
        #expect(!model.isKeptWithoutMatch("sample-keep-1"))
        // …false under a DIFFERENT active person…
        model.selectPerson(id: ava)
        #expect(!model.isKeptWithoutMatch("noface-1"))
        // …and true again when switching back (per-scope, not cleared on switch).
        model.selectPerson(id: kion)
        #expect(model.isKeptWithoutMatch("noface-1"))
    }

    // MARK: - Assertion 3: reversal clears the flag and teaches

    @Test("a later normal keep clears the flag and teaches .confirm")
    func reversalByKeep() async {
        let (model, spy, _, _) = makeModel()
        model.focusedID = "noface-1"
        model.keepWithoutMatchFocused()
        await model.flushLibrary()
        #expect(model.isKeptWithoutMatch("noface-1"))
        #expect(spy.recordedFeedback.isEmpty)

        // Re-focus it (the keep-without-match advanced the cursor) and keep normally.
        model.focusedID = "noface-1"
        model.keepFocused()
        await model.drainFeedback()

        #expect(model.state(for: "noface-1") == .keep)
        #expect(!model.isKeptWithoutMatch("noface-1")) // flag cleared
        #expect(spy.recordedFeedback.filter { $0.1 == .confirm }.count == 1) // teaches once
    }

    @Test("a later skip clears the flag, sets .skipped, and teaches .reject")
    func reversalBySkip() async {
        let (model, spy, _, _) = makeModel()
        model.focusedID = "noface-1"
        model.keepWithoutMatchFocused()
        await model.flushLibrary()
        #expect(model.isKeptWithoutMatch("noface-1"))

        model.focusedID = "noface-1"
        model.skipFocused()
        await model.drainFeedback()

        #expect(model.state(for: "noface-1") == .skipped)
        #expect(!model.isKeptWithoutMatch("noface-1"))
        #expect(spy.recordedFeedback.filter { $0.1 == .reject }.count == 1)
    }

    // MARK: - Assertion 4: idempotent

    @Test("a second keep-without-match on an already-flagged photo is a no-op")
    func idempotent() async {
        let (model, spy, lib, _) = makeModel()
        model.focusedID = "noface-1"
        model.keepWithoutMatchFocused()
        await model.flushLibrary()
        await model.drainFeedback()
        // Count SAVE INVOCATIONS (dedupe-independent): a fresh keep-without-match saves once.
        let savesAfterFirst = lib.saveCallCount
        #expect(savesAfterFirst == 1)

        // Re-focus on the same photo and keep-without-match it again.
        model.focusedID = "noface-1"
        model.keepWithoutMatchFocused()
        await model.flushLibrary()
        await model.drainFeedback()

        #expect(lib.saveCallCount == savesAfterFirst) // no second save invocation (not masked by dedupe)
        #expect(spy.recordedFeedback.isEmpty) // still zero teaching
        #expect(model.focusedID == "noface-1") // did NOT advance
        #expect(model.state(for: "noface-1") == .keep)
        #expect(model.isKeptWithoutMatch("noface-1"))
    }

    // MARK: - Assertion 5: advances the cursor like keep

    @Test("a fresh keep-without-match advances focus to preDecisionQueue[index + 1]")
    func advancesCursor() {
        let (model, _, _, _) = makeModel()
        model.focusedID = "noface-1"

        let queue = model.keepCandidates + model.maybeCandidates + model.otherCandidates
        let index = queue.firstIndex(of: "noface-1")
        #expect(index != nil)
        guard let index, index + 1 < queue.count else {
            Issue.record("expected a candidate after noface-1 in the pre-decision queue")
            return
        }
        let expectedNext = queue[index + 1]

        model.keepWithoutMatchFocused()
        #expect(model.focusedID == expectedNext)
        #expect(model.focusedID != "noface-1")
    }
}

/// Item 37 assertion 6: the `KeyCommand` mapping. Return / keypad-enter WITH Shift is
/// keep-without-match; WITHOUT Shift it stays a normal keep.
@Suite("KeyCommand keep-without-match mapping (item 37)")
struct KeyCommandKeepWithoutMatchTests {
    @Test("Shift + Return / keypad-enter maps to keepWithoutMatch")
    func shiftEnterMapsToKeepWithoutMatch() {
        #expect(KeyCommand(keyCode: 36, shift: true) == .keepWithoutMatch) // Return
        #expect(KeyCommand(keyCode: 76, shift: true) == .keepWithoutMatch) // keypad enter
    }

    @Test("Return / keypad-enter WITHOUT Shift stays a normal keep")
    func plainEnterMapsToKeep() {
        #expect(KeyCommand(keyCode: 36, shift: false) == .keep)
        #expect(KeyCommand(keyCode: 76, shift: false) == .keep)
        #expect(KeyCommand(keyCode: 36) == .keep) // default shift == false
        #expect(KeyCommand(keyCode: 76) == .keep)
    }
}

/// Wraps a real `KeptLibrary` and COUNTS `save(originalAt:…)` invocations, so a test can
/// prove "exactly one save on a fresh keep-without-match" and "unchanged on the idempotent
/// repeat" independent of `KeptLibrary`'s byte-hash dedupe (which would mask a second save
/// in `allEntries`). All other ops pass through to the wrapped library.
final class SaveCountingLibrary: KeptLibrarySaving, @unchecked Sendable {
    private let wrapped: KeptLibrary
    private let lock = NSLock()
    private var _saveCalls = 0

    /// Number of times `save` was invoked (incremented on entry, before dedupe).
    var saveCallCount: Int { lock.withLock { _saveCalls } }

    init(wrapping wrapped: KeptLibrary) { self.wrapped = wrapped }

    var allEntries: [KeptEntry] { wrapped.allEntries }

    func save(originalAt source: URL, subjectId: String, personName: String, score: Double) async -> KeptSaveResult {
        lock.withLock { _saveCalls += 1 }
        return await wrapped.save(originalAt: source, subjectId: subjectId, personName: personName, score: score)
    }

    func isSaved(sourcePath: String, subjectId: String) -> Bool {
        wrapped.isSaved(sourcePath: sourcePath, subjectId: subjectId)
    }

    func remove(_ entry: KeptEntry) async -> Bool { await wrapped.remove(entry) }
    func updateRoot(_ url: URL) { wrapped.updateRoot(url) }
    func renameSubject(_ subjectId: String, to newName: String) async { await wrapped.renameSubject(subjectId, to: newName) }
    func removeSubject(_ subjectId: String) async { await wrapped.removeSubject(subjectId) }
    func flush() async { await wrapped.flush() }
}
