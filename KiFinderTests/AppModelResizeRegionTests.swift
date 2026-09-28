import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 21: the resize gesture commits on release by handing a NEW raw rect to the
/// SAME `addManualRegion` replace-in-place path that draw uses (no new model method,
/// no append). These tests drive that path directly on `AppModel` with the
/// deterministic `SampleTriageEngine`: a resize after a draw leaves the box count
/// unchanged, updates the box in place, keeps the manual index + selection, and does
/// NOT disturb the stashed prior-auto-pick.
@Suite("App model resize region")
@MainActor
struct AppModelResizeRegionTests {
    private let kris = SampleTriageEngine.primarySubjectID

    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-resize-region-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func sampleModel() -> AppModel {
        AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    /// The drawn region and the post-resize region (a different rect).
    private let drawn = CGRect(x: 0.40, y: 0.45, width: 0.18, height: 0.22)
    private let resized = CGRect(x: 0.34, y: 0.40, width: 0.30, height: 0.34)

    @Test("resize replaces the manual box in place: count unchanged, box updated, no append")
    func resizeReplacesInPlace() throws {
        let model = sampleModel()
        let base = try #require(model.candidate(for: "sample-keep-1"))
        let detectedCount = base.faceBoxes.count // 2 auto faces

        // Draw a manual region (first commit → appends one box, stashes prior pick).
        model.addManualRegion(to: base, normalizedRect: drawn)
        let afterDraw = try #require(model.candidate(for: "sample-keep-1"))
        let manualIndex = try #require(model.manualFaceIndex(for: afterDraw))
        #expect(afterDraw.faceBoxes.count == detectedCount + 1)
        #expect(afterDraw.faceBoxes[manualIndex] == drawn)

        // The stash recorded at draw time (the active person's prior auto-pick was face 0).
        let stashAfterDraw = afterDraw.priorAutoPickBySubject

        // Resize commit: the SAME path with a new rect.
        model.addManualRegion(to: afterDraw, normalizedRect: resized)
        let afterResize = try #require(model.candidate(for: "sample-keep-1"))

        // Count unchanged (replaced, not appended), and the SAME index updated.
        #expect(afterResize.faceBoxes.count == detectedCount + 1)
        #expect(model.manualFaceIndex(for: afterResize) == manualIndex)
        #expect(afterResize.faceBoxes[manualIndex] == resized)

        // Selection stays pinned on the manual index for the active person + default.
        #expect(afterResize.selectedFaceIndexBySubject[kris] == manualIndex)
        #expect(afterResize.selectedFaceIndex == manualIndex)

        // The stashed prior-auto-pick is untouched by the resize (only the FIRST draw
        // records it) — a later remove must still restore the original auto-pick.
        #expect(afterResize.priorAutoPickBySubject == stashAfterDraw)
        #expect(afterResize.priorAutoPickBySubject[kris] == .some(0))
    }

    @Test("after a resize, remove still restores the ORIGINAL prior auto-pick")
    func removeAfterResizeRestoresOriginalPick() throws {
        let model = sampleModel()
        let base = try #require(model.candidate(for: "sample-keep-1"))
        #expect(base.selectedFaceIndexBySubject[kris] == 0) // original auto-pick

        model.addManualRegion(to: base, normalizedRect: drawn)
        let afterDraw = try #require(model.candidate(for: "sample-keep-1"))
        model.addManualRegion(to: afterDraw, normalizedRect: resized) // resize
        let afterResize = try #require(model.candidate(for: "sample-keep-1"))

        model.removeManualRegion(from: afterResize)
        let afterRemove = try #require(model.candidate(for: "sample-keep-1"))
        // Restored to the EXACT original auto-pick (0), not nil — the resize didn't
        // clobber the stash.
        #expect(afterRemove.selectedFaceIndexBySubject[kris] == 0)
        #expect(afterRemove.manualFaceIndexBySubject[kris] == nil)
    }
}
