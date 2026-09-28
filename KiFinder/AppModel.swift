import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KionEngine
import Observation
import UniformTypeIdentifiers

/// Cross-view app state: person/roster management, library/export lifecycle, scan
/// orchestration, and onboarding/model readiness. The review-decision responsibility
/// (candidate ordering, keep/skip decisions, focus/selection, live re-ranking,
/// face/manual-region mutation) is COMPOSED from `review: ReviewSession` (item 59) —
/// a separate `@Observable @MainActor` type, not an extension — and forwarded here so
/// every view/test call site keeps working unchanged. Every decision is routed
/// through `TriageEngine.recordFeedback` and, when the `KION_FEEDBACK_LOG` hook is
/// set, appended to a `photoKey,label` log for verification.
@Observable
@MainActor
final class AppModel {
    let engine: any TriageEngine
    /// When true, decision/lightbox changes complete without animation.
    let reduceMotion: Bool
    /// Logical columns used for keyboard arrow navigation and the grid layout.
    let columnCount: Int

    /// The composed review sub-model (item 59): owns candidate ordering/details,
    /// decisions, focus/selection, live re-ranking, and face/manual-region mutation.
    /// `private(set)` — nothing outside `AppModel` replaces the instance; its OWN
    /// state stays `private`/`private(set)` on `ReviewSession` itself, reachable only
    /// through the forwarders below (and the few call sites, like `apply(_:)` and the
    /// `activePersonID` `didSet`, that hand it new candidates / a person switch).
    private(set) var review: ReviewSession!

    /// The composed export sub-model (item 61): owns the export-summary/error channel and
    /// the single `runExport` core every export entry point (including the rerouted
    /// library export, now `LibraryModel.selectedLibraryFileURLs`, item 65) funnels
    /// through. `private(set)` — nothing outside `AppModel` replaces the instance; its OWN
    /// state stays `private`/`private(set)` on `ExportController` itself, reachable only
    /// through the forwarders below.
    private(set) var export: ExportController!

    /// The composed scan sub-model (item 63): owns the scan sheet's live progress
    /// state, the scan-summary fields, and the single `apply(_:)` terminal-tick
    /// handler `runScan`/`startScan` funnel through. `private(set)` — nothing outside
    /// `AppModel` replaces the instance; its OWN state stays `private`/`private(set)`
    /// on `ScanController` itself, reachable only through the forwarders below.
    private(set) var scan: ScanController!

    /// The composed people sub-model (item 67): owns the roster, the active-person
    /// selection (and its `didSet` cross-sub-model choreography), the roster-write
    /// error channel (item 53), and the add/rename/delete CRUD paths with their
    /// item-51/53 safety adjacencies. `private(set)` — nothing outside `AppModel`
    /// replaces the instance; its OWN state stays `private`/`private(set)` on
    /// `PeopleStore` itself, reachable only through the forwarders below. Assigned
    /// LATE in init (after `library` and `review`, both injected deps).
    private(set) var peopleStore: PeopleStore!

    /// Whether the review grid has any candidates to show for the **active person**.
    /// Item 7: every scanned photo is visible under every person, so this means
    /// "any scanned photo exists for the active person to see" — true once a scan has
    /// produced any candidate id with a details entry, false (the person-aware empty
    /// state, "no scan yet") before then.
    var hasCandidates: Bool {
        review.hasCandidates
    }

    /// When set (`KION_TEST_SCAN=1`), the scan sheet shows a deterministic
    /// "Scan Sample Album" affordance so XCUITest can start a scan without a
    /// system file picker — mirrors the enrollment sample-references hook.
    let showsScanTestAffordance: Bool
    /// When set (`KION_EXPORT_DEST=/path`), "Export to Folder" exports straight to
    /// this directory instead of opening `NSOpenPanel` — XCUITest can't drive the
    /// system picker, and the unsandboxed app can write where the test names.
    let testExportDest: URL?
    /// When set (`KION_LIBRARY_PICK=/path`), the onboarding/Settings "Choose…" button
    /// sets the library root straight to this directory instead of opening
    /// `NSOpenPanel` — same XCUITest-can't-drive-the-picker rationale as export.
    let testLibraryPickDest: URL?

    private let feedbackLogURL: URL?

    // MARK: - Review forwarders (item 59 — thin passthrough to `ReviewSession`)

    /// Whether a photo was kept-without-match for the ACTIVE person (item 37).
    func isKeptWithoutMatch(_ id: String) -> Bool {
        review.isKeptWithoutMatch(id)
    }

    /// Seeds a pending promotion for `id` directly — a deterministic test seam. Not
    /// used in production paths.
    func seedPendingPromotionForTesting(_ id: String, _ state: ReviewState) {
        review.seedPendingPromotionForTesting(id, state)
    }

    /// Drives one rescore deterministically — a test seam. Not used in production paths.
    func rescoreNowForTesting() async {
        await review.rescoreNowForTesting()
    }

    /// Undecided photos whose match improved enough (after teaching) to belong in a
    /// higher section, mapped to that section. Surfaced as a banner; nothing moves
    /// until the user applies them.
    var pendingPromotions: [String: ReviewState] {
        review.pendingPromotions
    }

    /// True once the user has made a fresh TEACHING decision (keep/skip) since the
    /// last re-score — the "Find new matches" button (item 50) is enabled while this
    /// holds.
    var hasUnscoredDecisions: Bool {
        review.hasUnscoredDecisions
    }

    /// Awaits every currently-tracked in-flight `selectFace` application to
    /// completion — a deterministic seam so a race test can prove a late `selectFace`
    /// result has actually been applied (or dropped) before asserting.
    func drainFaceSelectionsForTesting() async {
        await review.drainFaceSelectionsForTesting()
    }

    /// Awaits the CURRENT rescore task (if any) to run to completion — a
    /// deterministic seam for a race/cancellation test.
    func awaitRescoreTaskForTesting() async {
        await review.awaitRescoreTaskForTesting()
    }

    /// The candidate whose tile currently holds keyboard focus. Owned on
    /// `ReviewSession` (not in SwiftUI `@FocusState`) so an AppKit key handler can
    /// drive it and every tile can mirror it onto its accessibility element. A
    /// settable forwarder because views (and tests) bind/assign it directly.
    var focusedID: String? {
        get { review.focusedID }
        set { review.focusedID = newValue }
    }

    /// The candidate shown in the right inspector panel (and the lightbox when the
    /// big preview is up). Tracks the keyboard cursor (item 20).
    var selectedCandidateID: String? {
        review.selectedCandidateID
    }

    /// Whether the full-size Quick Look-style preview is taking over the center
    /// content area.
    var isPreviewPresented: Bool {
        review.isPreviewPresented
    }

    /// Whether manual-region drawing is armed in the large center preview.
    var isDrawingManualRegion: Bool {
        get { review.isDrawingManualRegion }
        set { review.isDrawingManualRegion = newValue }
    }

    // MARK: - Multi-selection (item 17)

    /// The grid's transient multi-selection: every photo the user has lassoed for a
    /// bulk Skip/Export.
    var selectedPhotoIDs: Set<String> {
        review.selectedPhotoIDs
    }

    /// Whether any photos are currently multi-selected (drives the bulk-action bar).
    var hasSelection: Bool {
        review.hasSelection
    }

    /// Number of multi-selected photos.
    var selectionCount: Int {
        review.selectionCount
    }

    // MARK: - Enrollment

    /// On-disk subject id of stores written by earlier single-person builds — a
    /// migration-compatibility constant, not a product name. The migration path keys
    /// on this value to adopt an existing single-person store; the *active* subject is
    /// derived from `activePersonID`, not from this constant.
    static let legacySubjectID = "person"

    private let profileRepository: any ProfileRepository
    private let testReferencePaths: [URL]

    // MARK: - People forwarders (item 67 — thin passthrough to `PeopleStore`)

    /// Everyone the app knows about (roster source of truth). Item 67: owned by
    /// `peopleStore`; forwarded read-only so every view/test call site keeps working
    /// unchanged.
    var people: [Person] { peopleStore.people }

    /// The selected (active) person whose candidates Review shows and whose profile
    /// gates enrollment. `nil` only before the first person is enrolled. Item 67:
    /// owned by `peopleStore` (its `didSet` runs the cross-sub-model choreography —
    /// enrolled-profile refresh, then `review.activePersonDidChange`); SETTABLE here
    /// because `AppModelManualRegionTests` assigns `model.activePersonID = nil`
    /// directly, and the set must route through `PeopleStore`'s own `didSet`.
    var activePersonID: String? {
        get { peopleStore.activePersonID }
        set { peopleStore.activePersonID = newValue }
    }

    /// Display name of the active person, or `nil` when no one is active (first
    /// run, or after the last person is deleted). Item 67: owned by `peopleStore`.
    var activePersonName: String? { peopleStore.activePersonName }

    /// Passthrough to the repository's cached thumbnail URL for a person, so the
    /// sidebar can render each person's real face crop without reaching into the
    /// repository seam directly. Item 67: owned by `peopleStore`.
    func thumbnailURL(for id: String) -> URL? {
        peopleStore.thumbnailURL(for: id)
    }

    /// Enrolled reference count for an arbitrary person (not just the active one),
    /// read from the embedding store. `nil` when that person isn't enrolled yet.
    /// Used by the sidebar to show each row's reference count. Item 67: owned by
    /// `peopleStore`.
    func referenceCount(for id: String) -> Int? {
        peopleStore.referenceCount(for: id)
    }

    /// The locally persisted enrolled profile for the active person, or `nil` when
    /// the active person still needs enrollment. Cached and refreshed whenever the
    /// active person changes so the sheet's presentation is deterministic.
    private(set) var enrolledProfile: ProfileBundle?
    /// Whether the enrollment sheet is currently presented over Review.
    var isEnrollmentPresented = false
    /// The live model backing the presented sheet, owned here so it survives view
    /// recomputations for the lifetime of the presentation.
    private(set) var enrollmentModel: EnrollmentModel?

    /// Whether the presented enrollment is MANDATORY — the first-run (or
    /// delete-last-person, item 51) enrollment with no one yet enrolled. When true
    /// the sheet hides Cancel and disables interactive dismissal, so the user can't
    /// escape onboarding onto an empty Review with no subject to find. Re-enrolling
    /// an existing person or adding one while others remain stays freely cancelable.
    /// Item 67: owned by `peopleStore`.
    var isEnrollmentMandatory: Bool { peopleStore.isEnrollmentMandatory }

    // MARK: - Scan moment (item 63: forwarders to the composed `ScanController`)

    /// Whether the album-scan sheet is presented over Review. Settable: `KiFinderRootView`
    /// binds `$model.isScanPresented` directly to a `.sheet`.
    var isScanPresented: Bool {
        get { scan.isScanPresented }
        set { scan.isScanPresented = newValue }
    }
    /// True while a scan stream is being consumed.
    var isScanning: Bool { scan.isScanning }
    /// 0…1 progress of the active/last scan, for the determinate bar.
    var scanProgress: Double { scan.scanProgress }
    /// True when progress can't be measured (live one-shot scan) → show a spinner.
    var scanIndeterminate: Bool { scan.scanIndeterminate }
    /// Running matched-candidate count shown live during the scan.
    var scanMatchesSoFar: Int { scan.scanMatchesSoFar }
    /// Live status line (e.g. "42 of 312 · June.zip").
    var scanStatusText: String { scan.scanStatusText }
    /// True once the active scan finished (candidates applied → route to Review).
    var scanComplete: Bool { scan.scanComplete }
    /// Display name of the album being scanned.
    var scanAlbumName: String { scan.scanAlbumName }
    /// Non-nil when the last scan FAILED (a localized, user-facing message).
    /// Distinct from a genuinely empty result: a failure keeps the prior review
    /// intact rather than clobbering it into a "nothing found" state, and the UI
    /// offers a retry/dismiss affordance. Cleared on a new scan or dismissal.
    var scanError: String? { scan.scanError }
    /// Total photos in the current scan, shown in the toolbar subtitle and sidebar.
    /// Zero until a scan runs and reports a real count.
    var totalPhotoCount: Int { scan.totalPhotoCount }
    /// True once any scan has completed (sample seed or a real album), so the UI
    /// can show an inviting empty state before the first scan instead of bogus
    /// zero/placeholder counts.
    var hasCompletedScan: Bool { scan.hasCompletedScan }
    /// Label of the most recently completed scan (album name, or "Sample Album"),
    /// or `nil` before the first scan. Drives the sidebar's current-scan summary.
    var currentScanLabel: String? { scan.currentScanLabel }

    /// Queue of one-time notices for EVERY store that quarantined an unreadable file
    /// at construction (item 57), in store order (roster, kept-index, skip-store).
    /// Plural and retained (not `??`-coalesced to just the first) so that when two
    /// or three stores are corrupt in the SAME launch, every one of them still gets
    /// its own root-level notice — dismissing one reveals the next rather than the
    /// others being silently dropped. See `ProfileRepository.rosterQuarantineNotice`/
    /// `KeptLibrarySaving.quarantineNotice`/`SkipRecording.quarantineNotice`.
    private(set) var dataIntegrityNotices: [String] = []

    /// The notice currently presented (the head of `dataIntegrityNotices`), or `nil`
    /// once the queue is empty. Presented at the ROOT level (`KiFinderRootView`,
    /// outside any sheet) via the same alert shape as `exportError`; dismissing it
    /// (`clearDataIntegrityNotice()`) pops the queue, so a second/third simultaneous
    /// notice surfaces next instead of being lost. Never re-shows a notice already
    /// popped — quarantining itself is one-time, so nothing re-enqueues it.
    var dataIntegrityNotice: String? {
        dataIntegrityNotices.first
    }

    // MARK: - Face backend (item 72)

    /// The face-embedding backend ACTIVE for THIS session — resolved exactly ONCE
    /// in `init` (env → persisted preference → default `.onnx`) and then FIXED for
    /// the app's lifetime: nothing later re-resolves it. Backs `activeDescriptor`,
    /// the per-backend store path, the repository stamp, the live engine, the
    /// item68 seed profiles, and the injected `EnrollmentModel` descriptor.
    /// Switching backends (via `faceBackend`'s setter, below) only persists the
    /// PREFERENCE for the NEXT launch to pick up — it never re-aims this running
    /// session (no rebuilding the engine/sub-models mid-session).
    private let activeBackend: FaceBackend

    /// The backend active for this session, exposed read-only for the UI (e.g. to
    /// show "currently: ArcFace" distinctly from the pending preference).
    var activeFaceBackend: FaceBackend { activeBackend }

    /// The model descriptor `activeBackend` resolves to — id/version/embedding
    /// dimension/calibration for the model THIS session's store/engine/enrollment
    /// are stamped and scored against.
    var activeDescriptor: FaceModelDescriptor { activeBackend.descriptor }

    /// The user's face-backend PREFERENCE. Reading it resolves FRESH every time
    /// (env → persisted → default), exactly like `manualRegionResizeEnabled`, so a
    /// Settings picker bound to it always reflects the current choice — including
    /// right after the user changes it. Setting it ONLY persists the choice; it
    /// never touches `activeBackend`/`activeDescriptor` above, so an already-
    /// running session keeps its own backend until the NEXT launch re-resolves
    /// (item 72's "relaunch to apply").
    var faceBackend: FaceBackend {
        get { resolveBackend(env: environment, defaults: libraryDefaults) }
        set { libraryDefaults.set(newValue.rawValue, forKey: BackendPreference.key) }
    }

    // MARK: - First-run backend chooser (item 73)

    /// Flips true the moment THIS session's chooser is answered. A plain
    /// `UserDefaults` write (via `faceBackend`'s setter) doesn't itself invalidate
    /// `@Observable` tracking of `needsBackendChoice` below, so this stored,
    /// observed property is what makes the chooser disappear without relaunch.
    private var didMakeFirstRunBackendChoice = false

    /// Whether the first-run backend chooser should be shown, evaluated BEFORE
    /// `needsOnboarding`'s own download gate: sample mode bypasses it entirely;
    /// answering it this session (`didMakeFirstRunBackendChoice`) or having
    /// ALREADY made an explicit choice (env override or a persisted preference —
    /// see `hasExplicitBackendChoice`) suppresses it permanently; and it's moot
    /// once nothing else needs onboarding (e.g. Vision needs no download, or the
    /// ONNX model is already installed).
    var needsBackendChoice: Bool {
        guard environment["KION_SAMPLE"] != "1" else { return false }
        guard !didMakeFirstRunBackendChoice else { return false }
        guard !hasExplicitBackendChoice(env: environment, defaults: libraryDefaults) else { return false }
        return needsOnboarding
    }

    /// Records the user's first-run backend choice: persists it (via `faceBackend`'s
    /// setter, so it's the SAME write path as the Settings picker) and marks the
    /// chooser answered for this session. Returns whether the App must reconstruct
    /// `AppModel` to apply it — `true` only when the choice DIFFERS from the backend
    /// already active this session (matching item72's "no live re-aim": this method
    /// never rebuilds anything itself, it only reports what the caller must do).
    @discardableResult
    func chooseFirstRunBackend(_ backend: FaceBackend) -> Bool {
        faceBackend = backend
        didMakeFirstRunBackendChoice = true
        return backend != activeFaceBackend
    }

    // MARK: - Onboarding / model readiness

    /// The environment used for the readiness gate (sample bypass + resolver env).
    private let environment: [String: String]
    /// Injectable filesystem roots the resolver consults (real dirs in production).
    private let modelLocations: ModelLocations
    /// The first-run model download state machine, owned here so its observable
    /// state drives `needsOnboarding` flipping to false on install without relaunch.
    let modelDownloader: ModelDownloader

    // MARK: - Kept-photo library (item 18a)

    /// The preference store the user-chosen library root's security-scoped bookmark
    /// persists to, and the store behind `hideAlreadyReviewed`/`manualRegionResizeEnabled`
    /// below. The SAME instance is also handed to `library` (item 65) — shared, not
    /// duplicated.
    private let libraryDefaults: UserDefaults
    /// The write side of the persistent kept-photo library (behind a seam so a test
    /// can inject a suspending save spy). A fresh `.keep` on the active person copies
    /// the kept original here off the keypress path.
    private let keptLibrary: any KeptLibrarySaving

    // MARK: - Hide already reviewed (item 48)

    /// The persistent per-person skip store (behind a seam so tests can inject an
    /// in-memory spy). A skip records the photo's source path under the active person;
    /// a keep clears it. Together with the kept library this lets Review hide photos the
    /// user already acted on across re-scans (see `hideAlreadyReviewed`).
    private let skipStore: any SkipRecording

    /// When ON, Review hides every photo the ACTIVE person has already acted on — kept
    /// or skipped this session, kept in a prior scan (library), or skipped in a prior
    /// scan (skip store) — from every section, its counts, and keyboard nav. DEFAULT
    /// OFF; when off Review behaves exactly as before. The last value persists in
    /// `libraryDefaults` (the injected `UserDefaults`) under a stable key.
    var hideAlreadyReviewed: Bool {
        didSet {
            guard oldValue != hideAlreadyReviewed else { return }
            libraryDefaults.set(hideAlreadyReviewed, forKey: HideReviewedPreference.key)
            // Toggling the filter reshuffles which tiles exist, so a carried-over
            // selection would point at photos the user can no longer see (filter on) or
            // at a set that no longer matches what's on screen (filter off). Drop it.
            review.clearSelection()
            // Turning the filter on can hide the currently-focused tile; move the
            // cursor onto a still-visible one (item 48).
            review.reseatFocusIfHidden()
        }
    }
    /// In-flight keep-hook library saves (and delete-subject purges), tracked so
    /// teardown/tests can await them deterministically via `drainLibrarySaves()`. Stays on
    /// `AppModel` (item 65): `LibraryModel`'s own async ops (`schedulePurge`, `removeFromLibrary`)
    /// return/run their own `Task`s but don't track this queue themselves.
    private var pendingLibrarySaves: [Task<Void, Never>] = []

    // MARK: - Library (item 65: composed `LibraryModel` forwarders)

    /// The composed library sub-model (item 65): owns the root/security-scoped-bookmark
    /// lifecycle and the browse/nav/selection flow — the former `AppModel+LibraryNavigation
    /// .swift` and `AppModel+LibrarySelection.swift` extensions, now DELETED, whose members
    /// are `LibraryModel` methods. `private(set)` — nothing outside `AppModel` replaces the
    /// instance; its OWN state stays `private`/`private(set)` on `LibraryModel` itself
    /// (except `libraryFocusedID`/`selectedLibraryIDs`, settable there too — tests assign
    /// them through the forwarders below), reachable only through the forwarders below.
    private(set) var library: LibraryModel!

    /// Bumped whenever a library save/removal/rename/root-switch lands so
    /// `isInLibrary`-driven views refresh.
    var libraryRevision: Int { library.libraryRevision }
    /// True when a STORED bookmark failed to resolve at launch (folder moved/deleted or
    /// data un-decodable): the root fell back to the container default and the UI can
    /// surface a re-select prompt. Cleared once the user picks a fresh root.
    var libraryRootNeedsReselection: Bool { library.libraryRootNeedsReselection }

    /// Whether the detail pane is showing the **Library** browse view instead of Review.
    var libraryBrowseActive: Bool { library.libraryBrowseActive }
    /// The browse filter: a specific `subjectId` (that person only) or `nil` (everyone).
    var libraryFilterSubjectID: String? { library.libraryFilterSubjectID }
    /// The grouped library data for the current filter, exposed to `LibraryBrowseView`.
    var libraryGroups: [LibraryPersonGroup] { library.libraryGroups }

    /// The keyboard cursor in the Library grid. Settable — tests assign it directly
    /// (`model.libraryFocusedID = …`), the same passthrough `ReviewSession.focusedID` uses.
    var libraryFocusedID: String? {
        get { library.libraryFocusedID }
        set { library.libraryFocusedID = newValue }
    }
    /// Whether the in-place full-size Library preview is showing.
    var libraryPreviewActive: Bool { library.libraryPreviewActive }

    /// The Library grid's transient multi-selection. Settable — tests assign it directly
    /// (`model.selectedLibraryIDs = …`), the same passthrough `libraryFocusedID` uses.
    var selectedLibraryIDs: Set<String> {
        get { library.selectedLibraryIDs }
        set { library.selectedLibraryIDs = newValue }
    }
    /// The shift-extend anchor for the Library selection.
    var libraryAnchorID: String? { library.libraryAnchorID }
    /// Whether any saved photos are multi-selected (drives the library selection bar).
    var hasLibrarySelection: Bool { library.hasLibrarySelection }
    /// Number of multi-selected saved photos.
    var librarySelectionCount: Int { library.librarySelectionCount }

    /// The persistent library root.
    var libraryRoot: URL { library.libraryRoot }
    /// The container default root (no bookmark/entitlement needed).
    var defaultLibraryRoot: URL { library.defaultLibraryRoot }
    /// True when the resolved root is the app-container default.
    var isUsingDefaultLibraryRoot: Bool { library.isUsingDefaultLibraryRoot }

    /// Persists a user-chosen CUSTOM folder as a security-scoped bookmark and switches the
    /// library root to it.
    func setCustomLibraryRoot(_ url: URL) {
        library.setCustomLibraryRoot(url)
    }

    /// Resets the library root to the app-container default and REMOVES any stored
    /// bookmark.
    func resetLibraryRootToDefault() {
        library.resetLibraryRootToDefault()
    }

    /// Whether the item-21 drag-handle resize of a drawn manual face region is offered
    /// (item 25). Resolved in priority order (env override → persisted user preference →
    /// default `false`). Assigning it persists the choice (the ONLY writer of the
    /// preference); resolving via the env override or the default never writes a
    /// preference. When `false` the manual box still draws/removes — only the resize
    /// handles are hidden.
    var manualRegionResizeEnabled: Bool {
        get { resolveManualRegionResizeEnabled(env: environment, defaults: libraryDefaults) }
        set { libraryDefaults.set(newValue, forKey: ManualRegionResizePreference.enabledKey) }
    }

    /// The user's scan-concurrency choice (item 75) as PICKED: `ScanWorkersPreference
    /// .automatic` (0) means "decide from the core count", any other value is an
    /// explicit width. Same env→persisted→default resolution as every other
    /// preference here; the engine resolves the same way at scan time, so this is the
    /// display/write side, `effectiveScanWorkerCount` the read-back.
    var scanWorkerCount: Int {
        get {
            if let raw = environment["KION_SCAN_WORKERS"], let value = Int(raw) { return value }
            if libraryDefaults.object(forKey: ScanWorkersPreference.countKey) != nil {
                return libraryDefaults.integer(forKey: ScanWorkersPreference.countKey)
            }
            return ScanWorkersPreference.automatic
        }
        set { libraryDefaults.set(newValue, forKey: ScanWorkersPreference.countKey) }
    }

    /// How many photos the NEXT scan will actually embed at once — the picked value
    /// resolved (Automatic → this machine's count) and clamped. What the Settings
    /// caption reports, and what the engine independently resolves for itself.
    var effectiveScanWorkerCount: Int {
        resolveScanWorkerCount(env: environment, defaults: libraryDefaults)
    }

    /// Whether a visible candidate's source is already in the **active person's**
    /// library — a cheap hint from the recorded source paths (distinct from the
    /// authoritative hash dedupe at save time). False with no active person, no
    /// `sourceURL`, or no matching saved entry.
    func isInLibrary(_ candidateID: String) -> Bool {
        _ = library.libraryRevision // observation dependency so the marker appears after a save lands
        // Item 59: candidate storage moved to `ReviewSession`; go through its
        // `candidate(for:)` accessor rather than a private `details` dict here.
        guard let candidate = review.candidate(for: candidateID),
              let source = candidate.sourceURL,
              let activePersonID
        else { return false }
        return keptLibrary.isSaved(sourcePath: source.path, subjectId: activePersonID)
    }

    /// Sets the library root from the onboarding/Settings "Choose…" control.
    func chooseLibraryRoot() {
        library.chooseLibraryRoot()
    }

    // MARK: - Library browse (item 18b: forwarders)

    /// Shows the Library browse view in the detail pane and (re)computes the grouped data
    /// for the current filter. Review state is untouched.
    func showLibrary() {
        library.showLibrary()
    }

    /// Returns the detail pane to Review (e.g. selecting a person). Review state is
    /// untouched.
    func showReview() {
        library.showReview()
    }

    /// Sets the browse person filter (`nil` = everyone) and recomputes the groups.
    func setLibraryFilter(_ subjectID: String?) {
        library.setLibraryFilter(subjectID)
    }

    /// The on-disk URL of a saved entry's copy, `<libraryRoot>/<entry.path>`.
    func libraryFileURL(for entry: KeptEntry) -> URL {
        library.libraryFileURL(for: entry)
    }

    /// Removes a saved photo from the library.
    func removeFromLibrary(_ entry: KeptEntry) {
        library.removeFromLibrary(entry)
    }

    // MARK: - Library browse focus & navigation (item 26a: forwarders)

    /// Every library entry's id in DISPLAY order, derived from `libraryGroups`.
    var libraryOrderedIDs: [String] { library.libraryOrderedIDs }
    /// The `LibraryPhotoItem` currently under the keyboard cursor, if any.
    var libraryFocusedItem: LibraryPhotoItem? { library.libraryFocusedItem }
    /// The focused `LibraryPhotoItem` under a name the view + tests read directly
    /// (item 26b); an alias for `libraryFocusedItem`.
    var focusedLibraryItem: LibraryPhotoItem? { library.focusedLibraryItem }
    /// The `KeptEntry` currently under the keyboard cursor, `nil` when nothing is focused.
    var focusedLibraryEntry: KeptEntry? { library.focusedLibraryEntry }

    /// Click-selects (focuses) a library cell WITHOUT opening the preview.
    func focusLibrary(_ id: String) { library.focusLibrary(id) }
    func moveLibraryLeft() { library.moveLibraryLeft() }
    func moveLibraryRight() { library.moveLibraryRight() }
    func moveLibraryUp() { library.moveLibraryUp() }
    func moveLibraryDown() { library.moveLibraryDown() }

    /// Removes the keyboard-focused entry and lands the cursor on the NEXT entry
    /// (item 26b).
    func removeFocusedFromLibrary() {
        library.removeFocusedFromLibrary()
    }

    /// Opens the in-place full-size preview on the focused entry.
    func openLibraryPreview() { library.openLibraryPreview() }
    /// Closes the in-place preview, returning the grid.
    func closeLibraryPreview() { library.closeLibraryPreview() }
    /// Space toggles the preview for the focused entry.
    func toggleLibraryPreview() { library.toggleLibraryPreview() }

    // MARK: - Library multi-selection (item 28: forwarders)

    /// Plain-click select: replaces the selection with just `id`.
    func selectLibrary(_ id: String) { library.selectLibrary(id) }
    /// ⌘-click: toggles `id` in/out of the selection.
    func toggleLibrarySelection(_ id: String) { library.toggleLibrarySelection(id) }
    /// ⇧-click: selects the inclusive range from the anchor to `id`.
    func extendLibrarySelection(to id: String) { library.extendLibrarySelection(to: id) }
    /// Clears the library multi-selection (also drops the range anchor).
    func clearLibrarySelection() { library.clearLibrarySelection() }

    /// The on-disk URLs of the selected saved photos, in `libraryOrderedIDs` order,
    /// skipping any whose backing file is missing. The export source set for
    /// `exportSelectedLibraryToPhotos`.
    var selectedLibraryFileURLs: [URL] { library.selectedLibraryFileURLs }

    /// Adds the selected saved copies to the Photos library (add-only). Rerouted through
    /// `ExportController.exportSelectedLibraryToPhotos()` (item 61), which shares the SAME
    /// `runExport` core and error/summary channel every other export uses. Stays a direct
    /// `export` forwarder (not a `LibraryModel` member): the library export destination is
    /// export machinery, and `LibraryModel` has no reference to `export`.
    func exportSelectedLibraryToPhotos() {
        export.exportSelectedLibraryToPhotos()
    }

    /// Deterministic readiness decision, testable WITHOUT a real model:
    /// `(KION_SAMPLE != "1") && (activeBackend needs a model) && resolveModelURL(...)
    /// == nil`. The downloader's observable `installed` state also clears it (so a
    /// freshly installed model flips the gate without relaunch, even when the
    /// gate's descriptor differs from the one just installed in tests). Sample
    /// mode bypasses BOTH the resolver and the downloader — CI/UI tests never need
    /// the 249 MB file. Item 72: a session whose ACTIVE backend is Vision needs no
    /// model download at all — `activeBackend.needsModelDownload` is `false` — so
    /// this never blocks on the (never-installed) ONNX model in that case.
    var needsOnboarding: Bool {
        guard environment["KION_SAMPLE"] != "1" else { return false }
        guard activeBackend.needsModelDownload else { return false }
        if case .installed = modelDownloader.state { return false }
        // `activeBackend.modelAsset` is non-nil whenever `needsModelDownload` is
        // true (the `?? .production` fallback above is unreachable here, but
        // keeps this a non-optional call without force-unwrapping).
        let asset = activeBackend.modelAsset ?? .production
        return resolveModelURL(env: environment, locations: modelLocations, descriptor: asset) == nil
    }

    init(
        engine: (any TriageEngine)? = nil,
        environment: [String: String] = KionEnvironment.process,
        modelLocations: ModelLocations = .production,
        modelDownloader: ModelDownloader? = nil,
        libraryLocations libLocations: LibraryLocations = .production,
        libraryDefaults injectedDefaults: UserDefaults? = nil,
        bookmarkResolver: LibraryBookmarkResolver = resolveLibraryBookmark,
        keptLibrary injectedKeptLibrary: (any KeptLibrarySaving)? = nil,
        skipStore injectedSkipStore: (any SkipRecording)? = nil,
        profileRepository injectedProfileRepository: (any ProfileRepository)? = nil
    ) {
        // Persist user prefs (library root/bookmark, resize toggle, hide-reviewed) to the
        // injected defaults; production passes `.standard`. When NOT injected (unit tests
        // that don't care about persistence), use a per-instance ISOLATED suite so a real
        // app run that toggles a pref into `.standard` can never leak into the shared test
        // host's defaults and flip these reads (item 48 test-isolation hardening).
        let libDefaults = injectedDefaults
            ?? UserDefaults(suiteName: "com.krisbaker.KiFinder.isolated.\(UUID().uuidString)")!

        // Item 72: resolve the ACTIVE face backend + its model descriptor ONCE, up
        // front — the store path, the repository stamp, the live engine, this
        // session's seed profiles, and the injected `EnrollmentModel` descriptor
        // all thread the SAME descriptor from here on. A PURE read (env →
        // persisted preference → default `.onnx`); nothing here writes the
        // preference (only `faceBackend`'s setter does, later). `activeBackend` is
        // then FIXED for the rest of this instance's life — switching the
        // preference takes effect on the NEXT launch, not this one.
        let backend = resolveBackend(env: environment, defaults: libDefaults)
        activeBackend = backend
        let activeDescriptor = backend.descriptor

        // The profile store path is shared by the live engine (to load the enrolled
        // profile for scanning) and the repository (first-run gating + reference
        // count), so both read/write the same file. Item 72: per-backend — the
        // production default is now suffixed by the active descriptor's model id
        // (migrating a pre-item-72 legacy file for the ArcFace default); an
        // explicit `KION_PROFILE_STORE` override is still honored VERBATIM.
        let storeURL = Self.resolveStoreURL(environment, descriptor: activeDescriptor)

        let repository = FileProfileRepository(
            storeURL: storeURL,
            modelId: activeDescriptor.id,
            modelVersion: activeDescriptor.version
        )
        let reset = environment["KION_RESET"] == "1"
        // Subjects to seed, in order. `KION_SEED_PROFILE` seeds the legacy subject
        // un-guarded by reset (bootstrap resets THEN seeds), while sample mode is a
        // pre-populated demo in which BOTH sample people are already enrolled, so the
        // Review-focused sample flows land directly on Review with a genuinely
        // multi-person roster — an explicit `KION_RESET` opts back into the
        // first-run enrollment sheet instead. Item 72: every seed is stamped with
        // the ACTIVE descriptor, so a Vision session seeds Vision-stamped samples.
        var seeds: [ProfileBundle] = []
        if environment["KION_SEED_PROFILE"] == "1" {
            seeds.append(Self.seedProfile(descriptor: activeDescriptor))
        }
        if environment["KION_SAMPLE"] == "1", !reset {
            seeds.append(
                contentsOf: SampleTriageEngine.samplePeople.map { Self.sampleProfile(subjectId: $0, descriptor: activeDescriptor) }
            )
        }
        // Resolve the embedding store + roster *before* building the live engine,
        // so the engine scans against the active person's subject id (the person
        // migrated from a legacy store after first run) rather than a hard-coded
        // constant. The preferred active person is the FIRST seeded subject when this
        // launch seeds anything — the `KION_SEED_PROFILE` subject, else sample mode's
        // primary demo person — so a seeded demo opens on the person it was built
        // around rather than whichever id happens to sort first. With no seeds the
        // preference is the legacy migration id, keeping a migrated single-person
        // store active exactly as before.
        let (roster, initialActiveID) = repository.bootstrapRoster(
            reset: reset,
            seedProfiles: seeds,
            preferredActiveID: seeds.first?.subjectId ?? Self.legacySubjectID
        )
        // Tests inject a repository spy (e.g. one that throws on a chosen write) to
        // exercise the roster-write-failure error channel; production and the
        // common test path use the real file-backed repository that just bootstrapped
        // the roster/store above.
        profileRepository = injectedProfileRepository ?? repository

        let selectedEngine: any TriageEngine
        if let engine {
            selectedEngine = engine
        } else if environment["KION_SAMPLE"] == "1" {
            selectedEngine = SampleTriageEngine(
                enrollDelay: Self.duration(environment["KION_ENROLL_DELAY_MS"]),
                scanTickDelay: Self.duration(environment["KION_SCAN_DELAY_MS"])
            )
        } else {
            selectedEngine = LiveTriageEngine(
                environment: environment,
                // Item74b: the engine resolves ITS OWN model — `.production` for
                // ONNX (unchanged), `.adaface` for CoreML — not always ONNX's.
                assetDescriptor: backend.modelAsset ?? .production,
                storeURL: storeURL,
                subjectId: initialActiveID ?? Self.legacySubjectID,
                modelId: activeDescriptor.id,
                modelVersion: activeDescriptor.version,
                makeProvider: { try backend.makeProvider(modelURL: $0) },
                // Resolved against THIS model's defaults (an isolated suite in tests,
                // the real domain in production) and re-read per scan, so the Settings
                // picker takes effect on the next scan without a relaunch.
                workerCount: { resolveScanWorkerCount(env: environment, defaults: libDefaults) }
            )
        }
        self.engine = selectedEngine

        reduceMotion = environment["KION_REDUCE_MOTION"] == "1"
        showsScanTestAffordance = environment["KION_TEST_SCAN"] == "1"
        if let dest = environment["KION_EXPORT_DEST"], !dest.isEmpty {
            testExportDest = URL(fileURLWithPath: dest, isDirectory: true)
        } else {
            testExportDest = nil
        }
        if let pick = environment["KION_LIBRARY_PICK"], !pick.isEmpty {
            testLibraryPickDest = URL(fileURLWithPath: pick, isDirectory: true)
        } else {
            testLibraryPickDest = nil
        }
        if let raw = environment["KION_REVIEW_COLUMNS"], let value = Int(raw), value >= 1 {
            columnCount = value
        } else {
            columnCount = 3
        }
        if let path = environment["KION_FEEDBACK_LOG"], !path.isEmpty {
            feedbackLogURL = URL(fileURLWithPath: path)
        } else {
            feedbackLogURL = nil
        }

        // Sample data is available synchronously so the grid renders (and the
        // first tile takes focus) deterministically on launch — handed to
        // `ReviewSession` below once every provider it needs is ready.
        let initialCandidates: [Candidate] = (selectedEngine as? SampleTriageEngine)?.candidates ?? []

        // Item 67: the roster and the initial active person are seeded onto
        // `peopleStore` further below (after `library`/`review` exist, both its
        // injected deps) — `roster`/`initialActiveID` stay live local `let`s until
        // then. `enrolledProfile` (stays on `AppModel`) is derived there too, via
        // the `didSet` cascade a non-nil seed fires through the settable
        // `activePersonID` forwarder.
        testReferencePaths = Self.resolveTestReferences(environment)

        // Onboarding readiness state: store the env + roots the gate resolves
        // through, and own a downloader that installs to the managed location.
        self.environment = environment
        // Test hook (`KION_APP_SUPPORT=/dir`): override the model-location root so a UI
        // test can deterministically land in onboarding — an empty temp root has no
        // managed model, so `needsOnboarding` is true regardless of the host's real
        // `~/Library/Application Support`. Production/unit paths use the injected default.
        if let appSupport = environment["KION_APP_SUPPORT"], !appSupport.isEmpty {
            self.modelLocations = ModelLocations(appSupportRoot: URL(fileURLWithPath: appSupport, isDirectory: true))
        } else {
            self.modelLocations = modelLocations
        }

        // Kept-photo library (item 18a + 44): resolve the root (env → security-scoped
        // bookmark → container default) through the injectable bookmark resolver and own
        // the write-side store. The index lives beside a test-provided root (or under
        // Application Support in production) so test runs never write the real library.
        // Resolved here (not stored on `AppModel` — item 65 moved the root/bookmark
        // lifecycle to `LibraryModel`) because `keptLibrary`'s index URL needs the
        // resolved root FIRST; `LibraryModel` is built further below, after `keptLibrary`.
        libraryDefaults = libDefaults
        // Item 76: BEFORE resolving the root, stage any runner-authored library seed into
        // the app's own container (`KION_LIBRARY_SEED_DIR` → `KION_LIBRARY_ROOT`). Both
        // processes are sandboxed to their own containers on macOS 27, so a library the
        // app must WRITE (Delete rewrites the index) can't live in the runner's temp — the
        // runner stages it, the app copies it in here. A no-op in production (env stripped
        // in RELEASE) and whenever the hook is unset; a broken seed is surfaced loudly (not
        // a silent empty library) rather than swallowed with `try?`.
        do {
            _ = try stageLibrarySeed(env: environment)
        } catch {
            assertionFailure("KION_LIBRARY_SEED_DIR staging failed: \(error)")
        }
        let resolution = resolveLibraryRoot(
            env: environment,
            defaults: libDefaults,
            locations: libLocations,
            bookmarkResolver: bookmarkResolver
        )
        if let injectedKeptLibrary {
            keptLibrary = injectedKeptLibrary
        } else {
            let indexURL = resolveLibraryIndexURL(env: environment, appSupportRoot: modelLocations.appSupportRoot)
            keptLibrary = KeptLibrary(root: resolution.url, indexURL: indexURL)
        }

        // Persistent per-person skip store (item 48): loaded from disk so a re-scan /
        // relaunch remembers prior skips, written off the keypress path. A test injects
        // an in-memory spy; production reads the managed (or `KION_SKIPPED_STORE`) path.
        if let injectedSkipStore {
            skipStore = injectedSkipStore
        } else {
            let skipURL = resolveSkipStoreURL(env: environment, appSupportRoot: modelLocations.appSupportRoot)
            skipStore = SkipStore(fileURL: skipURL)
        }
        // Surface EVERY store (not just the first) that quarantined an unreadable
        // file while loading above — one-time, plain-language notices for the
        // root-level UI (item 57). Each store only ever sets its own notice ONCE
        // (quarantining removes the corrupt bytes from the read path), so this
        // never re-fires on a later `AppModel` construction unless a NEW file goes
        // bad. Order matches store order (roster, kept-index, skip-store); a
        // simultaneous multi-corruption queues all of them instead of dropping all
        // but the first.
        dataIntegrityNotices = [
            repository.rosterQuarantineNotice,
            keptLibrary.quarantineNotice,
            skipStore.quarantineNotice,
        ].compactMap { $0 }
        // The "Hide already reviewed" toggle restores its last value (default OFF).
        hideAlreadyReviewed = libDefaults.bool(forKey: HideReviewedPreference.key)
        if let modelDownloader {
            self.modelDownloader = modelDownloader
        } else {
            // The downloader is built from the ACTIVE backend's asset — `.onnx`
            // → `.production` (unchanged), `.coreml` → `.adaface`. `.vision` has
            // no asset (`needsModelDownload` is already `false`, so this
            // downloader is never started/consulted); fall back to `.production`
            // purely to keep this property non-optional.
            let descriptor = backend.modelAsset ?? .production
            self.modelDownloader = ModelDownloader(
                descriptor: descriptor,
                installURL: managedModelURL(appSupportRoot: modelLocations.appSupportRoot, fileName: descriptor.installedName)
            )
        }

        // Item 65: `LibraryModel` owns the root/bookmark lifecycle (including the
        // security-scope begin-access + stale-bookmark-refresh work the old init did
        // inline here) plus the browse/nav/selection flow. Composed with the SHARED
        // `keptLibrary` + `libDefaults` + `libLocations` + `bookmarkResolver` + the
        // ALREADY-RESOLVED `resolution` from above (this type never re-resolves).
        // Assigned before `export`/`scan` (which re-wire to it below); its own init
        // performs no back-call through `self.library` (still the nil IUO here) —
        // only touches its injected `keptLibrary`/`libraryDefaults`.
        library = LibraryModel(
            keptLibrary: keptLibrary,
            libraryDefaults: libDefaults,
            libraryLocations: libLocations,
            resolution: resolution,
            columnCount: columnCount,
            testLibraryPickDest: testLibraryPickDest
        )

        // Item 59: constructed LAST, once every stored property `review` depends on
        // (`engine`/`keptLibrary`/`skipStore`, `activePersonID`, `hideAlreadyReviewed`,
        // `columnCount`) is set — so `self` is fully initialized by the point these
        // closures capture it, and every closure reads the CURRENT value at every
        // call rather than one snapshotted here (item 57's "never a stale snapshot").
        review = ReviewSession(
            engine: selectedEngine,
            keptLibrary: keptLibrary,
            skipStore: skipStore,
            feedbackLogURL: feedbackLogURL,
            initialCandidates: initialCandidates,
            activePersonID: { [weak self] in self?.activePersonID },
            hideAlreadyReviewed: { [weak self] in self?.hideAlreadyReviewed ?? false },
            columnCount: { [weak self] in self?.columnCount ?? 3 },
            isInLibrary: { [weak self] id in self?.isInLibrary(id) ?? false },
            saveToLibrary: { [weak self] candidate in self?.saveToLibrary(candidate) }
        )
        // Item 67: constructed right after `review` (its OTHER injected dep, besides
        // `library` above) — `ReviewSession.init` itself never invokes any of the
        // closures it was just handed (see the comment on `review.focusFirstIfNeeded()`
        // below), so building `peopleStore` here, BEFORE that first real invocation,
        // is safe: the `activePersonID` closure captured above will resolve through
        // the live `peopleStore` from its very first call.
        peopleStore = PeopleStore(
            people: roster,
            engine: selectedEngine,
            profileRepository: profileRepository,
            review: review,
            library: library,
            keptLibrary: keptLibrary,
            skipStore: skipStore,
            onActivePersonChanged: { [weak self] in self?.refreshEnrolledProfile() },
            presentEnrollment: { [weak self] personID in self?.presentEnrollment(personID: personID) },
            appendPendingLibrarySave: { [weak self] task in self?.pendingLibrarySaves.append(task) }
        )
        // Seats the initial active person WITHOUT the person-switch choreography —
        // `seedInitialActive(_:)` sets the backing value silently, mirroring main,
        // where the init-time `activePersonID = initialActiveID` was suppressed by
        // Swift (a set inside AppModel's own init) and so never re-aimed the engine
        // at launch. `enrolledProfile` is then seeded explicitly below (exactly as
        // the old `enrolledProfile = initialActiveID.flatMap { … }` line did), and
        // review focus is seeded by `review.focusFirstIfNeeded()`.
        peopleStore.seedInitialActive(initialActiveID)
        refreshEnrolledProfile()
        // Seed focus only now that `review`/`peopleStore` are both assigned:
        // `focusFirstIfNeeded()` reads `orderedIDs`, which filters through the
        // `isInLibrary` hook back into `review` and (via the `activePersonID`
        // closure) into `peopleStore`. A no-op when the seed above already seated
        // focus (non-nil active person); essential for the nil-active-person case,
        // where `orderedIDs` shows everyone (item 7) and needs its own seed here.
        review.focusFirstIfNeeded()

        // Item 61: assigned LAST, after `engine`, `review`, AND `library` — the
        // kept/selected key providers route through `review`
        // (`keptPhotoKeys`/`review.selectedPhotoKeys`) and the library-URL provider routes
        // through `library.selectedLibraryFileURLs` (item 65), so every closure must be
        // safe to call only once `self` is fully initialized. Each provider reads the
        // CURRENT value at every call rather than one snapshotted here (the same
        // never-a-stale-snapshot discipline `review`'s own providers follow).
        export = ExportController(
            engine: selectedEngine,
            keptKeys: { [weak self] in self?.keptPhotoKeys ?? [] },
            selectedKeys: { [weak self] in self?.review.selectedPhotoKeys ?? [] },
            libraryURLs: { [weak self] in self?.library.selectedLibraryFileURLs ?? [] }
        )

        // Item 63: assigned LAST, after `engine`, `review`, AND `export` — scan state has
        // no init-time seeding and `ScanController.init` has no back-call into
        // `AppModel.scan`, so there's no nil-IUO hazard here the way `review`'s
        // `focusFirstIfNeeded()` had; still assigned last to keep the same discipline.
        // `returnToReviewFromLibrary` reads `library.libraryBrowseActive`/calls
        // `library.showReview()` (item 65) fresh on every invocation (never a value
        // captured here) so a Library entry/exit between construction and a scan's
        // terminal tick is always honored.
        scan = ScanController(
            engine: selectedEngine,
            review: review,
            returnToReviewFromLibrary: { [weak self] in
                guard let self, self.library.libraryBrowseActive else { return }
                self.library.showReview()
            }
        )
    }

    // MARK: - Enrollment presentation

    var enrolledReferenceCount: Int? {
        enrolledProfile?.references.count
    }

    /// Presents the enrollment sheet on first launch when no profile is persisted.
    /// Called from the root view's `.task` so the window exists before the sheet.
    /// First run has no active person, so this enrolls a brand-new person.
    func presentEnrollmentIfNeeded() {
        guard enrolledProfile == nil, !isEnrollmentPresented else { return }
        presentEnrollment(personID: nil)
    }

    /// Presents the enrollment sheet for a specific target. `personID == nil`
    /// enrolls a **brand-new** person (fresh UUID, empty name prefill); a non-nil
    /// id **re-enrolls** that existing person (reusing their id, prefilling their
    /// current name). The seed/migration legacy-subject path re-enrolls under its id.
    func presentEnrollment(personID: String?) {
        let target: (subjectId: String, prefillName: String)
        if let personID, let person = people.first(where: { $0.id == personID }) {
            target = (person.id, person.displayName)
        } else {
            target = (UUID().uuidString, "")
        }
        enrollmentModel = EnrollmentModel(
            engine: engine,
            repository: profileRepository,
            subjectId: target.subjectId,
            initialName: target.prefillName,
            testReferencePaths: testReferencePaths,
            descriptor: activeDescriptor,
            onComplete: { [weak self] bundle in
                self?.finishEnrollment(bundle)
            }
        )
        isEnrollmentPresented = true
    }

    /// Starts enrolling a brand-new person from the sidebar's "+ Add person".
    func beginAddPerson() {
        presentEnrollment(personID: nil)
    }

    func dismissEnrollment() {
        isEnrollmentPresented = false
        enrollmentModel = nil
    }

    private func finishEnrollment(_ bundle: ProfileBundle) {
        // The enrollment model already saved the `Person` (real name + thumbnail) to
        // the roster, so just reload it and make the enrolled subject active — never
        // re-save a Person here, which would clobber the entered name with the id.
        // Item 67: calls INTO `peopleStore` to seat the reloaded roster/active
        // person (its own state is `private(set)`/settable-only-through-its-own-
        // `didSet`) rather than assigning `people`/`activePersonID` directly.
        peopleStore.adoptRoster(profileRepository.loadRoster())
        peopleStore.setActive(bundle.subjectId)
        enrolledProfile = bundle
        // No `engine.invalidateStore()` here (item 53): `EnrollmentModel.enroll()`
        // already ran its repository write as a capture→cancel→write→re-schedule
        // transaction via `engine.writingThroughRepository`, so the engine's
        // in-memory cache is ALREADY correctly synced (either `nil`, reloading a
        // fresh disk read next time, or the merged post-write snapshot with any
        // other person's pending feedback preserved). Invalidating again here would
        // cancel that just-armed re-schedule and silently drop it.
        dismissEnrollment()
    }

    // MARK: - Person management (item 67: forwarders to the composed `PeopleStore`)

    /// Refreshes the cached enrolled profile for the active person from the store.
    /// Called via the `onActivePersonChanged` closure `peopleStore` invokes FIRST
    /// inside its own `activePersonID.didSet`, before `review.activePersonDidChange`
    /// — `enrolledProfile` stays on `AppModel` (the enrollment cache), so this seam
    /// must not move.
    private func refreshEnrolledProfile() {
        enrolledProfile = activePersonID.flatMap { profileRepository.loadProfile(subjectId: $0) }
    }

    /// Adds a new (unenrolled) person with a fresh UUID id and makes them active.
    /// Enrollment of their references happens through the enrollment sheet. On a
    /// roster-write failure (item 53), surfaces `rosterError` with a retry and
    /// leaves `people`/`activePersonID` untouched — no phantom person appears.
    @discardableResult
    func addPerson(name: String) -> Person {
        peopleStore.addPerson(name: name)
    }

    /// Makes an existing person the active one (no-op for an unknown id).
    func selectPerson(id: String) {
        peopleStore.selectPerson(id: id)
    }

    /// Renames a person, persisting the new display name to the roster, then migrates
    /// their kept-photo library (folder + index) to the new name off the keypress path
    /// (mirroring the keep-hook). When the Library browse is open, the exposed
    /// `libraryGroups` are refreshed once the migration lands so they show the new name.
    /// Review state is otherwise untouched. On a roster-write failure (item 53),
    /// surfaces `rosterError` with a retry, shows the OLD name, and launches no
    /// library migration — no success-only mutation on failure.
    func renamePerson(id: String, to newName: String) {
        peopleStore.renamePerson(id: id, to: newName)
    }

    /// Removes a person entirely (roster entry + embeddings + thumbnail + their kept-photo
    /// library entries). If the active person was removed, falls back to the first
    /// remaining person. Item 53/51's durability + delete-last-person tail (see
    /// `PeopleStore.deletePerson`) are preserved exactly.
    func deletePerson(id: String) {
        peopleStore.deletePerson(id: id)
    }

    /// Item 72: `KION_PROFILE_STORE` (a single explicit test-override file) is
    /// still used VERBATIM, with no per-backend suffix — tests that set it also
    /// set the backend via `KION_BACKEND`, so one explicit path is unambiguous.
    /// Otherwise, delegates to `resolveProfileStoreURL` for the per-backend
    /// production path (and its arcface-only legacy migration).
    private static func resolveStoreURL(_ environment: [String: String], descriptor: FaceModelDescriptor) -> URL {
        if let path = environment["KION_PROFILE_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return resolveProfileStoreURL(descriptor: descriptor, appSupportRoot: base)
    }

    /// Resolves the test-only reference photos the enrollment sheet's sample
    /// affordance adds. Prefers `KION_TEST_REFERENCE_COUNT=N`, under which the
    /// (unsandboxed) **app itself** synthesizes N valid PNGs in its own temp
    /// directory — the XCUITest runner is sandboxed and cannot write files the app
    /// can read, so the app must create them. Falls back to an explicit
    /// `KION_TEST_REFERENCE_PATHS` list for callers that supply their own files.
    private static func resolveTestReferences(_ environment: [String: String]) -> [URL] {
        if let raw = environment["KION_TEST_REFERENCE_COUNT"], let count = Int(raw), count > 0 {
            return generateReferenceImages(count: count)
        }
        guard let raw = environment["KION_TEST_REFERENCE_PATHS"], !raw.isEmpty else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Writes `count` distinct, ImageIO-decodable PNGs to a fresh temp directory
    /// and returns their URLs. Used only by the `KION_TEST_REFERENCE_COUNT` hook;
    /// each file passes `ReferenceImageValidator` exactly as a dropped photo would.
    private static func generateReferenceImages(count: Int) -> [URL] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-test-refs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (0 ..< count).compactMap { index in
            let url = dir.appendingPathComponent("ref-\(index).png")
            return writePlaceholderPNG(to: url, seed: index) ? url : nil
        }
    }

    /// A 16×16 solid-color PNG (color varies by `seed` so files are distinct).
    /// Returns whether the write succeeded.
    private static func writePlaceholderPNG(to url: URL, seed: Int) -> Bool {
        let side = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        let shade = CGFloat(seed % 8) / 8.0
        context.setFillColor(CGColor(red: 0.23 + shade * 0.5, green: 0.56, blue: 0.38, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Parses an optional millisecond launch hook (e.g. `KION_ENROLL_DELAY_MS`,
    /// `KION_SCAN_DELAY_MS`) into a `Duration`, so UI tests can observe an
    /// in-progress state before it completes.
    private static func duration(_ raw: String?) -> Duration? {
        guard let raw, let ms = Int(raw), ms > 0 else { return nil }
        return .milliseconds(ms)
    }

    /// A pre-enrolled bundle used by the `KION_SEED_PROFILE` launch hook so a UI
    /// test can assert that a seeded profile lands directly on Review. Item 72:
    /// stamped with the session's ACTIVE descriptor (arcface by default), not a
    /// hardcoded one.
    private static func seedProfile(descriptor: FaceModelDescriptor) -> ProfileBundle {
        sampleProfile(subjectId: legacySubjectID, descriptor: descriptor)
    }

    /// A deterministic pre-enrolled bundle for a sample person, with five
    /// placeholder references so the roster shows a real reference count.
    /// Calibration is resolved through `FaceModelRegistry.standard` keyed on the
    /// model this profile is stamped with (item 69), so the sample converges with
    /// the CLI/enrollment seeds. Item 72: `descriptor` is the session's ACTIVE
    /// backend descriptor (injected by the caller), so a Vision session seeds a
    /// Vision-stamped sample rather than always arcface.
    private static func sampleProfile(subjectId: String, descriptor: FaceModelDescriptor) -> ProfileBundle {
        let calibration = FaceModelRegistry.standard.calibration(for: descriptor.id, modelVersion: descriptor.version)
        return ProfileBundle(
            subjectId: subjectId,
            references: (1 ... 5).map { FaceEmbedding([Float($0)]) },
            threshold: calibration.defaultThreshold,
            maybeMargin: calibration.maybeMargin,
            negativeMargin: calibration.negativeMargin,
            modelId: descriptor.id,
            modelVersion: descriptor.version
        )
    }

    // MARK: - Review forwarders (derived lists / focus / selection / lightbox)

    var keepCandidates: [String] { review.keepCandidates }
    var maybeCandidates: [String] { review.maybeCandidates }
    var otherCandidates: [String] { review.otherCandidates }
    var skippedCandidates: [String] { review.skippedCandidates }
    var keepCount: Int { review.keepCount }
    var maybeCount: Int { review.maybeCount }
    var keepCandidateDetails: [Candidate] { review.keepCandidateDetails }
    var maybeCandidateDetails: [Candidate] { review.maybeCandidateDetails }
    var otherCandidateDetails: [Candidate] { review.otherCandidateDetails }
    var skippedCandidateDetails: [Candidate] { review.skippedCandidateDetails }

    /// The displayed review section for a photo: the user's keep/skip decision when
    /// present, otherwise the active person's own engine bucket.
    func state(for id: String) -> ReviewState {
        review.state(for: id)
    }

    func candidate(for id: String) -> Candidate? {
        review.candidate(for: id)
    }

    func moveLeft() { review.moveLeft() }
    func moveRight() { review.moveRight() }
    func moveUp() { review.moveUp() }
    func moveDown() { review.moveDown() }

    func open(_ id: String) { review.open(id) }
    func openFocused() { review.openFocused() }
    func closeLightbox() { review.closeLightbox() }

    func openPreview() { review.openPreview() }
    func closePreview() { review.closePreview() }
    func toggleManualRegionDrawing() { review.toggleManualRegionDrawing() }
    func removeFocusedManualRegion() { review.removeFocusedManualRegion() }
    func togglePreview() { review.togglePreview() }

    /// 1-based position of the lightbox candidate within the navigation order.
    func position(of id: String) -> Int? {
        review.position(of: id)
    }

    var orderedCount: Int { review.orderedCount }

    // MARK: - Multi-selection operations (item 17)

    func select(_ id: String) { review.select(id) }
    func toggleSelection(_ id: String) { review.toggleSelection(id) }
    func extendSelection(to id: String) { review.extendSelection(to: id) }
    func selectSection(_ state: ReviewState) { review.selectSection(state) }
    func clearSelection() { review.clearSelection() }
    func keepSelected() { review.keepSelected() }
    func skipSelected() { review.skipSelected() }
    func skipSection(_ state: ReviewState) { review.skipSection(state) }

    // MARK: - Bulk export (item 17)

    /// Photo keys for the current multi-selection, in visible order — the export
    /// source set for `exportSelected*`.
    var selectedPhotoKeys: [String] { review.selectedPhotoKeys }

    /// Byte-for-byte copy of the SELECTED files into `folder` (item 61: forwards to
    /// `ExportController.exportSelected(toFolder:)`).
    func exportSelected(toFolder folder: URL) {
        export.exportSelected(toFolder: folder)
    }

    /// Adds the SELECTED files to the Photos library (add-only; item 61: forwards to
    /// `ExportController.exportSelectedToPhotos()`).
    func exportSelectedToPhotos() {
        export.exportSelectedToPhotos()
    }

    // MARK: - Escape precedence (item 17)

    /// Esc precedence: a presented preview closes first; otherwise a non-empty
    /// multi-selection clears; with neither, Esc is a no-op.
    func escape() {
        review.escape()
    }

    // MARK: - Decisions (idempotent, reversible until export)

    func keepFocused() {
        review.keepFocused()
    }

    func skipFocused() {
        review.skipFocused()
    }

    func keep(_ candidate: Candidate) {
        review.keep(candidate)
    }

    func skip(_ candidate: Candidate) {
        review.skip(candidate)
    }

    // MARK: - Keep without a match (item 37)

    /// Keeps the focused photo into the active person's library/export WITHOUT teaching
    /// the engine — for a real no-face case where there's nothing to learn from.
    func keepWithoutMatchFocused() {
        review.keepWithoutMatchFocused()
    }

    /// Copies a kept photo's full-res original into the active person's library off the
    /// keypress path. A no-op without an active person or a `sourceURL` (e.g. sample
    /// candidates with no on-disk original). `KeptLibrary`'s own per-person hash dedupe
    /// is a second guard against duplicate copies.
    private func saveToLibrary(_ candidate: Candidate) {
        guard let source = candidate.sourceURL, let subjectId = activePersonID else { return }
        let personName = activePersonName ?? subjectId
        let score = candidate.score
        let task = Task { [weak self, keptLibrary] in
            _ = await keptLibrary.save(
                originalAt: source,
                subjectId: subjectId,
                personName: personName,
                score: score
            )
            // Refresh the "already saved" surfacing now that the copy (or dedupe) landed.
            self?.library.bumpRevision()
        }
        // Track the in-flight save so teardown / tests can await it deterministically.
        // Appended synchronously on the main actor before returning, so `keep` stays
        // non-blocking yet the save is always drainable.
        pendingLibrarySaves.append(task)
    }

    /// Awaits every tracked in-flight keep-save to completion, then clears the list.
    /// Snapshots first so a save that schedules another (it doesn't today) can't strand
    /// the drain.
    private func drainLibrarySaves() async {
        let inFlight = pendingLibrarySaves
        pendingLibrarySaves.removeAll()
        for task in inFlight {
            await task.value
        }
    }

    // MARK: - Live re-ranking (surface, don't reflow)

    /// Number of undecided photos that now match better than their current section.
    var pendingPromotionCount: Int {
        review.pendingPromotionCount
    }

    /// User-triggered re-score (item 50). Wired to the "Find new matches" toolbar button.
    func rescoreNow() {
        review.rescoreNow()
    }

    /// Moves the surfaced photos into their now-better sections for the active
    /// person, on the user's say-so.
    func applyPendingPromotions() {
        review.applyPendingPromotions()
    }

    /// Awaits every tracked in-flight `recordFeedback` teach to completion. Tests
    /// `await drainFeedback()` before asserting the engine spy's `recordFeedback` counts.
    func drainFeedback() async {
        await review.drainFeedback()
    }

    /// Points the photo's match at the face the user picked in the lightbox.
    func selectFace(_ candidate: Candidate, faceIndex: Int) {
        review.selectFace(candidate, faceIndex: faceIndex)
    }

    // MARK: - Manual face regions (item 19)

    /// The active person's manually-drawn face index on this candidate, if any.
    func manualFaceIndex(for candidate: Candidate) -> Int? {
        review.manualFaceIndex(for: candidate)
    }

    /// Adds (or, on a re-draw, replaces) the active person's manually-drawn face
    /// region for a photo whose face the detector missed.
    func addManualRegion(to candidate: Candidate, normalizedRect: CGRect) {
        review.addManualRegion(to: candidate, normalizedRect: normalizedRect)
    }

    /// Removes the active person's manual region (deletes the box + the engine face,
    /// restores the prior auto-pick).
    func removeManualRegion(from candidate: Candidate) {
        review.removeManualRegion(from: candidate)
    }

    // MARK: - Scanning (item 63: forwarders to the composed `ScanController`)

    /// The deterministic test/primary scan entry (item 63: forwards to
    /// `ScanController.runScan(albums:)`).
    func runScan(albums: [URL]) async {
        await scan.runScan(albums: albums)
    }

    /// Completes any pending (coalesced, off-actor) feedback write. Called on normal
    /// teardown (scenePhase background/inactive) so taught feedback isn't dropped.
    /// Also flushes the kept-photo library index so a burst of keeps is durable.
    func flushPendingWrites() async {
        // Land any in-flight teaches into the engine's working store before it flushes.
        await drainFeedback()
        await engine.flush()
        await drainLibrarySaves()
        await keptLibrary.flush()
        await skipStore.flush()
    }

    /// Completes any pending library index write. Exposed for tests + teardown so a
    /// save's index entry is on disk before assertions / reload. Drains in-flight
    /// keep-saves first so the index flush covers the just-completed save.
    func flushLibrary() async {
        await drainLibrarySaves()
        await keptLibrary.flush()
        await skipStore.flush()
    }

    /// Safety net for the sample engine so a launch pre-populates the grid (item 63:
    /// forwards to `ScanController.refreshCandidatesIfNeeded()`).
    func refreshCandidatesIfNeeded() async {
        await scan.refreshCandidatesIfNeeded()
    }

    // MARK: - Scan moment presentation (item 63: forwarders to `ScanController`)

    /// Opens the album-scan sheet from a fresh idle state.
    func presentScan() {
        scan.presentScan()
    }

    /// Closes the scan sheet, cancelling any in-flight scan.
    func dismissScan() {
        scan.dismissScan()
    }

    /// Starts a scan for albums dropped onto the empty review grid, presenting the
    /// scan sheet so its live progress is visible.
    func scanDroppedAlbums(_ albums: [URL]) {
        scan.scanDroppedAlbums(albums)
    }

    /// Drives `TriageEngine.scan` for the dropped/chosen albums, updating live
    /// progress as ticks arrive and applying the merged candidate set on completion.
    func startScan(albums: [URL]) {
        scan.startScan(albums: albums)
    }

    /// Cancels an in-flight scan but leaves the sheet open on its idle state.
    func stopScan() {
        scan.stopScan()
    }

    // MARK: - Export (item 61: forwarders to the composed `ExportController`)

    /// Whether the export-summary sheet is presented. Settable: `KiFinderRootView` binds
    /// `$model.isExportSummaryPresented` directly (a swipe-dismiss writes through this
    /// setter, not through `dismissExportSummary()`).
    var isExportSummaryPresented: Bool {
        get { export.isExportSummaryPresented }
        set { export.isExportSummaryPresented = newValue }
    }
    /// Non-nil when the last export FAILED (a localized, user-facing message). Read-only —
    /// cleared via `clearExportError()`, not by assignment.
    var exportError: String? { export.exportError }
    /// Number of kept/selected files exported by the last run (byte-verified for folders).
    var exportedCount: Int { export.exportedCount }
    /// The folder the last export wrote to, for "Show in Finder" / messaging.
    var exportDestination: URL? { export.exportDestination }

    /// Non-nil when the last `addPerson`/`renamePerson`/`deletePerson` FAILED (a
    /// localized, user-facing message) — item 53's roster-write error channel,
    /// wired to the same alert-with-retry pattern as `exportError`. A failure never
    /// mutates `people`/`activePersonID`/other state; the operation is a no-op
    /// until retried. Item 67: owned by `peopleStore`.
    var rosterError: String? { peopleStore.rosterError }
    /// Maps a thrown export error to the message shown on `exportError` (item 54; item 61:
    /// forwards to `ExportController.exportErrorMessage(for:)`) — kept on `AppModel` too
    /// since call sites (views + tests) invoke it directly on the model.
    func exportErrorMessage(for error: Error) -> String {
        export.exportErrorMessage(for: error)
    }

    /// Whether there's anything to export from the KEPT set — gates the "Export Kept"
    /// affordance in the UI (the kept export methods themselves have no empty-guard).
    var canExport: Bool {
        keepCount > 0
    }

    /// The photo keys of every currently-kept candidate — the export source set fed to
    /// `ExportController` via the `keptKeys` provider.
    private var keptPhotoKeys: [String] {
        keepCandidateDetails.map(\.photoKey)
    }

    /// Straight byte-for-byte copy of the kept files into `folder` (item 61: forwards to
    /// `ExportController.exportKept(toFolder:)`).
    func exportKept(toFolder folder: URL) {
        export.exportKept(toFolder: folder)
    }

    /// Adds the kept files to the Photos library (add-only; item 61: forwards to
    /// `ExportController.exportKeptToPhotos()`).
    func exportKeptToPhotos() {
        export.exportKeptToPhotos()
    }

    func dismissExportSummary() {
        export.dismissExportSummary()
    }

    // MARK: - Error dismissal (item 43)

    /// Clears the scan-failure banner (user dismissed or is retrying; item 63: forwards
    /// to `ScanController.clearScanError()`).
    func clearScanError() {
        scan.clearScanError()
    }

    /// Re-runs the most recent scan (from the error banner's "Try Again"; item 63:
    /// forwards to `ScanController.retryScan()`). A no-op if there is no prior scan to
    /// retry.
    func retryScan() {
        scan.retryScan()
    }

    /// Clears the export-failure banner (user dismissed or is retrying; item 61: forwards
    /// to `ExportController.clearExportError()`).
    func clearExportError() {
        export.clearExportError()
    }

    /// Re-runs the most recent export (from the error banner's "Try Again"; item 61:
    /// forwards to `ExportController.retryExport()`). A no-op if there is no prior export
    /// to retry.
    func retryExport() {
        export.retryExport()
    }

    /// Clears the roster-write-failure banner (user dismissed or is retrying).
    /// Item 67: forwards to `PeopleStore.clearRosterError()`.
    func clearRosterError() {
        peopleStore.clearRosterError()
    }

    /// Re-runs the most recent failed add/rename/delete (from the error banner's
    /// "Try Again"). A no-op if there is no prior failure to retry. Retries exactly
    /// once per invocation — a still-broken repository re-surfaces the error rather
    /// than looping. Item 67: forwards to `PeopleStore.retryRoster()`.
    func retryRoster() {
        peopleStore.retryRoster()
    }

    /// Clears the CURRENT data-integrity notice (user dismissed it) by popping it
    /// off the front of `dataIntegrityNotices`. There is no retry — the quarantine
    /// already happened at construction. When another store ALSO quarantined in the
    /// same launch, that notice is now the new head and the alert re-presents for
    /// it — every simultaneously-affected store still gets its own one-time notice
    /// (item 57), not just the first-detected.
    func clearDataIntegrityNotice() {
        guard !dataIntegrityNotices.isEmpty else { return }
        dataIntegrityNotices.removeFirst()
    }
}
