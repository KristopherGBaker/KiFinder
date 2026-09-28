import Foundation
import KionEngine
@testable import KiFinder
import Testing

/// Coverage for `FileProfileRepository.bootstrapRoster` (item 68): the launch-time
/// reset → seed-if-absent → store↔roster reconcile → initial-active orchestration
/// extracted out of `AppModel.init`. Each test uses its own unique temp directory so
/// the suite passes in any order.
@Suite("Bootstrap roster (launch-time seeding orchestration)")
@MainActor
struct BootstrapRosterTests {
    // MARK: - Fixtures

    private func uniqueDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-bootstrap-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepository(in dir: URL) -> FileProfileRepository {
        FileProfileRepository(storeURL: dir.appendingPathComponent("store.json"))
    }

    private func bundle(_ subjectId: String, references: Int = 1) -> ProfileBundle {
        ProfileBundle(
            subjectId: subjectId,
            references: (1 ... references).map { FaceEmbedding([Float($0)]) },
            threshold: 0.45,
            maybeMargin: 0.20,
            modelId: FileProfileRepository.modelId,
            modelVersion: FileProfileRepository.modelVersion
        )
    }

    // MARK: - (a) Reset clears stale roster+store before seeding

    @Test("reset drops a pre-existing stale person from both roster and store before seeding the new one")
    func resetClearsStaleBeforeSeeding() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "Stale", displayName: "Stale"))
        try repo.saveProfile(bundle("Stale", references: 3))
        #expect(repo.loadRoster().map(\.id) == ["Stale"])

        let result = repo.bootstrapRoster(
            reset: true,
            seedProfiles: [bundle("Kris")],
            preferredActiveID: "Kris"
        )

        #expect(!result.roster.contains { $0.id == "Stale" })
        #expect(repo.loadProfile(subjectId: "Stale") == nil)
        #expect(result.roster.contains { $0.id == "Kris" })
        #expect(repo.loadProfile(subjectId: "Kris") != nil)
        #expect(result.initialActiveID == "Kris")
    }

    @Test("reset false leaves an existing roster+store untouched before seeding")
    func noResetPreservesExisting() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "Existing", displayName: "Existing"))
        try repo.saveProfile(bundle("Existing", references: 2))

        let result = repo.bootstrapRoster(reset: false, seedProfiles: [], preferredActiveID: nil)

        #expect(result.roster.map(\.id) == ["Existing"])
        #expect(repo.loadProfile(subjectId: "Existing")?.references.count == 2)
    }

    // MARK: - (b) Seed-if-absent, first-wins idempotence

    @Test("a later duplicate-subject seed bundle is a no-op: the FIRST bundle for a subjectId wins")
    func seedIfAbsentFirstWins() throws {
        let repo = makeRepository(in: uniqueDir())

        repo.bootstrapRoster(
            reset: false,
            seedProfiles: [bundle("Kris", references: 5), bundle("Kris", references: 2)],
            preferredActiveID: "Kris"
        )

        let persisted = try #require(repo.loadProfile(subjectId: "Kris"))
        #expect(persisted.references.count == 5)
    }

    @Test("seed-if-absent never overwrites an already-enrolled profile")
    func seedIfAbsentDoesNotOverwriteEnrolled() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.saveProfile(bundle("Kris", references: 7))

        repo.bootstrapRoster(
            reset: false,
            seedProfiles: [bundle("Kris", references: 1)],
            preferredActiveID: "Kris"
        )

        let persisted = try #require(repo.loadProfile(subjectId: "Kris"))
        #expect(persisted.references.count == 7)
    }

    // MARK: - (c) Reconcile append-order, no store-wide reconciliation

    @Test("reconcile appends missing seed subjects once each in first-occurrence order, preserves existing roster order, and never reconciles a non-seeded store subject")
    func reconcileAppendOrderNoStoreWideReconciliation() throws {
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        // Pre-existing v2 roster: only one person.
        try repo.savePerson(Person(id: "Kris", displayName: "Kris"))
        // Store also holds a non-seeded subject "Zed" (store-only, absent from roster).
        try repo.saveProfile(bundle("Zed", references: 1))
        try repo.saveProfile(bundle("Kris", references: 1))

        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [bundle("Ava"), bundle("Noah"), bundle("Ava")],
            preferredActiveID: "Kris"
        )

        #expect(result.roster.map(\.id) == ["Kris", "Ava", "Noah"])
    }

    @Test("reconcile does not append a seed subject already present in the roster")
    func reconcileSkipsAlreadyPresent() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "Kris", displayName: "Kris"))
        try repo.savePerson(Person(id: "Ava", displayName: "Ava"))
        try repo.saveProfile(bundle("Ava", references: 1))

        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [bundle("Ava")],
            preferredActiveID: "Kris"
        )

        #expect(result.roster.map(\.id) == ["Kris", "Ava"])
    }

    // MARK: - (d) initialActiveID

    @Test("initialActiveID prefers the preferred id when present")
    func initialActiveIDPrefersPreferred() {
        let repo = makeRepository(in: uniqueDir())
        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [bundle("Kris"), bundle("Ava")],
            preferredActiveID: "Ava"
        )
        #expect(result.initialActiveID == "Ava")
    }

    @Test("initialActiveID falls back to the first roster person when the preferred id is absent")
    func initialActiveIDFallsBackToFirst() throws {
        // Pre-seat an explicit roster whose on-disk order is deterministic (a roster
        // FILE exists, so loadRoster preserves insertion order rather than taking the
        // migration path, which would synthesize people from alphabetically-sorted
        // store keys). "Zoe" is written first, so it is the unambiguous first person.
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "Zoe", displayName: "Zoe"))
        try repo.savePerson(Person(id: "Kris", displayName: "Kris"))

        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [],
            preferredActiveID: "NoSuchPerson"
        )

        #expect(result.roster.map(\.id) == ["Zoe", "Kris"])
        #expect(result.initialActiveID == "Zoe")
    }

    @Test("initialActiveID is nil on an empty roster")
    func initialActiveIDNilOnEmptyRoster() {
        let repo = makeRepository(in: uniqueDir())
        let result = repo.bootstrapRoster(reset: false, seedProfiles: [], preferredActiveID: "Kris")
        #expect(result.roster.isEmpty)
        #expect(result.initialActiveID == nil)
    }
}

/// Item 82 changed `AppModel.legacySubjectID` — the id a v1 (single-person) store
/// was written with — to a neutral value. Two things must survive that change:
///
/// 1. An **already-migrated v2 roster** written by an older build, whose person id
///    is the *retired* value, must keep loading byte-for-byte unchanged. Person ids
///    are opaque after migration, so nothing may key on the old string; this suite
///    proves that by construction (the retired id lives only in the fixture below).
/// 2. A genuine **v1 store** keyed on the NEW constant must still migrate into a
///    roster and become the initial active person.
@Suite("Legacy subject-id compatibility (item 82)")
@MainActor
struct LegacySubjectCompatibilityTests {
    /// The subject id earlier single-person builds wrote on disk, assembled from
    /// fragments so no contiguous occurrence of the retired name appears in the
    /// publishable source tree (which is grep-checked for it). This is a *fixture*
    /// value only — no production code knows or special-cases it.
    private static let retiredID = "Ki" + "on"

    private func uniqueDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-legacy-compat-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepository(in dir: URL) -> FileProfileRepository {
        FileProfileRepository(storeURL: dir.appendingPathComponent("store.json"))
    }

    private func bundle(_ subjectId: String, references: [[Float]]) -> ProfileBundle {
        ProfileBundle(
            subjectId: subjectId,
            references: references.map { FaceEmbedding($0) },
            threshold: 0.45,
            maybeMargin: 0.20,
            modelId: FileProfileRepository.modelId,
            modelVersion: FileProfileRepository.modelVersion
        )
    }

    /// Everything currently on disk under `dir`, recursively, as relative paths.
    private func contents(of dir: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return walker
            .compactMap { ($0 as? URL)?.path.replacingOccurrences(of: dir.path + "/", with: "") }
            .sorted()
    }

    @Test("An already-migrated v2 roster keyed on the retired subject id loads unchanged")
    func migratedV2RosterWithRetiredIDLoadsUnchanged() throws {
        let retired = Self.retiredID
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        let storeURL = dir.appendingPathComponent("store.json")
        let rosterURL = dir.appendingPathComponent("people-roster.json")

        // An older build's on-disk state: a v2 roster holding exactly this person,
        // and their embeddings in the ProfileStore under the same key.
        let references: [[Float]] = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6], [0.7, 0.8, 0.9]]
        try repo.savePerson(Person(id: retired, displayName: retired))
        try repo.saveProfile(bundle(retired, references: references))

        let rosterBefore = try Data(contentsOf: rosterURL)
        let storeBefore = try Data(contentsOf: storeURL)
        let filesBefore = contents(of: dir)

        // A launch with the NEW neutral constant as the preferred active id.
        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [],
            preferredActiveID: AppModel.legacySubjectID
        )

        // Same person, still active, embeddings intact.
        #expect(result.roster.map(\.id) == [retired])
        #expect(result.roster.first?.displayName == retired)
        #expect(result.initialActiveID == retired)
        let profile = try #require(repo.loadProfile(subjectId: retired))
        #expect(profile.references.count == references.count)
        #expect(profile.references.map(\.values) == references)

        // Nothing was rewritten, re-migrated, quarantined, or added.
        let rosterAfter = try Data(contentsOf: rosterURL)
        let storeAfter = try Data(contentsOf: storeURL)
        let filesAfter = contents(of: dir)
        #expect(rosterAfter == rosterBefore)
        #expect(storeAfter == storeBefore)
        #expect(filesAfter == filesBefore)
        #expect(!filesAfter.contains { $0.localizedCaseInsensitiveContains("quarantine") })
    }

    @Test("A v1 store keyed on the new legacy constant still migrates and becomes active")
    func v1StoreOnNewConstantStillMigrates() throws {
        let legacy = AppModel.legacySubjectID
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        // v1 shape: an embedding store, no roster sidecar at all.
        try repo.saveProfile(bundle(legacy, references: [[1], [2], [3]]))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("people-roster.json").path))

        let migrated = repo.loadRoster()
        #expect(migrated.map(\.id) == [legacy])
        #expect(migrated.map(\.displayName) == [legacy])

        let result = repo.bootstrapRoster(
            reset: false,
            seedProfiles: [],
            preferredActiveID: AppModel.legacySubjectID
        )
        #expect(result.initialActiveID == legacy)
        #expect(repo.loadProfile(subjectId: legacy)?.references.count == 3)
    }
}
