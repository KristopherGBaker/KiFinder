import CoreGraphics
import Foundation
import KionEngine
import KionONNXEmbedder

enum ReviewBucket: String, Codable, Equatable {
    case keep
    case maybe
    /// Scanned photos that didn't match (or had no detectable face) — "The rest".
    case other
}

enum FeedbackLabel: String, Codable, Equatable {
    case confirm
    case reject
}

enum ExportDestination: Equatable {
    case folder(URL)
    case photos
}

/// Distinct, typed export failures (item 54) so the model layer can tell "the user
/// denied/hasn't granted Photos access" apart from a generic export failure or an
/// honest "there was nothing to export" — and surface a message that sends the user
/// to System Settings instead of a bogus "Exported 0" success.
enum ExportError: Error, Equatable {
    /// The current Photos authorization status for the add-only request level is
    /// anything other than `.authorized` — including `.limited`, which this app's
    /// add-only entitlement treats as insufficient (see `LiveTriageEngine.exportToPhotos`).
    case photosAccessNotAuthorized
}

struct ScanProgress: Equatable {
    /// 0…1 completion of the scan.
    var progress: Double
    /// Running count of candidates matched so far, shown live during the scan.
    var matchesSoFar: Int = 0
    /// Total photos enumerated across the scanned albums (0 until known).
    var totalPhotos: Int = 0
    /// Human-readable status line, e.g. "42 of 312 · June.zip" or
    /// "Album 2 of 3 · 88 of 140 · May.zip".
    var statusText: String = ""
    /// The full candidate set, populated on the terminal tick.
    var candidates: [Candidate] = []
    /// True only before the photo count is known (the brief "Preparing…" phase),
    /// so the UI shows a spinner; otherwise the bar is determinate.
    var indeterminate: Bool = false
    /// True on the last tick, which carries the complete candidate set.
    var isFinal: Bool = false
    /// Non-nil on a final tick ONLY when the scan failed (permission denied,
    /// corrupt archive, missing album, model/runtime load failure, …). A final
    /// progress with a non-nil `errorMessage` is a FAILURE — distinct from a
    /// final progress with empty `candidates`, which is a genuinely empty result.
    /// The string is localized and user-facing.
    var errorMessage: String? = nil
}

struct Candidate: Identifiable, Equatable {
    let id: String
    let photoKey: String
    let fileName: String
    /// Bundled asset name for sample candidates; empty for live ones.
    let imageResourceName: String
    /// Match score of the currently-selected face; updated when the user picks a
    /// different face in the lightbox.
    var score: Double
    let bucket: ReviewBucket
    /// On-disk source image for live candidates (real album photos); `nil` for
    /// sample candidates, which render from `imageResourceName`.
    var sourceURL: URL? = nil
    /// Every detected face's rectangle, normalized (0…1) with a top-left origin in
    /// the image's *raw* (un-oriented) pixel space — in detection order, matching
    /// the engine's stored faces by index. The lightbox renders each as a
    /// selectable overlay (applying the image's EXIF orientation). Empty when no
    /// face was detected.
    var faceBoxes: [CGRect] = []
    /// Index into `faceBoxes` of the currently-selected (matched) face, or `nil`
    /// when no face was detected.
    var selectedFaceIndex: Int? = nil
    /// The person this photo is attributed to: the best-matching enrolled person
    /// across everyone scanned in the one-pass multi-subject scan. `nil` when the
    /// photo matched no one (or in single-subject paths that don't attribute).
    /// `score`/`bucket` reflect this attributed match.
    var matchedSubjectID: String? = nil
    /// Per-person match score for this photo, keyed by `subjectId` — retained so a
    /// later item can filter/scope Review per person. The entry for
    /// `matchedSubjectID` equals `score`.
    var subjectScores: [String: Double] = [:]
    /// Each enrolled person's OWN bucket for this photo, keyed by `subjectId`, so a
    /// group photo can show under every person it matches in *their* section (keep/
    /// maybe/other) rather than only under the single best match. Empty when no
    /// person was scored (e.g. a photo with no detectable face). The entry for
    /// `matchedSubjectID` corresponds to `bucket`.
    var subjectBuckets: [String: ReviewBucket] = [:]
    /// The detected-face index each person matched, keyed by `subjectId`, so each
    /// person's tile/lightbox boxes *their own* face. Empty when no person matched a
    /// detectable face; callers fall back to `selectedFaceIndex` when a person has
    /// no entry.
    var selectedFaceIndexBySubject: [String: Int] = [:]
    /// The `faceBoxes` index of the manual region each person drew on this photo
    /// (item 19), keyed by `subjectId`. At most one per person — a re-draw replaces
    /// in place; a remove clears the entry. Absent when the person drew nothing.
    var manualFaceIndexBySubject: [String: Int] = [:]
    /// The auto-pick (`selectedFaceIndexBySubject` value, possibly `nil`) stashed at
    /// the moment a person FIRST drew a manual region, keyed by `subjectId`, so a
    /// later remove restores their original match instead of clearing it. The inner
    /// `Int?` distinguishes "had a prior auto-pick at index N" from "had none (nil)";
    /// a present key with value `.some(nil)` means the prior pick was nil.
    var priorAutoPickBySubject: [String: Int?] = [:]

    /// The selected face's box, when one is selected.
    var selectedFaceBox: CGRect? {
        guard let index = selectedFaceIndex, faceBoxes.indices.contains(index) else {
            return nil
        }
        return faceBoxes[index]
    }

    /// The face index the given person matched (`selectedFaceIndexBySubject`), or
    /// the photo's default `selectedFaceIndex` when that person has no per-person
    /// entry (or no active person is supplied). Used so each person boxes their own
    /// matched face in the tile/lightbox.
    func selectedFaceIndex(forSubject subjectId: String?) -> Int? {
        if let subjectId, let index = selectedFaceIndexBySubject[subjectId] {
            return index
        }
        return selectedFaceIndex
    }
}

/// Result of pointing a photo's match at a different detected face: the score and
/// bucket recomputed for the chosen face.
struct FaceSelectionResult: Equatable {
    var score: Double
    var bucket: ReviewBucket
}

/// Result of embedding a user-drawn region as a NEW detected face (item 19): the
/// index of the newly **appended** face plus its recomputed score/bucket against
/// the active profile. A later `recordFeedback(.confirm)` teaches THAT face.
struct ManualFaceResult: Equatable {
    /// Index of the appended face in the photo's face list — equal to the
    /// post-append last index (1:1 with the caller's `faceBoxes`).
    var faceIndex: Int
    var score: Double
    var bucket: ReviewBucket
}

/// Whether a drawn region is a usable face box: it has a positive (sign-preserving)
/// extent and at least partially overlaps the normalized image bounds. A degenerate
/// rect — empty/zero-area, negative size, or fully outside 0…1 — is rejected. Shared
/// by the engines and `AppModel` so the manual-region guard is identical everywhere
/// (and mirrors `FaceEmbedder.boundingBoxLandmarks`'s own nil-guard).
func isDrawableFaceRegion(_ rect: CGRect) -> Bool {
    guard rect.size.width > 0, rect.size.height > 0 else { return false }
    return rect.intersects(CGRect(x: 0, y: 0, width: 1, height: 1))
}

/// One photo's match after re-scoring the whole set against the (just-taught)
/// profile: the recomputed score/bucket and the re-picked best face.
struct RescoredPhoto: Equatable {
    var score: Double
    var bucket: ReviewBucket
    var selectedFaceIndex: Int?
}

@MainActor
protocol TriageEngine: AnyObject {
    /// Computes and returns one embedding per reference photo that contains a
    /// detectable face. The caller persists them as the enrolled profile.
    func enroll(referenceURLs: [URL]) async throws -> [FaceEmbedding]
    /// Produces a real cropped-face thumbnail (PNG `Data`, ~256px max edge) for the
    /// person being enrolled, detected on-device from the best reference photo. The
    /// app caches it via `ProfileRepository.saveThumbnail`. Additive to `enroll`
    /// (whose signature is unchanged); a default returns `nil` for engines without
    /// a real crop.
    func enrollmentThumbnail(referenceURLs: [URL]) async -> Data?
    /// Scans one or more albums (folders and/or .zips) as a single batch, yielding
    /// progress and a merged candidate set across all of them.
    func scan(albums: [URL]) -> AsyncStream<ScanProgress>
    func recordFeedback(photoKey: String, label: FeedbackLabel) async throws
    /// Re-points the photo's match at the chosen detected face (index into the
    /// photo's `faceBoxes`) and returns the recomputed score/bucket. A subsequent
    /// `recordFeedback(.confirm)` (i.e. Keep) then teaches that face to the profile.
    func selectFace(photoKey: String, faceIndex: Int) async throws -> FaceSelectionResult
    /// Embeds a user-drawn region (`normalizedRect`, normalized **top-left**
    /// raw-image space — the SAME convention as `Candidate.faceBoxes`) as a NEW
    /// detected face: converts it to Vision's bottom-left box, runs the item-8
    /// bounding-box → landmark fallback, **appends** the embedded face to
    /// `manifest[photoKey].faces` (preserving 1:1 index alignment with the caller's
    /// `faceBoxes`), scores it against the active profile, and makes it the photo's
    /// selected/match face. Returns the appended index + score/bucket, or `nil` for a
    /// degenerate rect (no mutation, no throw). A later `recordFeedback(.confirm)`
    /// teaches that face like any other.
    func addManualFace(photoKey: String, normalizedRect: CGRect) async throws -> ManualFaceResult?
    /// Drops the face at `faceIndex` from `manifest[photoKey].faces` (the inverse of
    /// `addManualFace`), keeping the remaining faces 1:1 with the caller's `faceBoxes`.
    /// No-op when the index is out of range.
    func removeManualFace(photoKey: String, faceIndex: Int) async throws
    /// Re-scores photos against the current profile (cheap: cosine over
    /// already-computed embeddings, no re-embedding) and re-picks each photo's
    /// best-matching face. Returns the updated score/bucket per `photoKey`. Used
    /// to surface newly-matching photos after feedback teaches the profile.
    ///
    /// `onlyPhotoKeys` scopes the work (item 49): `nil` re-scores EVERY known photo
    /// (back-compat); a set re-scores ONLY those photoKeys present in the engine's
    /// manifest. Non-selected photos are left untouched and are ABSENT from the
    /// returned results. The caller passes the set of UNDECIDED photos so confirming/
    /// skipping doesn't re-score the whole album (whose per-photo cost grows with the
    /// accumulated negatives) on every keystroke.
    func rescoreAll(onlyPhotoKeys: Set<String>?) async throws -> [String: RescoredPhoto]
    /// Copies the kept source files to `destination` and returns the number that
    /// were exported (and, where verifiable, byte-confirmed). Originals untouched.
    func export(photoKeys: [String], destination: ExportDestination) async throws -> Int
    /// Exports the given on-disk files directly to `destination` (`.photos` →
    /// add-to-Photos, `.folder` → copy) and returns the number exported. Unlike
    /// `export(photoKeys:)` the caller supplies resolved file URLs (e.g. saved
    /// library copies), so no key→source lookup happens. Originals untouched.
    func export(fileURLs: [URL], destination: ExportDestination) async throws -> Int
    /// Completes any pending (coalesced, off-actor) feedback write before returning.
    /// Called at concrete boundaries — before a rescan / any path that reloads the
    /// on-disk store, and on normal teardown — so taught feedback isn't dropped.
    func flush() async
    /// Drops the in-memory working store AND cancels/captures any pending coalesced
    /// write, returning the snapshot that was pending (`nil` if nothing was). This
    /// is the actual guarantee (item 53): call it BEFORE a repository-write path
    /// (rename/delete/enroll) mutates the store on disk, so a stale debounced write
    /// armed just before can never fire afterward and clobber that change. Because
    /// cancelling drops the WHOLE pending snapshot (it covers every enrolled
    /// person, not just the one being mutated), a caller with a non-nil result must
    /// re-arm a pruned/merged copy of it via `resumePendingWrite` once its write
    /// completes — otherwise another person's pending feedback is silently lost.
    /// `AppModel`/`EnrollmentModel` do this uniformly via
    /// `TriageEngine.writingThroughRepository`.
    @discardableResult
    func invalidateStore() -> ProfileStore?
    /// Re-arms a coalesced write for `store` (typically a captured-then-pruned/
    /// merged snapshot from `invalidateStore()`) and updates the in-memory working
    /// copy to match, so the next feedback call builds on it instead of silently
    /// reloading disk. Restores pending feedback that `invalidateStore()` would
    /// otherwise have dropped.
    func resumePendingWrite(_ store: ProfileStore)
    /// Points the engine at the subject whose profile scan/feedback/rescore should
    /// target, so switching the active person re-aims matching at the right profile
    /// instead of the one captured at construction. Item 2 generalizes matching to
    /// score every enrolled person; until then this keeps the single-subject path
    /// honest across person switches.
    func setActiveSubject(_ subjectId: String)
}

extension TriageEngine {
    /// Default no-op: engines without a single captured subject (e.g. the sample
    /// engine) ignore active-subject changes.
    func setActiveSubject(_: String) {}

    /// Default: no thumbnail. Engines override to return a real cropped-face PNG.
    func enrollmentThumbnail(referenceURLs _: [URL]) async -> Data? {
        nil
    }

    /// Default no-op: engines without an off-actor coalesced writer (e.g. the sample
    /// engine) have nothing pending to flush.
    func flush() async {}

    /// Default no-op: engines without an in-memory store (e.g. the sample engine)
    /// have nothing to invalidate or cancel, so there's never anything pending to
    /// hand back.
    @discardableResult
    func invalidateStore() -> ProfileStore? { nil }

    /// Default no-op: engines without a persister have nothing to re-arm.
    func resumePendingWrite(_: ProfileStore) {}

    /// Default: engines that don't support manually-drawn regions treat every draw
    /// as a no-op (returns `nil`). Live + Sample provide concrete implementations.
    func addManualFace(photoKey _: String, normalizedRect _: CGRect) async throws -> ManualFaceResult? {
        nil
    }

    /// Default no-op: nothing to remove when the engine has no manual faces.
    func removeManualFace(photoKey _: String, faceIndex _: Int) async throws {}

    /// Runs a repository write (`body`) as an ordered transaction against the
    /// persister's pending coalesced write (item 53's uniform mechanism for
    /// `addPerson`/`renamePerson`/`deletePerson`/enrollment completion):
    ///   1. Capture + cancel whatever is pending (`invalidateStore`) — so a stale
    ///      snapshot armed just before `body` runs can never fire mid- or
    ///      post-write and clobber what `body` writes to disk.
    ///   2. Run `body` (the actual repository call).
    ///   3. On success, `merge` the captured snapshot to reflect what `body` just
    ///      wrote (e.g. prune the deleted person, or upsert the fresh bundle an
    ///      enrollment just saved), then re-arm it (`resumePendingWrite`) — so
    ///      OTHER people's pending feedback the cancellation swept up is never
    ///      lost. `merge` defaults to a no-op for writes that never touch
    ///      `ProfileStore` contents (the roster-only saves behind add/rename).
    ///   4. On failure, restore the captured snapshot UNCHANGED — a surfaced
    ///      error must never drop pending feedback either.
    @discardableResult
    func writingThroughRepository<T>(
        merging merge: (inout ProfileStore) -> Void = { _ in },
        _ body: () throws -> T
    ) rethrows -> T {
        let captured = invalidateStore()
        do {
            let result = try body()
            if var captured {
                merge(&captured)
                resumePendingWrite(captured)
            }
            return result
        } catch {
            if let captured {
                resumePendingWrite(captured)
            }
            throw error
        }
    }
}
