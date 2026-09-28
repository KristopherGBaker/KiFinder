import AppKit
import Foundation
import Observation

/// The kept-photo-library responsibility carved out of `AppModel` (item 65): owns the
/// library root/security-scoped-bookmark lifecycle (item 18a/44) AND the browse/nav/
/// selection flow (items 18b/26a/26b/28) — everything that used to live directly on
/// `AppModel` plus the two file-split extensions `AppModel+LibraryNavigation.swift` and
/// `AppModel+LibrarySelection.swift`, both now DELETED.
///
/// A separate `@Observable @MainActor` type COMPOSED by `AppModel` (`model.library`) —
/// not an extension — mirroring `ReviewSession` (item 59), `ExportController` (item 61),
/// and `ScanController` (item 63). The old cross-file extensions had to widen
/// `libraryAnchorID`/`selectedLibraryIDs`/`libraryFocusedID`/`libraryPreviewActive` from
/// `private` to plain `internal` `var`s just so they could mutate `AppModel`'s state from
/// a different file; now that they're members of THIS type, `libraryAnchorID` and
/// `libraryPreviewActive` go back to `private(set)` (nothing outside ever assigns them
/// directly — every mutation routes through the ops below). `libraryFocusedID` and
/// `selectedLibraryIDs` stay settable `var`s: tests assign them directly through the
/// `AppModel` forwarder (`model.libraryFocusedID = …`, `model.selectedLibraryIDs = …`), the
/// same exception `ReviewSession.focusedID` and `ExportController.isExportSummaryPresented`
/// document for their own settable passthroughs.
///
/// `keptLibrary` is injected as the SAME (class-bound) instance `AppModel` holds — shared,
/// not duplicated — since `AppModel`'s keep-hook (`saveToLibrary`) and `isInLibrary` also
/// read/write it directly. `libraryDefaults`/`libraryLocations`/`bookmarkResolver` are
/// likewise injected live references/values. The `LibraryRootResolution` is passed in
/// ALREADY COMPUTED: `AppModel` resolves the root early (its `keptLibrary`'s index URL
/// needs the resolved root first), builds `keptLibrary`, and only THEN builds this type —
/// so `LibraryModel.init` never re-resolves anything, it just applies the resolution's
/// security-scope/stale-bookmark signals. This type does NOT touch the engine, `review`,
/// or `activePersonID` — library browse is independent of Review (`showReview()` only
/// flips `libraryBrowseActive` + clears the library selection, it never touches `review`).
@Observable
@MainActor
final class LibraryModel {
    /// The write side of the persistent kept-photo library — the SAME instance `AppModel`
    /// holds (shared, not copied): `AppModel`'s keep-hook/`isInLibrary` read/write it too.
    private let keptLibrary: any KeptLibrarySaving
    /// The preference store the user-chosen library root's security-scoped bookmark
    /// persists to — the SAME `UserDefaults` instance `AppModel` holds (also used there
    /// for `hideAlreadyReviewed`/`manualRegionResizeEnabled`).
    private let libraryDefaults: UserDefaults
    /// Injectable default for the library root (the app-container default), so
    /// resolver/persistence never touch the user's real Application Support in tests.
    private let libraryLocations: LibraryLocations
    /// Logical columns used for keyboard arrow navigation (mirrors `AppModel.columnCount`,
    /// a `let` fixed for the app's lifetime — injected by value, not a closure).
    private let columnCount: Int
    /// When set (`KION_LIBRARY_PICK=/path`), `chooseLibraryRoot()` sets the library root
    /// straight to this directory instead of opening `NSOpenPanel`.
    private let testLibraryPickDest: URL?

    // MARK: - Root + security-scoped bookmark lifecycle (item 18a/44)

    /// Bumped whenever a library save/removal/rename/root-switch lands so
    /// `isInLibrary`-driven views refresh. `AppModel.isInLibrary` reads this via
    /// `library.libraryRevision`; `AppModel.saveToLibrary`'s keep-hook calls `bumpRevision()`.
    private(set) var libraryRevision = 0

    /// Bumps `libraryRevision` — the seam `AppModel`'s keep-hook (and library-owned
    /// mutations here) use to signal `isInLibrary`-driven views to refresh.
    func bumpRevision() {
        libraryRevision += 1
    }

    /// The currently active library root, resolved once at init (env → bookmark →
    /// container default) and re-set when the user picks/reset. `libraryRoot` reads this;
    /// `keptLibrary` is kept in sync.
    private var resolvedLibraryRoot: URL
    /// The security-scoped URL we are currently accessing (a bookmarked custom root), held
    /// for the app lifetime and released before switching roots. `nil` for the container
    /// default (no scope needed).
    private var accessingScopedURL: URL?
    /// True when a STORED bookmark failed to resolve at launch (folder moved/deleted or
    /// data un-decodable): the root fell back to the container default and the UI can
    /// surface a re-select prompt. Cleared once the user picks a fresh root.
    private(set) var libraryRootNeedsReselection = false

    /// The persistent library root, resolved once at init in priority order
    /// (`KION_LIBRARY_ROOT` env → a stored security-scoped bookmark → the container
    /// default). Read-only here: the user changes it through `setCustomLibraryRoot`
    /// (stores a bookmark) or `resetLibraryRootToDefault` (clears it), so the
    /// clear-on-default and security-scope handling always run.
    var libraryRoot: URL {
        resolvedLibraryRoot
    }

    /// The container default root (no bookmark/entitlement needed). Onboarding pre-fills
    /// it and a Settings reset returns to it.
    var defaultLibraryRoot: URL {
        libraryLocations.defaultRoot
    }

    /// True when the resolved root is the app-container default (no bookmark in play); a
    /// custom root always differs in path (the UI shows "Use Default" only then).
    var isUsingDefaultLibraryRoot: Bool {
        resolvedLibraryRoot.standardizedFileURL.path == defaultLibraryRoot.standardizedFileURL.path
    }

    /// Persists a user-chosen CUSTOM folder as a security-scoped bookmark and switches the
    /// library root to it, starting security-scoped access (a no-op off the sandbox).
    /// Clears any pending re-selection prompt.
    func setCustomLibraryRoot(_ url: URL) {
        if let data = try? makeLibraryBookmark(for: url) {
            libraryDefaults.set(data, forKey: LibraryPreference.bookmarkKey)
        }
        libraryDefaults.removeObject(forKey: LibraryPreference.rootKey)
        libraryRootNeedsReselection = false
        activateLibraryRoot(url, securityScoped: true)
    }

    /// Resets the library root to the app-container default and REMOVES any stored
    /// bookmark, so a subsequent resolution no longer returns an old custom folder. Both
    /// the onboarding quick-accept and the Settings reset route through here.
    func resetLibraryRootToDefault() {
        libraryDefaults.removeObject(forKey: LibraryPreference.bookmarkKey)
        libraryDefaults.removeObject(forKey: LibraryPreference.rootKey)
        libraryRootNeedsReselection = false
        activateLibraryRoot(defaultLibraryRoot, securityScoped: false)
    }

    /// Switches the active root: releases any prior security-scoped access, starts it on
    /// the new URL when needed (held for the app lifetime), points the store at it, and
    /// bumps `libraryRevision` so dependent views refresh.
    private func activateLibraryRoot(_ url: URL, securityScoped: Bool) {
        if let previous = accessingScopedURL {
            previous.stopAccessingSecurityScopedResource()
            accessingScopedURL = nil
        }
        if securityScoped, url.startAccessingSecurityScopedResource() {
            accessingScopedURL = url
        }
        resolvedLibraryRoot = url
        keptLibrary.updateRoot(url)
        bumpRevision()
    }

    /// Sets the library root from the onboarding/Settings "Choose…" control: straight to
    /// the test-named directory when `KION_LIBRARY_PICK` is set, otherwise via the system
    /// folder picker.
    func chooseLibraryRoot() {
        if let dest = testLibraryPickDest {
            setCustomLibraryRoot(dest)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            setCustomLibraryRoot(url)
        }
    }

    /// The on-disk URL of a saved entry's copy, `<libraryRoot>/<entry.path>`.
    func libraryFileURL(for entry: KeptEntry) -> URL {
        libraryRoot.appendingPathComponent(entry.path)
    }

    // MARK: - Browse (item 18b)

    /// Whether the detail pane is showing the **Library** browse view instead of Review.
    /// Defaults to Review; the sidebar's Library entry flips it via `showLibrary()`,
    /// selecting a person (or a Review entry) flips it back via `showReview()`.
    /// Entering/leaving the Library never disturbs Review state (active person, decisions,
    /// selection, focus — all owned by `ReviewSession`, untouched here).
    private(set) var libraryBrowseActive = false
    /// The browse filter: a specific `subjectId` (that person only) or `nil` (everyone).
    private(set) var libraryFilterSubjectID: String?
    /// The grouped library data for the current filter, exposed to `LibraryBrowseView`.
    /// Refreshed on entering the Library, on filter changes, and after a remove.
    private(set) var libraryGroups: [LibraryPersonGroup] = []

    /// Shows the Library browse view in the detail pane and (re)computes the grouped data
    /// for the current filter. Review state is untouched.
    func showLibrary() {
        libraryBrowseActive = true
        refreshLibraryGroups()
        // The Library becomes active: seat the keyboard cursor on the first photo.
        libraryFocusedID = libraryOrderedIDs.first
    }

    /// Returns the detail pane to Review (e.g. selecting a person). Review state is
    /// untouched.
    func showReview() {
        libraryBrowseActive = false
        // The library multi-selection is scoped to the Library view; leaving it drops the
        // selection so it never lingers behind Review.
        clearLibrarySelection()
    }

    /// Sets `libraryBrowseActive` to false WITHOUT clearing the library selection —
    /// `AppModel.selectPerson`'s exact behavior (item 51/65): selecting a person returns
    /// the detail pane to Review, but it never routed through the selection-clearing
    /// `showReview()`, only flipped the flag. Callers that SHOULD also drop the selection
    /// (leaving the Library for any other reason) must call `showReview()` instead.
    func returnToReviewWithoutClearingSelection() {
        libraryBrowseActive = false
    }

    /// Sets the browse person filter (`nil` = everyone) and recomputes the groups.
    func setLibraryFilter(_ subjectID: String?) {
        libraryFilterSubjectID = subjectID
        refreshLibraryGroups()
        // Re-seat the cursor (the prior focus may not exist under the new filter) and drop
        // any open preview so it never lingers over a now-filtered-out photo.
        libraryFocusedID = libraryOrderedIDs.first
        libraryPreviewActive = false
        // The selection's ids may not exist under the new filter — drop it.
        clearLibrarySelection()
    }

    /// Removes a saved photo from the library: drops it from the exposed groups
    /// immediately (so the UI reflects the removal at once) and deletes the file + index
    /// entry off the main actor. The bytes become re-savable on a future Keep.
    func removeFromLibrary(_ entry: KeptEntry) {
        // Optimistic update so the exposed groups reflect the removal synchronously; the
        // disk + index delete runs off the main actor and then re-syncs.
        libraryGroups = prunedLibraryGroups(libraryGroups, removing: entry)
        reseatLibraryFocusIfNeeded()
        // A removal changes the entry set, so the selection's ids may no longer be valid —
        // drop it (item 28).
        clearLibrarySelection()
        Task { [weak self, keptLibrary] in
            _ = await keptLibrary.remove(entry)
            self?.refreshLibraryGroups()
            self?.reseatLibraryFocusIfNeeded()
            self?.bumpRevision()
        }
    }

    /// Recomputes `libraryGroups` from the current index + filter + root. Not `private` —
    /// `AppModel.renamePerson`'s off-actor migration completion calls it directly
    /// (`if libraryBrowseActive { refreshLibraryGroups() }`) to pick up the new name.
    func refreshLibraryGroups() {
        libraryGroups = groupLibrary(
            entries: keptLibrary.allEntries,
            root: libraryRoot,
            filter: libraryFilterSubjectID
        )
    }

    // MARK: - Person-delete/rename coupling (item 51/53 — granular entry points)

    /// The synchronous half of `AppModel.deletePerson`'s library-reference clearing
    /// (item 51/53): drops the doomed subject's ids from `selectedLibraryIDs`, nils
    /// `libraryFocusedID` if it pointed at one of them, and nils `libraryFilterSubjectID`
    /// if it was the deleted subject. Computes the doomed ids from the LIVE index (the
    /// purge itself hasn't run yet — that's `schedulePurge`, tracked by the caller in
    /// `pendingLibrarySaves`), so this must run BEFORE that purge lands. Pure, synchronous,
    /// no `Task` — mirrors the exact ordering the pre-extraction `AppModel.deletePerson`
    /// used.
    func purgeReferences(toSubject id: String) {
        let doomedEntryIDs = Set(keptLibrary.allEntries.filter { $0.subjectId == id }.map(\.id))
        selectedLibraryIDs.subtract(doomedEntryIDs)
        if let focused = libraryFocusedID, doomedEntryIDs.contains(focused) {
            libraryFocusedID = nil
        }
        if libraryFilterSubjectID == id {
            libraryFilterSubjectID = nil
        }
    }

    /// The off-actor half of the delete-person purge: removes the subject's saved copies
    /// from the index/disk, then re-syncs the exposed groups + cursor + revision. Returns
    /// the `Task` so `AppModel.deletePerson` can track it in `pendingLibrarySaves` (that
    /// tracking stays on `AppModel`, per item 65's scope) — this method itself does not
    /// append anywhere.
    func schedulePurge(ofSubject id: String) -> Task<Void, Never> {
        Task { [weak self, keptLibrary] in
            await keptLibrary.removeSubject(id)
            guard let self else { return }
            self.refreshLibraryGroups()
            self.reseatLibraryFocusIfNeeded()
            self.bumpRevision()
        }
    }

    // MARK: - Focus & navigation (item 26a)

    /// The keyboard cursor in the Library grid — DISTINCT from the review grid's
    /// `focusedID` so the two never interfere. Seated to `libraryOrderedIDs.first` when the
    /// Library becomes active, re-seated on filter/removal changes, `nil` when the library
    /// is empty; only ever holds an id present in `libraryOrderedIDs`. A settable `var`
    /// (like `ReviewSession.focusedID`) — tests assign it directly through the `AppModel`
    /// forwarder.
    var libraryFocusedID: String?
    /// Whether the in-place full-size Library preview is showing (Space-toggled, like the
    /// review center preview) — DISTINCT from the review grid's `isPreviewPresented`.
    /// `private(set)` (item 65's encapsulation win): every mutation routes through
    /// `openLibraryPreview`/`closeLibraryPreview`/`toggleLibraryPreview`/`setLibraryFilter`.
    private(set) var libraryPreviewActive = false

    /// Every library entry's id in DISPLAY order, derived from `libraryGroups`.
    var libraryOrderedIDs: [String] {
        libraryGroups.flatMap { person in
            person.months.flatMap { month in
                month.items.map(\.entry.id)
            }
        }
    }

    /// The `LibraryPhotoItem` currently under the keyboard cursor, if any (drives the
    /// in-place preview).
    var libraryFocusedItem: LibraryPhotoItem? {
        guard let id = libraryFocusedID else { return nil }
        for person in libraryGroups {
            for month in person.months {
                if let item = month.items.first(where: { $0.entry.id == id }) {
                    return item
                }
            }
        }
        return nil
    }

    /// The focused `LibraryPhotoItem` under a name the view + tests read directly
    /// (item 26b); an alias for `libraryFocusedItem`.
    var focusedLibraryItem: LibraryPhotoItem? {
        libraryFocusedItem
    }

    /// The `KeptEntry` currently under the keyboard cursor, `nil` when nothing is focused
    /// (item 26b — drives the Delete-key + preview remove paths).
    var focusedLibraryEntry: KeptEntry? {
        libraryFocusedItem?.entry
    }

    /// Click-selects (focuses) a library cell WITHOUT opening the preview — mirrors the
    /// review grid's "click selects, Space opens" split. A no-op for an unknown id.
    func focusLibrary(_ id: String) {
        guard libraryOrderedIDs.contains(id) else { return }
        libraryFocusedID = id
    }

    func moveLibraryLeft() {
        moveLibraryFocus(by: -1)
    }

    func moveLibraryRight() {
        moveLibraryFocus(by: 1)
    }

    func moveLibraryUp() {
        moveLibraryFocus(by: -columnCount)
    }

    func moveLibraryDown() {
        moveLibraryFocus(by: columnCount)
    }

    /// Moves the library cursor over `libraryOrderedIDs` by `delta`, clamped to the bounds
    /// (no wrap past either end).
    private func moveLibraryFocus(by delta: Int) {
        let ids = libraryOrderedIDs
        guard !ids.isEmpty else { return }
        let current = libraryFocusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let target = min(max(current + delta, 0), ids.count - 1)
        libraryFocusedID = ids[target]
    }

    /// Re-points (or clears) the library cursor when the underlying groups change so it
    /// only ever holds an id present in `libraryOrderedIDs`. Closes the preview when the
    /// library empties out. Not `private` — `removeFromLibrary`/`schedulePurge` and
    /// `AppModel.removeFocusedFromLibrary`'s composed op call it.
    func reseatLibraryFocusIfNeeded() {
        let ids = libraryOrderedIDs
        if let current = libraryFocusedID, ids.contains(current) { return }
        libraryFocusedID = ids.first
        if libraryFocusedID == nil { libraryPreviewActive = false }
    }

    // MARK: - Remove (item 26b)

    /// Removes the keyboard-focused entry through the REAL `removeFromLibrary` path (file
    /// + index delete, dedupe re-enabled) and lands the cursor on the NEXT entry — the one
    /// after the focused entry in `libraryOrderedIDs`, the new last when the removed entry
    /// was last, or `nil` when the library is now empty. A no-op when nothing is focused.
    func removeFocusedFromLibrary() {
        let ids = libraryOrderedIDs
        guard let focused = libraryFocusedID,
              let index = ids.firstIndex(of: focused),
              let entry = focusedLibraryEntry
        else { return }

        // The id the cursor should land on after the focused entry is gone.
        let nextID: String?
        if index + 1 < ids.count {
            nextID = ids[index + 1]
        } else if index - 1 >= 0 {
            nextID = ids[index - 1]
        } else {
            nextID = nil
        }

        // `removeFromLibrary` re-seats focus to the first entry; override that with the
        // computed NEXT id (still valid after the prune since it isn't the removed one).
        removeFromLibrary(entry)
        libraryFocusedID = nextID
    }

    // MARK: - In-place preview

    /// Opens the in-place full-size preview on the focused entry. A no-op when nothing is
    /// focused (empty library), so the preview never opens onto an empty grid.
    func openLibraryPreview() {
        guard libraryFocusedID != nil else { return }
        libraryPreviewActive = true
    }

    /// Closes the in-place preview, returning the grid. Focus is left where it is.
    func closeLibraryPreview() {
        libraryPreviewActive = false
    }

    /// Space toggles the preview for the focused entry; a safe no-op with no focus.
    func toggleLibraryPreview() {
        if libraryPreviewActive {
            closeLibraryPreview()
        } else {
            openLibraryPreview()
        }
    }

    // MARK: - Multi-selection (item 28)

    /// The Library grid's transient multi-selection — every saved photo the user has
    /// lassoed for an Export Selected to Photos. DISTINCT from both `libraryFocusedID`
    /// (the keyboard cursor) and the review grid's `selectedPhotoIDs`. Only ever holds ids
    /// present in `libraryOrderedIDs`; cleared on a filter change, on `showReview()`, and
    /// on any library removal. A settable `var` (like `libraryFocusedID`) — tests assign it
    /// directly through the `AppModel` forwarder.
    var selectedLibraryIDs: Set<String> = []
    /// The shift-extend anchor for the Library selection — the last cell that began a
    /// selection (a plain `selectLibrary`). `private(set)` (item 65's encapsulation win):
    /// only `selectLibrary`/`clearLibrarySelection` assign it. Not observable on its own;
    /// it only seeds `extendLibrarySelection`. SEPARATE from the review grid's `anchorID`.
    private(set) var libraryAnchorID: String?

    /// Whether any saved photos are multi-selected (drives the library selection bar).
    var hasLibrarySelection: Bool {
        !selectedLibraryIDs.isEmpty
    }

    /// Number of multi-selected saved photos.
    var librarySelectionCount: Int {
        selectedLibraryIDs.count
    }

    /// Plain-click select: replaces the selection with just `id`, re-seats the range
    /// anchor on it, AND focuses it (so the keyboard cursor follows the click). A no-op for
    /// an id outside `libraryOrderedIDs`.
    func selectLibrary(_ id: String) {
        guard libraryOrderedIDs.contains(id) else { return }
        selectedLibraryIDs = [id]
        libraryAnchorID = id
        libraryFocusedID = id
    }

    /// ⌘-click: toggles `id` in/out of the selection without disturbing the anchor. A
    /// no-op for an unknown id.
    func toggleLibrarySelection(_ id: String) {
        guard libraryOrderedIDs.contains(id) else { return }
        if selectedLibraryIDs.contains(id) {
            selectedLibraryIDs.remove(id)
        } else {
            selectedLibraryIDs.insert(id)
        }
    }

    /// ⇧-click: selects the inclusive range from the anchor to `id` over
    /// `libraryOrderedIDs` (works in both directions); leaves the anchor put so successive
    /// shift-extends grow from the same origin. With no anchor set, behaves like
    /// `selectLibrary`. A no-op for an unknown id.
    func extendLibrarySelection(to id: String) {
        let ids = libraryOrderedIDs
        guard ids.contains(id) else { return }
        guard let anchor = libraryAnchorID,
              let anchorIndex = ids.firstIndex(of: anchor),
              let targetIndex = ids.firstIndex(of: id)
        else {
            selectLibrary(id)
            return
        }
        let range = anchorIndex <= targetIndex ? anchorIndex ... targetIndex : targetIndex ... anchorIndex
        selectedLibraryIDs = Set(ids[range])
    }

    /// Clears the library multi-selection (also drops the range anchor).
    func clearLibrarySelection() {
        selectedLibraryIDs = []
        libraryAnchorID = nil
    }

    // MARK: - Selected file URLs (item 28/61)

    /// The on-disk URLs of the selected saved photos, in `libraryOrderedIDs` order,
    /// SKIPPING any selected entry whose backing file is missing on disk (so an export
    /// never points at a vanished copy). The export source set `ExportController`'s
    /// `libraryURLs` provider reads (`AppModel.init` wires it to
    /// `self.library.selectedLibraryFileURLs`).
    var selectedLibraryFileURLs: [URL] {
        libraryOrderedIDs
            .filter { selectedLibraryIDs.contains($0) }
            .compactMap { libraryEntry(for: $0) }
            .map { libraryFileURL(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The `KeptEntry` behind a library id (from the current `libraryGroups`), `nil` when
    /// no group holds it.
    private func libraryEntry(for id: String) -> KeptEntry? {
        for person in libraryGroups {
            for month in person.months {
                if let item = month.items.first(where: { $0.entry.id == id }) {
                    return item.entry
                }
            }
        }
        return nil
    }

    // MARK: - Init

    /// Constructed by `AppModel` LAST (before `export`/`scan`, which re-wire to it), once
    /// `keptLibrary` and the `LibraryRootResolution` already exist — `resolution` is
    /// computed by `AppModel` BEFORE this init runs (its `keptLibrary`'s index URL needed
    /// the resolved root first), so this initializer only APPLIES the resolution's
    /// security-scope/stale-bookmark signals; it never re-resolves anything itself. No
    /// back-call through `AppModel.library` here (it's still the nil IUO mid-assignment
    /// while this runs) — every touch below is to the injected `keptLibrary`/`defaults`.
    init(
        keptLibrary: any KeptLibrarySaving,
        libraryDefaults: UserDefaults,
        libraryLocations: LibraryLocations,
        resolution: LibraryRootResolution,
        columnCount: Int,
        testLibraryPickDest: URL?
    ) {
        self.keptLibrary = keptLibrary
        self.libraryDefaults = libraryDefaults
        self.libraryLocations = libraryLocations
        self.columnCount = columnCount
        self.testLibraryPickDest = testLibraryPickDest

        resolvedLibraryRoot = resolution.url
        accessingScopedURL = nil
        libraryRootNeedsReselection = resolution.needsReselection

        // A bookmarked custom root needs security-scoped access begun before any library
        // read/write (held for the app lifetime; a no-op off the sandbox). If the OS
        // flagged the bookmark stale, RE-CREATE it from the still-valid resolved URL
        // (Apple's `bookmarkDataIsStale` contract) — do not fall back or re-prompt.
        if resolution.isSecurityScoped {
            if resolution.url.startAccessingSecurityScopedResource() {
                accessingScopedURL = resolution.url
            }
            if resolution.needsBookmarkRefresh, let data = try? makeLibraryBookmark(for: resolution.url) {
                libraryDefaults.set(data, forKey: LibraryPreference.bookmarkKey)
            }
        }
    }
}
