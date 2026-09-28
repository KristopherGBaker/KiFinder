import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Photos
import Testing

/// Item 43: scan/export failures surface as a distinct, RETRYABLE error state on
/// `AppModel` instead of being swallowed into a "found nothing" / "Exported 0"
/// success. Covers the `ScanProgress` error channel, the `scanError`/`exportError`
/// observable state, non-clobbering of a prior review on a failed scan, the export
/// throw path, the empty-selection no-op, and the clear/reset seams.
@Suite("App model scan/export errors")
@MainActor
struct AppModelScanExportErrorTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-scan-export-error-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func model(_ engine: ScanExportSpyEngine) -> AppModel {
        AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStore()])
    }

    private func drain() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .keep) -> Candidate {
        Candidate(
            id: id,
            photoKey: "key-\(id)",
            fileName: "\(id).jpg",
            imageResourceName: "",
            score: 0.9,
            bucket: bucket
        )
    }

    private let tmpAlbum = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

    // MARK: - Assertion 1: ScanProgress distinguishes failure from empty result

    @Test("a final ScanProgress with errorMessage is distinct from an empty final result")
    func scanProgressFailureIsDistinct() {
        let failure = ScanProgress(progress: 1, candidates: [], isFinal: true, errorMessage: "boom")
        let emptyOK = ScanProgress(progress: 1, candidates: [], isFinal: true)
        #expect(failure.errorMessage != nil)
        #expect(emptyOK.errorMessage == nil)
        #expect(failure != emptyOK)
        // A defaulted errorMessage keeps existing call sites source-compatible.
        #expect(ScanProgress(progress: 0.5).errorMessage == nil)
    }

    // MARK: - Assertion 2: failed scan → scanError set, review not clobbered

    @Test("a failed scan sets scanError and does NOT empty the prior review")
    func failedScanKeepsPriorReview() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        // A first, successful scan seeds a review.
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 2)
        let seededOrder = model.keepCandidates

        // A second scan FAILS: scanError is set and the prior review survives.
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [], isFinal: true, errorMessage: "The scan couldn't be completed. Please try again.")]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError != nil)
        #expect(model.keepCount == 2) // NOT emptied into a "nothing found" state
        #expect(model.keepCandidates == seededOrder)
    }

    @Test("a normal final scan applies candidates and leaves scanError nil")
    func normalScanNoError() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("x"), candidate("y")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 2)
    }

    // MARK: - Assertion 3: LiveTriageEngine yields the error, not empty-success

    @Test("LiveTriageEngine.scan yields a final progress with a non-nil errorMessage when the pipeline throws")
    func liveScanYieldsError() async {
        // A bogus model URL (nonexistent) makes streamingScan throw before any
        // embedding — the catch must yield an error progress, not empty candidates.
        let engine = LiveTriageEngine(
            environment: [:],
            locations: ModelLocations(appSupportRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)),
            storeURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/store.json"),
            subjectId: "subj",
            modelId: "m",
            modelVersion: "1"
        )
        var finalTick: ScanProgress?
        for await progress in engine.scan(albums: [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).zip")]) {
            if progress.isFinal { finalTick = progress }
        }
        #expect(finalTick != nil)
        #expect(finalTick?.errorMessage != nil)
        #expect(finalTick?.candidates.isEmpty == true)
    }

    // MARK: - Assertion 4: export failures → exportError, no bogus summary

    @Test("a thrown export sets exportError and does NOT present the summary")
    func exportThrowSetsError() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        model.select("a")
        model.toggleSelection("b")
        #expect(!model.selectedPhotoIDs.isEmpty)

        spy.exportShouldThrow = true
        model.exportSelected(toFolder: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        await drain()

        #expect(model.exportError != nil)
        #expect(!model.isExportSummaryPresented)
        #expect(spy.exportCallCount == 1)
    }

    @Test("a successful export presents the summary and leaves exportError nil")
    func exportSuccessShowsSummary() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        model.select("a")
        model.toggleSelection("b")
        model.exportSelected(toFolder: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
    }

    @Test("exportSelectedToPhotos throw sets exportError, no summary")
    func exportPhotosThrowSetsError() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        model.select("a")

        spy.exportShouldThrow = true
        model.exportSelectedToPhotos()
        await drain()

        #expect(model.exportError != nil)
        #expect(!model.isExportSummaryPresented)
    }

    @Test("an empty selection export is a graceful no-op (no engine call, no error, no summary)")
    func emptyExportNoOp() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        #expect(model.selectedPhotoIDs.isEmpty)

        model.exportSelected(toFolder: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        model.exportSelectedToPhotos()
        await drain()

        #expect(spy.exportCallCount == 0)
        #expect(model.exportError == nil)
        #expect(!model.isExportSummaryPresented)
    }

    // MARK: - Assertion 5: clearable + reset-on-new

    @Test("clearScanError / clearExportError reset the state to nil")
    func clearErrors() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        spy.progressToYield = [ScanProgress(progress: 1, candidates: [], isFinal: true, errorMessage: "boom")]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError != nil)
        model.clearScanError()
        #expect(model.scanError == nil)

        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        model.select("a")
        spy.exportShouldThrow = true
        model.exportSelected(toFolder: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        await drain()
        #expect(model.exportError != nil)
        model.clearExportError()
        #expect(model.exportError == nil)
    }

    @Test("a new scan resets a prior scanError")
    func newScanResetsScanError() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [], isFinal: true, errorMessage: "boom")]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError != nil)

        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 1)
    }

    // MARK: - Item 47: a Library-initiated scan returns to Review on success

    // Assertion 1: a successful scan while in Library returns to Review + seeds.
    @Test("a successful scan started from Library returns to Review with the new candidates")
    func successFromLibraryReturnsToReview() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        model.showLibrary()
        #expect(model.libraryBrowseActive == true) // precondition: we're in Library

        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [candidate("a", bucket: .keep), candidate("b", bucket: .maybe)],
            isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)

        #expect(model.libraryBrowseActive == false) // FAILS pre-fix (stayed true)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 1)
        #expect(model.maybeCount == 1)
    }

    // Assertion 2: a FAILED scan while in Library stays in Library (error branch).
    @Test("a failed scan started from Library stays in Library and sets scanError")
    func failureFromLibraryStaysInLibrary() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        model.showLibrary()
        #expect(model.libraryBrowseActive == true)

        spy.progressToYield = [ScanProgress(progress: 1, candidates: [], isFinal: true, errorMessage: "boom")]
        await model.runScan(albums: tmpAlbum)

        #expect(model.libraryBrowseActive == true) // never yanked out of Library on failure
        #expect(model.scanError != nil)
    }

    // Assertion 3: a cancelled / dismissed scan does not force Review.
    @Test("dismissScan while in Library leaves the browse state unchanged")
    func dismissFromLibraryStaysInLibrary() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        model.showLibrary()
        #expect(model.libraryBrowseActive == true)

        model.dismissScan()

        #expect(model.libraryBrowseActive == true) // dismiss/cancel never routes through apply's success
        #expect(model.isScanning == false)
        #expect(model.isScanPresented == false)
    }

    // Assertion 4: no regression — a successful scan while already in Review stays + seeds.
    @Test("a successful scan while already in Review stays in Review and still seeds")
    func successFromReviewStaysInReview() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        #expect(model.libraryBrowseActive == false) // default: Review

        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [candidate("a", bucket: .keep), candidate("b", bucket: .keep)],
            isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)

        #expect(model.libraryBrowseActive == false)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 2)
    }
}

/// Item 47, assertion 5: the return-to-Review routes through `showReview()`, which also
/// clears the library-scoped multi-selection. Seeds a real library selection (via an
/// injected populated `KeptLibrary`) then drives a successful scan through the spy engine
/// and asserts the selection is dropped alongside `libraryBrowseActive`.
@Suite("App model library scan returns to review")
@MainActor
struct AppModelLibraryScanReturnTests {
    private let kion = SampleTriageEngine.primarySubjectID

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .keep) -> Candidate {
        Candidate(id: id, photoKey: "key-\(id)", fileName: "\(id).jpg", imageResourceName: "", score: 0.9, bucket: bucket)
    }

    @Test("a successful Library scan clears the library multi-selection via showReview")
    func scanClearsLibrarySelection() async {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)

        for i in 0 ..< 3 {
            let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG_\(i).jpg")
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.2 * CGFloat(i), exifDate: "2021:07:1\(i) 12:00:00")
            _ = await lib.save(originalAt: source, subjectId: kion, personName: kion, score: 0.9)
        }

        let spy = ScanExportSpyEngine()
        let model = AppModel(
            engine: spy,
            environment: ["KION_PROFILE_STORE": store(), "KION_LIBRARY_ROOT": root.path],
            keptLibrary: lib
        )

        model.showLibrary()
        #expect(model.libraryBrowseActive == true)
        let ids = model.libraryOrderedIDs
        #expect(ids.count >= 2)
        model.selectLibrary(ids[0])
        model.toggleLibrarySelection(ids[1])
        #expect(!model.selectedLibraryIDs.isEmpty) // precondition: a library selection exists

        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])

        #expect(model.libraryBrowseActive == false)
        #expect(model.selectedLibraryIDs.isEmpty) // showReview() dropped the selection
    }
}

/// Item 49: the per-decision rescore must be scoped to the photos the user hasn't
/// decided — and skipped entirely when there are none — so background CPU stops
/// scaling with the whole album (whose per-photo cost grows with the accumulated
/// negatives). Driven through the injected `ScanExportSpyEngine`, which records the
/// `onlyPhotoKeys` it's asked to re-score with and every teach it receives.
@Suite("App model rescore scoping (item 49)")
@MainActor
struct AppModelRescoreScopingTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-rescore-scoping-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func model(_ engine: ScanExportSpyEngine) -> AppModel {
        AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStore()])
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .maybe) -> Candidate {
        Candidate(id: id, photoKey: "key-\(id)", fileName: "\(id).jpg", imageResourceName: "", score: 0.5, bucket: bucket)
    }

    private let tmpAlbum = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

    /// Seeds a four-candidate review via the spy's scan channel.
    private func seededModel() async -> (AppModel, ScanExportSpyEngine) {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [candidate("a"), candidate("b"), candidate("c"), candidate("d")],
            isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)
        return (model, spy)
    }

    // MARK: - Assertion 3: rescore is asked for ONLY undecided photos

    @Test("rescore asks the engine for EXACTLY the undecided photoKeys")
    func rescoreScopesToUndecided() async throws {
        let (model, spy) = await seededModel()
        // Decide two (a keep + a skip); leave "c" and "d" undecided.
        model.keep(try #require(model.candidate(for: "a")))
        model.skip(try #require(model.candidate(for: "b")))

        await model.rescoreNowForTesting()

        let lastCall = try #require(spy.rescoreCalls.last)
        let onlyKeys = try #require(lastCall)
        #expect(onlyKeys == ["key-c", "key-d"])
    }

    // MARK: - Assertion 4: all decided ⇒ no engine rescore at all

    @Test("all decided ⇒ engine rescore is not called and no promotions are pending")
    func allDecidedSkipsEngine() async throws {
        let (model, spy) = await seededModel()
        for id in ["a", "b", "c", "d"] {
            model.keep(try #require(model.candidate(for: id)))
        }
        // A prior seeded suggestion would be cleared by the empty-set early return.
        model.seedPendingPromotionForTesting("a", .keep)

        await model.rescoreNowForTesting()

        #expect(spy.rescoreCalls.isEmpty) // engine never asked to re-score
        #expect(model.pendingPromotions.isEmpty)
    }

    // MARK: - Assertion 7: a fresh keep AND a fresh skip both teach + schedule a rescore

    @Test("a fresh keep and a fresh skip each teach and reach a scoped rescore")
    func keepAndSkipBothTeachAndRescore() async throws {
        let (model, spy) = await seededModel()

        model.keep(try #require(model.candidate(for: "a")))
        model.skip(try #require(model.candidate(for: "b")))
        await model.drainFeedback()

        // Both fresh decisions taught the engine (item 37: skip teaches too).
        #expect(spy.recordedFeedback.contains { $0.photoKey == "key-a" && $0.label == .confirm })
        #expect(spy.recordedFeedback.contains { $0.photoKey == "key-b" && $0.label == .reject })

        // And each reaches a scoped rescore (undecided photos still remain).
        await model.rescoreNowForTesting()
        let lastCall = try #require(spy.rescoreCalls.last)
        let onlyKeys = try #require(lastCall)
        #expect(onlyKeys == ["key-c", "key-d"])
    }
}

/// A `TriageEngine` spy for item 43: `scan` yields a caller-provided sequence of
/// `ScanProgress` ticks (so a test can drive a normal OR an error final tick), and
/// `export` either returns the input count or throws on demand. Records the export
/// call count so the empty-selection no-op is verifiable.
@MainActor
final class ScanExportSpyEngine: TriageEngine {
    var progressToYield: [ScanProgress] = []
    var exportShouldThrow = false
    /// Item 54: when set, `export` throws the SAME typed error `LiveTriageEngine`
    /// throws on a non-authorized Photos status, so a model-level test can prove the
    /// denial → `exportError` mapping without a real `LiveTriageEngine`.
    var exportShouldThrowNotAuthorized = false
    /// Item 54, assertion 6 (denial ≠ empty): when set, `export` returns this count
    /// instead of `photoKeys.count`/`fileURLs.count` WITHOUT throwing — simulates an
    /// authorized export that genuinely had nothing to write, distinct from a denial.
    var exportReturnCountOverride: Int?
    /// Item 54, assertion 8: maps a `photoKey` to a real on-disk source URL so a
    /// `.folder` export can perform the SAME production copy
    /// (`LiveTriageEngine.copyFilesOffMainActor`) the real engine uses — letting a
    /// folder-export flow test assert real files landed on disk without needing a
    /// real (model-dependent) scan.
    var sourceURLByPhotoKey: [String: URL] = [:]
    private(set) var exportCallCount = 0
    /// Item 54: every `export(photoKeys:destination:)` call, in order, so a test can
    /// assert the exact source set + destination that reached the engine.
    private(set) var photoKeyExportCalls: [(keys: [String], destination: ExportDestination)] = []
    /// Item 54: every `export(fileURLs:destination:)` call, in order — same purpose
    /// for the fileURLs-based entry point (`exportSelectedLibraryToPhotos`).
    private(set) var fileURLExportCalls: [(urls: [URL], destination: ExportDestination)] = []
    /// Item 49: every `onlyPhotoKeys` argument the engine is asked to re-score with,
    /// in call order (`nil` = "all"). Empty until a rescore fires.
    private(set) var rescoreCalls: [Set<String>?] = []
    /// Item 49: what `rescoreAll` returns, so a promotion-surfacing test can drive a
    /// deterministic result. Empty by default (no promotions).
    var rescoreResults: [String: RescoredPhoto] = [:]
    /// Item 49: every `recordFeedback` the engine received, so a test can prove a
    /// fresh keep AND a fresh skip both teach.
    private(set) var recordedFeedback: [(photoKey: String, label: KiFinder.FeedbackLabel)] = []

    struct ExportError: Error {}

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        let items = progressToYield
        return AsyncStream { continuation in
            for item in items {
                continuation.yield(item)
            }
            continuation.finish()
        }
    }

    func export(photoKeys: [String], destination: ExportDestination) async throws -> Int {
        exportCallCount += 1
        photoKeyExportCalls.append((photoKeys, destination))
        if exportShouldThrowNotAuthorized { throw KiFinder.ExportError.photosAccessNotAuthorized }
        if exportShouldThrow { throw ExportError() }
        if let override = exportReturnCountOverride { return override }
        // Item 54: only perform a REAL copy (so a test can verify files landed on
        // disk) when the test has opted in by populating `sourceURLByPhotoKey`.
        // Every OTHER (pre-existing) test leaves it empty and keeps the original
        // test-double behavior — echo the input count — so this spy's folder branch
        // never silently regresses a test that never asked for real-file semantics.
        if case let .folder(directory) = destination, !sourceURLByPhotoKey.isEmpty {
            let sources = photoKeys.compactMap { sourceURLByPhotoKey[$0] }
            return try LiveTriageEngine.copyFilesOffMainActor(sources: sources, directory: directory)
        }
        return photoKeys.count
    }

    func export(fileURLs: [URL], destination: ExportDestination) async throws -> Int {
        exportCallCount += 1
        fileURLExportCalls.append((fileURLs, destination))
        if exportShouldThrowNotAuthorized { throw KiFinder.ExportError.photosAccessNotAuthorized }
        if exportShouldThrow { throw ExportError() }
        if let override = exportReturnCountOverride { return override }
        return fileURLs.count
    }

    func enroll(referenceURLs _: [URL]) async throws -> [FaceEmbedding] {
        []
    }

    func recordFeedback(photoKey: String, label: KiFinder.FeedbackLabel) async throws {
        recordedFeedback.append((photoKey, label))
    }

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        FaceSelectionResult(score: 0, bucket: .other)
    }

    func rescoreAll(onlyPhotoKeys: Set<String>?) async throws -> [String: RescoredPhoto] {
        rescoreCalls.append(onlyPhotoKeys)
        return rescoreResults
    }
}

/// Item 50: keep/skip no longer AUTO-re-scores; the "Find new matches" toolbar button
/// (enabled once a fresh keep/skip has taught the engine) drives the item-49 scoped
/// re-score on demand and clears the flag. Driven through the `ScanExportSpyEngine`
/// (records every `onlyPhotoKeys` + teach) so both the "no auto-rescore" and the
/// manual-trigger contracts are observable without sleeps where possible.
@Suite("App model manual re-score button (item 50)")
@MainActor
struct AppModelManualRescoreTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-manual-rescore-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func model(_ engine: ScanExportSpyEngine) -> AppModel {
        AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStore()])
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .maybe) -> Candidate {
        Candidate(id: id, photoKey: "key-\(id)", fileName: "\(id).jpg", imageResourceName: "", score: 0.5, bucket: bucket)
    }

    private let tmpAlbum = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

    private func seededModel() async -> (AppModel, ScanExportSpyEngine) {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [candidate("a"), candidate("b"), candidate("c"), candidate("d")],
            isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)
        return (model, spy)
    }

    /// Polls the run-loop until the manual (non-testing) `rescoreNow()` task has run,
    /// bounded so a failure can't hang the suite.
    private func awaitRescore(_ spy: ScanExportSpyEngine) async {
        for _ in 0 ..< 200 {
            if !spy.rescoreCalls.isEmpty { return }
            await Task.yield()
        }
    }

    // MARK: - Assertion 1: no auto-rescore on keep/skip (teaching preserved)

    @Test("a fresh keep + skip do NOT auto-re-score even past the old 600ms debounce")
    func noAutoRescore() async throws {
        let (model, spy) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))
        model.skip(try #require(model.candidate(for: "b")))

        // Give the run loop a turn AND clear the old debounce window: nothing re-scores.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(700))
        #expect(spy.rescoreCalls.isEmpty)

        // Teaching is untouched — both fresh decisions still taught the engine.
        await model.drainFeedback()
        #expect(spy.recordedFeedback.contains { $0.photoKey == "key-a" && $0.label == .confirm })
        #expect(spy.recordedFeedback.contains { $0.photoKey == "key-b" && $0.label == .reject })
    }

    // MARK: - Assertion 2: the flag follows TEACHING, not plain freshness

    @Test("the flag starts false on a clean loaded model")
    func flagStartsFalse() async throws {
        let (model, _) = await seededModel()
        #expect(model.hasUnscoredDecisions == false)
    }

    @Test("a fresh keep sets the flag")
    func freshKeepSetsFlag() async throws {
        let (model, _) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))
        #expect(model.hasUnscoredDecisions)
    }

    @Test("a fresh skip sets the flag")
    func freshSkipSetsFlag() async throws {
        let (model, _) = await seededModel()
        model.skip(try #require(model.candidate(for: "a")))
        #expect(model.hasUnscoredDecisions)
    }

    @Test("keep-without-match never sets the flag, but a later normal keep (which teaches) does")
    func keepWithoutMatchThenUpgrade() async throws {
        let (model, _) = await seededModel()
        model.focusedID = "a"
        model.keepWithoutMatchFocused() // never teaches
        #expect(model.hasUnscoredDecisions == false)

        // The item-37 upgrade (normal keep of a kept-without-match photo) DOES teach.
        model.keep(try #require(model.candidate(for: "a")))
        #expect(model.hasUnscoredDecisions)
    }

    @Test("an idempotent repeat decision does not set the flag")
    func idempotentRepeatDoesNotSetFlag() async throws {
        let (model, _) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))
        await model.rescoreNowForTesting() // clears the flag
        #expect(model.hasUnscoredDecisions == false)

        // A repeat keep on the already-kept photo early-returns → no new teaching.
        model.keep(try #require(model.candidate(for: "a")))
        #expect(model.hasUnscoredDecisions == false)
    }

    // MARK: - Assertion 3: rescoreNow is the manual, non-debounced path; flag clears at start

    @Test("the manual re-score asks for EXACTLY the undecided keys and clears the flag")
    func manualRescoreScopesAndClears() async throws {
        let (model, spy) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))
        model.skip(try #require(model.candidate(for: "b")))
        #expect(model.hasUnscoredDecisions)

        await model.rescoreNowForTesting()

        #expect(model.hasUnscoredDecisions == false)
        let last = try #require(spy.rescoreCalls.last)
        let onlyKeys = try #require(last)
        #expect(onlyKeys == ["key-c", "key-d"])
    }

    @Test("the production rescoreNow() button path re-scores without a debounce and clears the flag")
    func productionRescoreNowRuns() async throws {
        let (model, spy) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))

        model.rescoreNow()
        await awaitRescore(spy)

        #expect(spy.rescoreCalls.isEmpty == false)
        #expect(model.hasUnscoredDecisions == false)
    }

    // MARK: - Assertion 4: the flag clears even with nothing to re-score

    @Test("all decided ⇒ manual re-score clears the flag, skips the engine, no promotions")
    func flagClearsWithNothingToRescore() async throws {
        let (model, spy) = await seededModel()
        for id in ["a", "b", "c", "d"] {
            model.keep(try #require(model.candidate(for: id)))
        }
        #expect(model.hasUnscoredDecisions)

        await model.rescoreNowForTesting()

        #expect(model.hasUnscoredDecisions == false)
        #expect(spy.rescoreCalls.isEmpty)
        #expect(model.pendingPromotions.isEmpty)
    }

    // MARK: - Assertion 5: a new scan resets the flag

    @Test("a successful new scan resets the flag to false")
    func newScanResetsFlag() async throws {
        let (model, spy) = await seededModel()
        model.keep(try #require(model.candidate(for: "a")))
        #expect(model.hasUnscoredDecisions)

        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [candidate("x"), candidate("y")],
            isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)
        #expect(model.hasUnscoredDecisions == false)
    }

    // MARK: - Assertion 6: promotions still surface via a manual re-score
    // Covered by `AppModelRescoreScoreTests` ("assertion 5: an undecided photo that now
    // scores better is still surfaced + applied"), which has a real active-person +
    // attributed-candidate setup — promotions require `activePersonID != nil`, which this
    // spy-engine harness (no enrolled person) does not provide. The manual re-score routes
    // through the same `rescoreAndSurface` body `rescoreNow()` uses, so that test exercises
    // the item-50 path.
}

/// Item 50: the deterministic on-device promotion hook — with
/// `KION_SAMPLE_PROMOTE_ON_RESCORE=<candidateId>` set, `SampleTriageEngine.rescoreAll`
/// promotes that candidate to `.keep` ONLY when it is in scope (item-49 `onlyPhotoKeys`),
/// and is otherwise inert (a byte-for-byte echo of today's behavior).
@Suite("Sample engine promote-on-rescore hook (item 50)")
@MainActor
struct SampleTriagePromoteHookTests {
    @Test("env set: the target promotes to .keep only when in scope, and is absent when excluded")
    func promotesTargetOnlyInScope() async throws {
        setenv("KION_SAMPLE_PROMOTE_ON_RESCORE", "sample-maybe-1", 1)
        defer { unsetenv("KION_SAMPLE_PROMOTE_ON_RESCORE") }
        let engine = SampleTriageEngine()
        let target = try #require(engine.candidates.first { $0.id == "sample-maybe-1" })
        let other = try #require(engine.candidates.first { $0.id == "sample-keep-2" })
        #expect(target.bucket == .maybe) // its default — proves the hook changed it

        // nil → all: promoted.
        let all = try await engine.rescoreAll(onlyPhotoKeys: nil)
        #expect(all[target.photoKey]?.bucket == .keep)
        // In-scope subset: promoted.
        let inScope = try await engine.rescoreAll(onlyPhotoKeys: [target.photoKey])
        #expect(inScope[target.photoKey]?.bucket == .keep)
        // Excluded from scope: ABSENT (item-49 scoping preserved), others echo unchanged.
        let excluded = try await engine.rescoreAll(onlyPhotoKeys: [other.photoKey])
        #expect(excluded[target.photoKey] == nil)
        #expect(excluded[other.photoKey]?.bucket == other.bucket)
    }

    @Test("env unset: rescore echoes exactly as today, honoring item-49 scoping")
    func inertWithoutEnv() async throws {
        unsetenv("KION_SAMPLE_PROMOTE_ON_RESCORE")
        let engine = SampleTriageEngine()
        let target = try #require(engine.candidates.first { $0.id == "sample-maybe-1" })

        // nil → all echoed unchanged (target stays .maybe, not .keep).
        let all = try await engine.rescoreAll(onlyPhotoKeys: nil)
        #expect(all[target.photoKey]?.bucket == target.bucket)
        #expect(all[target.photoKey]?.bucket == .maybe)
        #expect(all.count == engine.candidates.count)
        // Subset → only that key.
        let subset = try await engine.rescoreAll(onlyPhotoKeys: [target.photoKey])
        #expect(subset.count == 1)
        #expect(subset[target.photoKey]?.bucket == .maybe)
        // Empty → none.
        let none = try await engine.rescoreAll(onlyPhotoKeys: [])
        #expect(none.isEmpty)
    }
}

// MARK: - Item 54: export correctness (off-main copy, intra-batch de-collision, Photos denial)

/// Deterministic `PhotosAuthorizationClient` spy (item 54, `ModelDownloadClient`
/// style): drives `LiveTriageEngine.exportToPhotos`'s authorization branch with a
/// caller-chosen status, so tests can prove denied/limited/authorized behavior
/// WITHOUT ever touching the real `PHPhotoLibrary` from the test host process.
final class SpyPhotosAuthorizationClient: PhotosAuthorizationClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: PHAuthorizationStatus
    private var _requestCount = 0

    init(status: PHAuthorizationStatus) {
        _status = status
    }

    var requestCount: Int {
        lock.withLock { _requestCount }
    }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        lock.withLock {
            _requestCount += 1
            return _status
        }
    }
}

/// Records whether every observed file copy happened off the main thread. Guarded by
/// a lock because the recorder is invoked from inside `Task.detached` (item 54,
/// assertion 3) — off the `@MainActor` the test method itself runs on. `@unchecked
/// Sendable` is justified by the lock guarding all mutable state (same pattern as
/// `SpyKeptIndexWriter` in `LibraryTestSupport.swift`).
final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _observedMainThread = false

    func record() {
        lock.withLock {
            _callCount += 1
            if Thread.isMainThread { _observedMainThread = true }
        }
    }

    var callCount: Int { lock.withLock { _callCount } }
    var observedMainThread: Bool { lock.withLock { _observedMainThread } }
}

/// Item 54: `LiveTriageEngine.export(..., destination: .folder)` — the REAL
/// production entry point — exercised for off-main copying (assertion 3), intra-batch
/// de-collision with an honest count (assertion 1), the preserved pre-existing-file
/// overwrite behavior (assertion 2), and a mid-export partial failure surfacing as a
/// throw with the already-written file left intact (assertion 7, engine half). No
/// model/embedding is needed for export, so these construct a `LiveTriageEngine`
/// directly against a fresh, never-loaded store (feedback/scan are never exercised
/// here).
@Suite("LiveTriageEngine folder export (item 54)")
@MainActor
struct LiveTriageEngineFolderExportTests {
    private func engine() -> LiveTriageEngine {
        LiveTriageEngine(
            environment: [:],
            locations: ModelLocations(appSupportRoot: LibraryFixtures.tempDir("export-support")),
            storeURL: LibraryFixtures.tempDir("export-store").appendingPathComponent("store.json"),
            subjectId: "subj",
            modelId: "m",
            modelVersion: "1"
        )
    }

    // MARK: - Assertion 1: intra-batch collision de-collided, honest count

    /// Regression test for the pre-fix export loop in `LiveTriageEngine`, which computed
    /// `destination = directory.appendingPathComponent(source.lastPathComponent)`
    /// unconditionally for every source, so the SECOND `IMG_0001.jpg` silently
    /// `removeItem`s + `copyItem`s over the first — `exported` still increments to 2,
    /// but only ONE file (`IMG_0001.jpg`, holding B's bytes) exists on disk, so
    /// `entries.count == 2` here fails pre-fix.
    @Test("two exported photos that share a destination filename both survive under distinct names")
    func collisionDeCollidesAndPreservesBoth() async throws {
        let engine = engine()
        let dirA = LibraryFixtures.tempDir("collide-src-a")
        let dirB = LibraryFixtures.tempDir("collide-src-b")
        let sourceA = dirA.appendingPathComponent("IMG_0001.jpg")
        let sourceB = dirB.appendingPathComponent("IMG_0001.jpg")
        LibraryFixtures.writeImage(to: sourceA, red: 0.1)
        LibraryFixtures.writeImage(to: sourceB, red: 0.9) // distinct bytes from sourceA
        let dest = LibraryFixtures.tempDir("collide-dest")

        let count = try await engine.export(fileURLs: [sourceA, sourceB], destination: .folder(dest))

        #expect(count == 2)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
        #expect(entries == ["IMG_0001-2.jpg", "IMG_0001.jpg"]) // BOTH survive, distinct names

        let dataA = try Data(contentsOf: dest.appendingPathComponent("IMG_0001.jpg"))
        let dataB = try Data(contentsOf: dest.appendingPathComponent("IMG_0001-2.jpg"))
        let sourceDataA = try Data(contentsOf: sourceA)
        let sourceDataB = try Data(contentsOf: sourceB)
        #expect(dataA == sourceDataA) // each file byte-equal to ITS OWN source
        #expect(dataB == sourceDataB)
        #expect(dataA != dataB) // a clobber would make these identical
    }

    // MARK: - Assertion 2: pre-existing stale file is overwritten, not de-collided

    @Test("a name that only collides with a stale on-disk file is overwritten, not de-collided")
    func preExistingFileIsOverwrittenNotDecollided() async throws {
        let engine = engine()
        let dest = LibraryFixtures.tempDir("stale-dest")
        let stale = dest.appendingPathComponent("IMG_0001.jpg")
        LibraryFixtures.writeImage(to: stale, red: 0.05) // pre-seeded stale file

        let srcDir = LibraryFixtures.tempDir("stale-src")
        let newSource = srcDir.appendingPathComponent("IMG_0001.jpg")
        LibraryFixtures.writeImage(to: newSource, red: 0.75) // distinct bytes from the stale file

        let count = try await engine.export(fileURLs: [newSource], destination: .folder(dest))

        #expect(count == 1)
        let entries = try FileManager.default.contentsOfDirectory(atPath: dest.path)
        #expect(entries == ["IMG_0001.jpg"]) // no "-2" file created
        let written = try Data(contentsOf: dest.appendingPathComponent("IMG_0001.jpg"))
        let newSourceData = try Data(contentsOf: newSource)
        #expect(written == newSourceData) // overwritten with the NEW source's bytes
    }

    // MARK: - Assertion 3: the real entry point copies off the main actor

    @Test("export(..., destination: .folder) copies off the main actor, observed inside the real copy routine")
    func copyRunsOffMainActor() async throws {
        let engine = engine()
        let srcDir = LibraryFixtures.tempDir("offmain-src")
        var sources: [URL] = []
        for i in 0 ..< 3 {
            let url = srcDir.appendingPathComponent("f\(i).jpg")
            LibraryFixtures.writeImage(to: url, red: 0.1 * CGFloat(i))
            sources.append(url)
        }
        let dest = LibraryFixtures.tempDir("offmain-dest")
        let recorder = ThreadRecorder()
        engine.testDidCopyFile = { recorder.record() }

        // This test method itself runs on the @MainActor — the assertion is that the
        // recorder, fired from INSIDE the real off-actor copy loop, never observed
        // the main thread regardless of what thread the caller happens to be on.
        let count = try await engine.export(fileURLs: sources, destination: .folder(dest))

        #expect(count == 3)
        #expect(recorder.callCount == 3)
        #expect(recorder.observedMainThread == false)
    }

    // MARK: - Assertion 7 (engine half): a mid-export failure throws, first file intact

    @Test("a mid-export copy failure throws and leaves the already-written file byte-for-byte intact")
    func midExportFailureThrowsAndPreservesFirstFile() async throws {
        let engine = engine()
        let srcDir = LibraryFixtures.tempDir("partial-src")
        let goodSource = srcDir.appendingPathComponent("a.jpg")
        LibraryFixtures.writeImage(to: goodSource, red: 0.33)
        // Never written to disk — `copyItem` throws when the loop reaches it, AFTER
        // the first file has already landed.
        let missingSource = srcDir.appendingPathComponent("missing.jpg")
        let dest = LibraryFixtures.tempDir("partial-dest")

        do {
            _ = try await engine.export(fileURLs: [goodSource, missingSource], destination: .folder(dest))
            Issue.record("expected the mid-export copy failure to throw")
        } catch {
            // Expected: the second copy fails and the error propagates.
        }

        let written = dest.appendingPathComponent("a.jpg")
        #expect(FileManager.default.fileExists(atPath: written.path))
        let writtenData = try Data(contentsOf: written)
        let sourceData = try Data(contentsOf: goodSource)
        #expect(writtenData == sourceData) // byte-for-byte, no re-encode
    }
}

/// Item 54, assertion 4: `LiveTriageEngine.export(..., .photos)` at the ENGINE level —
/// a non-`.authorized` status (denied OR limited) throws the typed error rather than
/// returning 0, and the real `PHPhotoLibrary` is never touched (the injected spy
/// stands in for it entirely). Also covers the denial ≠ empty contrast at the engine
/// level: a genuinely empty source set returns 0 WITHOUT ever asking for
/// authorization.
@Suite("LiveTriageEngine Photos authorization (item 54)")
@MainActor
struct LiveTriageEnginePhotosAuthorizationTests {
    private func engine(status: PHAuthorizationStatus) -> LiveTriageEngine {
        LiveTriageEngine(
            environment: [:],
            locations: ModelLocations(appSupportRoot: LibraryFixtures.tempDir("photos-support")),
            storeURL: LibraryFixtures.tempDir("photos-store").appendingPathComponent("store.json"),
            subjectId: "subj",
            modelId: "m",
            modelVersion: "1",
            photosAuthorizationClient: SpyPhotosAuthorizationClient(status: status)
        )
    }

    private func aValidSource() -> URL {
        let dir = LibraryFixtures.tempDir("photos-src")
        let url = dir.appendingPathComponent("a.jpg")
        LibraryFixtures.writeImage(to: url)
        return url
    }

    @Test(".denied throws the typed error, never returns 0")
    func deniedThrows() async throws {
        let engine = engine(status: .denied)
        let source = aValidSource()

        do {
            let count = try await engine.export(fileURLs: [source], destination: .photos)
            Issue.record("expected photosAccessNotAuthorized to be thrown, got count \(count)")
        } catch let error as KiFinder.ExportError {
            #expect(error == .photosAccessNotAuthorized)
        } catch {
            Issue.record("expected KiFinder.ExportError, got \(error)")
        }
    }

    @Test(".limited throws the typed error (add-only entitlement treats it as insufficient), never returns 0")
    func limitedThrows() async throws {
        let engine = engine(status: .limited)
        let source = aValidSource()

        do {
            let count = try await engine.export(fileURLs: [source], destination: .photos)
            Issue.record("expected photosAccessNotAuthorized to be thrown, got count \(count)")
        } catch let error as KiFinder.ExportError {
            #expect(error == .photosAccessNotAuthorized)
        } catch {
            Issue.record("expected KiFinder.ExportError, got \(error)")
        }
    }

    @Test("an authorized-but-empty export returns 0 WITHOUT even requesting authorization — genuinely nothing to do")
    func emptySourcesNeverRequestsAuthorization() async throws {
        // A source that doesn't exist on disk ⇒ the "valid" set is empty, which the
        // engine treats as a genuine no-op BEFORE asking Photos for anything — the
        // contrast case: no denial ever occurred, so the denial error must not surface.
        let spy = SpyPhotosAuthorizationClient(status: .denied) // would throw if ever asked
        let engine = LiveTriageEngine(
            environment: [:],
            locations: ModelLocations(appSupportRoot: LibraryFixtures.tempDir("photos-support-2")),
            storeURL: LibraryFixtures.tempDir("photos-store-2").appendingPathComponent("store.json"),
            subjectId: "subj",
            modelId: "m",
            modelVersion: "1",
            photosAuthorizationClient: spy
        )
        let missing = LibraryFixtures.tempDir("photos-missing").appendingPathComponent("gone.jpg")

        let count = try await engine.export(fileURLs: [missing], destination: .photos)

        #expect(count == 0)
        #expect(spy.requestCount == 0) // never even asked — proves genuinely empty ≠ denial
    }
}

/// Item 54: the MODEL-layer half of the fix — the Photos-denial → `exportError`
/// mapping at every Photos entry point (assertion 5), the denial-vs-empty contrast
/// (assertion 6), the model surfacing a mid-export failure honestly rather than
/// claiming a stale count (assertion 7, model half), and every one of the five export
/// entry points routing the correct source set through to the engine and succeeding
/// on the happy path (assertion 8) — folder flows additionally verified by real files
/// on disk, since the spy's `.folder` branch reuses the REAL
/// `LiveTriageEngine.copyFilesOffMainActor` rather than re-implementing the copy.
@Suite("AppModel export denial + flows (item 54)")
@MainActor
struct AppModelExportCorrectnessTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-export-correctness-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func model(_ engine: ScanExportSpyEngine) -> AppModel {
        AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStore()])
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .keep) -> Candidate {
        Candidate(
            id: id,
            photoKey: "key-\(id)",
            fileName: "\(id).jpg",
            imageResourceName: "",
            score: 0.9,
            bucket: bucket
        )
    }

    private let tmpAlbum = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

    private func drain() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    private let genericMessage = String(localized: "The export couldn't be completed. Please try again.")

    // MARK: - Assertion 5: denial at every Photos entry point (×3)

    @Test("exportSelectedToPhotos: a Photos denial sets the System-Settings message, no summary, no count")
    func exportSelectedToPhotosDenial() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        model.select("a")

        spy.exportShouldThrowNotAuthorized = true
        model.exportSelectedToPhotos()
        await drain()

        let expectedMessage = model.exportErrorMessage(for: KiFinder.ExportError.photosAccessNotAuthorized)
        #expect(model.exportError == expectedMessage)
        #expect(model.exportError != genericMessage) // distinct from the generic failure message
        #expect(!model.isExportSummaryPresented)
        #expect(model.exportedCount == 0)
    }

    @Test("exportKeptToPhotos: a Photos denial sets the System-Settings message, no summary, no count")
    func exportKeptToPhotosDenial() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        spy.exportShouldThrowNotAuthorized = true
        model.exportKeptToPhotos()
        await drain()

        let expectedMessage = model.exportErrorMessage(for: KiFinder.ExportError.photosAccessNotAuthorized)
        #expect(model.exportError == expectedMessage)
        #expect(model.exportError != genericMessage)
        #expect(!model.isExportSummaryPresented)
        #expect(model.exportedCount == 0)
    }

    @Test("exportSelectedLibraryToPhotos: a Photos denial sets the System-Settings message, no summary, no count")
    func exportSelectedLibraryToPhotosDenial() async {
        let root = LibraryFixtures.tempDir("denial-root")
        let index = LibraryFixtures.tempDir("denial-index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)
        let source = LibraryFixtures.tempDir("denial-src").appendingPathComponent("IMG_0.jpg")
        LibraryFixtures.writeImage(to: source, red: 0.4)
        guard case .saved = await lib.save(originalAt: source, subjectId: "kion", personName: "kion", score: 0.9) else {
            Issue.record("expected a saved library entry")
            return
        }

        let spy = ScanExportSpyEngine()
        let model = AppModel(
            engine: spy,
            environment: ["KION_PROFILE_STORE": uniqueStore(), "KION_LIBRARY_ROOT": root.path],
            keptLibrary: lib
        )
        model.showLibrary()
        let ids = model.libraryOrderedIDs
        #expect(!ids.isEmpty) // precondition: something to select
        model.selectLibrary(ids[0])

        spy.exportShouldThrowNotAuthorized = true
        model.exportSelectedLibraryToPhotos()
        await drain()

        let expectedMessage = model.exportErrorMessage(for: KiFinder.ExportError.photosAccessNotAuthorized)
        #expect(model.exportError == expectedMessage)
        #expect(model.exportError != genericMessage)
        #expect(!model.isExportSummaryPresented)
        #expect(model.exportedCount == 0)
    }

    // MARK: - Assertion 6: denial ≠ empty — authorized-but-empty still succeeds

    @Test("an authorized export that genuinely has nothing to write still shows the success path")
    func authorizedButEmptyStillSucceeds() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        model.select("a")

        // Non-empty selection reaches the engine, but the engine (authorized) reports
        // 0 written WITHOUT throwing — distinct from a denial, which always throws.
        spy.exportReturnCountOverride = 0
        model.exportSelectedToPhotos()
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 0)
    }

    // MARK: - Assertion 7 (model half): a REAL mid-batch partial failure through the
    // production entry point — NOT a spy that throws before any real work happens.

    /// Drives `exportKept(toFolder:)` — a real production entry point — with the spy's
    /// `.folder` branch resolving BOTH photo keys to real on-disk URLs, so the exact
    /// production copy routine (`LiveTriageEngine.copyFilesOffMainActor`, reused by the
    /// spy rather than re-implemented) genuinely processes the batch in order: the
    /// FIRST source is a real file that copies byte-for-byte, the SECOND source is a
    /// path that was never written — a source that vanished mid-batch, the same
    /// realistic failure mechanism the real-engine half of this assertion uses — so
    /// `copyItem` genuinely throws only once the first file has already landed. This
    /// is the concrete, single-test proof that a genuine partial write neither reports
    /// a success summary nor claims the full count, closing the gap between the
    /// real-engine test (which never touches the model) and the old generic-throw
    /// spy test (which never touched a real byte).
    @Test("a real mid-batch partial failure through exportKept(toFolder:) leaves the first file intact and surfaces exportError, never a success summary or a stale count")
    func midExportPartialFailureThroughProductionPath() async throws {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        let srcDir = LibraryFixtures.tempDir("partial-model-src")
        let urlA = srcDir.appendingPathComponent("a.jpg")
        LibraryFixtures.writeImage(to: urlA, red: 0.44)
        // key-b resolves to a source that was NEVER written to disk — it "vanished"
        // before the batch reached it, so the real copy loop's `copyItem` genuinely
        // throws on the second file, after the first has already been written.
        let urlB = srcDir.appendingPathComponent("missing.jpg")
        spy.sourceURLByPhotoKey = ["key-a": urlA, "key-b": urlB]

        let dest = LibraryFixtures.tempDir("partial-model-dest")
        model.exportKept(toFolder: dest)
        await drain()

        // The model surfaces the failure honestly: an error, no summary, no count.
        #expect(model.exportError != nil)
        #expect(!model.isExportSummaryPresented)
        #expect(model.exportedCount == 0) // never a stale "2" (or "1")

        // The FIRST file genuinely landed, byte-for-byte — proof this was a REAL
        // partial write through the production copy routine, not a spy that threw
        // before any real work happened.
        let writtenA = dest.appendingPathComponent("a.jpg")
        #expect(FileManager.default.fileExists(atPath: writtenA.path))
        #expect(try Data(contentsOf: writtenA) == Data(contentsOf: urlA))
        // The failed second file never landed.
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("missing.jpg").path))
    }

    // MARK: - Assertion 8: all five export flows route + succeed

    @Test("exportKept(toFolder:) routes the kept source set through a real folder copy, verified on disk")
    func keptToFolderRoutesAndWritesFiles() async throws {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        let srcDir = LibraryFixtures.tempDir("kept-folder-src")
        let urlA = srcDir.appendingPathComponent("a.jpg")
        let urlB = srcDir.appendingPathComponent("b.jpg")
        LibraryFixtures.writeImage(to: urlA, red: 0.15)
        LibraryFixtures.writeImage(to: urlB, red: 0.65)
        spy.sourceURLByPhotoKey = ["key-a": urlA, "key-b": urlB]

        let dest = LibraryFixtures.tempDir("kept-folder-dest")
        model.exportKept(toFolder: dest)
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
        let call = try #require(spy.photoKeyExportCalls.last)
        #expect(Set(call.keys) == ["key-a", "key-b"])
        #expect(call.destination == .folder(dest))
        // Folder flow additionally verified by real files on disk, byte-for-byte.
        let writtenA = dest.appendingPathComponent("a.jpg")
        let writtenB = dest.appendingPathComponent("b.jpg")
        #expect(FileManager.default.fileExists(atPath: writtenA.path))
        #expect(FileManager.default.fileExists(atPath: writtenB.path))
        #expect(try Data(contentsOf: writtenA) == Data(contentsOf: urlA))
        #expect(try Data(contentsOf: writtenB) == Data(contentsOf: urlB))
    }

    @Test("exportKeptToPhotos routes exactly the kept source set with .photos")
    func keptToPhotosRoutes() async throws {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)

        model.exportKeptToPhotos()
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
        let call = try #require(spy.photoKeyExportCalls.last)
        #expect(Set(call.keys) == ["key-a", "key-b"])
        #expect(call.destination == .photos)
    }

    @Test("exportSelected(toFolder:) routes exactly the selected source set through a real folder copy, verified on disk")
    func selectedToFolderRoutesAndWritesFiles() async throws {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [
            ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b"), candidate("c")], isFinal: true),
        ]
        await model.runScan(albums: tmpAlbum)
        model.select("a")
        model.toggleSelection("c")

        let srcDir = LibraryFixtures.tempDir("selected-folder-src")
        let urlA = srcDir.appendingPathComponent("a.jpg")
        let urlC = srcDir.appendingPathComponent("c.jpg")
        LibraryFixtures.writeImage(to: urlA, red: 0.2)
        LibraryFixtures.writeImage(to: urlC, red: 0.8)
        spy.sourceURLByPhotoKey = ["key-a": urlA, "key-c": urlC]

        let dest = LibraryFixtures.tempDir("selected-folder-dest")
        model.exportSelected(toFolder: dest)
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
        let call = try #require(spy.photoKeyExportCalls.last)
        #expect(Set(call.keys) == ["key-a", "key-c"])
        let writtenA = dest.appendingPathComponent("a.jpg")
        let writtenC = dest.appendingPathComponent("c.jpg")
        #expect(FileManager.default.fileExists(atPath: writtenA.path))
        #expect(FileManager.default.fileExists(atPath: writtenC.path))
        #expect(try Data(contentsOf: writtenA) == Data(contentsOf: urlA))
        #expect(try Data(contentsOf: writtenC) == Data(contentsOf: urlC))
    }

    @Test("exportSelectedToPhotos routes exactly the selected source set with .photos")
    func selectedToPhotosRoutes() async throws {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        spy.progressToYield = [ScanProgress(progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true)]
        await model.runScan(albums: tmpAlbum)
        model.select("a")
        model.toggleSelection("b")

        model.exportSelectedToPhotos()
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
        let call = try #require(spy.photoKeyExportCalls.last)
        #expect(Set(call.keys) == ["key-a", "key-b"])
        #expect(call.destination == .photos)
    }

    @Test("exportSelectedLibraryToPhotos routes exactly the selected library URLs with .photos")
    func selectedLibraryToPhotosRoutes() async throws {
        let root = LibraryFixtures.tempDir("flow-root")
        let index = LibraryFixtures.tempDir("flow-index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)
        for i in 0 ..< 2 {
            let source = LibraryFixtures.tempDir("flow-src").appendingPathComponent("IMG_\(i).jpg")
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.3 * CGFloat(i), exifDate: "2021:07:1\(i) 12:00:00")
            guard case .saved = await lib.save(originalAt: source, subjectId: "kion", personName: "kion", score: 0.9)
            else {
                Issue.record("expected a saved library entry for index \(i)")
                continue
            }
        }

        let spy = ScanExportSpyEngine()
        let model = AppModel(
            engine: spy,
            environment: ["KION_PROFILE_STORE": uniqueStore(), "KION_LIBRARY_ROOT": root.path],
            keptLibrary: lib
        )
        model.showLibrary()
        let ids = model.libraryOrderedIDs
        #expect(ids.count == 2)
        model.selectLibrary(ids[0])
        model.toggleLibrarySelection(ids[1])
        let expectedURLs = model.selectedLibraryFileURLs
        #expect(expectedURLs.count == 2)

        model.exportSelectedLibraryToPhotos()
        await drain()

        #expect(model.exportError == nil)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
        let call = try #require(spy.fileURLExportCalls.last)
        #expect(call.urls == expectedURLs)
        #expect(call.destination == .photos)
    }
}
