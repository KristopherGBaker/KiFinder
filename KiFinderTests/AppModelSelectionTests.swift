import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Coverage for item 17's grid multi-selection on `AppModel`: the selection ops
/// (select/toggle/extend/selectSection/clear) and their anchor semantics, bulk
/// skip (skipSelected/skipSection) scoped per person, bulk export key ordering +
/// empty no-op, and the testable Esc seam. Selection is transient UI state scoped
/// to the active person's visible set, distinct from focus and the inspector.
@Suite("App model selection")
@MainActor
struct AppModelSelectionTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-selection-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// Sample mode (Kris + Ava enrolled, Kris active) with the five sample photos.
    /// For Kris the visible order (`orderedIDs`) is:
    ///   keep:  sample-keep-1
    ///   maybe: sample-maybe-1, sample-both-1
    ///   rest:  sample-keep-2, sample-maybe-2   (Ava's matches, item 7)
    private func sampleModel() -> AppModel {
        AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    private let orderForKion = [
        "sample-keep-1", "sample-maybe-1", "sample-both-1", "sample-keep-2", "sample-maybe-2",
    ]

    // MARK: - Selection ops

    @Test("select replaces the selection with one id and sets the range anchor")
    func selectReplacesAndAnchors() {
        let model = sampleModel()
        model.select("sample-both-1")
        #expect(model.selectedPhotoIDs == ["sample-both-1"])

        // The anchor is now sample-both-1 (index 2): extending forward to maybe-2
        // (index 4) yields exactly the inclusive range from that anchor.
        model.extendSelection(to: "sample-maybe-2")
        #expect(model.selectedPhotoIDs == ["sample-both-1", "sample-keep-2", "sample-maybe-2"])

        // Re-selecting collapses back to a single id (and re-anchors).
        model.select("sample-keep-1")
        #expect(model.selectedPhotoIDs == ["sample-keep-1"])
    }

    @Test("toggleSelection adds then removes an id without moving the anchor")
    func toggleAddsAndRemovesLeavingAnchor() {
        let model = sampleModel()
        model.select("sample-keep-1") // anchor = index 0

        model.toggleSelection("sample-maybe-2") // index 4
        #expect(model.selectedPhotoIDs == ["sample-keep-1", "sample-maybe-2"])
        model.toggleSelection("sample-maybe-2")
        #expect(model.selectedPhotoIDs == ["sample-keep-1"])

        // The toggle did NOT move the anchor: extend still runs from sample-keep-1.
        model.toggleSelection("sample-keep-2")
        model.extendSelection(to: "sample-both-1") // index 2
        #expect(model.selectedPhotoIDs == ["sample-keep-1", "sample-maybe-1", "sample-both-1"])
    }

    @Test("extendSelection yields the exact inclusive set in BOTH directions")
    func extendBothDirections() {
        let forward = sampleModel()
        forward.select("sample-keep-1") // index 0
        forward.extendSelection(to: "sample-both-1") // index 2
        let expected: Set = ["sample-keep-1", "sample-maybe-1", "sample-both-1"]
        #expect(forward.selectedPhotoIDs == expected)

        let backward = sampleModel()
        backward.select("sample-both-1") // index 2
        backward.extendSelection(to: "sample-keep-1") // index 0
        #expect(backward.selectedPhotoIDs == expected)
    }

    @Test("selectSection(.maybe) selects exactly the maybe ids and excludes others")
    func selectSectionMaybeIsExact() {
        let model = sampleModel()
        model.selectSection(.maybe)
        #expect(model.selectedPhotoIDs == ["sample-maybe-1", "sample-both-1"])
        // A select-everything impl would include these — assert they are excluded.
        #expect(!model.selectedPhotoIDs.contains("sample-keep-1")) // keep
        #expect(!model.selectedPhotoIDs.contains("sample-keep-2")) // rest/other
        #expect(!model.selectedPhotoIDs.contains("sample-maybe-2")) // rest/other
    }

    @Test("selectSection unions into the existing selection")
    func selectSectionUnions() {
        let model = sampleModel()
        model.select("sample-keep-1")
        model.selectSection(.other)
        #expect(model.selectedPhotoIDs == ["sample-keep-1", "sample-keep-2", "sample-maybe-2"])
    }

    @Test("no selection op admits an id outside the active person's visible set")
    func opsRejectOutOfVisibleIDs() {
        let model = sampleModel()
        model.select("does-not-exist")
        #expect(model.selectedPhotoIDs.isEmpty)
        model.toggleSelection("does-not-exist")
        #expect(model.selectedPhotoIDs.isEmpty)
        model.extendSelection(to: "does-not-exist")
        #expect(model.selectedPhotoIDs.isEmpty)
        // A real selection followed by an out-of-set extend leaves it unchanged.
        model.select("sample-keep-1")
        model.extendSelection(to: "ghost")
        #expect(model.selectedPhotoIDs == ["sample-keep-1"])
    }

    @Test("switching the active person empties the selection")
    func personSwitchClearsSelection() {
        let model = sampleModel()
        model.selectSection(.maybe)
        #expect(!model.selectedPhotoIDs.isEmpty)
        model.selectPerson(id: SampleTriageEngine.secondarySubjectID) // Ava
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("clearSelection empties the selection")
    func clearEmpties() {
        let model = sampleModel()
        model.selectSection(.maybe)
        model.clearSelection()
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    // MARK: - Bulk skip

    @Test("skipSelected skips the selection for the active person and clears it")
    func skipSelectedSkipsAndClears() {
        let model = sampleModel()
        #expect(model.maybeCount == 2)
        model.selectSection(.maybe) // sample-maybe-1, sample-both-1

        model.skipSelected()
        #expect(model.state(for: "sample-maybe-1") == .skipped)
        #expect(model.state(for: "sample-both-1") == .skipped)
        #expect(model.maybeCount == 0)
        #expect(model.keepCount == 1) // keep section untouched
        #expect(model.selectedPhotoIDs.isEmpty) // cleared after the bulk op
    }

    @Test("skipSelected is idempotent and reversible, and never crosses people")
    func skipSelectedIdempotentReversibleScoped() {
        let model = sampleModel()
        model.select("sample-both-1")
        model.skipSelected()
        #expect(model.state(for: "sample-both-1") == .skipped)

        // Idempotent: re-skipping (re-select + skip) is a no-op on the count.
        let skipped = model.skippedCandidates.count
        model.select("sample-both-1")
        model.skipSelected()
        #expect(model.skippedCandidates.count == skipped)

        // Reversible: a later keep overrides the skip.
        if let candidate = model.candidate(for: "sample-both-1") {
            model.keep(candidate)
        }
        #expect(model.state(for: "sample-both-1") == .keep)

        // Ava's review is untouched: sample-both-1 is still her own maybe.
        model.selectPerson(id: "Ava")
        #expect(model.state(for: "sample-both-1") == .maybe)
    }

    @Test("skipSection skips every visible candidate in that section")
    func skipSectionSkipsAll() {
        let model = sampleModel()
        let maybes = model.maybeCandidates
        #expect(maybes == ["sample-maybe-1", "sample-both-1"])
        model.skipSection(.maybe)
        for id in maybes {
            #expect(model.state(for: id) == .skipped)
        }
        #expect(model.maybeCount == 0)

        // Ava still owns sample-both-1 as her maybe — section skip didn't cross over.
        model.selectPerson(id: "Ava")
        #expect(model.state(for: "sample-both-1") == .maybe)
    }

    // MARK: - Bulk export

    @Test("selectedPhotoKeys returns distinct keys in orderedIDs order, not selection order")
    func selectedPhotoKeysOrdered() {
        let model = sampleModel()
        // Select two NON-ADJACENT photos, in reverse visible order, with distinct keys.
        model.select("sample-maybe-2") // index 4 → sample/copper-leaf.png
        model.toggleSelection("sample-keep-1") // index 0 → sample/fern-window.png

        // The keys must come back in orderedIDs order (index 0 then 4), proving the
        // computed property orders by the visible grid, not by selection order.
        #expect(model.selectedPhotoKeys == ["sample/fern-window.png", "sample/copper-leaf.png"])
    }

    @Test("exportSelected with an empty selection is a graceful no-op")
    func exportSelectedEmptyNoOp() {
        let model = sampleModel()
        #expect(model.selectedPhotoIDs.isEmpty)
        #expect(model.selectedPhotoKeys.isEmpty)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-empty-export-\(UUID().uuidString)", isDirectory: true)
        model.exportSelected(toFolder: dir)
        model.exportSelectedToPhotos()

        // No engine call ran, so no summary surfaced and the count stayed 0.
        #expect(model.exportedCount == 0)
        #expect(!model.isExportSummaryPresented)
    }

    // MARK: - Escape seam

    @Test("escape closes the preview first, leaving the selection intact")
    func escapeClosesPreviewLeavesSelection() {
        let model = sampleModel()
        model.selectSection(.maybe)
        model.openPreview() // requires a focused id (seeded at launch)
        #expect(model.isPreviewPresented)

        model.escape()
        #expect(!model.isPreviewPresented)
        #expect(!model.selectedPhotoIDs.isEmpty) // selection survives the preview close
    }

    @Test("escape with the preview closed clears a non-empty selection")
    func escapeClearsSelection() {
        let model = sampleModel()
        model.selectSection(.maybe)
        #expect(!model.isPreviewPresented)
        model.escape()
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    // MARK: - Keep/skip act on the WHOLE selection

    @Test("keepSelected keeps every selected photo for the active person and clears it")
    func keepSelectedKeepsAllAndClears() {
        let model = sampleModel()
        model.selectSection(.maybe) // sample-maybe-1, sample-both-1
        model.toggleSelection("sample-keep-2") // an .other tile too

        model.keepSelected()
        #expect(model.state(for: "sample-maybe-1") == .keep)
        #expect(model.state(for: "sample-both-1") == .keep)
        #expect(model.state(for: "sample-keep-2") == .keep)
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("Keyboard keep with a selection keeps the WHOLE selection, not just the focused tile")
    func keepFocusedWithSelectionKeepsAll() {
        let model = sampleModel()
        model.select("sample-maybe-1")
        model.toggleSelection("sample-both-1")
        // Focus a THIRD, unselected tile in the "rest" bucket (engineState .other) so it
        // would visibly flip to .keep if the cursor — rather than the batch — decided.
        model.focusedID = "sample-maybe-2"

        model.keepFocused()
        #expect(model.state(for: "sample-maybe-1") == .keep)
        #expect(model.state(for: "sample-both-1") == .keep)
        // The focused-but-unselected tile was NOT decided: it still reads its bucket.
        #expect(model.state(for: "sample-maybe-2") == .other)
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("Keyboard skip with a selection skips the WHOLE selection")
    func skipFocusedWithSelectionSkipsAll() {
        let model = sampleModel()
        model.selectSection(.maybe) // sample-maybe-1, sample-both-1
        model.focusedID = "sample-maybe-2" // unselected, bucket .other

        model.skipFocused()
        #expect(model.state(for: "sample-maybe-1") == .skipped)
        #expect(model.state(for: "sample-both-1") == .skipped)
        // The focused-but-unselected tile was untouched (still its bucket, not .skipped).
        #expect(model.state(for: "sample-maybe-2") == .other)
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("Keyboard keep with NO selection still keeps just the focused tile and advances")
    func keepFocusedWithoutSelectionIsSingle() throws {
        let model = sampleModel()
        #expect(!model.hasSelection)
        let focus = try #require(model.focusedID)
        model.keepFocused()
        // Exactly the focused tile was kept; nothing else was newly kept beyond the
        // sample's pre-existing keep tile.
        #expect(model.state(for: focus) == .keep)
        let keptCount = orderForKion.filter { model.state(for: $0) == .keep }.count
        #expect(keptCount <= 2) // the focused keep, plus at most the sample keep tile
    }

    // MARK: - A decision resets the selection

    @Test("a bulk keep decides every selected photo and then clears the selection")
    func keepClearsSelection() {
        let model = sampleModel()
        model.select("sample-maybe-1")
        model.toggleSelection("sample-both-1")
        #expect(model.selectionCount == 2)

        model.keepSelected()
        #expect(model.state(for: "sample-maybe-1") == .keep)
        #expect(model.state(for: "sample-both-1") == .keep)
        #expect(model.selectedPhotoIDs.isEmpty)
        #expect(!model.hasSelection)
    }

    @Test("after a bulk skip the dropped anchor doesn't resurrect a range")
    func skipClearsSelectionAndAnchor() {
        let model = sampleModel()
        model.select("sample-keep-1") // anchor = index 0
        model.toggleSelection("sample-maybe-1")

        model.skipSelected()
        #expect(model.state(for: "sample-keep-1") == .skipped)
        #expect(model.state(for: "sample-maybe-1") == .skipped)
        #expect(model.selectedPhotoIDs.isEmpty)

        // The anchor went with the cleared selection: a shift-extend now behaves like a
        // plain select instead of expanding from the stale, pre-decision origin.
        model.extendSelection(to: "sample-both-1")
        #expect(model.selectedPhotoIDs == ["sample-both-1"])
    }

    @Test("a section skip also resets an unrelated selection")
    func skipSectionClearsSelection() {
        let model = sampleModel()
        model.select("sample-keep-1") // not in the maybe section
        model.skipSection(.maybe)
        #expect(model.maybeCount == 0)
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("toggling Hide reviewed resets the selection in BOTH directions")
    func hideReviewedToggleClearsSelection() {
        let model = sampleModel()
        model.selectSection(.maybe)
        #expect(model.selectionCount == 2)

        model.hideAlreadyReviewed = true
        #expect(model.selectedPhotoIDs.isEmpty)

        model.selectSection(.maybe)
        #expect(!model.selectedPhotoIDs.isEmpty)
        model.hideAlreadyReviewed = false
        #expect(model.selectedPhotoIDs.isEmpty)
    }

    @Test("setting Hide reviewed to its CURRENT value leaves the selection alone")
    func hideReviewedNoOpKeepsSelection() {
        let model = sampleModel()
        #expect(!model.hideAlreadyReviewed)
        model.selectSection(.maybe)
        let before = model.selectedPhotoIDs

        // No transition, no side effects — the didSet guards on oldValue.
        model.hideAlreadyReviewed = false
        #expect(model.selectedPhotoIDs == before)
    }

    @Test("escape with neither preview nor selection is a no-op")
    func escapeNoOp() {
        let model = sampleModel()
        model.clearSelection()
        #expect(!model.isPreviewPresented)
        #expect(model.selectedPhotoIDs.isEmpty)
        let focus = model.focusedID
        model.escape()
        // Nothing changed: no preview opened/closed, no selection touched, focus put.
        #expect(!model.isPreviewPresented)
        #expect(model.selectedPhotoIDs.isEmpty)
        #expect(model.focusedID == focus)
    }
}
