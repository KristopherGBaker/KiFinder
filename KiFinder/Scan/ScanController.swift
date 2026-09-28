import Foundation
import KionEngine
import Observation

/// The scan-orchestration responsibility carved out of `AppModel` (item 63): owns the
/// scan sheet's live state (progress/status/error), the scan-summary fields, and the
/// single `apply(_:)` terminal-tick handler both `runScan`/`startScan` funnel through.
///
/// A separate `@Observable @MainActor` type COMPOSED by `AppModel` (`model.scan`) — not
/// an extension. Mirrors `ReviewSession` (item 59) and `ExportController` (item 61):
/// everything below is `private`/`private(set)`, reachable only through the narrow API
/// `AppModel` forwards.
///
/// `engine`/`review` are injected as their (class-bound) live references directly — a
/// reference type is already "live" with no snapshot risk. `returnToReviewFromLibrary`
/// is injected as a closure so it always reads `AppModel`'s CURRENT `libraryBrowseActive`
/// at the moment a scan's terminal tick lands, never a value snapshotted at
/// `ScanController` construction (item 57's "never a stale snapshot" discipline) — the
/// library-browse state itself stays on `AppModel`, which owns the rest of Library.
@Observable
@MainActor
final class ScanController {
    private let engine: any TriageEngine
    private let review: ReviewSession
    private let returnToReviewFromLibrary: () -> Void

    /// Whether the album-scan sheet is presented over Review. NOT `private(set)` —
    /// `KiFinderRootView` binds `$model.isScanPresented` directly to a `.sheet`, the
    /// same two-way-passthrough exception `ExportController.isExportSummaryPresented`
    /// documents (item 61).
    var isScanPresented = false
    /// True while a scan stream is being consumed.
    private(set) var isScanning = false
    /// 0…1 progress of the active/last scan, for the determinate bar.
    private(set) var scanProgress: Double = 0
    /// True when progress can't be measured (live one-shot scan) → show a spinner.
    private(set) var scanIndeterminate = false
    /// Running matched-candidate count shown live during the scan.
    private(set) var scanMatchesSoFar = 0
    /// Live status line (e.g. "42 of 312 · June.zip").
    private(set) var scanStatusText = ""
    /// True once the active scan finished (candidates applied → route to Review).
    private(set) var scanComplete = false
    /// Display name of the album being scanned.
    private(set) var scanAlbumName = ""
    private var scanTask: Task<Void, Never>?
    /// The albums of the most recent scan, retained so an error banner's "Try
    /// Again" can re-run the same scan.
    private var lastScanAlbums: [URL] = []
    /// Non-nil when the last scan FAILED (a localized, user-facing message).
    /// Distinct from a genuinely empty result: a failure keeps the prior review
    /// intact rather than clobbering it into a "nothing found" state, and the UI
    /// offers a retry/dismiss affordance. Cleared on a new scan or dismissal.
    private(set) var scanError: String?

    /// Total photos in the current scan, shown in the toolbar subtitle and sidebar.
    /// Zero until a scan runs and reports a real count.
    private(set) var totalPhotoCount = 0
    /// True once any scan has completed (sample seed or a real album), so the UI
    /// can show an inviting empty state before the first scan instead of bogus
    /// zero/placeholder counts.
    private(set) var hasCompletedScan = false
    /// Label of the most recently completed scan (album name, or "Sample Album"),
    /// or `nil` before the first scan. Drives the sidebar's current-scan summary.
    private(set) var currentScanLabel: String?

    init(
        engine: any TriageEngine,
        review: ReviewSession,
        returnToReviewFromLibrary: @escaping () -> Void
    ) {
        self.engine = engine
        self.review = review
        self.returnToReviewFromLibrary = returnToReviewFromLibrary
        // No back-call into the host: like `ExportController.init`, this type has no
        // init-time convenience that would route back through `AppModel.scan` while
        // it's still the nil IUO mid-assignment.
    }

    // MARK: - Deterministic scan entry (test/primary)

    func runScan(albums: [URL]) async {
        // A fresh scan clears any prior failure banner.
        scanError = nil
        // A scan reloads the store from disk, so flush any pending (coalesced)
        // feedback first — otherwise the scan could read a stale on-disk store.
        await engine.flush()
        for await progress in engine.scan(albums: albums) {
            apply(progress)
        }
    }

    /// Applies a scan tick. Only the terminal tick carries the candidate set, so
    /// intermediate progress ticks never clear the grid. Delegates the actual
    /// candidate-set write (ordering/decisions/selection/focus reset) to
    /// `ReviewSession.applyScan(candidates:)`; this method keeps the non-review scan
    /// bookkeeping (`scanError`, `totalPhotoCount`, `hasCompletedScan`, returning to
    /// Review from the Library browse).
    ///
    /// Item 54: on a final tick with an `errorMessage`, sets `scanError` and
    /// EARLY-RETURNS before `review.applyScan(...)` — a failed scan surfaces a
    /// retryable error and leaves the prior review grid intact; it must NOT clobber
    /// it to empty, and (from Library) it must NOT route to Review.
    private func apply(_ progress: ScanProgress) {
        guard progress.isFinal else { return }
        if let message = progress.errorMessage {
            scanError = message
            return
        }
        if progress.totalPhotos > 0 {
            totalPhotoCount = progress.totalPhotos
        }
        hasCompletedScan = true
        review.applyScan(candidates: progress.candidates)
        // A scan started from the Library browse view lands its results in Review, so
        // return the user there on success. Evaluated NOW (not a value captured at
        // `ScanController` construction) so a Library entry/exit between construction
        // and this tick is always honored.
        returnToReviewFromLibrary()
    }

    func refreshCandidatesIfNeeded() async {
        // Sample mode pre-populates the grid at init, so this is only a safety net
        // for the sample engine; the live engine waits for a real user-driven scan.
        guard !hasCompletedScan, engine is SampleTriageEngine else { return }
        currentScanLabel = String(localized: "Sample Album")
        await runScan(albums: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)])
    }

    // MARK: - Scan moment presentation

    /// Opens the album-scan sheet from a fresh idle state.
    func presentScan() {
        resetScanState()
        isScanPresented = true
    }

    /// Closes the scan sheet, cancelling any in-flight scan.
    func dismissScan() {
        cancelScanTask()
        isScanning = false
        isScanPresented = false
    }

    /// Starts a scan for albums dropped onto the empty review grid, presenting the
    /// scan sheet so its live progress is visible.
    func scanDroppedAlbums(_ albums: [URL]) {
        guard !albums.isEmpty else { return }
        resetScanState()
        isScanPresented = true
        startScan(albums: albums)
    }

    /// Drives `TriageEngine.scan` for the dropped/chosen albums, updating live
    /// progress as ticks arrive and applying the merged candidate set on completion.
    func startScan(albums: [URL]) {
        guard !albums.isEmpty else { return }
        lastScanAlbums = albums
        cancelScanTask()
        scanAlbumName = Self.scanLabel(for: albums)
        currentScanLabel = scanAlbumName
        scanProgress = 0
        scanMatchesSoFar = 0
        scanStatusText = ""
        scanIndeterminate = false
        scanComplete = false
        scanError = nil
        isScanning = true
        scanTask = Task { [weak self, engine] in
            guard let self else { return }
            // Flush pending feedback so the scan reads a fresh on-disk store.
            await engine.flush()
            for await progress in engine.scan(albums: albums) {
                if Task.isCancelled { break }
                scanProgress = progress.progress
                scanMatchesSoFar = progress.matchesSoFar
                scanStatusText = progress.statusText
                scanIndeterminate = progress.indeterminate
                if progress.totalPhotos > 0 {
                    totalPhotoCount = progress.totalPhotos
                }
                if progress.isFinal {
                    apply(progress)
                    // On failure, `apply` set `scanError` and left the review
                    // untouched — keep the scan sheet open on its error state
                    // (with retry) instead of routing to an empty Review.
                    scanComplete = (progress.errorMessage == nil)
                    isScanning = false
                }
            }
        }
    }

    /// Cancels an in-flight scan but leaves the sheet open on its idle state.
    func stopScan() {
        cancelScanTask()
        isScanning = false
        scanProgress = 0
        scanMatchesSoFar = 0
    }

    private func resetScanState() {
        cancelScanTask()
        isScanning = false
        scanProgress = 0
        scanMatchesSoFar = 0
        scanStatusText = ""
        scanIndeterminate = false
        scanComplete = false
        scanAlbumName = ""
    }

    private func cancelScanTask() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Title for the scan card: the single album's name, or a count for a batch.
    private static func scanLabel(for albums: [URL]) -> String {
        if albums.count == 1 {
            let name = albums[0].lastPathComponent
            return name.isEmpty ? String(localized: "Album") : name
        }
        return String(localized: "\(albums.count) albums")
    }

    // MARK: - Error dismissal (item 43)

    /// Clears the scan-failure banner (user dismissed or is retrying).
    func clearScanError() {
        scanError = nil
    }

    /// Re-runs the most recent scan (from the error banner's "Try Again").
    /// Clears the banner and starts over with the same albums; a no-op if there
    /// is no prior scan to retry.
    func retryScan() {
        clearScanError()
        guard !lastScanAlbums.isEmpty else { return }
        startScan(albums: lastScanAlbums)
    }
}
