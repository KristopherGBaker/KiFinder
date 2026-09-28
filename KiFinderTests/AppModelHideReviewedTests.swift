import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 48: the "Hide already reviewed" Review filter (default OFF, persisted) that, when
/// ON, hides photos the ACTIVE person already acted on — kept/skipped this session, kept
/// in a prior scan (library), or skipped in a prior scan (persistent skip store) — from
/// every review section, its counts, and keyboard nav.
@Suite("App model hide-already-reviewed (item 48)")
@MainActor
struct AppModelHideReviewedTests {
    private let kris = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID

    private func tempStore() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    private func realLibrary() -> KeptLibrary {
        KeptLibrary(
            root: LibraryFixtures.tempDir("root"),
            indexURL: LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        )
    }

    /// Sample-mode model (Kris active) with optional injected collaborators + extra
    /// source-backed candidates.
    private func model(
        candidates: [Candidate] = [],
        library: (any KeptLibrarySaving)? = nil,
        skipStore: (any SkipRecording)? = nil,
        defaults: UserDefaults? = nil
    ) -> AppModel {
        AppModel(
            engine: SampleTriageEngine(additionalCandidates: candidates),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": tempStore()],
            libraryDefaults: defaults ?? emptySuite(),
            keptLibrary: library ?? realLibrary(),
            skipStore: skipStore ?? SpySkipStore()
        )
    }

    /// A fresh, empty UserDefaults suite so the toggle's persisted value never leaks
    /// between tests or from `.standard`.
    private func emptySuite() -> UserDefaults {
        let name = "hide-reviewed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// A source-backed candidate (real bytes) so the library/skip-store paths engage.
    private func sourceCandidate(id: String, red: CGFloat) -> Candidate {
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("\(id).jpg")
        LibraryFixtures.writeImage(to: source, red: red)
        return LibraryFixtures.candidate(id: id, source: source, fileName: "\(id).jpg")
    }

    // MARK: - Assertion 1: default OFF preserves today's behavior

    @Test("default is OFF; acted-on photos stay visible when OFF")
    func defaultOffKeepsEverythingVisible() throws {
        let model = model()
        #expect(model.hideAlreadyReviewed == false)

        let baselineKeep = model.keepCount
        let baselineMaybe = model.maybeCount
        let baselineOrdered = model.orderedCount

        model.keep(try #require(model.candidate(for: "sample-keep-1")))
        model.skip(try #require(model.candidate(for: "sample-maybe-1")))

        #expect(model.keepCandidates.contains("sample-keep-1"))
        #expect(model.keepCandidateDetails.contains { $0.id == "sample-keep-1" })
        #expect(model.skippedCandidates.contains("sample-maybe-1"))
        // Kept/skipped photos stay counted + visible when OFF.
        #expect(model.keepCount == baselineKeep)
        #expect(model.maybeCount == baselineMaybe - 1) // sample-maybe-1 moved to skipped, still visible
        #expect(model.orderedCount == baselineOrdered)
    }

    // MARK: - Assertion 2: toggle ON hides in-session kept + skipped, reversibly

    @Test("ON hides in-session kept + skipped from sections/counts/nav; OFF restores")
    func toggleHidesInSessionReversibly() throws {
        let model = model()
        let baselineOrdered = model.orderedCount
        let baselineKeep = model.keepCount

        model.hideAlreadyReviewed = true
        model.keep(try #require(model.candidate(for: "sample-keep-1"))) // K
        model.skip(try #require(model.candidate(for: "sample-maybe-1"))) // S

        #expect(!model.keepCandidates.contains("sample-keep-1"))
        #expect(!model.keepCandidateDetails.contains { $0.id == "sample-keep-1" })
        #expect(!model.skippedCandidates.contains("sample-maybe-1"))
        #expect(model.keepCount == baselineKeep - 1)
        #expect(model.position(of: "sample-keep-1") == nil)
        #expect(model.position(of: "sample-maybe-1") == nil)
        #expect(model.orderedCount == baselineOrdered - 2)

        // Flipping OFF on the SAME instance restores both — a live view, not a mutation
        // of decisions/order.
        model.hideAlreadyReviewed = false
        #expect(model.keepCandidates.contains("sample-keep-1"))
        #expect(model.skippedCandidates.contains("sample-maybe-1"))
        #expect(model.orderedCount == baselineOrdered)
    }

    // MARK: - Assertion 3: nav skips hidden tiles

    @Test("nav skips a hidden tile; focus never lands on a hidden id")
    func navSkipsHidden() throws {
        let model = model()
        model.hideAlreadyReviewed = true
        // Skip the second visible tile so it's hidden between two visible ones.
        model.skip(try #require(model.candidate(for: "sample-maybe-1")))

        model.focusedID = "sample-keep-1"
        model.moveRight()
        // Lands on the next VISIBLE tile, never the hidden sample-maybe-1.
        #expect(model.focusedID != "sample-maybe-1")
        #expect(model.focusedID == "sample-both-1")
        #expect(model.position(of: "sample-maybe-1") == nil)

        // Every visible tile's position is contiguous within orderedCount.
        let visible = model.keepCandidates + model.maybeCandidates + model.otherCandidates + model.skippedCandidates
        let positions = visible.compactMap { model.position(of: $0) }.sorted()
        #expect(positions == Array(1 ... model.orderedCount))
    }

    // MARK: - Assertion 4: ON hides prior-scan KEPT photos via the library

    @Test("ON hides a prior-scan library-saved photo (no in-session decision)")
    func hidesPriorScanKept() async throws {
        let lib = realLibrary()
        let candidate = sourceCandidate(id: "lib-1", red: 0.3)
        let source = try #require(candidate.sourceURL)
        _ = await lib.save(originalAt: source, subjectId: kris, personName: kris, score: 0.9)
        let model = model(candidates: [candidate], library: lib)

        // No in-session decision — mirrors a re-scan surfacing an already-kept photo.
        #expect(model.state(for: "lib-1") == .other)
        #expect(model.isInLibrary("lib-1") == true)

        model.hideAlreadyReviewed = false
        #expect(model.otherCandidates.contains("lib-1"))
        model.hideAlreadyReviewed = true
        #expect(!model.otherCandidates.contains("lib-1"))
    }

    // MARK: - Assertion 5: ON hides prior-scan SKIPPED photos via the skip store

    @Test("ON hides a prior-scan skip-store photo (no in-session decision)")
    func hidesPriorScanSkipped() throws {
        let candidate = sourceCandidate(id: "skip-1", red: 0.5)
        let source = try #require(candidate.sourceURL)
        let spy = SpySkipStore(preloaded: [kris: [source.path]])
        let model = model(candidates: [candidate], skipStore: spy)

        // No in-session decision; the prior-scan skip lives only in the store.
        #expect(model.state(for: "skip-1") == .other)

        model.hideAlreadyReviewed = false
        #expect(model.otherCandidates.contains("skip-1"))
        model.hideAlreadyReviewed = true
        #expect(!model.otherCandidates.contains("skip-1"))
    }

    // MARK: - Assertion 6: skip records; keep paths clear

    @Test("skip records once; no-source/no-person records nothing; keep clears")
    func skipRecordsKeepClears() throws {
        let spy = SpySkipStore()
        let src = sourceCandidate(id: "src-1", red: 0.4)
        let source = try #require(src.sourceURL)
        let model = model(candidates: [src], skipStore: spy)

        // (a) skip a sample candidate with NO sourceURL → records nothing.
        model.focusedID = "sample-keep-1"
        model.skipFocused()
        #expect(spy.recordCalls.isEmpty)

        // (a) skip the source-backed candidate → records exactly once, path + subject.
        model.focusedID = "src-1"
        model.skipFocused()
        #expect(spy.recordCalls.count == 1)
        #expect(spy.recordCalls.first?.sourcePath == source.path)
        #expect(spy.recordCalls.first?.subjectId == kris)
        #expect(spy.isSkipped(sourcePath: source.path, subjectId: kris))

        // (b) a normal keep of the skipped photo clears the skip.
        model.keep(try #require(model.candidate(for: "src-1")))
        #expect(spy.clearCalls.contains { $0.sourcePath == source.path && $0.subjectId == kris })
        #expect(spy.isSkipped(sourcePath: source.path, subjectId: kris) == false)
    }

    @Test("keep-without-match of a skipped photo also clears the skip")
    func keepWithoutMatchClears() throws {
        let spy = SpySkipStore()
        let src = sourceCandidate(id: "src-1", red: 0.4)
        let source = try #require(src.sourceURL)
        let model = model(candidates: [src], skipStore: spy)

        model.focusedID = "src-1"
        model.skipFocused()
        #expect(spy.isSkipped(sourcePath: source.path, subjectId: kris))

        model.focusedID = "src-1"
        model.keepWithoutMatchFocused()
        #expect(spy.clearCalls.contains { $0.sourcePath == source.path && $0.subjectId == kris })
        #expect(spy.isSkipped(sourcePath: source.path, subjectId: kris) == false)
    }

    @Test("a normal skip still teaches the engine (feedback unchanged)")
    func skipStillTeaches() async throws {
        let spy = SpySkipStore()
        let src = sourceCandidate(id: "src-1", red: 0.4)
        let model = AppModel(
            engine: SampleTriageEngine(additionalCandidates: [src]),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": tempStore()],
            keptLibrary: realLibrary(),
            skipStore: spy
        )
        let engine = try #require(model.engine as? SampleTriageEngine)

        model.skip(try #require(model.candidate(for: "src-1")))
        await model.flushPendingWrites()
        #expect(engine.recordedFeedback.contains { $0.0 == "lib/src-1.jpg" && $0.1 == .reject })
    }

    // MARK: - Assertion 8: per-active-person filtering

    @Test("a photo acted on by A stays visible for B when ON")
    func perPersonScoping() async throws {
        // Kris keeps sample-keep-1 in-session; a library-saved source under Kris; a
        // skip-store skip under Kris — none should hide anything for Ava.
        let lib = realLibrary()
        let libCandidate = sourceCandidate(id: "lib-a", red: 0.3)
        let libSource = try #require(libCandidate.sourceURL)
        _ = await lib.save(originalAt: libSource, subjectId: kris, personName: kris, score: 0.9)

        let skipCandidate = sourceCandidate(id: "skip-a", red: 0.7)
        let skipSource = try #require(skipCandidate.sourceURL)
        let spy = SpySkipStore(preloaded: [kris: [skipSource.path]])

        let model = model(candidates: [libCandidate, skipCandidate], library: lib, skipStore: spy)
        model.hideAlreadyReviewed = true
        model.keep(try #require(model.candidate(for: "sample-keep-1"))) // A's in-session keep

        // Hidden for Kris…
        #expect(model.position(of: "sample-keep-1") == nil)
        #expect(model.position(of: "lib-a") == nil)
        #expect(model.position(of: "skip-a") == nil)

        // …still visible for Ava (no decision, no library entry, no skip for her).
        model.selectPerson(id: ava)
        #expect(model.position(of: "sample-keep-1") != nil)
        #expect(model.position(of: "lib-a") != nil)
        #expect(model.position(of: "skip-a") != nil)
    }

    // MARK: - Assertion 9: toggle state persists via injected UserDefaults

    @Test("toggle state persists via injected UserDefaults; fresh suite reads false")
    func togglePersists() {
        let suite = emptySuite()
        let first = model(defaults: suite)
        #expect(first.hideAlreadyReviewed == false)
        first.hideAlreadyReviewed = true

        let second = model(defaults: suite)
        #expect(second.hideAlreadyReviewed == true)

        let fresh = model(defaults: emptySuite())
        #expect(fresh.hideAlreadyReviewed == false)
    }

    // MARK: - Focus reseat when the focused tile becomes hidden (item 48 follow-up)

    @Test("turning the filter ON reseats focus off a now-hidden focused tile")
    func togglingOnReseatsFocusOffHiddenTile() {
        let m = model()
        // Keep a match this session, then point focus back at that (now acted-on) tile.
        m.focusedID = "sample-keep-1"
        m.keepFocused()
        m.focusedID = "sample-keep-1"
        #expect(m.state(for: "sample-keep-1") == .keep)
        #expect(m.position(of: "sample-keep-1") != nil) // visible while the filter is OFF

        m.hideAlreadyReviewed = true
        #expect(m.position(of: "sample-keep-1") == nil) // now hidden
        #expect(m.focusedID != "sample-keep-1") // focus reseated off the hidden tile
        if let focused = m.focusedID {
            #expect(m.position(of: focused) != nil) // reseated onto a visible tile
        }
    }

    @Test("with the filter ON, skipping the focused tile never leaves focus on a hidden id")
    func decidingWithFilterOnKeepsFocusVisible() {
        let m = model()
        m.hideAlreadyReviewed = true
        m.focusedID = "sample-maybe-1"
        #expect(m.position(of: "sample-maybe-1") != nil) // visible (not yet acted on)

        m.skipFocused()
        #expect(m.position(of: "sample-maybe-1") == nil) // hidden after the skip
        #expect(m.focusedID != "sample-maybe-1")
        if let focused = m.focusedID {
            #expect(m.position(of: focused) != nil) // focus stayed on a visible tile
        }
    }
}

/// Item 48 assertion 7: the concrete disk-backed `SkipStore` persists across "launches"
/// (a new instance over the same JSON), is subject-scoped, round-trips clear, and writes
/// through a coalesced writer with a deterministic flush seam (no sleeps).
@Suite("Skip store persistence (item 48)")
struct SkipStoreTests {
    private func tempURL() -> URL {
        LibraryFixtures.tempDir("skip").appendingPathComponent("skipped-index.json")
    }

    @Test("record then flush survives a fresh instance; subject-scoped; unrecorded is false")
    func persistsAcrossLaunches() async {
        let url = tempURL()
        let store = SkipStore(fileURL: url)
        store.recordSkip(sourcePath: "/a/b.jpg", subjectId: "kris")
        await store.flush()

        let reloaded = SkipStore(fileURL: url)
        #expect(reloaded.isSkipped(sourcePath: "/a/b.jpg", subjectId: "kris"))
        #expect(reloaded.isSkipped(sourcePath: "/a/b.jpg", subjectId: "ava") == false)
        #expect(reloaded.isSkipped(sourcePath: "/x/y.jpg", subjectId: "kris") == false)
    }

    @Test("clear round-trips to not-skipped across a reload")
    func clearRoundTrips() async {
        let url = tempURL()
        let store = SkipStore(fileURL: url)
        store.recordSkip(sourcePath: "/a/b.jpg", subjectId: "kris")
        await store.flush()
        store.clearSkip(sourcePath: "/a/b.jpg", subjectId: "kris")
        await store.flush()

        let reloaded = SkipStore(fileURL: url)
        #expect(reloaded.isSkipped(sourcePath: "/a/b.jpg", subjectId: "kris") == false)
    }

    @Test("removeSubject purges only that subject across a reload")
    func removeSubjectPurges() async {
        let url = tempURL()
        let store = SkipStore(fileURL: url)
        store.recordSkip(sourcePath: "/a/b.jpg", subjectId: "kris")
        store.recordSkip(sourcePath: "/c/d.jpg", subjectId: "ava")
        await store.flush()
        store.removeSubject("kris")
        await store.flush()

        let reloaded = SkipStore(fileURL: url)
        #expect(reloaded.isSkipped(sourcePath: "/a/b.jpg", subjectId: "kris") == false)
        #expect(reloaded.isSkipped(sourcePath: "/c/d.jpg", subjectId: "ava"))
    }

    @Test("writes coalesce: a burst schedules N with 0 writes, flush writes once")
    func coalescedWrites() async {
        let writer = SpySkipIndexWriter()
        let store = SkipStore(fileURL: tempURL(), indexWriter: writer)
        store.recordSkip(sourcePath: "/a.jpg", subjectId: "kris")
        store.recordSkip(sourcePath: "/b.jpg", subjectId: "kris")
        store.recordSkip(sourcePath: "/c.jpg", subjectId: "kris")
        #expect(writer.scheduledCount == 3)
        #expect(writer.materializedWrites == 0)

        await store.flush()
        #expect(writer.materializedWrites == 1)
        #expect(writer.lastWritten["kris"]?.count == 3)
    }
}

/// Counts `schedule` vs materialized writes so the coalescing test proves the store
/// schedules (not inline-writes) per call and one flush lands exactly one write.
final class SpySkipIndexWriter: SkipIndexWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduledCount = 0
    private var _materializedWrites = 0
    private var _lastScheduled: [String: Set<String>] = [:]
    private var _lastWritten: [String: Set<String>] = [:]

    var scheduledCount: Int { lock.withLock { _scheduledCount } }
    var materializedWrites: Int { lock.withLock { _materializedWrites } }
    var lastWritten: [String: Set<String>] { lock.withLock { _lastWritten } }

    func schedule(_ skips: [String: Set<String>]) {
        lock.withLock {
            _scheduledCount += 1
            _lastScheduled = skips
        }
    }

    func flush() async {
        lock.withLock {
            _materializedWrites += 1
            _lastWritten = _lastScheduled
        }
    }
}
