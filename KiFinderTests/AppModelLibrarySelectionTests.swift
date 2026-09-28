import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 28: the Library browse grid's multi-selection on `AppModel` — the selection ops
/// over `libraryOrderedIDs` (select/toggle/extend/clear) and their anchor semantics, the
/// ordered + missing-file-skipped `selectedLibraryFileURLs`, and `exportSelectedLibraryToPhotos`
/// routing exactly those URLs through the engine. The library selection is library-scoped
/// and SEPARATE from the review grid's `selectedPhotoIDs`.
@Suite("App model library selection")
@MainActor
struct AppModelLibrarySelectionTests {
    private let kion = SampleTriageEngine.primarySubjectID
    private let exif = "2021:07:15 12:00:00"

    private func store() -> String {
        LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path
    }

    /// Builds a sample-mode model whose injected library holds `count` saved photos for
    /// Kris (same month, distinct content), with `libraryRoot` wired to where the copies
    /// live. Returns the model, the library, and the saved entries (save order).
    private func populated(
        count: Int = 4,
        engine: (any TriageEngine)? = nil
    ) async -> (AppModel, KeptLibrary, [KeptEntry]) {
        let root = LibraryFixtures.tempDir("root")
        let index = LibraryFixtures.tempDir("index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)

        var entries: [KeptEntry] = []
        for i in 0 ..< count {
            let source = LibraryFixtures.tempDir("src").appendingPathComponent("IMG_\(i).jpg")
            // Distinct red ⇒ distinct bytes ⇒ distinct sha (per-person dedupe is happy);
            // distinct EXIF day keeps captureDate ordering deterministic within the month.
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.15 * CGFloat(i), exifDate: "2021:07:1\(i) 12:00:00")
            guard case let .saved(entry) = await lib.save(
                originalAt: source, subjectId: kion, personName: kion, score: 0.9
            ) else {
                Issue.record("expected .saved for entry \(i)")
                continue
            }
            entries.append(entry)
        }

        let model = AppModel(
            engine: engine ?? SampleTriageEngine(),
            environment: [
                "KION_SAMPLE": "1",
                "KION_PROFILE_STORE": store(),
                "KION_LIBRARY_ROOT": root.path,
            ],
            keptLibrary: lib
        )
        model.showLibrary()
        return (model, lib, entries)
    }

    private func drain() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    // MARK: - Selection ops

    @Test("selectLibrary replaces the selection with one id, sets the anchor, and focuses it")
    func selectReplacesAnchorsFocuses() async {
        let (model, _, _) = await populated()
        let ids = model.libraryOrderedIDs
        #expect(ids.count >= 4)

        model.selectLibrary(ids[1])
        #expect(model.selectedLibraryIDs == [ids[1]])
        #expect(model.libraryFocusedID == ids[1]) // select also focuses

        // The anchor is now ids[1]: extending forward to ids[3] yields the inclusive
        // range from that anchor (proving select re-seated the anchor).
        model.extendLibrarySelection(to: ids[3])
        #expect(model.selectedLibraryIDs == Set([ids[1], ids[2], ids[3]]))

        // Re-selecting collapses back to a single id (and re-anchors).
        model.selectLibrary(ids[0])
        #expect(model.selectedLibraryIDs == [ids[0]])
    }

    @Test("toggleLibrarySelection adds then removes an id without moving the anchor")
    func toggleAddsRemovesLeavingAnchor() async {
        let (model, _, _) = await populated()
        let ids = model.libraryOrderedIDs
        model.selectLibrary(ids[0]) // anchor = ids[0]

        model.toggleLibrarySelection(ids[3])
        #expect(model.selectedLibraryIDs == Set([ids[0], ids[3]]))
        model.toggleLibrarySelection(ids[3])
        #expect(model.selectedLibraryIDs == [ids[0]])

        // The toggle did NOT move the anchor: extend still runs from ids[0].
        model.toggleLibrarySelection(ids[2])
        model.extendLibrarySelection(to: ids[1])
        #expect(model.selectedLibraryIDs == Set([ids[0], ids[1]]))
    }

    @Test("extendLibrarySelection yields the exact inclusive set in BOTH directions")
    func extendBothDirections() async {
        let (forward, _, _) = await populated()
        let fids = forward.libraryOrderedIDs
        forward.selectLibrary(fids[0])
        forward.extendLibrarySelection(to: fids[2])
        #expect(forward.selectedLibraryIDs == Set([fids[0], fids[1], fids[2]]))

        let (backward, _, _) = await populated()
        let bids = backward.libraryOrderedIDs
        backward.selectLibrary(bids[2])
        backward.extendLibrarySelection(to: bids[0])
        #expect(backward.selectedLibraryIDs == Set([bids[0], bids[1], bids[2]]))
    }

    @Test("extendLibrarySelection with no anchor behaves like selectLibrary")
    func extendWithoutAnchor() async {
        let (model, _, _) = await populated()
        let ids = model.libraryOrderedIDs
        #expect(model.libraryAnchorID == nil)
        model.extendLibrarySelection(to: ids[2])
        #expect(model.selectedLibraryIDs == [ids[2]])
        #expect(model.libraryAnchorID == ids[2])
    }

    @Test("no library selection op admits an id outside libraryOrderedIDs")
    func opsRejectUnknownIDs() async {
        let (model, _, _) = await populated()
        let ids = model.libraryOrderedIDs

        model.selectLibrary("ghost")
        #expect(model.selectedLibraryIDs.isEmpty)
        model.toggleLibrarySelection("ghost")
        #expect(model.selectedLibraryIDs.isEmpty)
        model.extendLibrarySelection(to: "ghost")
        #expect(model.selectedLibraryIDs.isEmpty)

        // A real selection followed by an out-of-set extend leaves it unchanged.
        model.selectLibrary(ids[0])
        model.extendLibrarySelection(to: "ghost")
        #expect(model.selectedLibraryIDs == [ids[0]])
    }

    // MARK: - Clear paths

    @Test("setLibraryFilter / showReview / removeFromLibrary / removeFocusedFromLibrary each empty a non-empty selection")
    func clearPaths() async {
        // setLibraryFilter
        do {
            let (model, _, _) = await populated()
            model.selectLibrary(model.libraryOrderedIDs[0])
            #expect(!model.selectedLibraryIDs.isEmpty)
            model.setLibraryFilter(kion)
            #expect(model.selectedLibraryIDs.isEmpty)
        }
        // showReview
        do {
            let (model, _, _) = await populated()
            model.selectLibrary(model.libraryOrderedIDs[0])
            #expect(!model.selectedLibraryIDs.isEmpty)
            model.showReview()
            #expect(model.selectedLibraryIDs.isEmpty)
        }
        // removeFromLibrary
        do {
            let (model, _, entries) = await populated()
            model.selectLibrary(model.libraryOrderedIDs[0])
            #expect(!model.selectedLibraryIDs.isEmpty)
            model.removeFromLibrary(entries[0])
            #expect(model.selectedLibraryIDs.isEmpty)
            await drain()
        }
        // removeFocusedFromLibrary
        do {
            let (model, _, _) = await populated()
            let ids = model.libraryOrderedIDs
            model.focusLibrary(ids[0])
            model.selectLibrary(ids[1])
            #expect(!model.selectedLibraryIDs.isEmpty)
            model.removeFocusedFromLibrary()
            #expect(model.selectedLibraryIDs.isEmpty)
            await drain()
        }
    }

    // MARK: - selectedLibraryFileURLs

    @Test("selectedLibraryFileURLs is in libraryOrderedIDs order and skips missing files")
    func selectedURLsOrderedMissingSkipped() async {
        let (model, _, _) = await populated()
        let ids = model.libraryOrderedIDs
        #expect(ids.count >= 3)

        // Select two NON-ADJACENT entries (0 and 2) whose files exist, plus the entry
        // between them (1) whose backing file we delete on disk.
        model.toggleLibrarySelection(ids[2]) // selected first, but must come back 2nd by order
        model.toggleLibrarySelection(ids[0])
        model.toggleLibrarySelection(ids[1])

        // Delete ids[1]'s backing file → it must be SKIPPED.
        let item1 = libraryItem(model, id: ids[1])
        try? FileManager.default.removeItem(at: item1.url)
        #expect(!FileManager.default.fileExists(atPath: item1.url.path))

        let url0 = libraryItem(model, id: ids[0]).url
        let url2 = libraryItem(model, id: ids[2]).url
        // Exactly the existing-file URLs, IN libraryOrderedIDs order (0 then 2), missing absent.
        #expect(model.selectedLibraryFileURLs == [url0, url2])
    }

    private func libraryItem(_ model: AppModel, id: String) -> LibraryPhotoItem {
        model.libraryGroups.flatMap { $0.months.flatMap(\.items) }.first { $0.entry.id == id }!
    }

    // MARK: - exportSelectedLibraryToPhotos

    @Test("exportSelectedLibraryToPhotos routes exactly selectedLibraryFileURLs with .photos")
    func exportRoutesSelectedURLs() async {
        let spy = ExportSpyEngine()
        let (model, _, _) = await populated(engine: spy)
        let ids = model.libraryOrderedIDs

        model.toggleLibrarySelection(ids[0])
        model.toggleLibrarySelection(ids[2])
        let expected = model.selectedLibraryFileURLs
        #expect(expected.count == 2)

        model.exportSelectedLibraryToPhotos()
        await drain()

        #expect(spy.exportCalls.count == 1)
        #expect(spy.exportCalls.first?.urls == expected)
        #expect(spy.exportCalls.first?.destination == .photos)
        #expect(model.isExportSummaryPresented)
        #expect(model.exportedCount == 2)
    }

    @Test("exportSelectedLibraryToPhotos with an empty selection is a graceful no-op")
    func exportEmptyNoOp() async {
        let spy = ExportSpyEngine()
        let (model, _, _) = await populated(engine: spy)
        #expect(model.selectedLibraryIDs.isEmpty)

        model.exportSelectedLibraryToPhotos()
        await drain()

        #expect(spy.exportCalls.isEmpty)
        #expect(!model.isExportSummaryPresented)
        #expect(model.exportedCount == 0)
    }

    // MARK: - Separation from review selection

    @Test("the library selection never touches the review selectedPhotoIDs")
    func separateFromReview() async {
        let (model, _, _) = await populated()
        model.selectLibrary(model.libraryOrderedIDs[0])
        #expect(!model.selectedLibraryIDs.isEmpty)
        #expect(model.selectedPhotoIDs.isEmpty) // review selection untouched
    }
}

/// A `TriageEngine` spy that records every `export(fileURLs:destination:)` call so a test
/// can assert the exact URLs + destination the library export routes through. Returns the
/// input count (matching the Sample engine), so the model's summary count is meaningful.
@MainActor
final class ExportSpyEngine: TriageEngine {
    struct ExportCall: Equatable {
        let urls: [URL]
        let destination: ExportDestination
    }

    private(set) var exportCalls: [ExportCall] = []

    func export(fileURLs: [URL], destination: ExportDestination) async throws -> Int {
        exportCalls.append(ExportCall(urls: fileURLs, destination: destination))
        return fileURLs.count
    }

    func export(photoKeys: [String], destination _: ExportDestination) async throws -> Int {
        photoKeys.count
    }

    func enroll(referenceURLs _: [URL]) async throws -> [FaceEmbedding] {
        []
    }

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        AsyncStream { $0.finish() }
    }

    func recordFeedback(photoKey _: String, label _: KiFinder.FeedbackLabel) async throws {}

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        FaceSelectionResult(score: 0, bucket: .other)
    }

    func rescoreAll(onlyPhotoKeys _: Set<String>?) async throws -> [String: RescoredPhoto] {
        [:]
    }
}
