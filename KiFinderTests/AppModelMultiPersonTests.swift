import Foundation
import KionEngine
@testable import KiFinder
import Testing

/// Coverage for the multi-person plumbing on `AppModel`: the seed hook lands the
/// legacy-subject person (roster + bundle), migration makes the single person the
/// default active one, and add/select/rename/delete behave. Each test isolates its
/// store via `KION_PROFILE_STORE` in a fresh temp directory.
@Suite("App model multi-person")
@MainActor
struct AppModelMultiPersonTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-appmodel-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func makeModel(_ store: URL, extra: [String: String] = [:]) -> AppModel {
        var environment = ["KION_PROFILE_STORE": store.path]
        environment.merge(extra) { _, new in new }
        return AppModel(engine: SampleTriageEngine(), environment: environment)
    }

    // MARK: - Backward-compat (assertion 7)

    @Test("KION_SEED_PROFILE enrolls the legacy subject in the roster + bundle and makes it active")
    func seedProfilePopulatesRosterAndBundle() {
        let model = makeModel(uniqueStore(), extra: ["KION_SEED_PROFILE": "1", "KION_RESET": "1"])

        let legacy = AppModel.legacySubjectID
        #expect(model.people.contains { $0.id == legacy && $0.displayName == legacy })
        #expect(model.activePersonID == legacy)
        #expect(model.enrolledReferenceCount == 5)
    }

    @Test("Seed profile calibration is sourced from FaceModelDescriptor.arcface (item 66)")
    func seedProfileCalibrationMatchesDescriptor() {
        let model = makeModel(uniqueStore(), extra: ["KION_SEED_PROFILE": "1", "KION_RESET": "1"])
        let calibration = FaceModelDescriptor.arcface.calibration

        let bundle = model.enrolledProfile
        #expect(bundle?.threshold == calibration.defaultThreshold)
        #expect(bundle?.maybeMargin == calibration.maybeMargin)
        #expect(bundle?.negativeMargin == calibration.negativeMargin)
    }

    @Test("Migration makes the single migrated person the default active person")
    func migrationDefaultsActivePerson() throws {
        let store = uniqueStore()
        // Pre-seed a legacy single-subject (v1) store with no roster.
        let legacy = AppModel.legacySubjectID
        let repo = FileProfileRepository(storeURL: store)
        try repo.saveProfile(
            ProfileBundle(
                subjectId: legacy,
                references: (1 ... 5).map { FaceEmbedding([Float($0)]) },
                threshold: 0.45,
                modelId: FileProfileRepository.modelId,
                modelVersion: FileProfileRepository.modelVersion
            )
        )

        let model = makeModel(store)
        #expect(model.people.map(\.id) == [legacy])
        #expect(model.activePersonID == legacy)
        #expect(model.enrolledProfile?.references.count == 5)
    }

    @Test("Sample mode adds the second person to BOTH store and roster, even atop an existing v2 roster")
    func sampleModeReconcilesSecondPersonOntoExistingRoster() throws {
        let store = uniqueStore()
        // Simulate a user who already migrated to a v2 roster holding only Kris.
        let repo = FileProfileRepository(storeURL: store)
        try repo.savePerson(Person(id: "Kris", displayName: "Kris"))
        try repo.saveProfile(
            ProfileBundle(
                subjectId: "Kris",
                references: (1 ... 5).map { FaceEmbedding([Float($0)]) },
                threshold: 0.45,
                modelId: FileProfileRepository.modelId,
                modelVersion: FileProfileRepository.modelVersion
            )
        )
        #expect(repo.loadRoster().map(\.id) == ["Kris"])

        // Launching the sample demo must enroll Ava in the roster too, not only the
        // embedding store — the two must never drift.
        let model = makeModel(store, extra: ["KION_SAMPLE": "1"])
        #expect(Set(model.people.map(\.id)) == ["Kris", "Ava"])
        #expect(model.people.contains { $0.id == "Ava" && $0.displayName == "Ava" })

        // A fresh repository reading the persisted roster agrees (durable, not just in-memory).
        #expect(Set(FileProfileRepository(storeURL: store).loadRoster().map(\.id)) == ["Kris", "Ava"])
        // Default active stays Kris so the visible candidate set doesn't shift.
        #expect(model.activePersonID == "Kris")
    }

    // MARK: - Person management (assertion 6)

    @Test("addPerson creates a UUID-keyed person and makes them active")
    func addPersonActivates() {
        let model = makeModel(uniqueStore(), extra: ["KION_RESET": "1"])
        #expect(model.people.isEmpty)

        let person = model.addPerson(name: "Ava")
        #expect(UUID(uuidString: person.id) != nil)
        #expect(model.activePersonID == person.id)
        #expect(model.people.contains { $0.id == person.id && $0.displayName == "Ava" })
        // No bundle yet → not enrolled.
        #expect(model.enrolledProfile == nil)
    }

    @Test("selectPerson switches the active person and derived profile")
    func selectPersonSwitches() throws {
        let store = uniqueStore()
        // Two enrolled people on disk.
        let repo = FileProfileRepository(storeURL: store)
        try repo.savePerson(Person(id: "p1", displayName: "Ava"))
        try repo.savePerson(Person(id: "p2", displayName: "Kris"))
        try repo.saveProfile(
            ProfileBundle(
                subjectId: "p2",
                references: (1 ... 3).map { FaceEmbedding([Float($0)]) },
                threshold: 0.45,
                modelId: FileProfileRepository.modelId,
                modelVersion: FileProfileRepository.modelVersion
            )
        )

        let model = makeModel(store)
        model.selectPerson(id: "p2")
        #expect(model.activePersonID == "p2")
        #expect(model.enrolledReferenceCount == 3)

        model.selectPerson(id: "p1")
        #expect(model.activePersonID == "p1")
        #expect(model.enrolledProfile == nil)

        // Unknown id is a no-op.
        model.selectPerson(id: "nope")
        #expect(model.activePersonID == "p1")
    }

    @Test("renamePerson updates the display name in the roster")
    func renamePersonUpdates() {
        let model = makeModel(uniqueStore(), extra: ["KION_RESET": "1"])
        let person = model.addPerson(name: "Ava")

        model.renamePerson(id: person.id, to: "Ava B.")
        #expect(model.people.first { $0.id == person.id }?.displayName == "Ava B.")
    }

    @Test("deletePerson removes the person and falls back to another active person")
    func deletePersonFallsBack() {
        let model = makeModel(uniqueStore(), extra: ["KION_RESET": "1"])
        let ava = model.addPerson(name: "Ava")
        let kai = model.addPerson(name: "Kai")
        #expect(model.activePersonID == kai.id)

        model.deletePerson(id: kai.id)
        #expect(!model.people.contains { $0.id == kai.id })
        #expect(model.activePersonID == ava.id)
    }

    // MARK: - Item 57: simultaneous quarantine notices are all queued, not dropped

    /// A fresh temp library root (for `KION_LIBRARY_ROOT`), distinct from `uniqueStore()`'s
    /// profile-store directory, so the kept-index lives at its own `library-index.json`.
    private func uniqueLibraryRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-appmodel-tests-lib")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("two stores corrupt at once (roster + skip-store): BOTH get their own one-time notice, neither dropped")
    func twoSimultaneousQuarantinesAreBothQueued() throws {
        let store = uniqueStore()
        let dir = store.deletingLastPathComponent()
        let rosterURL = dir.appendingPathComponent("people-roster.json")
        let skipURL = dir.appendingPathComponent("skipped-index.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: rosterURL)
        try garbage.write(to: skipURL)

        // The kept-index is NOT corrupted here, so exactly 2 of the 3 stores quarantine —
        // proving this isn't just "always all 3" or "always the first 2" coincidentally.
        let model = makeModel(store, extra: ["KION_SKIPPED_STORE": skipURL.path])

        #expect(model.dataIntegrityNotices.count == 2)
        let first = try #require(model.dataIntegrityNotice)
        #expect(first.localizedCaseInsensitiveContains("people"))

        // Dismissing the first must NOT silently discard the second — the old
        // `roster ?? kept ?? skip` coalescing would have dropped it entirely by
        // never recording it in the first place.
        model.clearDataIntegrityNotice()
        let second = try #require(model.dataIntegrityNotice)
        #expect(second.localizedCaseInsensitiveContains("skip"))
        #expect(second != first)

        // Each notice is shown EXACTLY once: after both are dismissed, the queue is
        // empty (no third phantom notice, no re-showing either of the first two).
        model.clearDataIntegrityNotice()
        #expect(model.dataIntegrityNotices.isEmpty)
        #expect(model.dataIntegrityNotice == nil)
    }

    @Test("all three stores corrupt at once: all three get their own one-time notice, in store order, none dropped")
    func threeSimultaneousQuarantinesAreAllQueued() throws {
        let store = uniqueStore()
        let dir = store.deletingLastPathComponent()
        let rosterURL = dir.appendingPathComponent("people-roster.json")
        let skipURL = dir.appendingPathComponent("skipped-index.json")
        let libraryRoot = uniqueLibraryRoot()
        let indexURL = libraryRoot.appendingPathComponent("library-index.json")
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: rosterURL)
        try garbage.write(to: skipURL)
        try garbage.write(to: indexURL)

        let model = makeModel(store, extra: [
            "KION_SKIPPED_STORE": skipURL.path,
            "KION_LIBRARY_ROOT": libraryRoot.path,
        ])

        #expect(model.dataIntegrityNotices.count == 3)
        let notices = model.dataIntegrityNotices
        // Store order: roster, kept-index, skip-store.
        #expect(notices[0].localizedCaseInsensitiveContains("people"))
        #expect(notices[1].localizedCaseInsensitiveContains("photo"))
        #expect(notices[2].localizedCaseInsensitiveContains("skip"))
        // No two distinct stores collapsed onto the same message.
        #expect(Set(notices).count == 3)

        // Popping walks through all three IN ORDER, each exactly once, then empties —
        // proving the queue (not a `??` chain that only ever surfaces the first).
        #expect(model.dataIntegrityNotice == notices[0])
        model.clearDataIntegrityNotice()
        #expect(model.dataIntegrityNotice == notices[1])
        model.clearDataIntegrityNotice()
        #expect(model.dataIntegrityNotice == notices[2])
        model.clearDataIntegrityNotice()
        #expect(model.dataIntegrityNotice == nil)
        #expect(model.dataIntegrityNotices.isEmpty)
    }
}

/// Coverage for item 4's person-aware Review: candidate lists/counts filter to the
/// active person (with a `nil`-active fallback that shows all), switching people
/// re-filters and re-seats keyboard focus, `activePersonName` drives person-aware
/// copy (with a neutral fallback), and `presentEnrollment(personID:)` targets a
/// fresh id for a new person vs. the existing id (name prefilled) for a re-enroll.
@Suite("App model review filtering")
@MainActor
struct AppModelReviewFilteringTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-review-filter-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// A sample-mode model: both people (Kris + Ava) enrolled, Kris active, and the
    /// four sample candidates loaded (two attributed to each person).
    private func sampleModel() -> AppModel {
        AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    /// A model with no active person (empty reset roster), injected sample engine.
    private func neutralModel() -> AppModel {
        AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_RESET": "1"]
        )
    }

    // MARK: - (a) Filtering by active person + switching

    @Test("Active person's candidate lists/counts include only their candidates")
    func filtersToActivePerson() {
        let model = sampleModel()
        #expect(model.activePersonID == SampleTriageEngine.primarySubjectID) // Kris

        // Kris owns sample-keep-1 + sample-maybe-1, PLUS the both-people group photo
        // sample-both-1 (a maybe for both Kris and Ava — item 6).
        #expect(model.keepCandidates == ["sample-keep-1"])
        #expect(model.maybeCandidates == ["sample-maybe-1", "sample-both-1"])
        #expect(model.keepCount == 1)
        #expect(model.maybeCount == 2)
        #expect(model.keepCandidateDetails.map(\.id) == ["sample-keep-1"])
        #expect(model.maybeCandidateDetails.map(\.id) == ["sample-maybe-1", "sample-both-1"])
    }

    @Test("Switching the active person re-filters the grid and re-seats focus")
    func switchingRefiltersAndReseatsFocus() {
        let model = sampleModel()
        // Focus starts on Kris's first candidate.
        #expect(model.focusedID == "sample-keep-1")

        model.selectPerson(id: SampleTriageEngine.secondarySubjectID) // Ava
        #expect(model.activePersonID == "Ava")
        // Ava owns sample-keep-2 + sample-maybe-2, PLUS the both-people group photo
        // sample-both-1 (a maybe for Ava too — item 6).
        #expect(model.keepCandidates == ["sample-keep-2"])
        #expect(model.maybeCandidates == ["sample-maybe-2", "sample-both-1"])
        #expect(model.keepCount == 1)
        #expect(model.maybeCount == 2)
        // Focus re-seated onto the first candidate of the new (Ava) set.
        #expect(model.focusedID == "sample-keep-2")
    }

    @Test("nil-active fallback shows every candidate (injected engine, no active person)")
    func nilActiveShowsAll() {
        let model = neutralModel()
        #expect(model.activePersonID == nil)
        #expect(model.keepCandidates == ["sample-keep-1", "sample-keep-2"])
        // The both-people group photo (item 6) is a maybe headline bucket, so it
        // joins the nil-active "show all" maybe set.
        #expect(model.maybeCandidates == ["sample-maybe-1", "sample-maybe-2", "sample-both-1"])
        #expect(model.keepCount == 2)
        #expect(model.maybeCount == 3)
    }

    @Test("A brand-new person sees every scanned photo in The rest (empty state means no scan, not no matches)")
    func activePersonWithNoCandidatesIsEmpty() {
        let model = sampleModel()
        #expect(model.hasCandidates)
        let newcomer = model.addPerson(name: "Cleo")
        model.selectPerson(id: newcomer.id)

        #expect(model.activePersonID == newcomer.id)
        // Cleo has no matches of her own, so her keep/maybe stay empty…
        #expect(model.keepCount == 0)
        #expect(model.maybeCount == 0)
        // …but item 7 makes every scanned photo visible under every person: Cleo
        // sees all four sample photos in "The rest", so she HAS candidates. The
        // empty state now means "no scan yet", not "no matches for this person".
        #expect(model.hasCandidates)
        #expect(model.otherCandidates.count == model.orderedCount)
        #expect(model.otherCandidates.contains("sample-keep-1"))
        #expect(model.otherCandidates.contains("sample-keep-2"))
    }

    @Test("No-match photos (The rest) stay visible for every active person")
    func noMatchRestVisibleForEveryPerson() {
        // A scanned photo that matched nobody: bucket .other, no attribution.
        let rest = Candidate(
            id: "sample-other-1",
            photoKey: "sample/no-match.png",
            fileName: "IMG_1999.PNG",
            imageResourceName: "sample-maybe-01",
            score: 0.12,
            bucket: .other,
            matchedSubjectID: nil,
            subjectScores: ["Kris": 0.12, "Ava": 0.10]
        )
        let model = AppModel(
            engine: SampleTriageEngine(additionalCandidates: [rest]),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )

        // Kris active: "The rest" includes the unattributed photo (nothing hidden).
        #expect(model.activePersonID == "Kris")
        #expect(model.otherCandidates.contains("sample-other-1"))
        // Switching people keeps the no-match photo in their "The rest" too.
        model.selectPerson(id: SampleTriageEngine.secondarySubjectID)
        #expect(model.otherCandidates.contains("sample-other-1"))
    }

    // MARK: - (b) activePersonName / neutral fallback

    @Test("activePersonName follows the active person, nil when none is active")
    func activePersonNameFollowsActive() {
        let model = sampleModel()
        #expect(model.activePersonName == "Kris")

        model.selectPerson(id: SampleTriageEngine.secondarySubjectID)
        #expect(model.activePersonName == "Ava")

        let neutral = neutralModel()
        #expect(neutral.activePersonID == nil)
        #expect(neutral.activePersonName == nil)
    }

    @Test("Renaming the active person updates activePersonName")
    func renameUpdatesActivePersonName() {
        let model = sampleModel()
        model.renamePerson(id: SampleTriageEngine.primarySubjectID, to: "Rae")
        #expect(model.activePersonName == "Rae")
    }

    // MARK: - (c) presentEnrollment new vs. re-enroll target

    @Test("Re-enroll targets the existing id with the name prefilled")
    func reEnrollTargetsExistingIDWithName() {
        let model = sampleModel()
        model.presentEnrollment(personID: SampleTriageEngine.primarySubjectID)

        let enrollment = model.enrollmentModel
        #expect(model.isEnrollmentPresented)
        #expect(enrollment?.subjectId == "Kris")
        #expect(enrollment?.displayName == "Kris")
    }

    @Test("New-person enrollment targets a fresh UUID id with an empty name prefill")
    func newPersonTargetsFreshIDWithEmptyName() throws {
        let model = sampleModel()
        let existingIDs = Set(model.people.map(\.id))

        model.presentEnrollment(personID: nil)
        let enrollment = try #require(model.enrollmentModel)
        #expect(model.isEnrollmentPresented)
        // A brand-new, previously-unused UUID id…
        #expect(UUID(uuidString: enrollment.subjectId) != nil)
        #expect(!existingIDs.contains(enrollment.subjectId))
        // …with no prefilled name.
        #expect(enrollment.displayName == "")
    }

    @Test("beginAddPerson starts a brand-new person enrollment")
    func beginAddPersonStartsNewPerson() {
        let model = sampleModel()
        model.beginAddPerson()
        let enrollment = model.enrollmentModel
        #expect(model.isEnrollmentPresented)
        #expect(UUID(uuidString: enrollment?.subjectId ?? "") != nil)
        #expect(enrollment?.displayName == "")
    }

    // MARK: - (d) mandatory-enrollment gate (no-cancel onboarding)

    @Test("Enrollment is mandatory on first run, when no one is enrolled yet")
    func enrollmentMandatoryOnFirstRun() {
        let model = neutralModel()
        #expect(model.people.isEmpty)
        #expect(model.isEnrollmentMandatory)
    }

    @Test("Enrollment is not mandatory once at least one person is enrolled")
    func enrollmentNotMandatoryWithPeople() {
        let model = sampleModel()
        #expect(!model.people.isEmpty)
        #expect(!model.isEnrollmentMandatory)
    }

    @Test("Deleting the last person re-opens enrollment and makes it mandatory again")
    func enrollmentMandatoryAfterDeletingLastPerson() {
        let model = sampleModel()
        #expect(!model.isEnrollmentMandatory)

        for id in model.people.map(\.id) {
            model.deletePerson(id: id)
        }

        #expect(model.people.isEmpty)
        #expect(model.isEnrollmentMandatory)
        // Item 51: the sheet is re-presented, and now it can't be cancelled away.
        #expect(model.isEnrollmentPresented)
    }
}

/// Coverage for item 6's per-person bucketing (multi-home group photos): a photo
/// appears under EVERY person it matched, in *that person's own* bucket, each
/// boxing their own face; keep/skip is scoped per person (each person's review is
/// independent); and no-match "The rest" stays visible to everyone while a photo
/// matching only another person stays hidden.
@Suite("App model per-person bucketing")
@MainActor
struct AppModelPerPersonBucketingTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-per-person-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    /// Sample mode (Kris + Ava enrolled, Kris active) with `extra` appended to the
    /// default sample candidates.
    private func makeModel(extra: [Candidate] = []) -> AppModel {
        AppModel(
            engine: SampleTriageEngine(additionalCandidates: extra),
            environment: ["KION_PROFILE_STORE": uniqueStore().path, "KION_SAMPLE": "1"]
        )
    }

    /// A two-person group photo: `keep` for Kris and `maybe` for Ava, each matching
    /// a different detected face — so it lands in DIFFERENT buckets per person.
    private func groupPhoto(id: String = "group-1") -> Candidate {
        Candidate(
            id: id,
            photoKey: "sample/\(id).png",
            fileName: "GROUP_\(id).PNG",
            imageResourceName: "sample-keep-01",
            score: 0.90,
            bucket: .keep,
            faceBoxes: [
                CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2),
                CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.2),
            ],
            selectedFaceIndex: 0,
            matchedSubjectID: "Kris",
            subjectScores: ["Kris": 0.90, "Ava": 0.62],
            subjectBuckets: ["Kris": .keep, "Ava": .maybe],
            selectedFaceIndexBySubject: ["Kris": 0, "Ava": 1]
        )
    }

    // MARK: - Assertion 3: appears under BOTH people, each in their own bucket

    @Test("A two-person photo appears under both people in each person's own bucket")
    func twoPersonPhotoUnderBoth() {
        let model = makeModel(extra: [groupPhoto()])

        // Kris active: the group photo is in Kris's "Found matches" (keep).
        #expect(model.activePersonID == "Kris")
        #expect(model.keepCandidates.contains("group-1"))
        #expect(!model.maybeCandidates.contains("group-1"))
        #expect(model.state(for: "group-1") == .keep)

        // Ava: the SAME photo is in Ava's "Worth a look" (maybe), not keep.
        model.selectPerson(id: "Ava")
        #expect(model.maybeCandidates.contains("group-1"))
        #expect(!model.keepCandidates.contains("group-1"))
        #expect(model.state(for: "group-1") == .maybe)
    }

    // MARK: - Assertion 7: per-person face box

    @Test("Each person's candidate boxes their own matched face")
    func perPersonFaceBox() {
        let model = makeModel(extra: [groupPhoto()])
        #expect(model.candidate(for: "group-1")?.selectedFaceIndex == 0) // Kris's face
        model.selectPerson(id: "Ava")
        #expect(model.candidate(for: "group-1")?.selectedFaceIndex == 1) // Ava's face
    }

    // MARK: - Assertion 4: per-person sectioning counts

    @Test("Per-person counts reflect each person's own buckets, not one global bucket")
    func perPersonCounts() {
        let model = makeModel(extra: [groupPhoto()])
        // Kris: keep = sample-keep-1 + group-1; maybe = sample-maybe-1 + sample-both-1.
        #expect(model.keepCount == 2)
        #expect(model.maybeCount == 2)

        model.selectPerson(id: "Ava")
        // Ava: keep = sample-keep-2; maybe = sample-maybe-2 + sample-both-1 + group-1.
        #expect(model.keepCount == 1)
        #expect(model.maybeCount == 3)
    }

    // MARK: - Assertion 5: keep/skip is per person (reviews are independent)

    @Test("A keep/skip under one person never disturbs another person's review")
    func decisionIsPerPerson() throws {
        let model = makeModel(extra: [groupPhoto()])

        // Skip the group photo while Kris is active.
        let candidate = try #require(model.candidate(for: "group-1"))
        model.skip(candidate)
        #expect(model.state(for: "group-1") == .skipped)
        #expect(!model.keepCandidates.contains("group-1"))

        // Ava's review is INDEPENDENT: the photo is still her own maybe, not skipped.
        model.selectPerson(id: "Ava")
        #expect(model.state(for: "group-1") == .maybe)
        #expect(model.maybeCandidates.contains("group-1"))

        // Kris's skip is intact when switching back.
        model.selectPerson(id: "Kris")
        #expect(model.state(for: "group-1") == .skipped)
    }

    @Test("Export set is the active person's own kept photos; decisions don't cross people")
    func exportSetPerActivePerson() throws {
        let model = makeModel(extra: [groupPhoto()])

        // group-1 is Kris's keep by default → in Kris's export set.
        #expect(model.keepCandidateDetails.contains { $0.id == "group-1" })

        // Ava sees it as a maybe (not kept) → NOT in Ava's export set yet.
        model.selectPerson(id: "Ava")
        #expect(!model.keepCandidateDetails.contains { $0.id == "group-1" })

        // Keeping under Ava adds it to Ava's export set…
        let avaView = try #require(model.candidate(for: "group-1"))
        model.keep(avaView)
        #expect(model.keepCandidateDetails.contains { $0.id == "group-1" })

        // …but does NOT change Kris's review — Kris still has her own (default) keep.
        model.selectPerson(id: "Kris")
        #expect(model.keepCandidateDetails.contains { $0.id == "group-1" })

        // Idempotent + reversible within Kris's own scope.
        let kionView = try #require(model.candidate(for: "group-1"))
        let kept = model.keepCount
        model.keep(kionView)
        #expect(model.keepCount == kept)
        model.skip(kionView)
        #expect(model.state(for: "group-1") == .skipped)

        // Ava's keep is untouched by Kris's skip.
        model.selectPerson(id: "Ava")
        #expect(model.state(for: "group-1") == .keep)
    }

    // MARK: - Assertion 2 & 3 (item 7): "The rest" preserved; Y-only photo now IN X's rest

    @Test("No-match photo shows in everyone's rest; a photo matching only Y now lands in X's rest")
    func restPreservedAndYOnlyHidden() {
        // A scanned photo that matched nobody.
        let noMatch = Candidate(
            id: "no-match-1",
            photoKey: "sample/no-match.png",
            fileName: "NM.PNG",
            imageResourceName: "sample-maybe-01",
            score: 0.10,
            bucket: .other,
            matchedSubjectID: nil,
            subjectScores: ["Kris": 0.10, "Ava": 0.09],
            subjectBuckets: ["Kris": .other, "Ava": .other]
        )
        let model = makeModel(extra: [noMatch])

        // Item 7 REVERSES item-6's "a photo matching only Y is hidden from X": the
        // Ava-only photo (sample-keep-2) is now in Kris's "The rest", alongside the
        // no-match photo. Nothing scanned is hidden from anyone.
        #expect(model.otherCandidates.contains("no-match-1"))
        #expect(model.otherCandidates.contains("sample-keep-2"))

        // Ava: no-match still in The rest, and the Kris-only photo (sample-keep-1)
        // now appears in Ava's "The rest" too.
        model.selectPerson(id: "Ava")
        #expect(model.otherCandidates.contains("no-match-1"))
        #expect(model.otherCandidates.contains("sample-keep-1"))
    }

    // MARK: - Assertion 2 & 4 (item 7): Y's matches in X's rest, X's keep/maybe unchanged

    @Test("Other person's matches appear in X's rest while X's keep/maybe stay unchanged — both ways")
    func otherPersonMatchesInRestKeepMaybeUnchanged() {
        let model = makeModel()

        // Kris active (item-6 baseline): keep = sample-keep-1, maybe = sample-maybe-1
        // + the both-people group photo. These are UNCHANGED by item 7.
        #expect(model.keepCandidates == ["sample-keep-1"])
        #expect(model.maybeCandidates == ["sample-maybe-1", "sample-both-1"])
        // Ava's own keep/maybe matches now appear in Kris's "The rest"…
        #expect(model.otherCandidates.contains("sample-keep-2"))
        #expect(model.otherCandidates.contains("sample-maybe-2"))
        // …but never leak into Kris's keep/maybe, and the group photo is NOT
        // duplicated into the rest (it's Kris's own maybe).
        #expect(!model.keepCandidates.contains("sample-keep-2"))
        #expect(!model.maybeCandidates.contains("sample-maybe-2"))
        #expect(!model.otherCandidates.contains("sample-both-1"))

        // Symmetric for Ava: keep = sample-keep-2, maybe = sample-maybe-2 + group.
        model.selectPerson(id: "Ava")
        #expect(model.keepCandidates == ["sample-keep-2"])
        #expect(model.maybeCandidates == ["sample-maybe-2", "sample-both-1"])
        // Kris's own matches now show in Ava's "The rest".
        #expect(model.otherCandidates.contains("sample-keep-1"))
        #expect(model.otherCandidates.contains("sample-maybe-1"))
        #expect(!model.keepCandidates.contains("sample-keep-1"))
        #expect(!model.maybeCandidates.contains("sample-maybe-1"))
        #expect(!model.otherCandidates.contains("sample-both-1"))
    }

    // MARK: - Assertion 5: a photo is never in two sections for one person

    @Test("Every visible photo is in exactly one section for the active person")
    func everyPhotoInExactlyOneSection() {
        let model = makeModel(extra: [groupPhoto()])
        for person in ["Kris", "Ava"] {
            model.selectPerson(id: person)
            let sections = [
                model.keepCandidates,
                model.maybeCandidates,
                model.otherCandidates,
                model.skippedCandidates,
            ]
            let all = sections.flatMap { $0 }
            // No id appears in two sections, and the union covers every visible photo.
            #expect(Set(all).count == all.count)
            #expect(all.count == model.orderedCount)
        }
    }

    // MARK: - Assertion 8: keyboard decision on an other-person rest photo is recorded under X only

    @Test("Skipping an other-person rest photo via the keyboard records under X only and advances focus")
    func skipOtherPersonRestPhotoRecordsUnderXAndAdvancesFocus() throws {
        let model = makeModel()
        // Kris active: sample-keep-2 is Ava's KEEP, now visible in Kris's "The rest".
        // We SKIP it (skip ≠ Ava's keep baseline) so a cross-person leak would be
        // detectable, and we drive it through the focus-advancing keyboard path.
        #expect(model.otherCandidates.contains("sample-keep-2"))

        // decideFocused advances focus over `maybeCandidates + otherCandidates`,
        // snapshotted BEFORE the decision. Compute the expected next id from that
        // queue, and require the skipped photo is NOT last so focus actually moves.
        let reviewQueue = model.maybeCandidates + model.otherCandidates
        let skipIndex = try #require(reviewQueue.firstIndex(of: "sample-keep-2"))
        #expect(skipIndex + 1 < reviewQueue.count)
        let expectedNext = reviewQueue[skipIndex + 1]

        model.focusedID = "sample-keep-2"
        model.skipFocused()

        // (a) Focus advanced deterministically to the next still-to-review photo.
        #expect(model.focusedID == expectedNext)
        // (b) The skip is recorded under Kris: state is .skipped and it leaves the rest.
        #expect(model.state(for: "sample-keep-2") == .skipped)
        #expect(!model.otherCandidates.contains("sample-keep-2"))

        // No cross-person leak: Ava STILL sees it as her KEEP, not .skipped. Because
        // skip ≠ keep, this genuinely proves Kris's decision did not bleed into Ava's.
        model.selectPerson(id: "Ava")
        #expect(model.state(for: "sample-keep-2") == .keep)
        #expect(model.keepCandidates.contains("sample-keep-2"))
    }
}
