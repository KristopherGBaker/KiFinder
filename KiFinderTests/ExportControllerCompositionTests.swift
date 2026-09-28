import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 61 seam coverage: `AppModel` COMPOSES a separate `ExportController` — not an
/// `AppModel` extension, and not a duplicated copy of state — and the LIBRARY export
/// (`exportSelectedLibraryToPhotos`, `AppModel+LibrarySelection.swift`) is REROUTED
/// through that SAME controller/channel instead of writing `AppModel`'s state directly
/// (the behavior the pre-item-61 `internal`-widened setters existed for). This suite
/// proves, driven entirely through the `ScanExportSpyEngine` already shared across the
/// export test suites (`AppModelScanExportErrorTests.swift`, internal-level, reused here
/// without modifying that file):
///
/// (a) a THROWN `exportSelectedLibraryToPhotos` surfaces through `model.exportError` AND
///     `model.export.exportError` IDENTICALLY (the same channel, not a copy), presents no
///     summary, and reaches the engine's `export(fileURLs:destination:)` exactly once with
///     the selected library URLs.
/// (b) a SUCCESSFUL one surfaces matching summary state through BOTH the facade and the
///     composed controller (count, presented flag, destination).
/// (c) a NON-library facade export (`exportKept(toFolder:)`) mutates the SAME
///     `model.export` instance captured before the call — proving one shared
///     `ExportController`, not two.
@Suite("ExportController composition + shared channel (item 61)")
@MainActor
struct ExportControllerCompositionTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-exportcontroller-composition-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func drain() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    /// Builds a model whose injected library holds `count` saved photos for a subject and
    /// shows the Library (so `libraryOrderedIDs` is populated), wired to `engine`.
    private func populatedLibraryModel(engine: ScanExportSpyEngine, count: Int = 2) async -> AppModel {
        let root = LibraryFixtures.tempDir("export-ctrl-root")
        let index = LibraryFixtures.tempDir("export-ctrl-index").appendingPathComponent("library-index.json")
        let lib = KeptLibrary(root: root, indexURL: index)
        for i in 0 ..< count {
            let source = LibraryFixtures.tempDir("export-ctrl-src").appendingPathComponent("IMG_\(i).jpg")
            LibraryFixtures.writeImage(to: source, red: 0.1 + 0.2 * CGFloat(i), exifDate: "2021:07:1\(i) 12:00:00")
            _ = await lib.save(originalAt: source, subjectId: "kris", personName: "kris", score: 0.9)
        }
        let model = AppModel(
            engine: engine,
            environment: ["KION_PROFILE_STORE": uniqueStore(), "KION_LIBRARY_ROOT": root.path],
            keptLibrary: lib
        )
        model.showLibrary()
        return model
    }

    // MARK: - (a) a thrown library export shares the error channel, no summary, one call

    @Test("a thrown exportSelectedLibraryToPhotos surfaces through BOTH the facade and model.export identically")
    func libraryThrowSharesErrorChannel() async {
        let spy = ScanExportSpyEngine()
        let model = await populatedLibraryModel(engine: spy, count: 1)
        let ids = model.libraryOrderedIDs
        #expect(!ids.isEmpty)
        model.selectLibrary(ids[0])
        let expectedURLs = model.selectedLibraryFileURLs
        #expect(!expectedURLs.isEmpty)

        spy.exportShouldThrow = true
        model.exportSelectedLibraryToPhotos()
        await drain()

        // The SAME channel, not a second copy: facade and composed controller agree.
        #expect(model.exportError != nil)
        #expect(model.exportError == model.export.exportError)
        #expect(model.isExportSummaryPresented == false)
        #expect(model.export.isExportSummaryPresented == false)

        // Exactly ONE engine call, with the selected library URLs, routed through the
        // fileURLs overload (never the photoKeys one) at .photos.
        #expect(spy.exportCallCount == 1)
        #expect(spy.fileURLExportCalls.count == 1)
        #expect(spy.fileURLExportCalls.first?.urls == expectedURLs)
        #expect(spy.fileURLExportCalls.first?.destination == .photos)
        #expect(spy.photoKeyExportCalls.isEmpty)
    }

    // MARK: - (b) a successful library export shares the summary channel

    @Test("a successful exportSelectedLibraryToPhotos surfaces matching summary state through BOTH the facade and model.export")
    func librarySuccessSharesSummaryChannel() async {
        let spy = ScanExportSpyEngine()
        let model = await populatedLibraryModel(engine: spy, count: 2)
        let ids = model.libraryOrderedIDs
        #expect(ids.count == 2)
        model.selectLibrary(ids[0])
        model.toggleLibrarySelection(ids[1])
        let expectedURLs = model.selectedLibraryFileURLs
        #expect(expectedURLs.count == 2)

        model.exportSelectedLibraryToPhotos()
        await drain()

        #expect(model.exportError == nil)
        #expect(model.exportedCount == expectedURLs.count)
        #expect(model.export.exportedCount == expectedURLs.count)
        #expect(model.exportedCount == model.export.exportedCount)
        #expect(model.isExportSummaryPresented == true)
        #expect(model.export.isExportSummaryPresented == true)
        #expect(model.exportDestination == nil)
        #expect(model.export.exportDestination == nil)
    }

    // MARK: - (c) a non-library facade export mutates the SAME composed instance

    @Test("exportKept(toFolder:) — a non-library facade export — mutates the SAME model.export instance the library export uses")
    func nonLibraryExportMutatesSharedInstance() async throws {
        let spy = ScanExportSpyEngine()
        let model = AppModel(engine: spy, environment: ["KION_PROFILE_STORE": uniqueStore()])
        // Capture the composed instance BEFORE the export runs — proves it's never
        // replaced/duplicated by a later export call.
        let controller = try #require(model.export)

        spy.progressToYield = [ScanProgress(
            progress: 1,
            candidates: [Candidate(id: "a", photoKey: "key-a", fileName: "a.jpg", imageResourceName: "", score: 0.9, bucket: .keep)],
            isFinal: true
        )]
        await model.runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
        #expect(model.keepCount == 1)

        let dest = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-export-ctrl-kept-\(UUID().uuidString)", isDirectory: true)
        model.exportKept(toFolder: dest)
        await drain()

        #expect(model.export === controller) // same instance throughout
        #expect(controller.exportedCount == 1) // the captured instance's OWN state mutated
        #expect(controller.isExportSummaryPresented == true)
        #expect(model.exportedCount == 1)
        #expect(model.isExportSummaryPresented == true)
    }
}
