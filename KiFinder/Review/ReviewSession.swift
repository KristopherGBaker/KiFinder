import CoreGraphics
import Foundation
import KionEngine
import Observation

/// The review-decision responsibility carved out of `AppModel` (item 59): owns the
/// candidate ordering + details, every live keep/skip decision, focus/selection/
/// preview/navigation, live re-ranking, and face/manual-region candidate mutation.
///
/// A separate `@Observable @MainActor` type COMPOSED by `AppModel` (`model.review`)
/// — not an `AppModel` extension. The existing `AppModel+LibraryNavigation.swift` /
/// `AppModel+LibrarySelection.swift` file splits are extensions *within the same
/// module*, and because a cross-file extension can't see `private` members they
/// were forced to widen their state to `internal` (see `AppModel.swift`). This type
/// avoids repeating that: everything below is `private`/`private(set)`, reachable
/// only through the narrow API `AppModel` forwards.
///
/// Cross-object state that must be observed LIVE (never a value snapshotted at
/// construction) is injected as closures — `activePersonID`, `hideAlreadyReviewed`,
/// `columnCount`, and the `isInLibrary`/`saveToLibrary` hooks that read/write
/// `AppModel`'s own library state — so a person switch or a toggle flip is always
/// seen fresh (item 57). `engine`/`keptLibrary`/`skipStore` are injected as their
/// (class-bound) live references directly; a reference type is already "live" with
/// no snapshot risk.
@Observable
@MainActor
final class ReviewSession {
    private let engine: any TriageEngine
    private let keptLibrary: any KeptLibrarySaving
    private let skipStore: any SkipRecording
    /// Additive `KION_FEEDBACK_LOG` hook: `decide()` appends one `photoKey,label` line
    /// per recorded decision here. A constant snapshot of the env-resolved path is
    /// fine (unlike `activePersonID`/`hideAlreadyReviewed`/`columnCount`) since
    /// `AppModel` itself never changes this after init.
    private let feedbackLogURL: URL?

    private let activePersonIDProvider: () -> String?
    private let hideAlreadyReviewedProvider: () -> Bool
    private let columnCountProvider: () -> Int
    private let isInLibraryHook: (String) -> Bool
    private let saveToLibraryHook: (Candidate) -> Void

    /// Live read of the host's active person — every use re-invokes the provider,
    /// so this always reflects the CURRENT value, never one captured at init.
    private var activePersonID: String? { activePersonIDProvider() }
    private var hideAlreadyReviewed: Bool { hideAlreadyReviewedProvider() }
    private var columnCount: Int { columnCountProvider() }
    private func isInLibrary(_ id: String) -> Bool { isInLibraryHook(id) }
    private func saveToLibrary(_ candidate: Candidate) { saveToLibraryHook(candidate) }

    init(
        engine: any TriageEngine,
        keptLibrary: any KeptLibrarySaving,
        skipStore: any SkipRecording,
        feedbackLogURL: URL?,
        initialCandidates: [Candidate],
        activePersonID: @escaping () -> String?,
        hideAlreadyReviewed: @escaping () -> Bool,
        columnCount: @escaping () -> Int,
        isInLibrary: @escaping (String) -> Bool,
        saveToLibrary: @escaping (Candidate) -> Void
    ) {
        self.engine = engine
        self.keptLibrary = keptLibrary
        self.skipStore = skipStore
        self.feedbackLogURL = feedbackLogURL
        activePersonIDProvider = activePersonID
        hideAlreadyReviewedProvider = hideAlreadyReviewed
        columnCountProvider = columnCount
        isInLibraryHook = isInLibrary
        saveToLibraryHook = saveToLibrary
        // Sample data is available synchronously (mirrors the old `AppModel` init)
        // so the grid renders deterministically. Focus is seeded by `AppModel` via
        // `focusFirstIfNeeded()` AFTER it finishes assigning `review` — calling it here
        // would route through the injected `isInLibrary` hook back into `AppModel.review`
        // while that property is still nil (mid-assignment), crashing construction.
        details = Dictionary(uniqueKeysWithValues: initialCandidates.map { ($0.id, $0) })
        order = initialCandidates.map(\.id)
    }

    // MARK: - Candidate model

    private var order: [String]
    /// Candidate details by id. Mutable because a live scan populates it with the
    /// real album results (sample mode seeds it synchronously at init).
    private var details: [String: Candidate]

    /// Whether the review grid has any candidates to show for the **active person**.
    /// Item 7: every scanned photo is visible under every person, so this means
    /// "any scanned photo exists for the active person to see" — true once a scan has
    /// produced any `order` id with a `details` entry, false (the person-aware empty
    /// state, "no scan yet") before then. Driven by the visible `order`/`details`
    /// set, never by a stale `details` entry outside `order`.
    var hasCandidates: Bool {
        order.contains { belongsToActivePerson($0) }
    }

    // MARK: - Decisions (per person)

    /// User keep/skip decisions, scoped **per person**: `decisions[personID][photoID]`.
    /// Each person's review is independent — keeping a photo while reviewing one
    /// person never moves or un-keeps it in another person's review. The export set
    /// for the active person is that person's own kept photos. Empty until the user
    /// acts; the displayed section is otherwise the active person's own engine bucket.
    /// Live re-ranking never moves a decided photo — only photos the user hasn't acted on.
    private var decisions: [String: [String: ReviewState]] = [:]
    /// Key under which the active person's decisions live (a sentinel when no one is
    /// active — the nil-active fallback path used by injected-engine unit tests).
    private var decisionScope: String {
        activePersonID ?? "__all__"
    }

    /// The active person's decision for a photo, if any.
    private func decision(for id: String) -> ReviewState? {
        decisions[decisionScope]?[id]
    }

    /// Photos the active person kept WITHOUT a selectable face match (item 37): a
    /// keep into the library/export that deliberately did NOT teach the engine.
    /// Scoped per person exactly like `decisions` (`keptWithoutMatch[personID]`), so
    /// switching the active person flips `isKeptWithoutMatch`. A normal keep/skip
    /// landing on the photo un-flags it (and DOES teach); cleared automatically by the
    /// per-scope keying on a person switch.
    private var keptWithoutMatch: [String: Set<String>] = [:]

    /// Whether a photo was kept-without-match for the ACTIVE person — drives the
    /// review-tile badge and distinguishes a no-teach keep from a real match. False
    /// for a normal keep, an undecided photo, or a keep-without-match under a
    /// DIFFERENT active person (per-scope, like `decision(for:)`).
    func isKeptWithoutMatch(_ id: String) -> Bool {
        keptWithoutMatch[decisionScope]?.contains(id) ?? false
    }

    /// Seeds a pending promotion for `id` directly — a deterministic test seam so a
    /// suite can assert keep-without-match clears the entry WITHOUT waiting on the
    /// timed rescore. Not used in production paths.
    func seedPendingPromotionForTesting(_ id: String, _ state: ReviewState) {
        pendingPromotions[id] = state
    }

    /// Drives one rescore deterministically — a test seam so a suite can assert the
    /// rescore's score refresh synchronously. Routes through the SAME `rescoreAndSurface`
    /// body the "Find new matches" button uses (item 50), so it also clears
    /// `hasUnscoredDecisions`. Not used in production paths.
    func rescoreNowForTesting() async {
        await rescoreAndSurface()
    }

    /// Undecided photos whose match improved enough (after teaching) to belong in a
    /// higher section, mapped to that section. Surfaced as a banner; nothing moves
    /// until the user applies them.
    private(set) var pendingPromotions: [String: ReviewState] = [:]
    /// True once the user has made a fresh TEACHING decision (keep/skip) since the last
    /// re-score — the "Find new matches" button (item 50) is enabled while this holds.
    /// Set on every `decide()` path that teaches; cleared whenever a re-score runs
    /// (`rescoreAndSurface`) and on a new scan (`applyScan`). NOT set by an idempotent
    /// repeat (decide early-returns) nor by a keep-without-match (never teaches).
    private(set) var hasUnscoredDecisions = false
    /// Handle for the in-flight manual re-score (item 50), reused so overlapping button
    /// clicks cancel the prior run instead of piling up. Was the keep/skip debounce.
    private var rescoreTask: Task<Void, Never>?
    /// In-flight `recordFeedback` engine teaches. `recordFeedback(for:label:)` appends
    /// its `Task` here (synchronously, on the main actor) so `drainFeedback()` can await
    /// them deterministically — tests drain this before asserting the engine spy's
    /// `recordFeedback` counts (no sleeps).
    private var pendingFeedback: [Task<Void, Never>] = []
    /// In-flight `selectFace` engine applications. `selectFace(_:faceIndex:)` appends
    /// its `Task` here (synchronously, on the main actor) so a test can await the async
    /// application deterministically (`drainFaceSelectionsForTesting()`) instead of
    /// yield-looping/polling for a person-switch race to resolve. Not read anywhere
    /// in production paths.
    private var pendingFaceSelections: [Task<Void, Never>] = []

    /// Awaits every currently-tracked in-flight `selectFace` application to
    /// completion, then clears the list — mirrors `drainFeedback()`. A deterministic
    /// seam so a race test can prove a late `selectFace` result has actually been
    /// applied (or dropped) before asserting, with NO yield-spinning.
    func drainFaceSelectionsForTesting() async {
        let inFlight = pendingFaceSelections
        pendingFaceSelections.removeAll()
        for task in inFlight {
            await task.value
        }
    }

    /// Awaits the CURRENT `rescoreTask` (if any) to run to completion — a
    /// deterministic seam so a race/cancellation test can prove a `rescoreNow()`-driven
    /// rescore has fully applied (or, if cancelled by a person switch, finished
    /// unwinding) before asserting, with NO yield-spinning. `Task<Void, Never>` always
    /// completes — cancellation only flips `Task.isCancelled` inside it — so this never
    /// hangs even for a cancelled task.
    func awaitRescoreTaskForTesting() async {
        await rescoreTask?.value
    }

    // MARK: - Focus & selection

    /// The candidate whose tile currently holds keyboard focus. Owned here (not in
    /// SwiftUI `@FocusState`) so an AppKit key handler can drive it and every tile
    /// can mirror it onto its accessibility element.
    var focusedID: String? {
        didSet {
            // Inspector-follows-cursor (item 20): the right `.inspector` is always
            // mounted, so we keep the selected candidate in sync with the keyboard
            // cursor UNCONDITIONALLY — arrow navigation (and keep/skip advance, and
            // the initial focus seed) re-point the inspector to the focused photo
            // whether or not the full-size center preview is up. When the preview is
            // open it scrubs both the big preview and the inspector together; when it
            // is closed the inspector still tracks the cursor instead of going stale.
            if let focusedID {
                selectedCandidateID = focusedID
            }
            // Seed the shift-extend anchor on the focused tile so a shift-click (or
            // shift-extend) right after arrowing extends from where the cursor sits.
            if let focusedID {
                anchorID = focusedID
            }
            // Disarm manual-region drawing when the cursor moves to a different photo
            // so the 'R' arm never carries over onto the next photo's preview.
            if oldValue != focusedID {
                isDrawingManualRegion = false
            }
        }
    }

    /// The candidate shown in the right inspector panel (and the lightbox when the
    /// big preview is up). Since item 20 it TRACKS the keyboard cursor: any non-nil
    /// `focusedID` change re-points it, so the panel follows arrow navigation even
    /// with the preview closed. `closeLightbox()`/`escape()` may transiently nil it
    /// (the inspector shows its empty state) until the next focus change reselects.
    var selectedCandidateID: String?

    /// Whether the full-size Quick Look-style preview is taking over the center
    /// content area (the grid region). The right `.inspector` stays mounted and
    /// shows the same photo's info + keep/skip while this is true. Observable so the
    /// surface swaps between the grid and the big preview as it flips.
    var isPreviewPresented = false

    /// Whether manual-region drawing is armed in the large center preview (the 'R'
    /// keyboard shortcut / the `drawRegionButton` in `FaceBoxedImage` share this).
    /// Reset whenever the preview closes or the keyboard cursor moves to another
    /// photo, so the arm never carries stale onto a different photo.
    var isDrawingManualRegion = false

    // MARK: - Multi-selection (item 17)

    /// The grid's transient multi-selection: every photo the user has lassoed for a
    /// bulk Skip/Export. DISTINCT from `selectedCandidateID` (the inspector's open
    /// photo) and `focusedID` (the keyboard cursor). Only ever holds ids in the
    /// active person's visible set; cleared on a person switch and on a new scan.
    private(set) var selectedPhotoIDs: Set<String> = []
    /// The range anchor for shift-extend selection: the last tile that began a
    /// selection (a plain click/`select`) or took keyboard focus. Not observable —
    /// it only seeds `extendSelection`.
    private var anchorID: String?

    /// Whether any photos are currently multi-selected (drives the bulk-action bar).
    var hasSelection: Bool {
        !selectedPhotoIDs.isEmpty
    }

    /// Number of multi-selected photos.
    var selectionCount: Int {
        selectedPhotoIDs.count
    }

    // MARK: - Derived lists / counts

    /// Whether a candidate is visible in the active person's Review. Item 7 removed
    /// the per-person *visibility* filter: every scanned photo the model has details
    /// for is visible under every enrolled person. The active person's own keep/maybe
    /// matches show in "Found matches"/"Worth a look"; everything else — the OTHER
    /// person's keep/maybe matches AND every no-match photo — lands in that person's
    /// own "The rest" (sectioning, not visibility, is what keeps reviews per-person).
    /// The only ids excluded are those with no `details` entry. The `nil`-active
    /// fallback (first run, or injected-engine unit tests) still shows everything.
    private func belongsToActivePerson(_ id: String) -> Bool {
        details[id] != nil
    }

    /// The engine bucket for a photo from the ACTIVE person's perspective: that
    /// person's own bucket, the headline bucket when no one is active (the
    /// nil-active fallback that shows everything), else "The rest" (a no-match photo
    /// the active person didn't match). Drives the displayed section before any user
    /// decision.
    private func engineState(for id: String) -> ReviewState {
        guard let candidate = details[id] else { return .other }
        if let activePersonID {
            if let bucket = candidate.subjectBuckets[activePersonID] {
                return ReviewState(bucket: bucket)
            }
            return .other
        }
        return ReviewState(bucket: candidate.bucket)
    }

    /// Whether `id` should be hidden from Review because the ACTIVE person has already
    /// acted on it (item 48). Only ever `true` when `hideAlreadyReviewed` is ON — so with
    /// the toggle OFF every section/count/nav is byte-for-byte today's behavior. "Acted
    /// on" = a `.keep`/`.skipped` in-session decision, OR the source is already in this
    /// person's library (a prior-scan keep), OR the persistent skip store has this
    /// person's skip for the source path (a prior-scan skip). All three checks are scoped
    /// to the active person, so a photo one person acted on stays visible for another.
    private func isHiddenAsReviewed(_ id: String) -> Bool {
        guard hideAlreadyReviewed else { return false }
        if let decision = decision(for: id), decision == .keep || decision == .skipped {
            return true
        }
        if isInLibrary(id) { return true }
        guard let source = details[id]?.sourceURL, let activePersonID else { return false }
        return skipStore.isSkipped(sourcePath: source.path, subjectId: activePersonID)
    }

    var keepCandidates: [String] {
        order.filter { state(for: $0) == .keep && belongsToActivePerson($0) && !isHiddenAsReviewed($0) }
    }

    var maybeCandidates: [String] {
        order.filter { state(for: $0) == .maybe && belongsToActivePerson($0) && !isHiddenAsReviewed($0) }
    }

    var otherCandidates: [String] {
        order.filter { state(for: $0) == .other && belongsToActivePerson($0) && !isHiddenAsReviewed($0) }
    }

    var skippedCandidates: [String] {
        order.filter { state(for: $0) == .skipped && belongsToActivePerson($0) && !isHiddenAsReviewed($0) }
    }

    var keepCount: Int {
        keepCandidates.count
    }

    var maybeCount: Int {
        maybeCandidates.count
    }

    var keepCandidateDetails: [Candidate] {
        keepCandidates.compactMap { details[$0].map(personalized) }
    }

    var maybeCandidateDetails: [Candidate] {
        maybeCandidates.compactMap { details[$0].map(personalized) }
    }

    var otherCandidateDetails: [Candidate] {
        otherCandidates.compactMap { details[$0].map(personalized) }
    }

    var skippedCandidateDetails: [Candidate] {
        skippedCandidates.compactMap { details[$0].map(personalized) }
    }

    /// The displayed review section for a photo: the user's keep/skip decision when
    /// present, otherwise the active person's own engine bucket. So a group photo
    /// shows under each person it matched, in *that person's* section.
    func state(for id: String) -> ReviewState {
        decision(for: id) ?? engineState(for: id)
    }

    func candidate(for id: String) -> Candidate? {
        details[id].map(personalized)
    }

    /// A snapshot of the candidate from the ACTIVE person's perspective: that
    /// person's matched face index and own score, so each person's tile/lightbox
    /// boxes their own face and shows their own confidence. Falls back to the stored
    /// (best-match) values when no one is active or that person has no entry.
    private func personalized(_ candidate: Candidate) -> Candidate {
        guard let activePersonID else { return candidate }
        var result = candidate
        if let index = candidate.selectedFaceIndexBySubject[activePersonID] {
            result.selectedFaceIndex = index
        }
        if let score = candidate.subjectScores[activePersonID] {
            result.score = score
        }
        return result
    }

    /// Flat keyboard-navigation order (keep, then maybe, then the rest, then skipped).
    private var orderedIDs: [String] {
        keepCandidates + maybeCandidates + otherCandidates + skippedCandidates
    }

    private var focusedCandidate: Candidate? {
        focusedID.flatMap { details[$0] }
    }

    // MARK: - Focus & navigation

    /// Ensures a focused tile exists once candidates are available (e.g. on launch
    /// for sample data, or after a live scan finishes).
    func focusFirstIfNeeded() {
        if focusedID == nil { focusedID = orderedIDs.first }
    }

    /// Keeps the keyboard cursor on a VISIBLE tile: if the focused id is no longer in
    /// the (filtered) `orderedIDs` — because the hide-already-reviewed filter turned on,
    /// or a keep/skip hid the focused tile — reseat to the first visible tile (or `nil`
    /// when nothing is left). Prevents focus/inspector from pointing at a filtered-out
    /// photo (item 48). Non-private: `AppModel`'s `hideAlreadyReviewed` didSet (which
    /// stays in `AppModel`) calls this after the toggle flips.
    func reseatFocusIfHidden() {
        guard let id = focusedID, !orderedIDs.contains(id) else { return }
        focusedID = orderedIDs.first
    }

    func moveLeft() {
        moveFocus(by: -1)
    }

    func moveRight() {
        moveFocus(by: 1)
    }

    func moveUp() {
        moveFocus(by: -columnCount)
    }

    func moveDown() {
        moveFocus(by: columnCount)
    }

    private func moveFocus(by delta: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let current = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let target = min(max(current + delta, 0), ids.count - 1)
        focusedID = ids[target]
    }

    // MARK: - Lightbox

    func open(_ id: String) {
        focusedID = id
        selectedCandidateID = id
    }

    func openFocused() {
        guard let id = focusedID else { return }
        selectedCandidateID = id
    }

    func closeLightbox() {
        selectedCandidateID = nil
        isPreviewPresented = false
        isDrawingManualRegion = false
    }

    // MARK: - Center preview (Quick Look-style)

    /// Opens the full-size center preview on the focused photo and mirrors it into
    /// the right inspector. A no-op when nothing is focused, so the preview never
    /// opens onto an empty grid.
    func openPreview() {
        guard let focusedID else { return }
        isPreviewPresented = true
        selectedCandidateID = focusedID
    }

    /// Closes the center preview, returning the grid. Leaves keyboard focus where it
    /// is so navigation/keep/skip continue seamlessly.
    func closePreview() {
        isPreviewPresented = false
        // Leaving the large preview disarms drawing so the arm never lingers.
        isDrawingManualRegion = false
    }

    /// Arms/disarms manual-region drawing in the large center preview (the 'R'
    /// keyboard shortcut). No-op unless the big preview is up on a focused photo, so
    /// 'R' outside the preview does nothing surprising.
    func toggleManualRegionDrawing() {
        guard isPreviewPresented, focusedID != nil else { return }
        isDrawingManualRegion.toggle()
    }

    /// Removes the focused photo's manual face region (the 'Shift-R' shortcut) and
    /// disarms drawing. No-op unless the big preview is up on a focused photo; the
    /// underlying `removeManualRegion` itself no-ops when there is no manual region.
    func removeFocusedManualRegion() {
        guard isPreviewPresented, let id = focusedID, let candidate = candidate(for: id) else { return }
        isDrawingManualRegion = false
        removeManualRegion(from: candidate)
    }

    /// Space toggles the preview: opens it on the focused photo, or closes it back
    /// to the grid if it is already up.
    func togglePreview() {
        if isPreviewPresented {
            closePreview()
        } else {
            openPreview()
        }
    }

    /// 1-based position of the lightbox candidate within the navigation order.
    func position(of id: String) -> Int? {
        orderedIDs.firstIndex(of: id).map { $0 + 1 }
    }

    var orderedCount: Int {
        orderedIDs.count
    }

    // MARK: - Multi-selection operations (item 17)

    /// The active person's visible ids belonging to a displayed section, in grid
    /// order. Drives `selectSection`/`skipSection` so a select-everything impl can't
    /// pass for a single section.
    private func visibleIDs(in state: ReviewState) -> [String] {
        switch state {
        case .keep: keepCandidates
        case .maybe: maybeCandidates
        case .other: otherCandidates
        case .skipped: skippedCandidates
        }
    }

    /// Whether an id is in the active person's visible set (so selection never
    /// admits a photo the active person can't see).
    private func isVisible(_ id: String) -> Bool {
        belongsToActivePerson(id) && order.contains(id)
    }

    /// Replaces the selection with just `id` and re-seats the range anchor on it —
    /// the plain-click / single-select behavior.
    func select(_ id: String) {
        guard isVisible(id) else { return }
        selectedPhotoIDs = [id]
        anchorID = id
    }

    /// Toggles `id` in/out of the selection without disturbing the range anchor —
    /// the ⌘-click behavior.
    func toggleSelection(_ id: String) {
        guard isVisible(id) else { return }
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else {
            selectedPhotoIDs.insert(id)
        }
    }

    /// Selects the inclusive range from the anchor to `id` over `orderedIDs` (works
    /// in both directions); leaves the anchor put so successive shift-extends grow
    /// from the same origin. With no anchor set, behaves like `select`.
    func extendSelection(to id: String) {
        guard isVisible(id) else { return }
        let ids = orderedIDs
        guard let anchorID, let anchorIndex = ids.firstIndex(of: anchorID),
              let targetIndex = ids.firstIndex(of: id)
        else {
            select(id)
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex ... targetIndex : targetIndex ... anchorIndex
        selectedPhotoIDs = Set(ids[range])
    }

    /// Adds every visible candidate in `state`'s section (for the active person) to
    /// the selection — the "Select all" header action. Existing selection is kept.
    func selectSection(_ state: ReviewState) {
        selectedPhotoIDs.formUnion(visibleIDs(in: state))
    }

    /// Clears the multi-selection (Esc, after a bulk action, or after any keep/skip
    /// decision — see `decide`). Also drops the range anchor so a later shift-extend
    /// starts from a fresh click rather than a stale, now-deselected origin.
    func clearSelection() {
        selectedPhotoIDs = []
        anchorID = nil
    }

    // MARK: - Bulk decisions / export (item 17)

    /// Photo keys for the current multi-selection, in visible (`orderedIDs`) order —
    /// the export source set `AppModel.exportSelected*` reads.
    var selectedPhotoKeys: [String] {
        orderedIDs
            .filter { selectedPhotoIDs.contains($0) }
            .compactMap { details[$0]?.photoKey }
    }

    /// Keeps every multi-selected photo for the active person (same per-person
    /// decision + teaching + library-save path as a single keep), then clears the
    /// selection. Idempotent and reversible (a later skip overrides).
    func keepSelected() {
        decideSelected(.keep)
    }

    /// Skips every multi-selected photo for the active person (same per-person
    /// decision + feedback/persistence path as a single skip), then clears the
    /// selection. Idempotent and reversible (a later keep overrides).
    func skipSelected() {
        decideSelected(.skipped)
    }

    /// Applies one decision to EVERY selected photo, then clears the selection. This is
    /// what "keep/skip with multiple photos selected" runs — the batch is decided as a
    /// unit whether it was triggered from the SelectionBar or the keyboard. Iterates a
    /// value-snapshot of `selectedPhotoIDs`, so `decide`'s own mid-loop
    /// `clearSelection()` can't cut the batch short; the trailing clear is the explicit
    /// post-batch reset the user asked for.
    private func decideSelected(_ newState: ReviewState) {
        let label: FeedbackLabel = newState == .keep ? .confirm : .reject
        for id in selectedPhotoIDs {
            guard let candidate = details[id] else { continue }
            decide(candidate, newState: newState, label: label)
        }
        clearSelection()
    }

    /// Skips every visible candidate in `state`'s section for the active person —
    /// item 14's "skip all in section". Leaves any unrelated selection intact.
    func skipSection(_ state: ReviewState) {
        for id in visibleIDs(in: state) {
            guard let candidate = details[id] else { continue }
            skip(candidate)
        }
    }

    // MARK: - Escape precedence (item 17)

    /// Esc precedence, made testable as a model method: a presented preview closes
    /// first via `closeLightbox()` (which nils the inspector's `selectedCandidateID`
    /// but leaves the multi-selection `selectedPhotoIDs` intact — a later arrow
    /// re-points the inspector); otherwise a non-empty `selectedPhotoIDs` clears;
    /// with neither, Esc is a no-op.
    func escape() {
        if isPreviewPresented {
            closeLightbox()
        } else if !selectedPhotoIDs.isEmpty {
            clearSelection()
        }
    }

    // MARK: - Decisions (idempotent, reversible until export)

    func keepFocused() {
        decideFocused(.keep)
    }

    func skipFocused() {
        decideFocused(.skipped)
    }

    /// Applies a keep/skip to the focused tile and ALWAYS advances focus to the
    /// next still-to-review photo (Worth a look, then The rest) so culling flows
    /// from the keyboard without manual navigation — even over an already-decided
    /// photo (item 46: Enter keeps flowing over already-kept photos). The decision
    /// itself stays idempotent (`decide`/`keep`/`skip` no-op on a repeat, so no
    /// double teach / library-save / feedback-log line); only the ADVANCE is
    /// unconditional.
    private func decideFocused(_ newState: ReviewState) {
        // When a multi-selection is up, keep/skip acts on the WHOLE selection (that's
        // what the user means by "keep/skip the selected photos"), then clears it — the
        // focused tile is just one member of the batch. With no selection this falls
        // through to the single-focused behavior below, including its cursor advance.
        if hasSelection {
            decideSelected(newState)
            return
        }
        guard let candidate = focusedCandidate else { return }
        // Advance through matches too: the matches section sits at the FRONT of
        // the grid order, so deciding a match now moves to the next cell. Matches
        // never sit after a "maybe"/"other" tile, so this is additive — the
        // already-working maybe/other advance is unchanged. The skipped pile is
        // intentionally excluded so the cursor never lands on the done section
        // (already-skipped photos are simply absent from this queue → no advance).
        let advanceQueue = keepCandidates + maybeCandidates + otherCandidates
        switch newState {
        case .keep: keep(candidate)
        case .skipped: skip(candidate)
        default: return
        }
        // Unconditional advance: whether or not the photo was already in `newState`,
        // move the cursor to the next queued photo. Past the last item is a no-op.
        if let index = advanceQueue.firstIndex(of: candidate.id),
           index + 1 < advanceQueue.count
        {
            focusedID = advanceQueue[index + 1]
        }
        // `decide` already reseats off a now-hidden tile; deciding the LAST visible tile
        // (no advance target) leaves the cursor on that reseated visible tile (item 48).
    }

    func keep(_ candidate: Candidate) {
        decide(candidate, newState: .keep, label: .confirm)
    }

    func skip(_ candidate: Candidate) {
        decide(candidate, newState: .skipped, label: .reject)
    }

    private func decide(_ candidate: Candidate, newState: ReviewState, label: FeedbackLabel) {
        // Idempotent: a repeated NORMAL decision on an already-resolved tile is a no-op,
        // so no duplicate feedback (engine or log) is recorded. The decision is
        // scoped to the active person, so it never disturbs another person's review.
        // EXCEPTION (item 37): a photo kept-WITHOUT-match sits at `.keep` but never
        // taught — a later normal Keep on it must still teach (and un-flag), so it is
        // NOT a no-op even though its state already equals `.keep`.
        let alreadyDecided = decision(for: candidate.id) == newState
        let wasKeptWithoutMatch = isKeptWithoutMatch(candidate.id)
        guard !alreadyDecided || wasKeptWithoutMatch else { return }
        decisions[decisionScope, default: [:]][candidate.id] = newState
        // Mirror the decision into the persistent skip store (item 48): a skip records
        // the source path under the active person so a re-scan can hide it; a keep clears
        // any prior skip so a now-kept photo is no longer remembered as skipped.
        recordSkipDecision(candidate, newState: newState)
        // A normal keep/skip teaches the engine, so it reverses any kept-without-match
        // flag for this photo (item 37): the engine now learns from it.
        keptWithoutMatch[decisionScope]?.remove(candidate.id)
        // This photo is no longer a pending suggestion now that it's been decided.
        pendingPromotions[candidate.id] = nil
        recordFeedback(for: candidate, label: label)
        appendFeedbackLog(photoKey: candidate.photoKey, label: label)
        // This fresh keep/skip taught the engine, so a re-score could now surface new
        // matches. Item 50: rather than auto-re-scoring (background CPU after every
        // decision), just flag that one is AVAILABLE — the "Find new matches" toolbar
        // button enables and the user triggers `rescoreNow()` when they want it.
        hasUnscoredDecisions = true
        // A fresh Keep durably saves the kept original into the active person's library
        // — OFF the keypress path so the keystroke stays instant. Skip never saves. A
        // kept-without-match → normal-keep upgrade (`alreadyDecided`) already saved when
        // it was kept-without-match, so it never double-saves.
        if newState == .keep, !alreadyDecided {
            saveToLibrary(candidate)
        }
        // A decision always resets the multi-selection: acting on the focused tile while
        // a selection is up (or finishing a bulk skip / section skip) would otherwise
        // leave stale — possibly now-hidden — tiles selected and the SelectionBar
        // asserting a selection the user has moved past. `skipSelected`'s own trailing
        // `clearSelection()` is now redundant but harmless (it iterates a value-copied
        // snapshot of the set, so clearing here mid-loop can't cut the loop short).
        clearSelection()
        // Item 50: no auto-re-score here — the user triggers it via the toolbar button.
        // With the hide-already-reviewed filter on, this decision may have hidden the
        // focused tile (from ANY entry point: keyboard, the inspector Keep/Skip buttons,
        // or a bulk skip). Reseat the cursor onto a still-visible tile (item 48). In the
        // keyboard flow `decideFocused` then advances focus, which overrides this.
        reseatFocusIfHidden()
    }

    // MARK: - Keep without a match (item 37)

    /// Keeps the focused photo into the active person's library/export WITHOUT teaching
    /// the engine — for a real no-face case where there's nothing to learn from. Mirrors
    /// `decideFocused`'s pre-decision advance so the cursor flows on a FRESH keep.
    func keepWithoutMatchFocused() {
        guard let candidate = focusedCandidate else { return }
        // A repeat keep-without-match on an already-flagged `.keep` photo is a no-op,
        // so it must NOT advance the cursor — capture freshness before mutating.
        let isFresh = !(decision(for: candidate.id) == .keep && isKeptWithoutMatch(candidate.id))
        // The advance queue is captured BEFORE the decision, exactly like `decideFocused`.
        let advanceQueue = keepCandidates + maybeCandidates + otherCandidates
        keepWithoutMatch(candidate)
        if isFresh,
           let index = advanceQueue.firstIndex(of: candidate.id),
           index + 1 < advanceQueue.count
        {
            focusedID = advanceQueue[index + 1]
        }
    }

    /// Keeps `candidate` without teaching: sets `.keep` (so it joins `keepCandidates` →
    /// the kept/export set AND saves to the active person's library), flags it
    /// kept-without-match, and clears any pending promotion — but records NO engine
    /// teaching (`recordFeedback`) and NO feedback-log line, and never touches the
    /// photo's faces. Idempotent: a repeat on an already kept-without-match `.keep`
    /// photo is a no-op (no second save, still zero feedback).
    private func keepWithoutMatch(_ candidate: Candidate) {
        let alreadyKeep = decision(for: candidate.id) == .keep
        // No-op once it's both `.keep` AND flagged kept-without-match (idempotent).
        guard !(alreadyKeep && isKeptWithoutMatch(candidate.id)) else { return }
        decisions[decisionScope, default: [:]][candidate.id] = .keep
        keptWithoutMatch[decisionScope, default: []].insert(candidate.id)
        // A keep-without-match is still a keep: clear any prior skip (item 48) so a
        // previously-skipped photo kept this way is no longer remembered as skipped.
        recordSkipDecision(candidate, newState: .keep)
        // Clear any pending promotion for this photo (it's decided now).
        pendingPromotions[candidate.id] = nil
        // Deliberately NO `recordFeedback` / `appendFeedbackLog`: keep-without-match
        // never teaches the engine. Save the original (a normal keep already saved, so
        // an upgrade from a normal keep never double-saves).
        if !alreadyKeep {
            saveToLibrary(candidate)
        }
        // Same as `decide`: a keep resets the multi-selection.
        clearSelection()
        // A keep-without-match with the filter on hides the tile too — reseat off it
        // (item 48). `keepWithoutMatchFocused` then advances, overriding this.
        reseatFocusIfHidden()
    }

    /// Mirrors a keep/skip decision into the persistent per-person skip store (item 48):
    /// a `.skipped` records the source path, a `.keep` clears any prior skip. A no-op
    /// without a `sourceURL` (sample candidates) or an active person — so the skip store
    /// only ever tracks real, source-backed photos.
    private func recordSkipDecision(_ candidate: Candidate, newState: ReviewState) {
        guard let source = candidate.sourceURL, let subjectId = activePersonID else { return }
        switch newState {
        case .skipped: skipStore.recordSkip(sourcePath: source.path, subjectId: subjectId)
        case .keep: skipStore.clearSkip(sourcePath: source.path, subjectId: subjectId)
        default: break
        }
    }

    // MARK: - Live re-ranking (surface, don't reflow)

    /// Number of undecided photos that now match better than their current section.
    var pendingPromotionCount: Int {
        pendingPromotions.count
    }

    /// User-triggered re-score (item 50, replaces the keep/skip auto-debounce): runs the
    /// item-49 scoped `rescoreAndSurface` immediately (no `Task.sleep`), reusing/cancelling
    /// the shared `rescoreTask` so overlapping button clicks don't pile up. Wired to the
    /// "Find new matches" toolbar button.
    func rescoreNow() {
        rescoreTask?.cancel()
        rescoreTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await self?.rescoreAndSurface()
        }
    }

    private func rescoreAndSurface() async {
        // Item 50: the manual re-score has run, so clear the "decisions since last score"
        // flag up front — on EVERY path (success, empty-undecided skip below, or a failing
        // engine call) — which disables the button and is why `rescoreNowForTesting()`
        // clears it too (it routes through this same body).
        hasUnscoredDecisions = false
        // Captured at initiation (mirrors `addManualRegion`, item 57): the engine call
        // below suspends, and the user is free to switch people while it's in flight —
        // this rescore's results belong to whoever was active when it STARTED.
        let subject = activePersonID
        // Item 49: scope the re-score to the photos the user hasn't decided yet.
        // `rescoreAndSurface` only ever SURFACES promotions (and refreshes displayed
        // scores) for undecided photos — decided ones already sit in their keep/skip
        // section — so re-scoring the rest is wasted work whose per-photo cost grows
        // with the accumulated negatives as culling proceeds. Compute the undecided
        // photoKeys (scoped to the active person via `decision(for:)`) and ask the
        // engine to re-score only those.
        var undecidedKeys: Set<String> = []
        for (id, candidate) in details where decision(for: id) == nil {
            undecidedKeys.insert(candidate.photoKey)
        }
        // Nothing undecided ⇒ nothing can be promoted or refreshed; skip the engine
        // call entirely (the compounding-cost win at the end of a cull).
        guard !undecidedKeys.isEmpty else {
            pendingPromotions = [:]
            return
        }
        guard let results = try? await engine.rescoreAll(onlyPhotoKeys: undecidedKeys) else { return }
        // Whether the CAPTURED subject is still the active person now that the engine
        // call has returned — a switch (which cancels this task, see
        // `activePersonDidChange`) may still lose the race and land here anyway, so
        // this is the authoritative guard, not the cancellation.
        let subjectStillActive = activePersonID == subject
        var promotions: [String: ReviewState] = [:]
        for (id, candidate) in details {
            guard let result = results[candidate.photoKey] else { continue }
            // Silently refresh the score and re-picked face — but never move the
            // tile. The re-picked face is recorded under the CAPTURED subject, keyed
            // by `subject` rather than a re-read of `activePersonID` (item 57), so a
            // late result always lands on the person it was computed for, never on
            // whoever the user has since switched to.
            var updated = candidate
            updated.score = result.score
            // Refresh the subject's personalized score too: `personalized(_:)`
            // overrides the displayed score with `subjectScores[activePersonID]`, so
            // without this the tile/inspector would show the stale per-subject value
            // (mirrors `applyManualFaceResult`, but SCORE ONLY — never the bucket,
            // which would move the tile to another section).
            if let subject {
                updated.subjectScores[subject] = result.score
            }
            if let index = result.selectedFaceIndex {
                updated.selectedFaceIndex = index
                if let subject {
                    updated.selectedFaceIndexBySubject[subject] = index
                }
            }
            // Only reassign when something actually changed, so a rescore doesn't
            // invalidate every `@Observable` entry (a full-list observation storm for
            // ~800 photos). Surfaced promotions are unaffected — they're derived from
            // `result.bucket` below, not from this reassignment.
            if updated != candidate {
                details[id] = updated
            }

            // Surface only promotions for photos the user hasn't decided on, for the
            // CAPTURED subject's own section — and only while that subject is STILL
            // active: `pendingPromotions` is a single, currently-active-person banner
            // (not scoped like the per-subject dicts above), so a late result must
            // never repaint it onto whoever is active now (item 57). A person switch
            // already cleared it via `activePersonDidChange`; leave it that way.
            guard subjectStillActive, subject != nil, decision(for: id) == nil else { continue }
            let suggested = ReviewState(bucket: result.bucket)
            if Self.rank(suggested) > Self.rank(engineState(for: id)) {
                promotions[id] = suggested
            }
        }
        guard subjectStillActive else { return }
        pendingPromotions = promotions
    }

    /// Moves the surfaced photos into their now-better sections for the active
    /// person, on the user's say-so — by upgrading that person's own bucket (which
    /// also makes a newly-matching photo visible to them).
    func applyPendingPromotions() {
        guard let activePersonID else {
            pendingPromotions = [:]
            return
        }
        for (id, newState) in pendingPromotions {
            guard decision(for: id) == nil, var candidate = details[id] else { continue }
            candidate.subjectBuckets[activePersonID] = Self.bucket(for: newState)
            details[id] = candidate
        }
        pendingPromotions = [:]
    }

    /// Maps a displayed review state back to an engine bucket (promotions only ever
    /// upgrade into keep/maybe; skipped/other collapse to `.other`).
    private static func bucket(for state: ReviewState) -> ReviewBucket {
        switch state {
        case .keep: .keep
        case .maybe: .maybe
        case .other, .skipped: .other
        }
    }

    /// Section precedence for deciding whether a re-score is a promotion.
    private static func rank(_ state: ReviewState) -> Int {
        switch state {
        case .keep: 2
        case .maybe: 1
        case .other, .skipped: 0
        }
    }

    func recordFeedback(for candidate: Candidate, label: FeedbackLabel) {
        // Track the teach so `drainFeedback()` can await it deterministically (tests
        // assert the engine spy's counts without sleeps). Appended synchronously on the
        // main actor before returning, so the keystroke stays non-blocking.
        let task = Task { [engine] in
            _ = try? await engine.recordFeedback(photoKey: candidate.photoKey, label: label)
        }
        pendingFeedback.append(task)
    }

    /// Awaits every tracked in-flight `recordFeedback` teach to completion, then clears
    /// the list. Called from `AppModel.flushPendingWrites()`/tests before asserting the
    /// engine spy's `recordFeedback` counts.
    func drainFeedback() async {
        let inFlight = pendingFeedback
        pendingFeedback.removeAll()
        for task in inFlight {
            await task.value
        }
    }

    // MARK: - Face selection

    /// Points the photo's match at the face the user picked in the lightbox. The
    /// box updates immediately; the engine then recomputes the score/bucket for
    /// that face and the photo re-buckets to match (a later Keep teaches the face).
    func selectFace(_ candidate: Candidate, faceIndex: Int) {
        guard var updated = details[candidate.id],
              updated.faceBoxes.indices.contains(faceIndex)
        else { return }
        // Re-point the ACTIVE person's matched face (so each person picks their own
        // face); fall back to the photo's default index when no one is active.
        let currentIndex = updated.selectedFaceIndex(forSubject: activePersonID)
        guard currentIndex != faceIndex else { return }
        // Captured at initiation (mirrors `addManualRegion`, item 57): a person
        // switch while the engine call below is in flight must never write ITS
        // result onto whoever is active when it returns.
        let subject = activePersonID
        if let subject {
            updated.selectedFaceIndexBySubject[subject] = faceIndex
        }
        updated.selectedFaceIndex = faceIndex
        details[candidate.id] = updated

        let task = Task { @MainActor [weak self, engine] in
            guard let result = try? await engine.selectFace(
                photoKey: candidate.photoKey,
                faceIndex: faceIndex
            ) else { return }
            self?.applyFaceSelection(to: candidate.id, subjectID: subject, result: result)
        }
        // Tracked so `drainFaceSelectionsForTesting()` can await it deterministically
        // (mirrors `pendingFeedback`); appended synchronously on the main actor before
        // returning, so the keystroke stays non-blocking.
        pendingFaceSelections.append(task)
    }

    private func applyFaceSelection(to id: String, subjectID: String?, result: FaceSelectionResult) {
        guard var updated = details[id] else { return }
        updated.score = result.score
        // Reflect the chosen face's match in the CAPTURED subject's own bucket —
        // keyed by `subjectID`, not a re-read of `activePersonID` (item 57), so a
        // late result always lands on the person it was requested for, never on
        // whoever the user has since switched to. The displayed section follows it
        // unless the photo carries a standing keep/skip decision (which
        // `state(for:)` always prioritizes).
        if let subjectID {
            updated.subjectBuckets[subjectID] = result.bucket
        }
        details[id] = updated
    }

    // MARK: - Manual face regions (item 19)

    /// The active person's manually-drawn face index on this candidate, if any — so
    /// the inspector/preview can style that box distinctly and offer a remove.
    func manualFaceIndex(for candidate: Candidate) -> Int? {
        guard let activePersonID else { return nil }
        return candidate.manualFaceIndexBySubject[activePersonID]
    }

    /// Adds (or, on a re-draw, replaces) the active person's manually-drawn face
    /// region for a photo whose face the detector missed. The box appears at once
    /// (mirroring `selectFace`); the engine then embeds the region, scores it, and
    /// the photo re-buckets to match. At most one manual face per person per photo.
    /// No-op with no active person or a degenerate rect.
    func addManualRegion(to candidate: Candidate, normalizedRect: CGRect) {
        guard let activePersonID,
              isDrawableFaceRegion(normalizedRect),
              var updated = details[candidate.id]
        else { return }

        let index: Int
        if let existing = updated.manualFaceIndexBySubject[activePersonID],
           updated.faceBoxes.indices.contains(existing)
        {
            // Re-draw: replace the active person's existing manual box IN PLACE — the
            // box count never grows past one manual face per person, and the prior-pick
            // stash is left untouched (only the FIRST draw records it).
            index = existing
            updated.faceBoxes[existing] = normalizedRect
        } else {
            // First draw: append a new box and stash the prior auto-pick (which may be
            // nil) so a later remove restores it. `.some(prior)` writes the key even
            // when `prior` is nil — a bare `dict[key] = nil` would delete it.
            index = updated.faceBoxes.count
            updated.faceBoxes.append(normalizedRect)
            let prior: Int? = updated.selectedFaceIndexBySubject[activePersonID]
            updated.priorAutoPickBySubject[activePersonID] = .some(prior)
            updated.manualFaceIndexBySubject[activePersonID] = index
        }
        // Select the manual face for the active person (and as the photo default).
        updated.selectedFaceIndexBySubject[activePersonID] = index
        updated.selectedFaceIndex = index
        details[candidate.id] = updated

        Task { @MainActor [weak self, engine] in
            guard let result = try? await engine.addManualFace(
                photoKey: candidate.photoKey,
                normalizedRect: normalizedRect
            ) else { return }
            self?.applyManualFaceResult(to: candidate.id, subjectID: activePersonID, result: result)
        }
    }

    /// Removes the active person's manual region: deletes the box (and the engine
    /// face), clears the manual map entry, restores the person's selection to the
    /// auto-pick stashed at draw time (a real index OR nil — NOT an unconditional
    /// nil), and re-indexes every stored index above the removed one across ALL
    /// subjects so they stay valid. No-op when the active person has no manual face.
    func removeManualRegion(from candidate: Candidate) {
        guard let activePersonID,
              var updated = details[candidate.id],
              let removedIndex = updated.manualFaceIndexBySubject[activePersonID],
              updated.faceBoxes.indices.contains(removedIndex)
        else { return }

        // Drop the box and the active person's manual entry.
        updated.faceBoxes.remove(at: removedIndex)
        updated.manualFaceIndexBySubject[activePersonID] = nil

        // Restore the active person's prior auto-pick (the inner value may be nil).
        // A present stash key means "had a prior pick" — restore it; clear the stash.
        let restored: Int? = updated.priorAutoPickBySubject[activePersonID] ?? nil
        if let restored {
            updated.selectedFaceIndexBySubject[activePersonID] = restored
        } else {
            updated.selectedFaceIndexBySubject[activePersonID] = nil
        }
        updated.selectedFaceIndex = restored
        updated.priorAutoPickBySubject[activePersonID] = nil

        // Index-stability: every index > removedIndex shifts down by one, across ALL
        // subjects, so remaining `faceBoxes` references stay valid (the shift bug).
        func shifted(_ value: Int) -> Int {
            value > removedIndex ? value - 1 : value
        }
        updated.selectedFaceIndexBySubject = updated.selectedFaceIndexBySubject.mapValues(shifted)
        updated.manualFaceIndexBySubject = updated.manualFaceIndexBySubject.mapValues(shifted)
        updated.priorAutoPickBySubject = updated.priorAutoPickBySubject.mapValues { $0.map(shifted) }
        if let selected = updated.selectedFaceIndex { updated.selectedFaceIndex = shifted(selected) }
        details[candidate.id] = updated

        Task { @MainActor [engine] in
            try? await engine.removeManualFace(photoKey: candidate.photoKey, faceIndex: removedIndex)
        }
    }

    private func applyManualFaceResult(to id: String, subjectID: String, result: ManualFaceResult) {
        guard var updated = details[id] else { return }
        updated.score = result.score
        updated.subjectScores[subjectID] = result.score
        updated.subjectBuckets[subjectID] = result.bucket
        details[id] = updated
    }

    /// Additive `KION_FEEDBACK_LOG` hook: append one `photoKey,label` line per
    /// recorded decision. Written synchronously so a polling test sees it
    /// immediately after the keypress.
    private func appendFeedbackLog(photoKey: String, label: FeedbackLabel) {
        guard let url = feedbackLogURL else { return }
        let line = "\(photoKey),\(label.rawValue)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Ensure the file exists before opening an append handle: FileHandle(for
        // WritingTo:) fails on a missing file, so create it first, then append.
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Scan / person-switch integration

    /// Writes a scan's terminal candidate set into the review state — called from
    /// `AppModel.apply(_:)` once a tick's candidates land. Seeds the ordering
    /// (ranked by the headline best-match bucket; the displayed section per person
    /// is derived from each candidate's own `subjectBuckets`, not this ordering) and
    /// starts every candidate clean: decisions start empty, and since candidate ids
    /// are stable source paths, a re-scan of the same album can reintroduce an id
    /// this run previously kept-without-match or surfaced as a pending promotion —
    /// clear both alongside `decisions` (item 57) so a re-scan never leaves a stale
    /// badge/banner with no decision backing it. A fresh scan also replaces the
    /// candidate set, so any prior multi-selection no longer refers to visible
    /// photos — clear it (and its anchor) too, and reseat focus.
    func applyScan(candidates: [Candidate]) {
        for candidate in candidates {
            details[candidate.id] = candidate
        }
        let keep = candidates.filter { $0.bucket == .keep }
        let maybe = candidates.filter { $0.bucket == .maybe }
        let other = candidates.filter { $0.bucket == .other }
        order = keep.map(\.id) + maybe.map(\.id) + other.map(\.id)
        decisions = [:]
        keptWithoutMatch = [:]
        pendingPromotions = [:]
        // A fresh scan starts with no decisions, so nothing is owed a re-score yet
        // (item 50): the "Find new matches" button starts disabled.
        hasUnscoredDecisions = false
        selectedPhotoIDs = []
        anchorID = nil
        focusFirstIfNeeded()
    }

    /// Reproduces the exact person-switch choreography previously inlined in
    /// `AppModel.activePersonID`'s `didSet` (item 59 extraction) — same operations,
    /// same order: cancel any in-flight manual re-score (item 57 — it belongs to
    /// whoever was active when it started, a switch mid-flight makes it stale;
    /// `rescoreAndSurface`'s subject-at-initiation guard is the belt to this
    /// suspenders), re-aim the engine's active-subject matching at the newly active
    /// person, drop promotions surfaced for the previously-active person (they'd
    /// otherwise apply to the wrong person's buckets), re-seat keyboard focus onto
    /// the new person's first candidate (every scanned photo is visible under each
    /// person, but sectioning is per-person, so the previously-focused tile may now
    /// sit in a different section), and clear the multi-selection (scoped to the
    /// previous person's visible set).
    func activePersonDidChange(to newActivePersonID: String?) {
        rescoreTask?.cancel()
        if let newActivePersonID {
            engine.setActiveSubject(newActivePersonID)
        }
        pendingPromotions = [:]
        focusedID = orderedIDs.first
        selectedPhotoIDs = []
    }
}
