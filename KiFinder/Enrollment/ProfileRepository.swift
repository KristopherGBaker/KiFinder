import Foundation
import KionEngine

/// Persistence seam for the app-layer enrollment substrate: the **people roster**
/// (who exists, their names + thumbnail refs), their **embeddings** (the engine's
/// `ProfileStore`, keyed by `subjectId`), and their cached **thumbnails**. Views
/// never touch the JSON store or the roster file directly — they go through this
/// protocol so the store path stays test-injectable (one unique temp file per
/// test) and the encode/decode lives in one place.
@MainActor
protocol ProfileRepository: AnyObject {
    /// Roster (who exists) — the source of truth for the set of people.
    /// Loads the roster, migrating a legacy single-subject store on first load.
    func loadRoster() -> [Person]
    /// Upserts a person's name/thumbnail reference into the roster.
    func savePerson(_ person: Person) throws
    /// Removes the roster entry, the person's `ProfileBundle`, and any cached thumbnail.
    func deletePerson(id: String) throws

    // Embeddings (the engine's concern, keyed by subjectId).
    func loadProfile(subjectId: String) -> ProfileBundle?
    func saveProfile(_ bundle: ProfileBundle) throws
    func reset()

    /// Thumbnails (bytes produced by the engine crop in item 2; the seam exists now).
    /// The on-disk URL of the person's cached thumbnail, or `nil` if none exists.
    func thumbnailURL(for id: String) -> URL?
    /// Writes PNG bytes as the person's cached thumbnail and returns its URL.
    @discardableResult
    func saveThumbnail(_ pngData: Data, for id: String) throws -> URL
}

/// `ProfileRepository` backed by on-disk JSON: a single `ProfileStore` file for
/// embeddings, a versioned `people-roster.json` sidecar in the **same directory**
/// for the roster, and a `thumbnails/` subdir for cached face crops. The model
/// stamp resolves to `KionEngine`'s single canonical `ModelIdentity` (item 58) —
/// the SAME identity the CLI resolves to — rather than a hand-typed, made-up
/// local-only constant. A legacy store stamped with the app's old
/// `"kion-local-enroll"` label is a recognized alias of the same model and
/// self-heals to canonical at load (`ProfileStore.load`); nothing here writes
/// that legacy label again.
@MainActor
final class FileProfileRepository: ProfileRepository {
    /// The DEFAULT model stamp written into every persisted store when no
    /// `modelId`/`modelVersion` is supplied: `KionEngine`'s single canonical
    /// identity. Kept stable so a relaunch against the same file loads the bundle
    /// without a version reset. Every existing caller (which constructs
    /// `FileProfileRepository(storeURL:)` without the new params) stays pinned to
    /// arcface exactly as before item 72.
    static let modelId = ModelIdentity.canonical.modelId
    static let modelVersion = ModelIdentity.canonical.modelVersion

    /// Current roster schema version. Bumped from the implicit "v1" single-subject
    /// store to v2 when the multi-person roster was introduced.
    static let rosterSchemaVersion = 2

    let storeURL: URL
    /// The model stamp THIS instance reads/writes — defaults to the statics above
    /// (arcface) so every pre-item-72 call site is unaffected. A repository built
    /// for the Vision backend passes `.visionFeaturePrint`'s id/version instead, so
    /// its store is stamped (and gated) as `vision-featureprint`, never arcface.
    private let modelId: String
    private let modelVersion: String

    /// Set once when a `loadRoster()` call finds an undecodable roster file and
    /// quarantines it aside — a plain-language, one-time notice for the root-level
    /// UI (item 57). `nil` until that happens; stays set for the life of this
    /// instance (the quarantined bytes are gone from `rosterURL`, so a later
    /// `loadRoster()` in the SAME run never re-triggers it, and a fresh app launch
    /// sees no roster file at all — "no nag on every launch").
    private(set) var rosterQuarantineNotice: String?

    init(
        storeURL: URL,
        modelId: String = ModelIdentity.canonical.modelId,
        modelVersion: String = ModelIdentity.canonical.modelVersion
    ) {
        self.storeURL = storeURL
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    // MARK: - Roster

    /// The roster sidecar, alongside the embedding store.
    private var rosterURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("people-roster.json")
    }

    func loadRoster() -> [Person] {
        if let data = try? Data(contentsOf: rosterURL) {
            if let roster = try? JSONDecoder().decode(PersonRoster.self, from: data) {
                return roster.people
            }
            // The file exists but is undecodable: preserve the evidence (display
            // names + thumbnail refs a store-derived migration can never recover)
            // BEFORE falling through to the migration below — never silently
            // discard it (item 57).
            quarantineRoster()
        }
        // No roster file (clean first run, OR it was just quarantined above):
        // migrate. Synthesize one person per existing `ProfileStore` subject (a
        // legacy single-subject store's `subjectId` becomes a person of that id and
        // name) without ever touching the store, then write roster v2. Recovery
        // happens AFTER quarantine, so
        // today's self-healing behavior is preserved.
        let migrated = migratedPeople()
        try? writeRoster(migrated)
        return migrated
    }

    /// Renames the unreadable roster aside and, on success, records the one-time
    /// notice. A failed rename (e.g. no write permission) leaves the notice unset
    /// rather than lying about what happened; the migration fallback still runs.
    private func quarantineRoster() {
        guard (try? DataQuarantine.quarantineUnreadable(at: rosterURL)) != nil else { return }
        rosterQuarantineNotice = String(
            localized: "Your saved people list couldn't be read, so it was set aside instead of erased. Names may need to be re-entered, but your enrolled faces are safe.",
            comment: "Root-level notice shown once when the people-roster.json file was corrupt and quarantined."
        )
    }

    /// Synthesizes a roster from the existing embedding store, preserving each
    /// `subjectId` as the person `id` so embeddings stay reachable. Returns `[]`
    /// when there is no store (clean first run).
    private func migratedPeople() -> [Person] {
        guard let store = try? loadStore(), !store.profiles.isEmpty else { return [] }
        return store.profiles.keys.sorted().map { subjectId in
            Person(id: subjectId, displayName: subjectId)
        }
    }

    func savePerson(_ person: Person) throws {
        var people = loadRoster()
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
        } else {
            people.append(person)
        }
        try writeRoster(people)
    }

    func deletePerson(id: String) throws {
        // 1. Roster entry.
        var people = loadRoster()
        people.removeAll { $0.id == id }
        try writeRoster(people)

        // 2. Embedding bundle in the ProfileStore (store left intact if absent).
        // `try` (not `try?`): a store file that EXISTS but fails to load (a
        // persist-failure or a genuine mismatch) must surface, not be silently
        // treated as "no bundle to remove".
        if var store = try loadStore(), store.profiles[id] != nil {
            store.profiles[id] = nil
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try store.encode(to: storeURL)
        }

        // 3. Cached thumbnail file, if any.
        let thumbnail = thumbnailFileURL(for: id)
        if FileManager.default.fileExists(atPath: thumbnail.path) {
            try? FileManager.default.removeItem(at: thumbnail)
        }
    }

    private func writeRoster(_ people: [Person]) throws {
        let roster = PersonRoster(schemaVersion: Self.rosterSchemaVersion, people: people)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(roster)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: rosterURL, options: [.atomic])
    }

    // MARK: - Embeddings

    func loadProfile(subjectId: String) -> ProfileBundle? {
        (try? loadStore())?[subjectId]
    }

    func saveProfile(_ bundle: ProfileBundle) throws {
        // `try` (not `try?`): if a store file EXISTS but fails to load — a
        // recognized-alias migration whose atomic rewrite failed, or a genuine
        // `ModelVersionMismatchError` — that failure must propagate here rather
        // than be swallowed into "no store", which would make this line create a
        // FRESH, empty store and atomically overwrite the taught data still sitting
        // on disk (the exact data-loss chain this item closes). Only a genuinely
        // absent file (`loadStore()` returning `nil` with no throw) falls back to a
        // brand-new store, which is legitimate first-run behavior.
        var store = try loadStore() ?? ProfileStore(modelId: modelId, modelVersion: modelVersion)
        store[bundle.subjectId] = bundle
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try store.encode(to: storeURL)
    }

    func reset() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Loads the on-disk store, distinguishing "no store file exists" (returns
    /// `nil`; a legitimate first run) from "a store file exists but couldn't be
    /// loaded" (throws — a recognized-alias migration whose persist failed, or a
    /// genuine `ModelVersionMismatchError`). Callers that must never clobber
    /// existing-but-unloadable data (`saveProfile`, `deletePerson`) propagate the
    /// throw; callers for which "can't read it" and "nothing there" are equally
    /// fine to treat as absent (`loadProfile`, roster migration) swallow it.
    func loadStore() throws -> ProfileStore? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        return try ProfileStore.load(
            from: storeURL,
            expectingModelId: modelId,
            expectingModelVersion: modelVersion
        )
    }

    // MARK: - Thumbnails

    /// The thumbnails directory next to the store (created lazily on write).
    private var thumbnailsDirectory: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// The canonical on-disk path for a person's thumbnail (existence not checked).
    private func thumbnailFileURL(for id: String) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(id).png")
    }

    func thumbnailURL(for id: String) -> URL? {
        let url = thumbnailFileURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func saveThumbnail(_ pngData: Data, for id: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: thumbnailsDirectory,
            withIntermediateDirectories: true
        )
        let url = thumbnailFileURL(for: id)
        try pngData.write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Launch-time bootstrap

    /// Launch-time bootstrap of the roster against optional seed profiles. Env-free and
    /// idempotent; encapsulates the reset → seed-if-absent → store↔roster reconcile →
    /// initial-active dance that `AppModel.init` used to hand-roll. Returns the reconciled
    /// roster (in on-disk order) and the initial active person id.
    @discardableResult
    func bootstrapRoster(
        reset: Bool,
        seedProfiles: [ProfileBundle],
        preferredActiveID: String?
    ) -> (roster: [Person], initialActiveID: String?) {
        if reset {
            self.reset()
            // A reset clears enrollment; drop the roster sidecar too so the next
            // load migrates/rebuilds cleanly rather than resurrecting stale people.
            for person in loadRoster() {
                try? deletePerson(id: person.id)
            }
        }
        // Subjects we expect enrolled after seeding, in first-occurrence order.
        // Reconciled into BOTH the embedding store and the roster below so the two
        // never drift (e.g. a sample-seeded "Ava" must not land in the store while a
        // pre-existing v2 roster keeps only its own single person).
        var seededSubjects: [String] = []
        for bundle in seedProfiles {
            if loadProfile(subjectId: bundle.subjectId) == nil {
                try? saveProfile(bundle)
            }
            if !seededSubjects.contains(bundle.subjectId) {
                seededSubjects.append(bundle.subjectId)
            }
        }
        // Load the roster (migrates a legacy single-subject store on first load),
        // then make sure EVERY seeded subject is represented as a person — even when
        // a v2 roster already existed (so migration didn't run for the new subject).
        var roster = loadRoster()
        var rosterChanged = false
        for subjectId in seededSubjects where !roster.contains(where: { $0.id == subjectId }) {
            try? savePerson(Person(id: subjectId, displayName: subjectId))
            rosterChanged = true
        }
        if rosterChanged { roster = loadRoster() }
        // Default active person stays the preferred id (e.g. the seed subject) when
        // present — the migrated single person and the sample path both keep it
        // active so the visible candidate set/counts don't change before
        // per-person filtering. Otherwise fall back to the first person in the roster.
        let initialActiveID = roster.first(where: { $0.id == preferredActiveID })?.id ?? roster.first?.id
        return (roster, initialActiveID)
    }
}
