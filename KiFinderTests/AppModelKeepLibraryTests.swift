import Foundation
@testable import KiFinder
import Testing

/// Item-18a assertions 6–8: the `AppModel` keep-hook (per-person, idempotent, skip
/// never saves, non-blocking), the "already saved" model flag, and graceful keep of a
/// missing source.
@Suite("App model keep library hook")
@MainActor
struct AppModelKeepLibraryTests {
    private let kris = SampleTriageEngine.primarySubjectID
    private let ava = SampleTriageEngine.secondarySubjectID

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    private func realLibrary() -> KeptLibrary {
        KeptLibrary(
            root: LibraryFixtures.tempDir("root"),
            indexURL: LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        )
    }

    private func model(candidates: [Candidate], library: any KeptLibrarySaving) -> AppModel {
        AppModel(
            engine: SampleTriageEngine(additionalCandidates: candidates),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": store()],
            keptLibrary: library
        )
    }

    // MARK: - Assertion 6

    @Test("keep saves one copy for the active person; re-keep does not save again")
    func keepSavesOnceIdempotent() async throws {
        let lib = realLibrary()
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: "2021:07:15 12:00:00")
        let model = model(candidates: [LibraryFixtures.candidate(id: "lib-1", source: source)], library: lib)

        let candidate = try #require(model.candidate(for: "lib-1"))
        model.keep(candidate)
        await model.flushLibrary()
        #expect(lib.allEntries.filter { $0.subjectId == kris }.count == 1)

        // Re-keep is idempotent: no second copy.
        model.keep(candidate)
        await model.flushLibrary()
        #expect(lib.allEntries.filter { $0.subjectId == kris }.count == 1)
    }

    @Test("switching the active person and keeping the same photo saves under that person")
    func keepPerPerson() async throws {
        let lib = realLibrary()
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: "2021:07:15 12:00:00")
        let model = model(candidates: [LibraryFixtures.candidate(id: "lib-1", source: source)], library: lib)

        let candidate = try #require(model.candidate(for: "lib-1"))
        model.keep(candidate)
        await model.flushLibrary()

        model.selectPerson(id: ava)
        let avaCandidate = try #require(model.candidate(for: "lib-1"))
        model.keep(avaCandidate)
        await model.flushLibrary()

        #expect(lib.allEntries.filter { $0.subjectId == kris }.count == 1)
        #expect(lib.allEntries.filter { $0.subjectId == ava }.count == 1)
    }

    @Test("skip never saves to the library")
    func skipNeverSaves() async throws {
        let lib = realLibrary()
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: "2021:07:15 12:00:00")
        let model = model(candidates: [LibraryFixtures.candidate(id: "lib-1", source: source)], library: lib)

        let candidate = try #require(model.candidate(for: "lib-1"))
        model.skip(candidate)
        await model.flushLibrary()
        #expect(lib.allEntries.isEmpty)
    }

    @Test("keep is non-blocking: the decision is recorded before the suspended save completes")
    func keepIsNonBlocking() async throws {
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: "2021:07:15 12:00:00")
        let spy = SuspendingSaveSpy(wrapping: realLibrary())
        let model = model(candidates: [LibraryFixtures.candidate(id: "lib-1", source: source)], library: spy)

        let candidate = try #require(model.candidate(for: "lib-1"))
        model.keep(candidate)
        // The decision is recorded synchronously, BEFORE the save has completed.
        #expect(model.state(for: "lib-1") == .keep)
        #expect(spy.completedSaves == 0)

        // Releasing the spy lets the copy land; the awaitable seam (not a yield loop)
        // gates the post-completion assertions.
        spy.release()
        await model.flushLibrary()
        #expect(spy.completedSaves == 1)
        #expect(spy.savedEntries.filter { $0.subjectId == kris }.count == 1)
    }

    // MARK: - Assertion 7

    @Test("isInLibrary is true for a saved source under the active person, false for another person")
    func alreadySavedFlag() async {
        let lib = realLibrary()
        let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4, exifDate: "2021:07:15 12:00:00")
        // Pre-save the source for Kris.
        _ = await lib.save(originalAt: source, subjectId: kris, personName: kris, score: 0.9)

        let other = LibraryFixtures.tempDir("src2").appendingPathComponent("OTHER.jpg")
        LibraryFixtures.writeImage(to: other, red: 0.7, exifDate: "2021:07:15 12:00:00")
        let model = model(
            candidates: [
                LibraryFixtures.candidate(id: "lib-1", source: source),
                LibraryFixtures.candidate(id: "lib-2", source: other),
            ],
            library: lib
        )

        // True for the saved source under the active person (Kris)…
        #expect(model.isInLibrary("lib-1") == true)
        // …false for a candidate whose source was never saved…
        #expect(model.isInLibrary("lib-2") == false)
        // …and false for a different person (Ava has no entry for this source).
        model.selectPerson(id: ava)
        #expect(model.isInLibrary("lib-1") == false)
    }

    // MARK: - Assertion 8b

    @Test("keeping a missing source records the decision but writes nothing")
    func keepMissingSource() async throws {
        let lib = realLibrary()
        let missing = LibraryFixtures.tempDir("src").appendingPathComponent("missing.jpg") // never written
        let model = model(candidates: [LibraryFixtures.candidate(id: "lib-1", source: missing)], library: lib)

        let candidate = try #require(model.candidate(for: "lib-1"))
        model.keep(candidate)
        // Decision recorded immediately.
        #expect(model.state(for: "lib-1") == .keep)

        await model.flushLibrary()
        #expect(lib.allEntries.isEmpty)
    }
}
