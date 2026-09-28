import Foundation
@testable import KiFinder
import Testing

/// Pure-logic coverage for the keyboard-first culling model: focus navigation,
/// idempotent + reversible decisions, and lightbox selection. The AppKit key
/// handler maps key codes onto exactly these primitives, so exercising them here
/// verifies the behavior the UI tests drive end-to-end.
@Suite("Keyboard navigation & culling")
@MainActor
struct KeyboardNavigationTests {
    private func makeModel(columns: Int = 2) -> AppModel {
        // Isolate the store and reset it so there is no active person: Review now
        // filters candidates to the active person, and the `nil`-active fallback
        // shows all of them. Pinning that precondition keeps these keyboard
        // assertions deterministic regardless of any roster on the host machine.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-keyboard-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_REVIEW_COLUMNS": String(columns),
                "KION_PROFILE_STORE": dir.appendingPathComponent("store.json").path,
                "KION_RESET": "1",
            ]
        )
    }

    private func focusedFileName(_ model: AppModel) -> String? {
        model.focusedID.flatMap { model.candidate(for: $0)?.fileName }
    }

    private func selectedFileName(_ model: AppModel) -> String? {
        model.selectedCandidateID.flatMap { model.candidate(for: $0)?.fileName }
    }

    @Test("Initial focus is the first candidate")
    func initialFocus() {
        let model = makeModel()
        #expect(focusedFileName(model) == "IMG_1842.PNG")
    }

    @Test("Arrow navigation moves focus across a 2-column grid")
    func arrowNavigation() {
        let model = makeModel(columns: 2)

        model.moveRight()
        #expect(focusedFileName(model) == "IMG_1851.PNG")
        model.moveLeft()
        #expect(focusedFileName(model) == "IMG_1842.PNG")
        model.moveDown()
        #expect(focusedFileName(model) == "IMG_1861.PNG")
        model.moveUp()
        #expect(focusedFileName(model) == "IMG_1842.PNG")
    }

    @Test("Navigation clamps at the grid bounds")
    func navigationClamps() {
        let model = makeModel()

        model.moveLeft()
        model.moveUp()
        #expect(focusedFileName(model) == "IMG_1842.PNG")
    }

    @Test("Return keeps a maybe candidate, updating both counts")
    func keepMovesBucket() {
        let model = makeModel()
        model.moveDown() // IMG_1861, a maybe
        #expect(model.keepCount == 2)
        // Item 6 added the both-people sample candidate (a maybe for both people),
        // so the nil-active "show all" maybe bucket now has three tiles, not two.
        #expect(model.maybeCount == 3)

        // Keeping advances focus to the next photo to review, so assert on the tile
        // that was kept, not on where focus landed.
        let keptID = model.focusedID
        model.keepFocused()
        #expect(model.keepCount == 3)
        #expect(model.maybeCount == 2)
        #expect(model.state(for: keptID ?? "") == .keep)
    }

    @Test("Repeated keep on the same tile is idempotent")
    func keepIsIdempotent() {
        let model = makeModel()
        model.moveDown()
        let keptID = model.focusedID
        model.keepFocused()
        let kept = model.keepCount

        // Re-decide the SAME tile (focus has advanced); a repeat keep is a no-op.
        if let keptID, let candidate = model.candidate(for: keptID) {
            model.keep(candidate)
        }
        #expect(model.keepCount == kept)
    }

    @Test("Skip is reversible until export")
    func skipIsReversible() {
        let model = makeModel() // focus IMG_1842, a keep
        // Skip/keep now ADVANCE the cursor (item 35), so reverse the decision on the
        // captured tile id rather than via the (now-moved) focusedID.
        let tile = model.focusedID!

        model.skipFocused()
        #expect(model.keepCount == 1)
        #expect(model.state(for: tile) == .skipped)

        model.focusedID = tile
        model.keepFocused()
        #expect(model.keepCount == 2)
        #expect(model.state(for: tile) == .keep)
    }

    @Test("Lightbox open/close tracks the focused candidate and retains focus")
    func lightboxSelection() {
        let model = makeModel()
        // Item 20: the inspector follows the keyboard cursor unconditionally, so on
        // load the selection already mirrors the seeded focus (no longer nil).
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(selectedFileName(model) == "IMG_1842.PNG")

        model.openFocused()
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(model.position(of: model.focusedID ?? "") == 1)
        // Five sample candidates now (item 6 added the both-people group photo).
        #expect(model.orderedCount == 5)

        let focusBefore = model.focusedID
        model.closeLightbox()
        #expect(model.selectedCandidateID == nil)
        #expect(model.focusedID == focusBefore)
    }

    // MARK: - Center preview (Quick Look-style, item 9)

    @Test("Opening the preview presents it and mirrors the focused photo to the inspector")
    func previewOpenMirrorsSelection() {
        let model = makeModel()
        #expect(model.isPreviewPresented == false)
        // Item 20: selection already mirrors the seeded focus before any preview.
        #expect(model.selectedCandidateID == model.focusedID)

        model.openPreview()
        #expect(model.isPreviewPresented)
        #expect(model.selectedCandidateID == model.focusedID)
    }

    @Test("Toggle and Esc/close clear the preview")
    func previewToggleAndClose() {
        let model = makeModel()

        model.togglePreview()
        #expect(model.isPreviewPresented)
        model.togglePreview()
        #expect(model.isPreviewPresented == false)

        // Esc routes through closeLightbox(), which also drops the preview.
        model.openPreview()
        #expect(model.isPreviewPresented)
        model.closeLightbox()
        #expect(model.isPreviewPresented == false)

        // closePreview() likewise clears it.
        model.openPreview()
        model.closePreview()
        #expect(model.isPreviewPresented == false)
    }

    @Test("Opening the preview with no focused candidate is a safe no-op")
    func previewOpenWithoutFocus() {
        let model = makeModel()
        // Clear the seeded inspector selection, then drop focus. Nil-ing focus does
        // not re-point the inspector (the sync only fires on a non-nil focus), so the
        // selection stays cleared — opening the preview with nothing focused must not
        // present anything or resurrect a selection.
        model.closeLightbox()
        model.focusedID = nil
        #expect(model.selectedCandidateID == nil)

        model.openPreview()
        #expect(model.isPreviewPresented == false)
        #expect(model.selectedCandidateID == nil)
    }

    @Test("While the preview is open, a move updates both focus and selection")
    func previewFollowsNavigation() {
        let model = makeModel(columns: 2)
        model.openPreview()
        let first = model.focusedID

        model.moveRight()
        #expect(model.focusedID != first)
        #expect(model.selectedCandidateID == model.focusedID)

        model.moveDown()
        #expect(model.selectedCandidateID == model.focusedID)
    }

    @Test("Keep works while the preview is open")
    func keepWithPreviewOpen() {
        let model = makeModel()
        model.moveDown() // a maybe candidate
        let keptID = model.focusedID
        model.openPreview()
        #expect(model.isPreviewPresented)

        model.keepFocused()
        #expect(model.state(for: keptID ?? "") == .keep)
        // The preview stays up after a keep (it follows the advanced focus).
        #expect(model.isPreviewPresented)
    }

    // MARK: - Inspector follows the keyboard cursor (item 20)

    @Test("Initial focus seeds both the cursor and the inspector to the first candidate")
    func initialFocusSelectsInspector() {
        let model = makeModel()
        // No click, no preview: the inspector is non-empty on load and points at the
        // concrete first sample candidate, in lock-step with the keyboard cursor.
        #expect(model.focusedID != nil)
        #expect(model.selectedCandidateID != nil)
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(model.isPreviewPresented == false)
        #expect(focusedFileName(model) == "IMG_1842.PNG")
        #expect(selectedFileName(model) == "IMG_1842.PNG")
    }

    @Test("Arrow nav with the preview CLOSED moves to distinct photos and the inspector follows")
    func navigationClosedFollowsFocus() {
        let model = makeModel(columns: 2)
        #expect(model.isPreviewPresented == false)

        // Step 0: seeded focus is the first candidate; inspector mirrors it.
        #expect(focusedFileName(model) == "IMG_1842.PNG")
        #expect(model.selectedCandidateID == model.focusedID)

        // Step 1: moveRight advances the cursor to a DISTINCT candidate, and the
        // inspector (preview still closed) re-points to it. A frozen cursor or a
        // preview-gated impl fails here.
        model.moveRight()
        #expect(focusedFileName(model) == "IMG_1851.PNG")
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(selectedFileName(model) == "IMG_1851.PNG")
        #expect(model.isPreviewPresented == false)

        // Step 2: moveDown advances again to a third DISTINCT candidate; inspector follows.
        model.moveDown()
        #expect(focusedFileName(model) == "IMG_1874.PNG")
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(selectedFileName(model) == "IMG_1874.PNG")
        #expect(model.isPreviewPresented == false)
    }

    @Test("Keep-advance moves focus and the inspector follows to the advanced candidate")
    func keepAdvanceFollowsFocus() {
        let model = makeModel()
        model.moveDown() // IMG_1861, a maybe
        let capturedID = model.focusedID
        #expect(capturedID != nil)

        model.keepFocused()
        #expect(model.state(for: capturedID ?? "") == .keep)
        #expect(model.focusedID != capturedID, "focus should have advanced to a different candidate")
        #expect(model.selectedCandidateID == model.focusedID)
    }

    @Test("Preview-open scrubbing still works, and close nils selection while retaining focus")
    func previewOpenScrubsThenCloseRetainsFocus() {
        let model = makeModel(columns: 2)
        let first = model.focusedID

        model.openPreview()
        #expect(model.isPreviewPresented)

        model.moveRight()
        #expect(model.focusedID != first, "cursor advanced to a distinct target")
        #expect(model.selectedCandidateID == model.focusedID)
        #expect(model.isPreviewPresented)

        let focusBeforeClose = model.focusedID
        model.closeLightbox()
        #expect(model.selectedCandidateID == nil, "close transiently nils the inspector selection")
        #expect(model.focusedID == focusBeforeClose, "focus is retained across a close")
        #expect(model.isPreviewPresented == false)

        // The next non-nil focus change legitimately re-points the inspector.
        model.moveDown()
        #expect(model.selectedCandidateID == model.focusedID)
    }

    @Test("Arrowing re-points the inspector but leaves the multi-selection untouched")
    func navigationLeavesMultiSelectionUnchanged() {
        let model = makeModel(columns: 2)
        let first = model.focusedID ?? ""
        model.toggleSelection(first)
        let selectionBefore = model.selectedPhotoIDs
        #expect(selectionBefore.contains(first))

        model.moveRight()
        #expect(model.selectedCandidateID == model.focusedID, "inspector follows the cursor")
        #expect(model.selectedPhotoIDs == selectionBefore, "multi-selection is unaffected by arrowing")

        model.moveDown()
        #expect(model.selectedPhotoIDs == selectionBefore)
    }

    // MARK: - Decide advances through the matches section too (item 35)

    @Test("Keeping a focused MATCH tile advances to the next cell")
    func keepAdvancesFromMatch() {
        let model = makeModel()
        // The matches section: nil-active shows all, so the two `.keep` candidates
        // head the grid order. Focus the FIRST match and confirm there is a second.
        #expect(model.keepCandidates.count >= 2)
        let firstMatch = model.keepCandidates[0]
        let nextMatch = model.keepCandidates[1]
        model.focusedID = firstMatch
        #expect(focusedFileName(model) == "IMG_1842.PNG")

        model.keepFocused()
        // The cursor moved to the NEXT cell in `keep + maybe + other` (the next
        // match), not stuck on the just-decided one.
        #expect(model.focusedID == nextMatch)
        #expect(model.focusedID != firstMatch)
        #expect(focusedFileName(model) == "IMG_1851.PNG")
    }

    @Test("Skipping a focused MATCH tile advances to the next cell")
    func skipAdvancesFromMatch() {
        let model = makeModel()
        #expect(model.keepCandidates.count >= 2)
        let firstMatch = model.keepCandidates[0]
        let nextMatch = model.keepCandidates[1]
        model.focusedID = firstMatch

        model.skipFocused()
        #expect(model.state(for: firstMatch) == .skipped)
        #expect(model.focusedID == nextMatch)
        #expect(model.focusedID != firstMatch)
    }

    @Test("Deciding a maybe/other tile still advances exactly as before")
    func decideAdvancesFromNonMatch() {
        // Keep: focus a maybe tile, confirm it advances to the next active tile.
        let keepModel = makeModel()
        let firstMaybe = keepModel.maybeCandidates[0]
        let nextActive = (keepModel.maybeCandidates + keepModel.otherCandidates)[1]
        keepModel.focusedID = firstMaybe
        keepModel.keepFocused()
        #expect(keepModel.focusedID == nextActive)
        #expect(keepModel.focusedID != firstMaybe)

        // Skip: same starting state, same advance target (skip doesn't reshuffle the
        // pre-decision order the cursor walks).
        let skipModel = makeModel()
        let skipFirstMaybe = skipModel.maybeCandidates[0]
        let skipNextActive = (skipModel.maybeCandidates + skipModel.otherCandidates)[1]
        skipModel.focusedID = skipFirstMaybe
        skipModel.skipFocused()
        #expect(skipModel.focusedID == skipNextActive)
        #expect(skipModel.focusedID != skipFirstMaybe)
    }

    @Test("Last active tile stays put; a re-decision on a non-last tile still advances (item 46)")
    func lastTileNoWrapButReDecisionAdvances() {
        // Last tile in `keep + maybe + other`: deciding it must not wrap or crash.
        let model = makeModel()
        let active = model.keepCandidates + model.maybeCandidates + model.otherCandidates
        let last = active[active.count - 1]
        model.focusedID = last
        model.keepFocused()
        #expect(model.focusedID == last, "last active tile stays put — no wrap")

        // Item 46: Enter keeps flowing even over an ALREADY-kept photo. Keep the first
        // match (cursor advances), then point focus BACK at it and keep again — the
        // decision is idempotent, but the cursor now advances again (it is not last).
        let idempotentModel = makeModel()
        let firstMatch = idempotentModel.keepCandidates[0]
        idempotentModel.focusedID = firstMatch
        idempotentModel.keepFocused()
        #expect(idempotentModel.focusedID != firstMatch, "first decision advanced")

        let queue = idempotentModel.keepCandidates + idempotentModel.maybeCandidates + idempotentModel.otherCandidates
        let index = queue.firstIndex(of: firstMatch)
        #expect(index != nil)
        idempotentModel.focusedID = firstMatch
        idempotentModel.keepFocused()
        if let index, index + 1 < queue.count {
            #expect(idempotentModel.focusedID == queue[index + 1], "re-keep on an already-kept photo advances")
            #expect(idempotentModel.focusedID != firstMatch)
        }
    }
}

/// Pure mapping coverage for the raw-key-code → `KeyCommand` translation, the seam
/// the AppKit key handler drives. Item 9 swapped Return→keep and Space→preview.
@Suite("Key command mapping")
struct KeyCommandMappingTests {
    @Test("Return and keypad-enter keep")
    func returnKeeps() {
        #expect(KeyCommand(keyCode: 36) == .keep)
        #expect(KeyCommand(keyCode: 76) == .keep)
    }

    @Test("Space toggles the preview")
    func spacePreviews() {
        #expect(KeyCommand(keyCode: 49) == .preview)
    }

    @Test("Delete and forward-delete skip")
    func deleteSkips() {
        #expect(KeyCommand(keyCode: 51) == .skip)
        #expect(KeyCommand(keyCode: 117) == .skip)
    }

    @Test("Escape closes")
    func escCloses() {
        #expect(KeyCommand(keyCode: 53) == .close)
    }

    @Test("Arrows map to directions")
    func arrows() {
        #expect(KeyCommand(keyCode: 123) == .left)
        #expect(KeyCommand(keyCode: 124) == .right)
        #expect(KeyCommand(keyCode: 125) == .down)
        #expect(KeyCommand(keyCode: 126) == .up)
    }

    @Test("Keep and preview are distinct, and unknown codes map to nil")
    func distinctAndUnknown() {
        #expect(KeyCommand.keep != KeyCommand.preview)
        #expect(KeyCommand(keyCode: 0) == nil)
        #expect(KeyCommand(keyCode: 99) == nil)
    }
}
