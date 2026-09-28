import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Coverage for item 19's manually-drawn face regions on `AppModel`, driven by the
/// deterministic `SampleTriageEngine`: add/replace (one manual face per person),
/// degenerate no-op, per-person isolation, remove with index-stability across
/// subjects, and the prior-auto-pick restore (a real index OR nil). The geometry
/// inverse is tested separately in `FaceBoxGeometryTests`.
@Suite("App model manual region")
@MainActor
struct AppModelManualRegionTests {
    private let kion = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID

    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-manual-region-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// A photo neither sample person matched (no per-subject selection entries), so a
    /// drawing person's prior auto-pick is genuinely `nil`.
    private func unmatchedCandidate() -> Candidate {
        Candidate(
            id: "manual-nil-prior",
            photoKey: "sample/manual-nil.png",
            fileName: "IMG_9000.PNG",
            imageResourceName: "sample-keep-01",
            score: 0.2,
            bucket: .other,
            faceBoxes: [CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)],
            selectedFaceIndex: 0,
            matchedSubjectID: nil,
            subjectScores: [:],
            subjectBuckets: [:],
            selectedFaceIndexBySubject: [:]
        )
    }

    private func sampleModel(extra: [Candidate] = []) -> AppModel {
        AppModel(
            engine: SampleTriageEngine(additionalCandidates: extra),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    /// A valid, non-degenerate normalized region, and an alternate for re-draw tests.
    private let region = CGRect(x: 0.40, y: 0.45, width: 0.18, height: 0.22)
    private let region2 = CGRect(x: 0.10, y: 0.12, width: 0.14, height: 0.16)

    /// Lets the async `engine.addManualFace` task apply its score/bucket.
    private func drain() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    // MARK: - Add

    @Test("first draw appends exactly one box and selects it for the active person")
    func firstDrawAppendsAndSelects() throws {
        let model = sampleModel()
        let before = try #require(model.candidate(for: "sample-keep-1"))
        let beforeCount = before.faceBoxes.count // 2 detected faces in the sample

        model.addManualRegion(to: before, normalizedRect: region)

        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(after.faceBoxes.count == beforeCount + 1)
        #expect(after.faceBoxes.last == region)
        // The manual face is index `beforeCount` and is selected for Kris.
        #expect(model.manualFaceIndex(for: after) == beforeCount)
        #expect(after.selectedFaceIndexBySubject[kion] == beforeCount)
        #expect(after.selectedFaceIndex == beforeCount) // personalized to Kris
    }

    @Test("second draw by the same person replaces in place (count unchanged, one manual face)")
    func secondDrawReplacesInPlace() throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        let beforeCount = candidate.faceBoxes.count

        model.addManualRegion(to: candidate, normalizedRect: region)
        let afterFirst = try #require(model.candidate(for: "sample-keep-1"))
        let firstIndex = try #require(model.manualFaceIndex(for: afterFirst))
        model.addManualRegion(to: afterFirst, normalizedRect: region2)

        let afterSecond = try #require(model.candidate(for: "sample-keep-1"))
        // Count grew by exactly ONE across both draws — the re-draw replaced.
        #expect(afterSecond.faceBoxes.count == beforeCount + 1)
        #expect(model.manualFaceIndex(for: afterSecond) == firstIndex)
        #expect(afterSecond.faceBoxes[firstIndex] == region2) // replaced in place
        #expect(afterSecond.selectedFaceIndexBySubject[kion] == firstIndex)
    }

    @Test("a degenerate rect is a no-op")
    func degenerateIsNoOp() throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        let beforeCount = candidate.faceBoxes.count

        model.addManualRegion(to: candidate, normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
        model.addManualRegion(to: candidate, normalizedRect: CGRect(x: 2, y: 2, width: 0.2, height: 0.2)) // out of bounds

        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(after.faceBoxes.count == beforeCount)
        #expect(model.manualFaceIndex(for: after) == nil)
    }

    @Test("no active person is a no-op")
    func noActivePersonIsNoOp() throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        let before = candidate.faceBoxes.count
        model.activePersonID = nil // the nil-active fallback path
        model.addManualRegion(to: candidate, normalizedRect: region)
        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(after.faceBoxes.count == before)
    }

    @Test("one person's draw leaves another person's selection and manual map untouched")
    func drawDoesNotCrossPeople() throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-both-1")) // kion:0, ava:1
        model.addManualRegion(to: candidate, normalizedRect: region)

        let after = try #require(model.candidate(for: "sample-both-1"))
        // Ava is untouched: same matched face index, no manual entry.
        #expect(after.selectedFaceIndexBySubject[ava] == 1)
        #expect(after.manualFaceIndexBySubject[ava] == nil)
        // Switching to Ava, her view boxes her own face (index 1), not the manual one.
        model.selectPerson(id: ava)
        let avaView = try #require(model.candidate(for: "sample-both-1"))
        #expect(avaView.selectedFaceIndex == 1)
        #expect(model.manualFaceIndex(for: avaView) == nil)
    }

    @Test("the async engine result applies the score and bucket for the active person")
    func asyncResultAppliesScoreAndBucket() async throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-maybe-1")) // Kris maybe
        model.addManualRegion(to: candidate, normalizedRect: region)
        await drain()

        let after = try #require(model.candidate(for: "sample-maybe-1"))
        // Sample engine returns a deterministic keep-ish score/bucket for a draw.
        #expect(after.subjectBuckets[kion] == .keep)
        #expect(abs(after.score - SampleTriageEngine.manualFaceScore) < 1e-9)
        #expect(model.state(for: "sample-maybe-1") == .keep)
    }

    // MARK: - Remove

    @Test("remove deletes the box and a co-located second person's manual index stays correct")
    func removeReindexesOtherSubjectsManualFace() throws {
        let model = sampleModel()

        // Kris draws on sample-both-1 → appended at index 2.
        let base = try #require(model.candidate(for: "sample-both-1"))
        let detectedCount = base.faceBoxes.count // 2
        model.addManualRegion(to: base, normalizedRect: region)

        // Ava draws on the SAME photo → appended at index 3.
        model.selectPerson(id: ava)
        let avaBase = try #require(model.candidate(for: "sample-both-1"))
        model.addManualRegion(to: avaBase, normalizedRect: region2)
        let avaManual = try #require(model.candidate(for: "sample-both-1"))
        #expect(model.manualFaceIndex(for: avaManual) == detectedCount + 1) // 3
        #expect(avaManual.faceBoxes.count == detectedCount + 2) // 4

        // Kris removes their manual face (index 2).
        model.selectPerson(id: kion)
        let kionManual = try #require(model.candidate(for: "sample-both-1"))
        model.removeManualRegion(from: kionManual)

        let afterRemove = try #require(model.candidate(for: "sample-both-1"))
        #expect(afterRemove.faceBoxes.count == detectedCount + 1) // 3 — one removed
        #expect(afterRemove.manualFaceIndexBySubject[kion] == nil)

        // Ava's manual face shifted down from index 3 → 2 and still points at HER box.
        #expect(afterRemove.manualFaceIndexBySubject[ava] == detectedCount) // 2
        #expect(afterRemove.selectedFaceIndexBySubject[ava] == detectedCount)
        #expect(afterRemove.faceBoxes[detectedCount] == region2) // the box is Ava's drawn rect
    }

    @Test("remove restores a NON-nil prior auto-pick (fails an always-nil impl)")
    func removeRestoresNonNilPriorPick() throws {
        let model = sampleModel()
        // Kris's auto-pick on sample-keep-1 is face index 0.
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        #expect(candidate.selectedFaceIndexBySubject[kion] == 0)

        model.addManualRegion(to: candidate, normalizedRect: region)
        let drawn = try #require(model.candidate(for: "sample-keep-1"))
        #expect(drawn.selectedFaceIndexBySubject[kion] != 0) // now the manual index

        model.removeManualRegion(from: drawn)
        let restored = try #require(model.candidate(for: "sample-keep-1"))
        // Restored to the EXACT prior auto-pick, not nil.
        #expect(restored.selectedFaceIndexBySubject[kion] == 0)
        #expect(restored.manualFaceIndexBySubject[kion] == nil)
    }

    @Test("remove restores a nil prior auto-pick to nil")
    func removeRestoresNilPriorPick() throws {
        let model = sampleModel(extra: [unmatchedCandidate()])
        let candidate = try #require(model.candidate(for: "manual-nil-prior"))
        #expect(candidate.selectedFaceIndexBySubject[kion] == nil) // no prior pick

        model.addManualRegion(to: candidate, normalizedRect: region)
        let drawn = try #require(model.candidate(for: "manual-nil-prior"))
        #expect(drawn.selectedFaceIndexBySubject[kion] != nil) // manual selected

        model.removeManualRegion(from: drawn)
        let restored = try #require(model.candidate(for: "manual-nil-prior"))
        // Restored to nil (no entry) — the stashed prior was nil.
        #expect(restored.selectedFaceIndexBySubject[kion] == nil)
        #expect(restored.manualFaceIndexBySubject[kion] == nil)
    }

    @Test("remove is a no-op when the active person has no manual face")
    func removeWithoutManualIsNoOp() throws {
        let model = sampleModel()
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        let beforeCount = candidate.faceBoxes.count
        model.removeManualRegion(from: candidate)
        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(after.faceBoxes.count == beforeCount)
        #expect(after.selectedFaceIndexBySubject[kion] == 0) // unchanged auto-pick
    }

    // MARK: - Keyboard shortcut arm / remove (R, Shift-R)

    @Test("R arms drawing only while the large preview is up, and toggles it")
    func toggleArmsOnlyInPreview() throws {
        let model = sampleModel()
        model.focusedID = "sample-keep-1"

        // Outside the preview the shortcut is inert, so 'R' never surprises in the grid.
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion == false)

        model.openPreview()
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion == true)
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion == false)
    }

    @Test("moving the keyboard cursor to another photo disarms drawing")
    func focusChangeDisarms() throws {
        let model = sampleModel()
        model.focusedID = "sample-keep-1"
        model.openPreview()
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion)

        model.focusedID = "sample-maybe-1"
        #expect(model.isDrawingManualRegion == false)
    }

    @Test("closing the preview disarms drawing")
    func closingPreviewDisarms() throws {
        let model = sampleModel()
        model.focusedID = "sample-keep-1"
        model.openPreview()
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion)

        model.closePreview()
        #expect(model.isDrawingManualRegion == false)
    }

    @Test("Shift-R removes the focused photo's manual region and disarms")
    func removeFocusedManualRegionClearsAndDisarms() throws {
        let model = sampleModel()
        model.focusedID = "sample-keep-1"
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        model.addManualRegion(to: candidate, normalizedRect: region)
        #expect(try model.manualFaceIndex(for: #require(model.candidate(for: "sample-keep-1"))) != nil)

        model.openPreview()
        model.toggleManualRegionDrawing()
        #expect(model.isDrawingManualRegion)

        model.removeFocusedManualRegion()
        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(model.manualFaceIndex(for: after) == nil)
        #expect(model.isDrawingManualRegion == false)
    }

    @Test("Shift-R is a no-op outside the preview (leaves the manual region intact)")
    func removeFocusedIsNoOpOutsidePreview() throws {
        let model = sampleModel()
        model.focusedID = "sample-keep-1"
        let candidate = try #require(model.candidate(for: "sample-keep-1"))
        model.addManualRegion(to: candidate, normalizedRect: region)

        // Preview is closed → the shortcut does nothing.
        model.removeFocusedManualRegion()
        let after = try #require(model.candidate(for: "sample-keep-1"))
        #expect(model.manualFaceIndex(for: after) != nil)
    }
}
