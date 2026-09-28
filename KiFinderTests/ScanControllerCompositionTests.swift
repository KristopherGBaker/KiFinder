import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item 63 seam coverage: `AppModel` COMPOSES a separate `ScanController` — not an
/// `AppModel` extension, and not a duplicated copy of state. Mirrors
/// `ExportControllerCompositionTests` (item 61): driven entirely through the
/// `ScanExportSpyEngine` already shared across the scan/export test suites
/// (`AppModelScanExportErrorTests.swift`, reused here without modifying that file).
///
/// Proves:
/// (a) a scan routed through the AppModel facade is reflected in `ScanController` state —
///     `model.scanError == model.scan.scanError`, the SAME instance, not a copy.
/// (b) the item-54 guard holds through the facade: a failed scan sets `model.scanError`
///     AND leaves `model.keepCount` unchanged — the prior review is never clobbered.
@Suite("ScanController composition + item-54 guard through the facade (item 63)")
@MainActor
struct ScanControllerCompositionTests {
    private func uniqueStore() -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-scancontroller-composition-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json").path
    }

    private func model(_ engine: ScanExportSpyEngine) -> AppModel {
        AppModel(engine: engine, environment: ["KION_PROFILE_STORE": uniqueStore()])
    }

    private func candidate(_ id: String, bucket: ReviewBucket = .keep) -> Candidate {
        Candidate(id: id, photoKey: "key-\(id)", fileName: "\(id).jpg", imageResourceName: "", score: 0.9, bucket: bucket)
    }

    private let tmpAlbum = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]

    // MARK: - (a) same channel, same instance — not a duplicated copy of state

    @Test("model.scanError and model.scan.scanError are the SAME channel through a failed scan routed via the facade")
    func facadeAndControllerShareScanErrorChannel() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)
        // Capture the composed instance BEFORE the scan runs — proves it's never
        // replaced/duplicated by a later scan call.
        let controller = model.scan

        spy.progressToYield = [ScanProgress(
            progress: 1, candidates: [], isFinal: true, errorMessage: "boom"
        )]
        await model.runScan(albums: tmpAlbum)

        #expect(model.scan === controller) // same instance throughout
        #expect(model.scanError != nil)
        #expect(model.scanError == model.scan.scanError) // the SAME channel, not a copy
    }

    // MARK: - (b) the item-54 guard through the facade: error ⇒ scanError set, keepCount untouched

    @Test("through the facade, a failed scan sets model.scanError and leaves model.keepCount unchanged")
    func item54GuardHoldsThroughFacade() async {
        let spy = ScanExportSpyEngine()
        let model = model(spy)

        // A first, successful scan seeds a review via the facade.
        spy.progressToYield = [ScanProgress(
            progress: 1, candidates: [candidate("a"), candidate("b")], isFinal: true
        )]
        await model.runScan(albums: tmpAlbum)
        #expect(model.scanError == nil)
        #expect(model.keepCount == 2)

        // A second scan, routed through the SAME facade call, FAILS.
        spy.progressToYield = [ScanProgress(
            progress: 1, candidates: [], isFinal: true, errorMessage: "boom"
        )]
        await model.runScan(albums: tmpAlbum)

        #expect(model.scanError != nil)
        #expect(model.scan.scanError != nil)
        #expect(model.keepCount == 2) // NOT clobbered to empty
        #expect(model.keepCandidates.count == 2)
    }
}
