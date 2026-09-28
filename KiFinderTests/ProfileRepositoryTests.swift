import Foundation
import KionEngine
@testable import KiFinder
import Testing

/// Coverage for the multi-person data substrate: legacy-store migration,
/// `savePerson` round-trips, complete `deletePerson`, the thumbnail seam, and the
/// versioned roster sidecar. Each test uses its own unique temp directory so the
/// suite passes in any order.
@Suite("Profile repository (roster + thumbnails)")
@MainActor
struct ProfileRepositoryTests {
    // MARK: - Fixtures

    /// The on-disk subject id a v1 (single-person) store was written with — the one
    /// value the roster migration keys on.
    private let legacyID = AppModel.legacySubjectID

    private func uniqueDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-repo-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepository(in dir: URL) -> FileProfileRepository {
        FileProfileRepository(storeURL: dir.appendingPathComponent("store.json"))
    }

    private func bundle(subjectId: String, references: Int) -> ProfileBundle {
        ProfileBundle(
            subjectId: subjectId,
            references: (1 ... references).map { FaceEmbedding([Float($0)]) },
            threshold: 0.45,
            maybeMargin: 0.20,
            modelId: FileProfileRepository.modelId,
            modelVersion: FileProfileRepository.modelVersion
        )
    }

    private func rosterURL(in dir: URL) -> URL {
        dir.appendingPathComponent("people-roster.json")
    }

    // MARK: - Migration (assertion 3 / 9a)

    @Test("Migration synthesizes one named person from a legacy single-subject store without dropping the bundle")
    func migrationFromLegacyStore() throws {
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        let legacy = bundle(subjectId: legacyID, references: 5)
        try repo.saveProfile(legacy)

        // No roster file yet — first load migrates.
        #expect(!FileManager.default.fileExists(atPath: rosterURL(in: dir).path))

        let people = repo.loadRoster()
        #expect(people.count == 1)
        #expect(people.first?.id == legacyID)
        #expect(people.first?.displayName == legacyID)

        // The store + its legacy bundle are untouched by migration.
        let after = try #require(repo.loadProfile(subjectId: legacyID))
        #expect(after == legacy)
    }

    @Test("Migration writes a schemaVersion: 2 roster sidecar")
    func migrationWritesSchemaVersionTwo() throws {
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        try repo.saveProfile(bundle(subjectId: legacyID, references: 5))
        _ = repo.loadRoster()

        let data = try Data(contentsOf: rosterURL(in: dir))
        let roster = try JSONDecoder().decode(PersonRoster.self, from: data)
        #expect(roster.schemaVersion == 2)
        #expect(roster.people.map(\.id) == [legacyID])
    }

    @Test("Clean first load (no store) yields an empty roster")
    func cleanFirstLoadIsEmpty() {
        let repo = makeRepository(in: uniqueDir())
        #expect(repo.loadRoster().isEmpty)
    }

    // MARK: - savePerson round-trip (assertion 9b)

    @Test("savePerson round-trips through a fresh repository")
    func savePersonRoundTrips() throws {
        let dir = uniqueDir()
        let writer = makeRepository(in: dir)
        let person = Person(id: UUID().uuidString, displayName: "Ava", thumbnailFileName: "ava.png")
        try writer.savePerson(person)

        // A brand-new repository over the same store reads the persisted roster.
        let reader = makeRepository(in: dir)
        let loaded = try #require(reader.loadRoster().first { $0.id == person.id })
        #expect(loaded.displayName == "Ava")
        #expect(loaded.thumbnailFileName == "ava.png")
    }

    @Test("savePerson upserts an existing person rather than duplicating")
    func savePersonUpserts() throws {
        let repo = makeRepository(in: uniqueDir())
        var person = Person(id: "p1", displayName: "Ava")
        try repo.savePerson(person)
        person.displayName = "Ava B."
        try repo.savePerson(person)

        let people = repo.loadRoster().filter { $0.id == "p1" }
        #expect(people.count == 1)
        #expect(people.first?.displayName == "Ava B.")
    }

    // MARK: - deletePerson completeness (assertion 5 / 9c)

    @Test("deletePerson removes the roster entry, the bundle, and the thumbnail")
    func deletePersonIsComplete() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "p1", displayName: "Ava"))
        try repo.saveProfile(bundle(subjectId: "p1", references: 5))
        let thumbnail = try repo.saveThumbnail(Data([0x89, 0x50, 0x4E, 0x47]), for: "p1")
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))

        try repo.deletePerson(id: "p1")

        #expect(!repo.loadRoster().contains { $0.id == "p1" })
        #expect(repo.loadProfile(subjectId: "p1") == nil)
        #expect(repo.thumbnailURL(for: "p1") == nil)
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
    }

    @Test("deletePerson leaves other people and their bundles intact")
    func deletePersonScoped() throws {
        let repo = makeRepository(in: uniqueDir())
        try repo.savePerson(Person(id: "p1", displayName: "Ava"))
        try repo.savePerson(Person(id: "p2", displayName: "Kris"))
        try repo.saveProfile(bundle(subjectId: "p2", references: 4))

        try repo.deletePerson(id: "p1")

        #expect(repo.loadRoster().map(\.id) == ["p2"])
        #expect(repo.loadProfile(subjectId: "p2")?.references.count == 4)
    }

    // MARK: - Thumbnail seam (assertion 4)

    @Test("saveThumbnail writes under a thumbnails/ subdir and thumbnailURL resolves it")
    func thumbnailSeam() throws {
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        #expect(repo.thumbnailURL(for: "p1") == nil)

        let url = try repo.saveThumbnail(Data([0x1, 0x2, 0x3]), for: "p1")
        #expect(url.deletingLastPathComponent().lastPathComponent == "thumbnails")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().path == dir.path)
        #expect(repo.thumbnailURL(for: "p1") == url)
        #expect(try Data(contentsOf: url) == Data([0x1, 0x2, 0x3]))
    }

    // MARK: - Quarantine notice (item 57, assertion 4)

    @Test("a corrupt roster surfaces a plain-language notice once; a second repository over the same directory sees nothing to report")
    func rosterQuarantine_noticeOnceThenSilent() throws {
        let dir = uniqueDir()
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: rosterURL(in: dir))

        let repo = makeRepository(in: dir)
        #expect(repo.rosterQuarantineNotice == nil) // not yet loaded
        _ = repo.loadRoster()

        let notice = try #require(repo.rosterQuarantineNotice)
        // Plain language naming what was set aside — no implementation jargon.
        #expect(notice.localizedCaseInsensitiveContains("people"))
        #expect(!notice.localizedCaseInsensitiveContains("json"))
        #expect(!notice.localizedCaseInsensitiveContains("decode"))

        // The SAME repository doesn't re-report on a second load (the corrupt
        // bytes are gone from `rosterURL`; nothing left to quarantine).
        _ = repo.loadRoster()
        #expect(repo.rosterQuarantineNotice == notice)

        // A FRESH repository over the same directory — the "next app launch" case
        // — finds no corrupt file either, so it never nags.
        let reopened = makeRepository(in: dir)
        _ = reopened.loadRoster()
        #expect(reopened.rosterQuarantineNotice == nil)
    }

    // MARK: - Item 58: truthful, unified model stamp + lossless legacy migration

    /// The user story this item fixes: a store written before the app's stamp was
    /// corrected must still load with every taught face intact, and self-heal to
    /// the canonical stamp — never silently read as empty.
    @Test("A legacy-stamped (\"kion-local-enroll\") on-disk store loads through the repository without losing its taught data, and self-heals to canonical")
    func legacyStoreLoadsThroughRepositoryWithoutDataLoss() throws {
        let dir = uniqueDir()
        let storeURL = dir.appendingPathComponent("store.json")
        let legacyBundle = ProfileBundle(
            subjectId: legacyID,
            references: [FaceEmbedding([0.1, 0.2, 0.3])],
            confirmedPositives: [FaceEmbedding([0.4, 0.5, 0.6])],
            negatives: [FaceEmbedding([0.7, 0.8, 0.9])],
            threshold: 0.42,
            maybeMargin: 0.13,
            negativeMargin: 0.02,
            modelId: "kion-local-enroll",
            modelVersion: "1"
        )
        let legacyStore = ProfileStore(modelId: "kion-local-enroll", modelVersion: "1", profiles: [legacyID: legacyBundle])
        try legacyStore.encode(to: storeURL)

        let repo = makeRepository(in: dir)
        let loaded = try #require(repo.loadProfile(subjectId: legacyID))
        #expect(loaded.references == legacyBundle.references)
        #expect(loaded.confirmedPositives == legacyBundle.confirmedPositives)
        #expect(loaded.negatives == legacyBundle.negatives)
        #expect(loaded.threshold == legacyBundle.threshold)
        #expect(loaded.maybeMargin == legacyBundle.maybeMargin)
        #expect(loaded.negativeMargin == legacyBundle.negativeMargin)
        #expect(loaded.modelId == FileProfileRepository.modelId)
        #expect(loaded.modelVersion == FileProfileRepository.modelVersion)

        // The roster derived from the store is non-empty — the overwrite-destroys-
        // legacy path (mismatch -> try? -> empty store -> fresh save) never fires.
        let roster = repo.loadRoster()
        #expect(!roster.isEmpty)
        #expect(roster.contains { $0.id == legacyID })

        // Self-heal: re-reading the RAW on-disk JSON shows the canonical stamp at
        // both store and bundle level, with the taught data intact.
        let rawData = try Data(contentsOf: storeURL)
        let rawStore = try JSONDecoder().decode(ProfileStore.self, from: rawData)
        #expect(rawStore.modelId == FileProfileRepository.modelId)
        #expect(rawStore.modelVersion == FileProfileRepository.modelVersion)
        let rawBundle = try #require(rawStore.profiles[legacyID])
        #expect(rawBundle.modelId == FileProfileRepository.modelId)
        #expect(rawBundle.modelVersion == FileProfileRepository.modelVersion)
        #expect(rawBundle.references == legacyBundle.references)
        #expect(rawBundle.confirmedPositives == legacyBundle.confirmedPositives)
        #expect(rawBundle.negatives == legacyBundle.negatives)

        // A second load re-reads the now-canonical file without rewriting it again.
        let secondLoad = try #require(repo.loadProfile(subjectId: legacyID))
        #expect(secondLoad == loaded)
    }

    /// Closes the data-loss chain directly: an existing-but-unloadable store file
    /// must surface its load error rather than be treated as "nothing there", so a
    /// subsequent `saveProfile` never atomically overwrites it with a fresh, empty
    /// store.
    @Test("An existing-but-unloadable store file surfaces its load error and is never overwritten by a subsequent saveProfile")
    func loadErrorOnExistingFileNeverOverwritesOnSave() throws {
        let dir = uniqueDir()
        let repo = makeRepository(in: dir)
        let storeURL = dir.appendingPathComponent("store.json")

        // A genuinely foreign stamp (NOT a recognized legacy alias) — the file
        // exists and decodes fine, but the model-stamp gate rejects it.
        let foreignBundle = ProfileBundle(
            subjectId: legacyID,
            references: [FaceEmbedding([0.1, 0.2, 0.3])],
            threshold: 0.5,
            modelId: "mobilefacenet",
            modelVersion: "1"
        )
        let foreignStore = ProfileStore(modelId: "mobilefacenet", modelVersion: "1", profiles: [legacyID: foreignBundle])
        try foreignStore.encode(to: storeURL)
        let originalBytes = try Data(contentsOf: storeURL)

        // `loadStore()` surfaces the error rather than quietly returning `nil`.
        #expect(throws: ModelVersionMismatchError.self) {
            _ = try repo.loadStore()
        }

        // A subsequent saveProfile must NOT fall back to a fresh, empty store and
        // clobber the on-disk (unloadable) data — it propagates the same failure.
        let newBundle = ProfileBundle(
            subjectId: "Ava",
            references: [FaceEmbedding([1, 0, 0])],
            threshold: 0.5,
            modelId: FileProfileRepository.modelId,
            modelVersion: FileProfileRepository.modelVersion
        )
        #expect(throws: ModelVersionMismatchError.self) {
            try repo.saveProfile(newBundle)
        }

        let afterBytes = try Data(contentsOf: storeURL)
        #expect(afterBytes == originalBytes)
    }

    /// The env var a cross-consumer verification run sets
    /// (`TEST_RUNNER_KION_TEST_STORE_PATH` at `xcodebuild test` time becomes
    /// `KION_TEST_STORE_PATH` in-process) — `nil` outside such a run, in which
    /// case the test below skips rather than failing.
    nonisolated static var cliStorePath: String? {
        ProcessInfo.processInfo.environment["KION_TEST_STORE_PATH"]
    }

    @Test(
        "The exact store file the CLI enrolled (KION_TEST_STORE_PATH) loads through FileProfileRepository with its subject present",
        .enabled(if: ProfileRepositoryTests.cliStorePath != nil)
    )
    func cliProducedStoreLoadsThroughRepository() throws {
        let path = try #require(ProfileRepositoryTests.cliStorePath)
        let repo = FileProfileRepository(storeURL: URL(fileURLWithPath: path))
        let store = try #require(try repo.loadStore())
        #expect(!store.profiles.isEmpty)
    }

    // MARK: - Quarantine collision (item 57, assertion 6)

    @Test("two quarantines forced to the same base name never overwrite each other")
    func quarantineCollision_neverOverwrites() throws {
        let dir = uniqueDir()
        let target = dir.appendingPathComponent("dummy.json")

        try Data("first-blob".utf8).write(to: target)
        let first = try DataQuarantine.quarantineUnreadable(at: target, token: "FIXED-TOKEN")

        try Data("second-blob".utf8).write(to: target)
        let second = try DataQuarantine.quarantineUnreadable(at: target, token: "FIXED-TOKEN")

        let firstURL = try #require(first)
        let secondURL = try #require(second)
        #expect(firstURL != secondURL)
        #expect(try Data(contentsOf: firstURL) == Data("first-blob".utf8))
        #expect(try Data(contentsOf: secondURL) == Data("second-blob".utf8))
    }
}
