import Foundation
import KionEngine
import Observation

/// The person-roster responsibility carved out of `AppModel` (item 67): owns the
/// roster (`people`), the active-person selection with its cross-sub-model
/// choreography, the roster-write error channel (item 53), and the three CRUD paths
/// — add/rename/delete — with their item-51/53 safety adjacencies.
///
/// A separate `@Observable @MainActor` type COMPOSED by `AppModel` (`model.peopleStore`)
/// — not an extension — mirroring `ReviewSession` (item 59), `ExportController`
/// (item 61), `ScanController` (item 63), and `LibraryModel` (item 65): everything
/// below is `private`/`private(set)`, reachable only through the narrow API `AppModel`
/// forwards.
///
/// `engine`/`profileRepository`/`review`/`library`/`keptLibrary`/`skipStore` are
/// injected as their (class-bound) live references directly — a reference type is
/// already "live" with no snapshot risk. Three seams reach back INTO `AppModel`
/// because their state deliberately stays there (item 57's discipline: never a stale
/// snapshot, and never move state across the seam that the plan says stays put):
/// `onActivePersonChanged` refreshes `AppModel`'s own enrolled-profile cache,
/// `presentEnrollment` re-opens `AppModel`'s enrollment sheet for the item-51
/// delete-last-person tail, and `appendPendingLibrarySave` tracks a delete's async
/// library purge on `AppModel`'s own drain queue.
@Observable
@MainActor
final class PeopleStore {
    private let engine: any TriageEngine
    private let profileRepository: any ProfileRepository
    private let review: ReviewSession
    private let library: LibraryModel
    private let keptLibrary: any KeptLibrarySaving
    private let skipStore: any SkipRecording
    private let onActivePersonChanged: () -> Void
    private let presentEnrollment: (String?) -> Void
    private let appendPendingLibrarySave: (Task<Void, Never>) -> Void

    /// Everyone the app knows about (roster source of truth). Single-element after
    /// migration; grows as people are added. Mutated only through the add/rename/
    /// delete methods (and `adoptRoster(_:)`, the enrollment-completion seat) so it
    /// stays in sync with the repository.
    private(set) var people: [Person] = []

    /// The selected (active) person whose candidates Review shows and whose profile
    /// gates enrollment. `nil` only before the first person is enrolled. NOT
    /// `private(set)` — `AppModel`'s settable `activePersonID` forwarder (and the
    /// `ManualRegionTests` direct `= nil` assignment routed through it) writes here
    /// directly, exactly the exception `ReviewSession.focusedID` documents for its
    /// own settable passthrough.
    private var _activePersonID: String?
    var activePersonID: String? {
        get { _activePersonID }
        set {
            guard newValue != _activePersonID else { return }
            _activePersonID = newValue
            // Item 59/67: the rest of the person-switch choreography — cancel the
            // in-flight manual re-score, re-aim the engine's active-subject
            // matching, drop promotions surfaced for the previous person, re-seat
            // keyboard focus onto the new person's first candidate, and clear the
            // (per-person, transient) multi-selection — is reproduced, in the SAME
            // order, by `ReviewSession.activePersonDidChange(to:)`. The enrollment
            // cache refresh runs FIRST, exactly as it did on `AppModel` before the
            // extraction. No engine call is added here — the engine re-aim already
            // lives inside `review.activePersonDidChange`.
            onActivePersonChanged()
            review.activePersonDidChange(to: _activePersonID)
        }
    }

    /// Seats the initial active id WITHOUT running the person-switch choreography.
    /// This mirrors main EXACTLY: there, `AppModel.activePersonID = initialActiveID`
    /// was assigned inside `AppModel`'s OWN init, so Swift SUPPRESSED the `didSet`
    /// (no engine re-aim, no focus reseat, no promotions clear at construction). Once
    /// `activePersonID` moved onto this separate object, seating it through the
    /// observed setter from `AppModel.init` would fire that choreography — re-aiming
    /// the engine's active subject at launch, which nothing did before (and which
    /// breaks the item-53 delete-vs-write tests that rely on the engine keeping its
    /// constructed subject). `AppModel.init` seeds `enrolledProfile` explicitly and
    /// seeds review focus via `review.focusFirstIfNeeded()`, exactly as on main.
    func seedInitialActive(_ id: String?) {
        _activePersonID = id
    }

    /// Display name of the active person, or `nil` when no one is active (first run,
    /// or after the last person is deleted). Drives person-aware Review/Scan copy;
    /// never used as an accessibility identifier (it's user data).
    var activePersonName: String? {
        activePersonID.flatMap { id in people.first { $0.id == id }?.displayName }
    }

    /// Whether the presented enrollment is MANDATORY — the first-run (or
    /// delete-last-person, item 51) enrollment with no one yet enrolled.
    var isEnrollmentMandatory: Bool {
        people.isEmpty
    }

    /// Non-nil when the last `addPerson`/`renamePerson`/`deletePerson` FAILED (a
    /// localized, user-facing message) — item 53's roster-write error channel, wired
    /// to the same alert-with-retry pattern `AppModel.exportError` uses. A failure
    /// never mutates `people`/`activePersonID`/other state; the operation is a no-op
    /// until retried.
    private(set) var rosterError: String?
    /// Re-runs the most recent failed roster write, retained so the error banner's
    /// "Try Again" repeats exactly the same add/rename/delete call.
    private var lastRosterRetry: (() -> Void)?

    // MARK: - Passthroughs (repository reads the sidebar needs)

    /// Passthrough to the repository's cached thumbnail URL for a person, so the
    /// sidebar can render each person's real face crop without reaching into the
    /// repository seam directly.
    func thumbnailURL(for id: String) -> URL? {
        profileRepository.thumbnailURL(for: id)
    }

    /// Enrolled reference count for an arbitrary person (not just the active one),
    /// read from the embedding store. `nil` when that person isn't enrolled yet.
    /// Used by the sidebar to show each row's reference count.
    func referenceCount(for id: String) -> Int? {
        profileRepository.loadProfile(subjectId: id)?.references.count
    }

    // MARK: - Init

    /// Constructed by `AppModel` LAST — after `library` AND `review` both exist (both
    /// are injected deps here). Seeded with the ALREADY-loaded/migrated/reconciled
    /// roster (`AppModel.init` still does that inline); `activePersonID` is left at
    /// its default `nil` here on purpose — `AppModel` seats the initial active id
    /// AFTER assigning `peopleStore` via `seedInitialActive(_:)`, which sets the
    /// backing value WITHOUT firing the person-switch choreography. That mirrors main,
    /// where the init-time `AppModel.activePersonID = initialActiveID` was a set inside
    /// AppModel's own init and Swift SUPPRESSED its didSet (no engine re-aim at
    /// launch). No back-call through any injected closure runs during this init —
    /// every touch below is a plain stored-property assignment.
    init(
        people: [Person],
        engine: any TriageEngine,
        profileRepository: any ProfileRepository,
        review: ReviewSession,
        library: LibraryModel,
        keptLibrary: any KeptLibrarySaving,
        skipStore: any SkipRecording,
        onActivePersonChanged: @escaping () -> Void,
        presentEnrollment: @escaping (String?) -> Void,
        appendPendingLibrarySave: @escaping (Task<Void, Never>) -> Void
    ) {
        self.people = people
        self.engine = engine
        self.profileRepository = profileRepository
        self.review = review
        self.library = library
        self.keptLibrary = keptLibrary
        self.skipStore = skipStore
        self.onActivePersonChanged = onActivePersonChanged
        self.presentEnrollment = presentEnrollment
        self.appendPendingLibrarySave = appendPendingLibrarySave
    }

    // MARK: - Enrollment-completion seat (called FROM `AppModel.finishEnrollment`)

    /// Replaces the roster wholesale — `AppModel.finishEnrollment`'s reload after the
    /// enrollment model already saved the `Person` (real name + thumbnail) to the
    /// roster. `people` is `private(set)`, so this is the seam that seats it from
    /// outside; never re-saves a `Person` itself.
    func adoptRoster(_ roster: [Person]) {
        people = roster
    }

    /// Makes `id` the active person — the seam `AppModel.finishEnrollment` uses to
    /// seat the just-enrolled subject active (fires the didSet choreography exactly
    /// like any other value-changing assignment to `activePersonID`). A thin, named
    /// alias for the settable property, kept alongside `adoptRoster(_:)` so the
    /// enrollment-completion seat reads as one paired call.
    func setActive(_ id: String?) {
        activePersonID = id
    }

    // MARK: - Person management

    /// Adds a new (unenrolled) person with a fresh UUID id and makes them active.
    /// Enrollment of their references happens through the enrollment sheet. On a
    /// roster-write failure (item 53), surfaces `rosterError` with a retry and
    /// leaves `people`/`activePersonID` untouched — no phantom person appears.
    @discardableResult
    func addPerson(name: String) -> Person {
        rosterError = nil
        let person = Person(displayName: name)
        do {
            // Roster-only write; the transaction still runs so a pending coalesced
            // store write can never be silently dropped by this repository call.
            try engine.writingThroughRepository {
                try profileRepository.savePerson(person)
            }
        } catch {
            presentRosterError { [weak self] in self?.addPerson(name: name) }
            return person
        }
        people = profileRepository.loadRoster()
        activePersonID = person.id
        return person
    }

    /// Makes an existing person the active one (no-op for an unknown id).
    func selectPerson(id: String) {
        guard people.contains(where: { $0.id == id }) else { return }
        // Selecting a person is a Review action: return the detail pane to Review if the
        // Library was open (item 18b) — WITHOUT clearing the library selection. Item 65:
        // this must NOT route through the selection-clearing `library.showReview()`;
        // `selectPerson` only ever flipped the flag.
        library.returnToReviewWithoutClearingSelection()
        activePersonID = id
    }

    /// Renames a person, persisting the new display name to the roster, then migrates
    /// their kept-photo library (folder + index) to the new name off the keypress path
    /// (mirroring the keep-hook). When the Library browse is open, the exposed
    /// `libraryGroups` are refreshed once the migration lands so they show the new name.
    /// Review state is otherwise untouched. On a roster-write failure (item 53),
    /// surfaces `rosterError` with a retry, shows the OLD name, and launches no
    /// library migration — no success-only mutation on failure.
    func renamePerson(id: String, to newName: String) {
        rosterError = nil
        guard var person = people.first(where: { $0.id == id }) else { return }
        person.displayName = newName
        do {
            // Roster-only write; the transaction still runs so a pending coalesced
            // store write can never be silently dropped by this repository call.
            try engine.writingThroughRepository {
                try profileRepository.savePerson(person)
            }
        } catch {
            presentRosterError { [weak self] in self?.renamePerson(id: id, to: newName) }
            return
        }
        people = profileRepository.loadRoster()
        // Migrate the library off the main path so a rename never blocks on file I/O.
        Task { [weak self, keptLibrary] in
            await keptLibrary.renameSubject(id, to: newName)
            guard let self else { return }
            if self.library.libraryBrowseActive {
                self.library.refreshLibraryGroups()
            }
            self.library.bumpRevision()
        }
    }

    /// Removes a person entirely (roster entry + embeddings + thumbnail + their kept-photo
    /// library entries). If the active person was removed, falls back to the first
    /// remaining person.
    ///
    /// Item 53 — durable against an in-flight coalesced write: a keep/skip recorded
    /// just before this call may have armed a pending write of the WHOLE store
    /// (including the doomed person's pre-delete bundle). `engine.writingThroughRepository`
    /// captures + cancels that pending snapshot BEFORE the repository delete runs (so
    /// it can never fire afterward and resurrect the deleted person), then — once the
    /// delete lands — prunes the deleted id from the captured snapshot and re-arms it,
    /// so any OTHER person's pending feedback in that snapshot survives. On the common
    /// "nothing pending" path this never awaits anything (no debounce-length wait); on
    /// a repository throw, the captured snapshot is restored unchanged and the failure
    /// surfaces via `rosterError` with NO other state mutated (roster, skip store,
    /// library/browse/selection, `activePersonID` all left intact; enrollment is not
    /// re-opened).
    func deletePerson(id: String) {
        rosterError = nil
        do {
            try engine.writingThroughRepository(merging: { store in store.profiles[id] = nil }) {
                try profileRepository.deletePerson(id: id)
            }
        } catch {
            presentRosterError { [weak self] in self?.deletePerson(id: id) }
            return
        }
        people = profileRepository.loadRoster()
        if activePersonID == id {
            activePersonID = people.first?.id
        }
        // Purge the deleted subject's persistent skips too (item 48 parity with the
        // library purge below), so their prior skips never affect a re-enrolled person.
        skipStore.removeSubject(id)

        // Clear ONLY the library browse state that referenced the deleted person,
        // SYNCHRONOUSLY (item 65: `LibraryModel.purgeReferences(toSubject:)` — the index
        // still holds their entries here; the purge itself runs off the main path below).
        library.purgeReferences(toSubject: id)

        // Purge the deleted subject's saved copies off the main path (mirrors the keep
        // hook), tracked on `AppModel.pendingLibrarySaves` (item 65's home for that
        // queue) via the injected `appendPendingLibrarySave` closure so tests can still
        // drain it deterministically through `AppModel`.
        let task = library.schedulePurge(ofSubject: id)
        appendPendingLibrarySave(task)

        // Item 51: deleting the SOLE remaining person would strand the user on an empty
        // Review (or in Library browse) with no path forward. Return the detail pane to
        // Review if the Library was open, then present enrollment for a brand-new person
        // (fresh id, empty name prefill — same target semantics as `AppModel.beginAddPerson`),
        // via the injected `presentEnrollment` closure (that presentation state stays on
        // `AppModel`). Deleting a person while others remain keeps today's behavior
        // (fallback to a remaining person above, no sheet, no forced return to Review).
        if people.isEmpty {
            if library.libraryBrowseActive {
                library.showReview()
            }
            presentEnrollment(nil)
        }
    }

    // MARK: - Roster error channel (item 53)

    /// Clears the roster-write-failure banner (user dismissed or is retrying).
    func clearRosterError() {
        rosterError = nil
    }

    /// Re-runs the most recent failed add/rename/delete (from the error banner's
    /// "Try Again"). A no-op if there is no prior failure to retry. Retries exactly
    /// once per invocation — a still-broken repository re-surfaces the error rather
    /// than looping.
    func retryRoster() {
        clearRosterError()
        lastRosterRetry?()
    }

    /// Surfaces a roster/store write failure (item 53) through the same
    /// alert-with-retry channel `AppModel.exportError` uses, so add/rename/delete
    /// never silently no-op on a repository throw.
    private func presentRosterError(retry: @escaping () -> Void) {
        rosterError = String(localized: "This change couldn't be saved. Please try again.")
        lastRosterRetry = retry
    }
}
