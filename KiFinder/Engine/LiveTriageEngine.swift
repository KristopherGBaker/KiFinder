import Foundation
import ImageIO
import KionEngine
import KionONNXEmbedder
import Photos

/// Real, on-device engine: wraps `KionEngine` (Vision + ONNX Runtime / ArcFace).
/// Enroll embeds the reference faces, scan runs the matching pipeline over a real
/// album, feedback updates the local profile, and export copies the kept files.
/// All on device — no network, no photos ever leave the Mac.
@MainActor
final class LiveTriageEngine: TriageEngine {
    /// The launch environment + filesystem roots used to resolve the model. Kept on
    /// the instance so the model URL is resolved LAZILY at each use (see `modelURL`)
    /// rather than cached at init — first-run onboarding installs the model AFTER the
    /// engine is built, and the very next enroll/scan must pick it up with no relaunch.
    private let environment: [String: String]
    private let locations: ModelLocations
    /// The asset descriptor `modelURL` resolves against — item74b: threads the
    /// ACTIVE backend's asset (`.production` for ONNX, `.adaface` for CoreML) so
    /// this engine resolves its OWN model, not always ONNX's. Defaults to
    /// `.production`, preserving today's exact ArcFace resolution for every
    /// existing call site that never mentions this.
    private let assetDescriptor: ModelAssetDescriptor
    private let storeURL: URL
    /// The face-embedding provider factory (item 64): every embed site constructs
    /// its provider through this seam rather than naming `FaceEmbedder` directly,
    /// so the engine only ever depends on `any FaceEmbeddingProvider`. Defaults to
    /// the real ONNX ArcFace embedder; tests/bring-your-own-model can inject a
    /// different provider without touching the 4 call sites.
    private let makeProvider: @Sendable (URL?) throws -> any FaceEmbeddingProvider
    /// How many photos a scan embeds concurrently (item 75), as a CLOSURE rather than
    /// a stored number: it's read once per `scan`, so a change in Settings applies to
    /// the next scan without rebuilding the engine or relaunching. Defaults to
    /// resolving the preference itself, so every existing call site (and the CLI-ish
    /// test constructions) keeps working untouched.
    private let workerCount: () -> Int
    /// The subject this engine scores against. Mutable so a person switch re-aims
    /// matching at the active person's profile (see `setActiveSubject`).
    private var subjectId: String
    private let modelId: String
    private let modelVersion: String

    /// Results retained from the last scan so feedback and export can act on the
    /// real on-disk files (scan keys are relative; these resolve to absolute URLs).
    private var lastManifest: Manifest?
    private var sourceURLByKey: [String: URL] = [:]

    /// The working `ProfileStore`, held in memory and mutated in place for confirm/
    /// reject. Loaded ONCE (refreshed at scan time, or lazily on first feedback) so a
    /// keep/skip never re-decodes the whole store from disk. This in-memory copy is
    /// the source of truth for `rescoreAll`/`selectFace`, so teaching is reflected
    /// immediately; the on-disk store is brought up to date by `persister` (coalesced,
    /// off the main actor).
    private var store: ProfileStore?

    /// Off-actor, debounced writer for the working store. Injectable so tests can
    /// prove keep/skip schedules (rather than writes inline) and that flush coalesces.
    private let persister: ProfileStorePersisting

    /// Photos authorization seam (item 54). Injectable so tests can drive
    /// denied/limited/authorized deterministically without ever touching the real
    /// `PHPhotoLibrary` from the test host process.
    private let photosAuthorizationClient: PhotosAuthorizationClient

    /// Test seam (item 54): when set, invoked once per file copy from INSIDE the real
    /// off-actor folder-export copy loop, so a test can prove the production
    /// `export(..., destination: .folder)` entry point's file-copy work truly runs off
    /// `Thread.isMainThread` — not by unit-testing an extracted helper in isolation.
    /// `nil` in production; a no-op cost when unset.
    var testDidCopyFile: (@Sendable () -> Void)?

    /// The currently-resolved model URL, computed fresh on every access so it
    /// reflects the CURRENT on-disk state. Resolves through the SAME function the
    /// onboarding gate uses (assertion 2): explicit `KION_MODEL_PATH`, then the
    /// managed install location, then the legacy `~/.cache` dev cache. `nil` →
    /// `FaceEmbedder` reports `modelNotFound`. Internal so tests can assert it
    /// changes as the filesystem changes (no relaunch / no engine re-creation).
    var modelURL: URL? {
        resolveModelURL(env: environment, locations: locations, descriptor: assetDescriptor)
    }

    init(
        environment: [String: String] = KionEnvironment.process,
        locations: ModelLocations = .production,
        assetDescriptor: ModelAssetDescriptor = .production,
        storeURL: URL,
        subjectId: String,
        modelId: String,
        modelVersion: String,
        persister: ProfileStorePersisting? = nil,
        photosAuthorizationClient: PhotosAuthorizationClient = SystemPhotosAuthorizationClient(),
        makeProvider: @escaping @Sendable (URL?) throws -> any FaceEmbeddingProvider = { try FaceEmbedder(modelURL: $0) },
        workerCount: (() -> Int)? = nil
    ) {
        self.workerCount = workerCount ?? {
            resolveScanWorkerCount(env: environment, defaults: .standard)
        }
        self.environment = environment
        self.locations = locations
        self.assetDescriptor = assetDescriptor
        self.storeURL = storeURL
        self.subjectId = subjectId
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.persister = persister ?? CoalescingProfileStoreWriter(storeURL: storeURL)
        self.photosAuthorizationClient = photosAuthorizationClient
        self.makeProvider = makeProvider
    }

    // MARK: - In-memory store

    /// The working store, loaded ONCE from disk the first time it's needed and then
    /// reused (and refreshed at scan time). A keep/skip never re-decodes the store.
    ///
    /// Distinguishes "no store file exists" (returns `nil`; nothing enrolled yet)
    /// from "a store file exists but couldn't be loaded" (throws — item 58: a
    /// recognized-alias migration whose persist failed, or a genuine
    /// `ModelVersionMismatchError`), so a caller never mistakes the latter for an
    /// empty store and goes on to overwrite real on-disk data.
    private func loadedStore() throws -> ProfileStore? {
        if let store { return store }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return nil
        }
        let loaded = try ProfileStore.load(
            from: storeURL,
            expectingModelId: modelId,
            expectingModelVersion: modelVersion
        )
        store = loaded
        return loaded
    }

    /// Test seam: preloads the in-memory store + manifest so feedback/rescore can be
    /// exercised deterministically without a real scan (which needs the embedding
    /// model). Production paths populate these via `scan`.
    func loadForTesting(store: ProfileStore, manifest: Manifest) {
        self.store = store
        lastManifest = manifest
    }

    /// Test seam: the in-memory working store (source of truth for feedback/rescore),
    /// exposed read-only so tests can assert exemplars landed without disk I/O.
    var workingStore: ProfileStore? {
        store
    }

    /// Test seam (item 72): the model stamp this engine reads/writes — read via
    /// `AppModel.engine` so a backend-selection test can confirm which model a
    /// `LiveTriageEngine` was constructed for (e.g. the vision stamp when the
    /// Vision backend is active), without duplicating `AppModel`'s own descriptor
    /// resolution.
    var modelIdentityForTesting: (modelId: String, modelVersion: String) {
        (modelId, modelVersion)
    }

    /// Completes any pending coalesced write before returning (assertion 3).
    func flush() async {
        await persister.flush()
    }

    /// Drops the cached working store AND cancels any armed persister debounce,
    /// returning the snapshot that was pending (item 53). Used before an
    /// enrollment/rename/delete rewrites the store through the repository, so the
    /// engine's in-memory copy — and any stale, already-armed write — can't clobber
    /// that change. See the protocol doc for the full invariant.
    @discardableResult
    func invalidateStore() -> ProfileStore? {
        store = nil
        return persister.cancelPending()
    }

    /// Re-arms a coalesced write for `store` and brings the in-memory cache back in
    /// sync with it, so a subsequent feedback call builds on the restored/merged
    /// snapshot rather than lazily reloading disk.
    func resumePendingWrite(_ store: ProfileStore) {
        self.store = store
        persister.schedule(store)
    }

    /// Re-aims scan/feedback/rescore at the active person's profile when the user
    /// switches people. Scan state (manifest/source map) is left intact; the next
    /// scan loads the new subject's profile from the shared store.
    func setActiveSubject(_ subjectId: String) {
        self.subjectId = subjectId
    }

    // MARK: - Enroll

    func enroll(referenceURLs: [URL]) async throws -> [FaceEmbedding] {
        let modelURL = modelURL
        let makeProvider = makeProvider
        return try await Task.detached(priority: .userInitiated) {
            let embedder = try makeProvider(modelURL)
            var embeddings: [FaceEmbedding] = []
            for url in referenceURLs {
                guard let image = ScanPipeline.decodeImage(at: url) else { continue }
                if let face = try? await embedder.embedFace(image) {
                    embeddings.append(face.embedding)
                }
            }
            guard !embeddings.isEmpty else {
                throw FaceEmbedderError.landmarkDetectionFailed
            }
            return embeddings
        }.value
    }

    // MARK: - Enrollment thumbnail

    /// Detects the best face across the reference photos (highest detection score
    /// with a real bounding box) and returns a cropped-face PNG (~256px). Runs the
    /// detection off the main actor; on-device only. `nil` when no reference yields
    /// a detectable, boxed face (the UI then falls back to a placeholder).
    func enrollmentThumbnail(referenceURLs: [URL]) async -> Data? {
        let modelURL = modelURL
        let makeProvider = makeProvider
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let embedder = try? makeProvider(modelURL) else { return nil }
            var bestImage: CGImage?
            var bestBox: NormalizedRect?
            var bestOrientation: CGImagePropertyOrientation = .up
            var bestScore: Float = -1
            for url in referenceURLs {
                guard let image = ScanPipeline.decodeImage(at: url),
                      let face = try? await embedder.embedFace(image),
                      let box = face.qualityMetrics.faceBoundingBox
                else { continue }
                if face.qualityMetrics.detectionScore > bestScore {
                    bestScore = face.qualityMetrics.detectionScore
                    bestImage = image
                    bestBox = box
                    bestOrientation = Self.orientation(at: url)
                }
            }
            guard let image = bestImage, let box = bestBox else { return nil }
            let rect = CGRect(
                x: CGFloat(box.x),
                y: CGFloat(box.y),
                width: CGFloat(box.width),
                height: CGFloat(box.height)
            )
            // The box/crop stays in raw pixel space; only the OUTPUT is rotated to the
            // source's display orientation so the saved thumbnail is upright.
            return FaceThumbnail.croppedPNG(from: image, normalizedRect: rect, orientation: bestOrientation)
        }.value
    }

    // MARK: - Scan

    func scan(albums: [URL]) -> AsyncStream<ScanProgress> {
        let modelURL = modelURL
        let storeURL = storeURL
        let subjectId = subjectId
        let modelId = modelId
        let modelVersion = modelVersion
        let makeProvider = makeProvider
        // Resolved per scan (not cached at init) so changing the Settings picker takes
        // effect on the NEXT scan, with no relaunch.
        let workerCount = self.workerCount()
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                // Indeterminate only until the albums are enumerated and the photo
                // count is known; then the scan reports determinate per-photo progress.
                continuation.yield(ScanProgress(progress: 0, statusText: String(localized: "Preparing…"), indeterminate: true))
                do {
                    let outcome = try await Self.streamingScan(
                        albums: albums,
                        modelURL: modelURL,
                        storeURL: storeURL,
                        subjectId: subjectId,
                        modelId: modelId,
                        modelVersion: modelVersion,
                        workerCount: workerCount,
                        makeProvider: makeProvider
                    ) { progress, matches, total, status in
                        continuation.yield(
                            ScanProgress(
                                progress: progress,
                                matchesSoFar: matches,
                                totalPhotos: total,
                                statusText: status
                            )
                        )
                    }
                    await self.retain(manifest: outcome.manifest, sources: outcome.sourceURLByKey, store: outcome.store)
                    continuation.yield(
                        ScanProgress(
                            progress: 1,
                            matchesSoFar: outcome.candidates.count,
                            totalPhotos: outcome.total,
                            statusText: String(localized: "Done"),
                            candidates: outcome.candidates,
                            isFinal: true
                        )
                    )
                } catch {
                    continuation.yield(
                        ScanProgress(
                            progress: 1,
                            candidates: [],
                            isFinal: true,
                            errorMessage: String(localized: "The scan couldn't be completed. Please try again.")
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func retain(manifest: Manifest, sources: [String: URL], store: ProfileStore?) {
        lastManifest = manifest
        sourceURLByKey = sources
        // Refresh the in-memory working store from the copy the scan just loaded, so
        // enrollment changes made before this scan are picked up and feedback mutates
        // the current store.
        if let store { self.store = store }
    }

    private struct ScanOutcome {
        var candidates: [Candidate]
        var manifest: Manifest
        var sourceURLByKey: [String: URL]
        var total: Int
        /// The store the scan loaded from disk, so the engine refreshes its in-memory
        /// copy from it (and feedback never re-decodes per decision). `nil` only when
        /// the scan never reached a load.
        var store: ProfileStore?
    }

    /// Runs the match pipeline per photo (rather than ScanPipeline's atomic scan)
    /// so it can report live, determinate progress: a folder/zip is enumerated to
    /// learn the photo count, then each image is embedded and scored, reporting
    /// `progress`, the running match count, and a status line as it goes. Keys are
    /// re-keyed by absolute path so they stay globally unique across albums.
    private nonisolated static func streamingScan(
        albums: [URL],
        modelURL: URL?,
        storeURL: URL,
        subjectId: String,
        modelId: String,
        modelVersion: String,
        workerCount: Int,
        makeProvider: @Sendable (URL?) throws -> any FaceEmbeddingProvider,
        onProgress: (Double, Int, Int, String) -> Void
    ) async throws -> ScanOutcome {
        let store = try ProfileStore.load(
            from: storeURL,
            expectingModelId: modelId,
            expectingModelVersion: modelVersion
        )
        // Locked decision: a scan matches EVERY enrolled person in one pass, not
        // just the active one. Sorted by subjectId for deterministic tie-breaking.
        // An empty store means nobody is enrolled → no candidates, as before.
        let profiles = store.bundles.values.sorted { $0.subjectId < $1.subjectId }
        guard !profiles.isEmpty else {
            return ScanOutcome(
                candidates: [],
                manifest: Manifest(modelId: modelId, modelVersion: modelVersion),
                sourceURLByKey: [:],
                total: 0,
                store: store
            )
        }

        // One embedder PER WORKER (item 75). A single instance is an actor, so every
        // call through it serializes — sharing one across the fan-out would keep the
        // scan exactly as serial as it was, just with more ceremony. At `workers == 1`
        // exactly one provider is constructed, as before.
        //
        // (This block used to also build a `ScanPipeline` purely to borrow its
        // `enumerateImages`; enumeration is now reached statically, so the throwaway
        // pipeline is gone rather than left sitting here unused.)
        let workers = max(1, workerCount)
        let embedders = try (0 ..< workers).map { _ in try makeProvider(modelURL) }

        // First pass: resolve roots and enumerate so the total photo count is known.
        // A folder is scanned in place; a .zip is extracted to a kept cache dir so
        // matched files survive for Review and export. A scan may mix folders and
        // zips in one call — each album is resolved by its own type. With more than
        // one worker the extractions run concurrently, so dropping three zips no
        // longer waits out three sequential `unzip` runs before any photo is embedded.
        let albumsToScan = try await resolveAndEnumerateConcurrently(
            albums: albums,
            workers: workers,
            // The STATIC enumeration (pure, `Sendable`) rather than the instance
            // method — the pipeline itself can't cross a task boundary.
            enumerate: ScanPipeline.enumerateImages(in:)
        )
        let total = albumsToScan.reduce(0) { $0 + $1.keys.count }

        // The flat work list: every (album, photo) pair in scan order. Parallel work
        // completes out of order, so each item carries its ORIGINAL index and results
        // are re-seated by it below — the outcome is identical to the serial scan's,
        // independent of how the workers interleave.
        let work: [PhotoWork] = albumsToScan.enumerated().flatMap { index, album in
            album.keys.map { relativeKey in
                PhotoWork(
                    albumIndex: index,
                    albumName: album.name,
                    sourceURL: album.root.appendingPathComponent(relativeKey)
                )
            }
        }

        var mergedManifest = Manifest(modelId: modelId, modelVersion: modelVersion)
        var sources: [String: URL] = [:]
        var processed = 0
        var matches = 0
        let multiple = albumsToScan.count > 1
        // Completed outcomes, seated at their work index (`nil` = not finished, which
        // is how a cancelled scan's partial results stay in scan order).
        var completed = [PhotoOutcome?](repeating: nil, count: work.count)

        func outcome() -> ScanOutcome {
            // Buckets are filled in WORK order (not completion order), then ranked by
            // score — byte-identical to the serial scan, including how equal scores
            // tie-break, because the sort sees the same input sequence.
            var keep: [Candidate] = []
            var maybe: [Candidate] = []
            var other: [Candidate] = []
            for finished in completed.compactMap({ $0 }) {
                switch finished.candidate.bucket {
                case .keep: keep.append(finished.candidate)
                case .maybe: maybe.append(finished.candidate)
                case .other: other.append(finished.candidate)
                }
            }
            keep.sort { $0.score > $1.score }
            maybe.sort { $0.score > $1.score }
            other.sort { $0.score > $1.score }
            return ScanOutcome(
                candidates: keep + maybe + other,
                manifest: mergedManifest,
                sourceURLByKey: sources,
                total: total,
                store: store
            )
        }

        try await withThrowingTaskGroup(of: PhotoOutcome.self) { group in
            // A worker "slot" owns one embedder for the life of the scan. At most
            // `workers` photos are ever in flight: a new one is only started as a
            // finished one frees its slot, so memory stays bounded no matter how many
            // photos (or albums) were dropped.
            var freeSlots = Array((0 ..< workers).reversed())
            var nextIndex = 0

            func startNext() {
                guard nextIndex < work.count, let slot = freeSlots.popLast() else { return }
                let item = work[nextIndex]
                let index = nextIndex
                let embedder = embedders[slot]
                nextIndex += 1
                group.addTask {
                    try await processPhoto(
                        item,
                        index: index,
                        slot: slot,
                        profiles: profiles,
                        subjectId: subjectId,
                        embedder: embedder
                    )
                }
            }

            for _ in 0 ..< workers { startNext() }

            while let finished = try await group.next() {
                // Merge FIRST, then check cancellation: this photo's work is already
                // done and paid for, so dropping it would make the partial result
                // needlessly poorer than it has to be.
                completed[finished.index] = finished
                sources[finished.key] = finished.work.sourceURL
                if let best = finished.best {
                    mergedManifest[finished.key] = best
                }
                processed += 1
                if finished.isMatch { matches += 1 }

                if Task.isCancelled {
                    // Stop handing out work and cancel what's in flight; what completed
                    // is returned, exactly as the serial scan's mid-loop cancellation
                    // returned its partial results.
                    group.cancelAll()
                    break
                }

                let fraction = total > 0 ? Double(processed) / Double(total) : 1
                // The album named is the one the just-finished photo belongs to; with
                // several albums in flight that label moves around, but the counts —
                // which is what the progress bar reads — stay strictly monotonic.
                let status = multiple
                    ? String(localized: "Album \(finished.work.albumIndex + 1) of \(albumsToScan.count) · \(processed) of \(total) · \(finished.work.albumName)")
                    : String(localized: "\(processed) of \(total) · \(finished.work.albumName)")
                onProgress(fraction, matches, total, status)

                freeSlots.append(finished.slot)
                startNext()
            }
        }

        return outcome()
    }

    /// One photo's worth of scan input.
    private struct PhotoWork: Sendable {
        /// Index of the owning album in `albumsToScan` — drives the "Album i of N"
        /// status text only.
        var albumIndex: Int
        var albumName: String
        var sourceURL: URL
    }

    /// One photo's worth of scan output, carrying everything the coordinator merges
    /// plus the bookkeeping (`index`, `slot`) that lets results arrive out of order.
    private struct PhotoOutcome: Sendable {
        /// Position in the flat work list, so results re-seat into scan order.
        var index: Int
        /// The worker slot (and therefore embedder) this photo used, returned so the
        /// coordinator can hand it to the next photo.
        var slot: Int
        var work: PhotoWork
        var key: String
        var candidate: Candidate
        /// The manifest entry, or `nil` when no face was detected (or the file
        /// wouldn't decode) — the same "no entry" the serial scan left behind.
        var best: BestFace?
        /// Whether this photo matched SOMEBODY (`keep`/`maybe`), for the running
        /// match count in progress.
        var isMatch: Bool
    }

    /// Decodes, embeds, and scores ONE photo against every enrolled profile — the
    /// body of what used to be the scan's inner loop, lifted out so it can run on a
    /// worker task. Pure with respect to scan state: it reads only its own inputs and
    /// returns everything the coordinator needs to merge, which is what makes the
    /// parallel scan's result independent of completion order.
    private nonisolated static func processPhoto(
        _ work: PhotoWork,
        index: Int,
        slot: Int,
        profiles: [ProfileBundle],
        subjectId: String,
        embedder: any FaceEmbeddingProvider
    ) async throws -> PhotoOutcome {
        let sourceURL = work.sourceURL
        let key = sourceURL.path

        // A cancelled scan shouldn't pay for a full decode + embed on a photo nobody
        // will look at. The unscored `.other` candidate this returns is only ever
        // merged into a partial outcome the consumer has already walked away from.
        if Task.isCancelled {
            return PhotoOutcome(
                index: index,
                slot: slot,
                work: work,
                key: key,
                candidate: Candidate(
                    id: key,
                    photoKey: key,
                    fileName: sourceURL.lastPathComponent,
                    imageResourceName: "",
                    score: 0,
                    bucket: .other,
                    sourceURL: sourceURL
                ),
                best: nil,
                isMatch: false
            )
        }

        // Every photo becomes a candidate; its bucket is its match result
        // (or "other" when it didn't match or has no detectable face).
        var reviewBucket: ReviewBucket = .other
        var score = 0.0
        var faceBoxes: [CGRect] = []
        var selectedFaceIndex: Int?
        var matchedSubjectID: String?
        var subjectScores: [String: Double] = [:]
        // Per-person bucket + matched-face index for EVERY enrolled person,
        // so a group photo surfaces under each person it matched in their
        // own section (and boxing their own face).
        var subjectBuckets: [String: ReviewBucket] = [:]
        var selectedFaceIndexBySubject: [String: Int] = [:]
        var best: BestFace?
        var isMatch = false
        if let image = ScanPipeline.decodeImage(at: sourceURL) {
            let faces = (try? await embedder.embedAllFaces(image)) ?? []
            if !faces.isEmpty {
                faceBoxes = faces.map(Self.cgRect)
                // One-pass multi-person attribution: the detected faces are
                // embedded once, then EVERY enrolled person is scored against
                // their own best-matching face (so a group photo lands in the
                // right bucket per person). The photo is attributed to its
                // best match across people; per-person scores are retained.
                var selectedIndexByPerson: [String: Int] = [:]
                var subjectResults: [String: SubjectResult] = [:]
                var bestPersonId: String?
                var bestBucket: Bucket = .no
                var bestScore = -Float.greatestFiniteMagnitude
                for profile in profiles {
                    // includeFallbackFaces: false — a face embedded by
                    // FaceEmbedder's blind heuristic fallback (no real
                    // detector found anything) must not be scored as a
                    // match: it's the whole photo embedded as a guess, not
                    // a detected face (item 56). Consistent with
                    // ScanPipeline's own default.
                    let match = try FaceMatcher.bestMatchingFace(
                        among: faces,
                        profile: profile,
                        minDetectionScore: 0.0,
                        minBoundingBoxArea: 0.0,
                        includeFallbackFaces: false
                    )
                    let faceIndex = match?.index ?? 0
                    let adjusted: Float
                    let bucket: Bucket
                    if let match {
                        adjusted = match.score
                        bucket = FaceMatcher.bucket(
                            score: adjusted,
                            threshold: profile.threshold,
                            maybeMargin: profile.maybeMargin
                        )
                    } else {
                        // No detected face passed the gate for this
                        // profile (e.g. the only "face" was a blind
                        // guess) — force `.no` rather than scoring the
                        // excluded face, exactly as
                        // `ScanPipeline.subjectResult` does. The photo
                        // still surfaces in "other" (below), never
                        // silently dropped.
                        adjusted = 0
                        bucket = .no
                    }
                    selectedIndexByPerson[profile.subjectId] = faceIndex
                    subjectScores[profile.subjectId] = Double(adjusted)
                    subjectResults[profile.subjectId] = SubjectResult(score: adjusted, bucket: bucket)
                    selectedFaceIndexBySubject[profile.subjectId] = faceIndex
                    switch bucket {
                    case .keep: subjectBuckets[profile.subjectId] = .keep
                    case .maybe: subjectBuckets[profile.subjectId] = .maybe
                    default: subjectBuckets[profile.subjectId] = .other
                    }
                    // Best match = highest bucket (keep > maybe > no), tie-broken by score.
                    let better = Self.bucketRank(bucket) > Self.bucketRank(bestBucket)
                        || (Self.bucketRank(bucket) == Self.bucketRank(bestBucket) && adjusted > bestScore)
                    if better {
                        bestBucket = bucket
                        bestScore = adjusted
                        bestPersonId = profile.subjectId
                    }
                }

                // score/bucket reflect the best (attributed) match across people.
                score = Double(bestScore)
                switch bestBucket {
                case .keep: reviewBucket = .keep
                case .maybe: reviewBucket = .maybe
                default: reviewBucket = .other
                }
                // A photo matching nobody stays "other" with no attribution —
                // exactly as a no-match is today.
                if bestBucket == .keep || bestBucket == .maybe {
                    matchedSubjectID = bestPersonId
                    isMatch = true
                }

                // Representative = the ACTIVE subject's best face so a later
                // confirm/reject/select (which still target the active person)
                // act on the right face; fall back to the best-matching person,
                // then face 0. Every face is kept for re-pointing.
                let repIndex = selectedIndexByPerson[subjectId]
                    ?? bestPersonId.flatMap { selectedIndexByPerson[$0] }
                    ?? 0
                selectedFaceIndex = repIndex
                let representative = faces[repIndex]
                best = BestFace(
                    embedding: representative.embedding,
                    qualityMetrics: representative.qualityMetrics,
                    subjectResults: subjectResults,
                    faces: faces
                )
            }
        }

        let candidate = Candidate(
            id: key,
            photoKey: key,
            fileName: sourceURL.lastPathComponent,
            imageResourceName: "",
            score: score,
            bucket: reviewBucket,
            sourceURL: sourceURL,
            faceBoxes: faceBoxes,
            selectedFaceIndex: selectedFaceIndex,
            matchedSubjectID: matchedSubjectID,
            subjectScores: subjectScores,
            subjectBuckets: subjectBuckets,
            selectedFaceIndexBySubject: selectedFaceIndexBySubject
        )
        return PhotoOutcome(
            index: index,
            slot: slot,
            work: work,
            key: key,
            candidate: candidate,
            best: best,
            isMatch: isMatch
        )
    }

    /// Resolves each album's root and enumerates its image keys — the model-
    /// independent first pass of a scan. A folder is enumerated in place; a `.zip`
    /// is extracted to a kept cache dir first. A single scan may mix folders and
    /// zips; each album is resolved by its own type. Factored out so the
    /// combination path is testable without the embedding model.
    nonisolated static func resolveAndEnumerate(
        albums: [URL],
        enumerate: (URL) throws -> [String]
    ) throws -> [(root: URL, name: String, keys: [String])] {
        try albums.map { album in
            let resolved = try resolveOne(album, enumerate: enumerate)
            return (resolved.root, resolved.name, resolved.keys)
        }
    }

    /// `resolveAndEnumerate`, but with up to `workers` albums resolved at once — the
    /// unzip of one album overlaps the unzip/enumeration of the next, which is the
    /// whole point when several zips are dropped together.
    ///
    /// Order is preserved (results are re-seated by index), and failure semantics are
    /// unchanged: the first album that fails to resolve throws out of the whole scan,
    /// exactly as the serial `map` did. `workers == 1` runs them one at a time.
    nonisolated static func resolveAndEnumerateConcurrently(
        albums: [URL],
        workers: Int,
        enumerate: @escaping @Sendable (URL) throws -> [String]
    ) async throws -> [(root: URL, name: String, keys: [String])] {
        guard workers > 1, albums.count > 1 else {
            return try resolveAndEnumerate(albums: albums, enumerate: enumerate)
        }
        let resolved = try await withThrowingTaskGroup(
            of: (Int, ResolvedAlbum).self
        ) { group -> [Int: ResolvedAlbum] in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < albums.count else { return }
                let album = albums[nextIndex]
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (index, try resolveOne(album, enumerate: enumerate))
                }
            }
            for _ in 0 ..< min(workers, albums.count) { startNext() }

            var byIndex: [Int: ResolvedAlbum] = [:]
            while let (index, album) = try await group.next() {
                byIndex[index] = album
                startNext()
            }
            return byIndex
        }
        return albums.indices.compactMap { resolved[$0] }.map { ($0.root, $0.name, $0.keys) }
    }

    /// A resolved album as a named, `Sendable` value — the tuple `resolveAndEnumerate`
    /// returns can't cross a task boundary.
    private struct ResolvedAlbum: Sendable {
        var root: URL
        var name: String
        var keys: [String]
    }

    /// Resolves ONE album (the body of `resolveAndEnumerate`'s `map`).
    private nonisolated static func resolveOne(
        _ album: URL,
        enumerate: (URL) throws -> [String]
    ) throws -> ResolvedAlbum {
        // A loose image file scans as just itself: its root is the PARENT and the
        // only key is its name, so `sourceURLByKey` (root + key) points back at the
        // ORIGINAL file. Detect this FIRST — routing it through `persistentAlbumRoot`/
        // `enumerate` would reduce to the parent dir and wrongly pull in siblings.
        if ScanPipeline.isImageFile(album), !isDirectory(album) {
            return ResolvedAlbum(
                root: album.deletingLastPathComponent(),
                name: album.lastPathComponent,
                keys: [album.lastPathComponent]
            )
        }
        let root = try persistentAlbumRoot(for: album)
        return try ResolvedAlbum(root: root, name: album.lastPathComponent, keys: enumerate(root))
    }

    /// Whether `url` is an existing directory (so a `.heic`-named *folder* still
    /// resolves through the folder path rather than as a loose image file).
    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// A folder is returned as-is; a .zip is unzipped into a persistent cache dir.
    private nonisolated static func persistentAlbumRoot(for album: URL) throws -> URL {
        guard album.pathExtension.lowercased() == "zip" else { return album }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KiFinder/scans/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", album.path, "-d", root.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScanPipelineError.zipExtractionFailed(album.path)
        }
        return root
    }

    /// Reads the EXIF display orientation of the image at `url` via ImageIO only
    /// (no model). Defaults to `.up` when the source is unreadable or carries no
    /// orientation tag. Exposed for `@testable` verification of the read.
    nonisolated static func orientation(at url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let number = properties[kCGImagePropertyOrientation] as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: number.uint32Value)
        else { return .up }
        return orientation
    }

    /// Bucket precedence for picking a photo's best match across enrolled people
    /// (keep > maybe > no), so a photo is attributed to whoever matched it strongest.
    private nonisolated static func bucketRank(_ bucket: Bucket) -> Int {
        switch bucket {
        case .keep: 2
        case .maybe: 1
        case .no: 0
        }
    }

    /// A detected face's normalized box as a `CGRect` (`.zero` for the rare
    /// heuristic face that carries no box), preserving index alignment.
    private nonisolated static func cgRect(_ face: DetectedFace) -> CGRect {
        guard let box = face.qualityMetrics.faceBoundingBox else { return .zero }
        return CGRect(x: CGFloat(box.x), y: CGFloat(box.y),
                      width: CGFloat(box.width), height: CGFloat(box.height))
    }

    // MARK: - Feedback

    func recordFeedback(photoKey: String, label: FeedbackLabel) async throws {
        // Source of truth is the in-memory store (loaded once); no per-decision disk
        // reload. Mutate it in place, then SCHEDULE the write off the main actor —
        // never encode/write inline before returning (assertions 1 & 2).
        guard var manifest = lastManifest, var workingStore = try loadedStore() else { return }
        switch label {
        case .confirm:
            try? FaceMatcher.confirm(photoKey: photoKey, subjectId: subjectId, manifest: &manifest, store: &workingStore)
        case .reject:
            try? FaceMatcher.reject(photoKey: photoKey, subjectId: subjectId, manifest: &manifest, store: &workingStore)
        }
        lastManifest = manifest
        store = workingStore
        // Hand an immutable `Sendable` snapshot to the coalescing writer (no shared
        // mutable state across actors), then return — the burst coalesces to one write.
        persister.schedule(workingStore)
    }

    // MARK: - Face selection

    func selectFace(photoKey: String, faceIndex: Int) async throws -> FaceSelectionResult {
        guard var manifest = lastManifest,
              var bestFace = manifest[photoKey],
              let faces = bestFace.faces,
              faces.indices.contains(faceIndex),
              let profile = try loadedStore()?[subjectId]
        else {
            return FaceSelectionResult(score: 0, bucket: .other)
        }

        let chosen = faces[faceIndex]
        let metric = FaceModelRegistry.standard.metric(for: profile)
        let raw = try FaceMatcher.score(embedding: chosen.embedding, profile: profile, metric: metric)
        let adjusted = try FaceMatcher.adjustedScore(
            raw: raw,
            embedding: chosen.embedding,
            negatives: profile.negatives,
            negativeMargin: profile.negativeMargin,
            metric: metric
        )
        let bucket = FaceMatcher.bucket(
            score: adjusted,
            threshold: profile.threshold,
            maybeMargin: profile.maybeMargin
        )

        // Re-point the photo's selected face so a later confirm/reject (Keep/Skip)
        // teaches the chosen face rather than the auto-picked one.
        bestFace.embedding = chosen.embedding
        bestFace.qualityMetrics = chosen.qualityMetrics
        let feedback = bestFace.subjectResults[subjectId]?.feedback
        bestFace.subjectResults[subjectId] = SubjectResult(score: adjusted, bucket: bucket, feedback: feedback)
        manifest[photoKey] = bestFace
        lastManifest = manifest

        let reviewBucket: ReviewBucket
        switch bucket {
        case .keep: reviewBucket = .keep
        case .maybe: reviewBucket = .maybe
        default: reviewBucket = .other
        }
        return FaceSelectionResult(score: Double(adjusted), bucket: reviewBucket)
    }

    // MARK: - Manual face regions (item 19)

    func addManualFace(photoKey: String, normalizedRect: CGRect) async throws -> ManualFaceResult? {
        guard isDrawableFaceRegion(normalizedRect),
              var manifest = lastManifest,
              let sourceURL = sourceURLByKey[photoKey],
              let image = ScanPipeline.decodeImage(at: sourceURL),
              let profile = try loadedStore()?[subjectId]
        else {
            return nil
        }

        // Convert the top-left raw rect to Vision's bottom-left normalized box
        // (y' = 1 - maxY); the embedder's bbox path warps + embeds from there.
        let visionBox = CGRect(
            x: normalizedRect.minX,
            y: 1 - normalizedRect.maxY,
            width: normalizedRect.width,
            height: normalizedRect.height
        )
        let embedder = try makeProvider(modelURL)
        guard let face = try? await embedder.embedFace(in: image, regionBoundingBox: visionBox) else {
            // Degenerate after conversion or embedding failure ⇒ no mutation, no throw.
            return nil
        }

        // Append the manual face, keeping the photo's faces 1:1 with `faceBoxes`.
        var bestFace = manifest[photoKey] ?? BestFace(
            embedding: face.embedding,
            qualityMetrics: face.qualityMetrics,
            subjectResults: [:],
            faces: []
        )
        var faces = bestFace.faces ?? [DetectedFace(
            embedding: bestFace.embedding,
            qualityMetrics: bestFace.qualityMetrics
        )]
        faces.append(face)
        let appendedIndex = faces.count - 1

        let metric = FaceModelRegistry.standard.metric(for: profile)
        let raw = try FaceMatcher.score(embedding: face.embedding, profile: profile, metric: metric)
        let adjusted = try FaceMatcher.adjustedScore(
            raw: raw,
            embedding: face.embedding,
            negatives: profile.negatives,
            negativeMargin: profile.negativeMargin,
            metric: metric
        )
        let bucket = FaceMatcher.bucket(
            score: adjusted,
            threshold: profile.threshold,
            maybeMargin: profile.maybeMargin
        )

        // Re-point the photo's match at the manual face so a later confirm/reject
        // (Keep/Skip) teaches the drawn face.
        bestFace.faces = faces
        bestFace.embedding = face.embedding
        bestFace.qualityMetrics = face.qualityMetrics
        let feedback = bestFace.subjectResults[subjectId]?.feedback
        bestFace.subjectResults[subjectId] = SubjectResult(score: adjusted, bucket: bucket, feedback: feedback)
        manifest[photoKey] = bestFace
        lastManifest = manifest

        return ManualFaceResult(
            faceIndex: appendedIndex,
            score: Double(adjusted),
            bucket: Self.reviewBucket(for: bucket)
        )
    }

    func removeManualFace(photoKey: String, faceIndex: Int) async throws {
        guard var manifest = lastManifest,
              var bestFace = manifest[photoKey],
              var faces = bestFace.faces,
              faces.indices.contains(faceIndex)
        else {
            return
        }
        faces.remove(at: faceIndex)
        bestFace.faces = faces
        // Re-seat the representative on a surviving face so the manifest stays
        // consistent; AppModel restores the per-person selection separately.
        if let first = faces.first {
            bestFace.embedding = first.embedding
            bestFace.qualityMetrics = first.qualityMetrics
        }
        manifest[photoKey] = bestFace
        lastManifest = manifest
    }

    /// Maps an engine `Bucket` to the app's `ReviewBucket`.
    private nonisolated static func reviewBucket(for bucket: Bucket) -> ReviewBucket {
        switch bucket {
        case .keep: .keep
        case .maybe: .maybe
        case .no: .other
        }
    }

    func rescoreAll(onlyPhotoKeys: Set<String>?) async throws -> [String: RescoredPhoto] {
        // Rescore reads the SAME in-memory store, so newly-taught feedback is
        // reflected immediately (no stale on-disk copy). Snapshot the Sendable
        // value-typed inputs on the main actor, then run the scoring OFF the main
        // actor (matching scan/thumbnail offloads) so confirming/skipping never
        // blocks the UI. The result is applied back on @MainActor only AFTER the
        // await — the detached closure never touches engine state. `onlyPhotoKeys`
        // (item 49) scopes the loop to the undecided photos the caller supplies, so
        // the per-decision cost stays proportional to what's left to review.
        guard let manifest = lastManifest,
              let profile = try loadedStore()?[subjectId]
        else {
            return [:]
        }
        let subjectId = subjectId
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.computeRescore(
                manifest: manifest, profile: profile, subjectId: subjectId, onlyPhotoKeys: onlyPhotoKeys
            )
        }.value
        lastManifest = outcome.manifest
        return outcome.results
    }

    /// Pure, off-actor rescore: re-scores the requested photos against `profile` and
    /// re-picks each photo's best-matching face, returning the updated manifest plus
    /// the per-`photoKey` score/bucket/selected-face map. Extracted verbatim from the
    /// former inline `rescoreAll` loop so results are byte-for-byte identical; takes
    /// only `Sendable` value-typed inputs and returns `Sendable` values, so the
    /// compiler proves the heavy compute can run off the `@MainActor`.
    ///
    /// `onlyPhotoKeys` (item 49): `nil` re-scores every manifest entry; a set
    /// re-scores ONLY those keys present in the manifest. Non-selected entries are
    /// carried through UNCHANGED in the returned manifest and are ABSENT from
    /// `results`, so the caller can leave decided photos' scores/sections alone.
    nonisolated static func computeRescore(
        manifest: Manifest,
        profile: ProfileBundle,
        subjectId: String,
        onlyPhotoKeys: Set<String>? = nil
    ) -> (manifest: Manifest, results: [String: RescoredPhoto]) {
        var manifest = manifest
        var results: [String: RescoredPhoto] = [:]
        for (key, original) in manifest.bestFacesByPhotoPath {
            // Scope: skip (leave untouched, absent from results) any photo not in the
            // requested set. `nil` means "all", preserving the original behavior.
            if let onlyPhotoKeys, !onlyPhotoKeys.contains(key) { continue }
            var bestFace = original
            // Re-pick the best-matching face: a newly-taught positive can make a
            // different face in a group photo the better match.
            let faces = bestFace.faces ?? [DetectedFace(
                embedding: bestFace.embedding,
                qualityMetrics: bestFace.qualityMetrics
            )]
            // includeFallbackFaces: false — mirrors `streamingScan`'s gate (item
            // 56): a face embedded by FaceEmbedder's blind heuristic fallback must
            // not be (re-)scored as a match on rescore either, or teaching a new
            // exemplar could resurrect a face-less photo that a fresh scan
            // correctly excluded.
            //
            // `try?` (item 60): `bestMatchingFace` now throws on a dimension
            // mismatch, but `computeRescore` stays non-throwing — its signature
            // is pinned by `LiveTriageEngineRescoreTests` and it runs inside a
            // non-throwing `Task.detached` closure. A dimension mismatch here is
            // exactly as "should be impossible" as everywhere else (item 58's
            // stamp gating keeps a manifest/profile pair on one model); `nil`
            // routes through the SAME already-existing "no face passed the
            // gate" branch below (force `.no`, keep face 0), rather than
            // introducing a second sentinel-swallowing path.
            let best = try? FaceMatcher.bestMatchingFace(
                among: faces,
                profile: profile,
                minDetectionScore: 0.0,
                minBoundingBoxArea: 0.0,
                includeFallbackFaces: false
            )
            let index = best?.index ?? 0
            let selected = faces[index]
            let adjusted: Float
            let bucket: Bucket
            if let best {
                adjusted = best.score
                bucket = FaceMatcher.bucket(
                    score: adjusted,
                    threshold: profile.threshold,
                    maybeMargin: profile.maybeMargin
                )
            } else {
                // No face passed the gate (e.g. only a blind-guess fallback face
                // is present) — force `.no` rather than scoring the excluded
                // face, exactly as `ScanPipeline.subjectResult` does.
                adjusted = 0
                bucket = .no
            }

            bestFace.embedding = selected.embedding
            bestFace.qualityMetrics = selected.qualityMetrics
            let feedback = bestFace.subjectResults[subjectId]?.feedback
            bestFace.subjectResults[subjectId] = SubjectResult(score: adjusted, bucket: bucket, feedback: feedback)
            manifest[key] = bestFace

            let reviewBucket: ReviewBucket
            switch bucket {
            case .keep: reviewBucket = .keep
            case .maybe: reviewBucket = .maybe
            default: reviewBucket = .other
            }
            results[key] = RescoredPhoto(
                score: Double(adjusted),
                bucket: reviewBucket,
                selectedFaceIndex: bestFace.faces != nil ? index : nil
            )
        }
        return (manifest, results)
    }

    // MARK: - Export

    func export(photoKeys: [String], destination: ExportDestination) async throws -> Int {
        let sources = photoKeys.compactMap { sourceURLByKey[$0] }
        return try await export(fileURLs: sources, destination: destination)
    }

    func export(fileURLs: [URL], destination: ExportDestination) async throws -> Int {
        switch destination {
        case let .folder(directory):
            return try await exportToFolder(fileURLs, directory: directory)
        case .photos:
            return try await exportToPhotos(fileURLs)
        }
    }

    /// Copies `sources` into `directory`, off the main actor (item 54: N full-res
    /// `FileManager.copyItem` calls used to run inline on this `@MainActor` type,
    /// beachballing the UI on an export of a few hundred keepers). Snapshots the
    /// `Sendable` inputs, hands the heavy work to `copyFilesOffMainActor` via
    /// `Task.detached` (mirroring `computeRescore`), and applies only the resulting
    /// count back here — the detached closure never touches engine state.
    private func exportToFolder(_ sources: [URL], directory: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = testDidCopyFile
        return try await Task.detached(priority: .userInitiated) {
            try Self.copyFilesOffMainActor(sources: sources, directory: directory, onCopy: recorder)
        }.value
    }

    /// Pure, off-actor folder copy (item 54): plans de-collided destinations for
    /// `sources` (`FolderExportPlanner` — two exported photos that would land on the
    /// same filename both survive under distinct names) then copies each
    /// byte-for-byte, returning the count of files ACTUALLY WRITTEN. A pre-existing
    /// stale file already at a destination is deliberately overwritten
    /// (`removeItem` + `copyItem`) — the same intent as before this item;
    /// de-collision applies only to a name collision between two sources in THIS
    /// batch. Throws (without swallowing) on the first copy failure, so a
    /// mid-export failure is surfaced as a thrown error rather than reported as a
    /// smaller-than-real success count. Takes/returns only `Sendable` value types so
    /// the compiler proves this can run entirely off the `@MainActor`. `onCopy`, when
    /// non-nil, fires once per file from INSIDE this loop — the item-54 off-main test
    /// seam, exercised through the real `export(...)` entry point.
    nonisolated static func copyFilesOffMainActor(
        sources: [URL],
        directory: URL,
        fileManager: FileManager = .default,
        onCopy: (@Sendable () -> Void)? = nil
    ) throws -> Int {
        // Ensure the destination exists (item 76): under macOS 27 the sandboxed XCUITest
        // runner can no longer pre-create `KION_EXPORT_DEST`, so the app must. Idempotent
        // and intermediate-safe; `exportToFolder` also creates it, so this only makes the
        // pure copy path self-sufficient (and unit-testable against a not-yet-existing dir).
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let plans = FolderExportPlanner.plan(sources: sources, directory: directory, fileManager: fileManager)
        var exported = 0
        for plan in plans {
            onCopy?()
            if fileManager.fileExists(atPath: plan.destination.path) {
                try fileManager.removeItem(at: plan.destination)
            }
            // Straight byte-for-byte copy; originals untouched.
            try fileManager.copyItem(at: plan.source, to: plan.destination)
            exported += 1
        }
        return exported
    }

    // NOTE (item 54): deliberately NOT `nonisolated` — it reads the MainActor-isolated
    // `photosAuthorizationClient` instance property. The .photos path is async/callback
    // I/O (Photos' own `performChanges` does the heavy lifting on its own queues), not
    // CPU-bound like the folder copy, so staying on the MainActor here doesn't
    // reintroduce the beachball this item fixes for `exportToFolder`.
    private func exportToPhotos(_ sources: [URL]) async throws -> Int {
        let valid = sources.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return 0 }

        let status = await photosAuthorizationClient.requestAddOnlyAuthorization()
        // Item 54: any non-`.authorized` status — including `.limited`, which this
        // add-only entitlement treats as insufficient (see `ExportError`) — throws a
        // TYPED error distinct from "there was nothing to export", so the model layer
        // never reports a bogus "Exported 0" success when access was actually denied.
        guard status == .authorized else { throw ExportError.photosAccessNotAuthorized }

        // Reference the original file as a photo resource (no re-encode, originals
        // preserved) rather than `creationRequestForAssetFromImage(atFileURL:)`,
        // which decodes the image and can raise on files it can't handle. The
        // completion-handler form surfaces failures as a thrown error, not a crash.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for source in valid {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .photo, fileURL: source, options: options)
                }
            } completionHandler: { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return valid.count
    }
}
