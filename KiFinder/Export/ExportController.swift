import Foundation
import Observation

/// The export responsibility carved out of `AppModel` (item 61): owns the export-summary/
/// error channel and the ONE `runExport` core every export entry point funnels through —
/// collapsing what used to be four (soon five) copy-pasted `Task { do { try await
/// engine.export… } catch { … } }` bodies into a single place.
///
/// A separate `@Observable @MainActor` type COMPOSED by `AppModel` (`model.export`) — not
/// an `AppModel` extension. The old `AppModel+LibrarySelection.swift`'s library export had
/// to reach across files into `AppModel`'s error/summary state, which forced that state to
/// widen from `private` to `internal` just so the cross-file extension could write it (see
/// the removed doc comments on `AppModel.exportError`/`exportedCount`/`lastExportRetry`).
/// This type avoids repeating that: the library export now routes through `runExport` HERE,
/// so its own state stays `private`/`private(set)` (mirroring `ReviewSession`, item 59) —
/// reachable only through the narrow API `AppModel` forwards. `isExportSummaryPresented` is
/// the one exception, exactly like `ReviewSession.focusedID`: a plain `var` (not
/// `private(set)`) because `AppModel` needs a genuine two-way passthrough for
/// `KiFinderRootView`'s `$model.isExportSummaryPresented` sheet binding (a swipe-dismiss
/// writes straight through the binding's setter, not through `dismissExportSummary()`).
///
/// Source data (kept/selected photo keys, selected library file URLs) is injected as LIVE
/// closures — never snapshotted — so a decision made between construction and an export
/// call is always reflected, the same discipline `ReviewSession`'s
/// `activePersonID`/`hideAlreadyReviewed`/`columnCount` providers use (item 57: never a
/// stale snapshot). `engine` is injected as its (class-bound) live reference directly — a
/// reference type is already "live" with no snapshot risk.
@Observable
@MainActor
final class ExportController {
    private let engine: any TriageEngine
    private let keptKeysProvider: () -> [String]
    private let selectedKeysProvider: () -> [String]
    private let libraryURLsProvider: () -> [URL]

    /// Whether the export-summary sheet is presented. NOT `private(set)` — see the type
    /// doc comment: `AppModel` needs a settable passthrough for the SwiftUI sheet binding.
    var isExportSummaryPresented = false
    /// Non-nil when the last export FAILED (a localized, user-facing message). Distinct
    /// from an "Exported 0" success: a failure does NOT present the summary; the UI shows
    /// a retry/dismiss affordance. Cleared on a new export or `clearExportError()`.
    private(set) var exportError: String?
    /// Number of kept/selected files exported by the last run (byte-verified for folders).
    private(set) var exportedCount = 0
    /// The folder the last export wrote to, for "Show in Finder" / messaging; `nil` for a
    /// Photos-library export.
    private(set) var exportDestination: URL?
    /// Re-runs the most recent export, retained so an export-error banner's "Try Again"
    /// can repeat exactly the same export. Private to this type (item 61): the old
    /// `AppModel.lastExportRetry` had to be `internal` only so the library export in
    /// `AppModel+LibrarySelection.swift` could register its own retry across files; now
    /// that export runs through `runExport` HERE, nothing outside this file needs it.
    private var lastExportRetry: (() -> Void)?

    init(
        engine: any TriageEngine,
        keptKeys: @escaping () -> [String],
        selectedKeys: @escaping () -> [String],
        libraryURLs: @escaping () -> [URL]
    ) {
        self.engine = engine
        keptKeysProvider = keptKeys
        selectedKeysProvider = selectedKeys
        libraryURLsProvider = libraryURLs
        // No back-call into the host: unlike `ReviewSession.focusFirstIfNeeded()`, this
        // type has no init-time convenience that would route back through
        // `AppModel.export` while it's still the nil IUO mid-assignment. If a future
        // convenience default is added here, honor that ordering hazard.
    }

    // MARK: - Maps the two engine overloads to one core (item 61's `runExport`)

    /// The two shapes `TriageEngine.export` accepts — a photo-key batch (looked up by the
    /// engine) or resolved on-disk file URLs (the library export, which already has real
    /// paths). `runExport` is the ONE core both funnel through.
    private enum ExportSource {
        case photoKeys([String])
        case fileURLs([URL])
    }

    /// Consolidated export core: clears any prior error, arms `retry` as the new
    /// `lastExportRetry`, and runs the engine call off the caller's turn — on success,
    /// records the count/destination and presents the summary; on failure (item 54), maps
    /// the thrown error to a user-facing message and NEVER reaches the success branch (no
    /// bogus "Exported 0" summary). Every public export method is a thin wrapper that
    /// resolves its OWN source set (and, for #1/#2/#5, its OWN empty-guard) before calling
    /// this — the empty-guard is intentionally NOT baked in here, since #3/#4 (kept
    /// exports) have no empty-guard at all (`canExport` gates the UI instead).
    private func runExport(_ source: ExportSource, destination: ExportDestination, retry: @escaping () -> Void) {
        exportError = nil
        lastExportRetry = retry
        Task { [weak self] in
            guard let self else { return }
            do {
                let count: Int
                switch source {
                case let .photoKeys(keys):
                    count = try await self.engine.export(photoKeys: keys, destination: destination)
                case let .fileURLs(urls):
                    count = try await self.engine.export(fileURLs: urls, destination: destination)
                }
                self.exportedCount = count
                self.exportDestination = Self.folderURL(for: destination)
                self.isExportSummaryPresented = true
            } catch {
                self.exportError = self.exportErrorMessage(for: error)
            }
        }
    }

    private static func folderURL(for destination: ExportDestination) -> URL? {
        if case let .folder(url) = destination { return url }
        return nil
    }

    // MARK: - The five export entry points (thin wrappers over `runExport`)

    /// Byte-for-byte copy of the SELECTED files into `folder` (the multi-selection's
    /// keys). An empty selection is a graceful no-op: no engine call, no mutation of any
    /// export state (not even a stale-retry replacement).
    func exportSelected(toFolder folder: URL) {
        let keys = selectedKeysProvider()
        guard !keys.isEmpty else { return }
        runExport(.photoKeys(keys), destination: .folder(folder)) { [weak self] in
            self?.exportSelected(toFolder: folder)
        }
    }

    /// Adds the SELECTED files to the Photos library (add-only). Empty selection is the
    /// same graceful no-op as `exportSelected(toFolder:)`.
    func exportSelectedToPhotos() {
        let keys = selectedKeysProvider()
        guard !keys.isEmpty else { return }
        runExport(.photoKeys(keys), destination: .photos) { [weak self] in
            self?.exportSelectedToPhotos()
        }
    }

    /// Straight byte-for-byte copy of the KEPT files into `folder`. No empty-guard — a
    /// kept export always runs; `AppModel.canExport` (`keepCount > 0`) gates the UI
    /// affordance instead, matching the pre-item-61 behavior exactly.
    func exportKept(toFolder folder: URL) {
        let keys = keptKeysProvider()
        runExport(.photoKeys(keys), destination: .folder(folder)) { [weak self] in
            self?.exportKept(toFolder: folder)
        }
    }

    /// Adds the KEPT files to the Photos library (add-only). No empty-guard, same as
    /// `exportKept(toFolder:)`.
    func exportKeptToPhotos() {
        let keys = keptKeysProvider()
        runExport(.photoKeys(keys), destination: .photos) { [weak self] in
            self?.exportKeptToPhotos()
        }
    }

    /// Adds the selected LIBRARY copies to the Photos library (add-only) through the
    /// engine's `export(fileURLs:destination:.photos)` overload — the item-61 reroute:
    /// this used to write `AppModel`'s error/summary state directly from
    /// `AppModel+LibrarySelection.swift`; now it shares the exact same `runExport` core
    /// (and channel) every other export uses. An EMPTY selection (or one whose files are
    /// all missing — already filtered out of `urls` by the caller) is a graceful no-op.
    func exportSelectedLibraryToPhotos() {
        let urls = libraryURLsProvider()
        guard !urls.isEmpty else { return }
        runExport(.fileURLs(urls), destination: .photos) { [weak self] in
            self?.exportSelectedLibraryToPhotos()
        }
    }

    // MARK: - Summary / error dismissal

    func dismissExportSummary() {
        isExportSummaryPresented = false
    }

    /// Clears the export-failure banner (user dismissed or is retrying).
    func clearExportError() {
        exportError = nil
    }

    /// Re-runs the most recent export (from the error banner's "Try Again"). A no-op if
    /// there is no prior export to retry.
    func retryExport() {
        clearExportError()
        lastExportRetry?()
    }

    /// Maps a thrown export error to the message shown on `exportError` (item 54): a
    /// Photos authorization denial gets a distinct, plain-language message that sends the
    /// user to System Settings, instead of the generic retry message (and instead of a
    /// bogus "Exported 0" success — the caller never reaches the success branch when this
    /// throws). Shared by every export entry point, including the rerouted library one, so
    /// the message is identical everywhere the user can reach an export.
    func exportErrorMessage(for error: Error) -> String {
        if let typedError = error as? ExportError, typedError == .photosAccessNotAuthorized {
            return String(localized: "KiFinder isn't allowed to add photos to your Photos library. Grant access in System Settings > Privacy & Security > Photos, then try again.")
        }
        return String(localized: "The export couldn't be completed. Please try again.")
    }
}
