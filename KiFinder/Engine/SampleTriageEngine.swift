import CoreGraphics
import Foundation
import KionEngine

@MainActor
final class SampleTriageEngine: TriageEngine {
    /// The deterministic people the sample path models. The first is the default
    /// active person (sample mode prefers the first seeded subject) so visible counts
    /// don't regress before per-person filtering (item 4); the second makes the
    /// sample/test path genuinely multi-person.
    static let primarySubjectID = "Kris"
    static let secondarySubjectID = "Ava"
    // Both are demo names for sample mode only — not real people.
    /// The subject ids the sample path seeds (roster + embedding store) so the
    /// sample/test path has two enrolled people. Display names are the ids
    /// themselves, set by the repository's roster migration.
    static let samplePeople: [String] = [primarySubjectID, secondarySubjectID]

    let candidates: [Candidate]
    var recordedFeedback: [(String, FeedbackLabel)] = []
    /// Spy log of every `enroll` call, in order, with the exact reference URLs.
    private(set) var recordedEnrollments: [[URL]] = []
    /// Optional artificial enroll latency so a UI test can observe the
    /// in-progress (disabled) enrollment state before completion.
    private let enrollDelay: Duration?
    /// Delay between scan progress ticks so a UI test can observe the live
    /// in-progress scan card before it completes and routes to Review.
    private let scanTickDelay: Duration?

    init(
        enrollDelay: Duration? = nil,
        scanTickDelay: Duration? = nil,
        additionalCandidates: [Candidate] = []
    ) {
        self.enrollDelay = enrollDelay
        self.scanTickDelay = scanTickDelay
        // Sample mode is a simulation, so candidates carry distinct (normalized,
        // top-left) face boxes — some with multiple faces — to exercise the real
        // per-photo overlay and the face picker.
        let kris = Self.primarySubjectID
        let ava = Self.secondarySubjectID
        // Each candidate carries per-person scores AND per-person buckets spanning
        // BOTH people, and is attributed (`matchedSubjectID`) to its best match;
        // `score`/`bucket` reflect that attributed person. The first four are
        // single-attributed (each person's OTHER bucket is `.other`) so item-4/5's
        // per-person visibility holds exactly: Kris sees keep-1 + maybe-1, Ava sees
        // keep-2 + maybe-2. `sample-both-1` is a genuine multi-home group photo —
        // `maybe` for BOTH Kris and Ava — so it surfaces in each person's "Worth a
        // look", exercising the per-person bucketing path (item 6).
        candidates = [
            Candidate(
                id: "sample-keep-1",
                photoKey: "sample/fern-window.png",
                fileName: "IMG_1842.PNG",
                imageResourceName: "sample-keep-01",
                score: 0.93,
                bucket: .keep,
                faceBoxes: [
                    CGRect(x: 0.36, y: 0.22, width: 0.30, height: 0.36),
                    CGRect(x: 0.08, y: 0.30, width: 0.18, height: 0.22),
                ],
                selectedFaceIndex: 0,
                matchedSubjectID: kris,
                subjectScores: [kris: 0.93, ava: 0.41],
                subjectBuckets: [kris: .keep, ava: .other],
                selectedFaceIndexBySubject: [kris: 0, ava: 1]
            ),
            Candidate(
                id: "sample-keep-2",
                photoKey: "sample/greenhouse.png",
                fileName: "IMG_1851.PNG",
                imageResourceName: "sample-keep-02",
                score: 0.88,
                bucket: .keep,
                faceBoxes: [CGRect(x: 0.52, y: 0.30, width: 0.26, height: 0.32)],
                selectedFaceIndex: 0,
                matchedSubjectID: ava,
                subjectScores: [ava: 0.88, kris: 0.39],
                subjectBuckets: [ava: .keep, kris: .other],
                selectedFaceIndexBySubject: [ava: 0, kris: 0]
            ),
            Candidate(
                id: "sample-maybe-1",
                photoKey: "sample/amber-path.png",
                fileName: "IMG_1861.PNG",
                imageResourceName: "sample-maybe-01",
                score: 0.68,
                bucket: .maybe,
                faceBoxes: [
                    CGRect(x: 0.18, y: 0.26, width: 0.28, height: 0.34),
                    CGRect(x: 0.60, y: 0.20, width: 0.22, height: 0.30),
                ],
                selectedFaceIndex: 0,
                matchedSubjectID: kris,
                subjectScores: [kris: 0.68, ava: 0.30],
                subjectBuckets: [kris: .maybe, ava: .other],
                selectedFaceIndexBySubject: [kris: 0, ava: 1]
            ),
            Candidate(
                id: "sample-maybe-2",
                photoKey: "sample/copper-leaf.png",
                fileName: "IMG_1874.PNG",
                imageResourceName: "sample-maybe-01",
                score: 0.61,
                bucket: .maybe,
                faceBoxes: [CGRect(x: 0.40, y: 0.18, width: 0.24, height: 0.30)],
                selectedFaceIndex: 0,
                matchedSubjectID: ava,
                subjectScores: [ava: 0.61, kris: 0.28],
                subjectBuckets: [ava: .maybe, kris: .other],
                selectedFaceIndexBySubject: [ava: 0, kris: 0]
            ),
            // Multi-home group photo: BOTH Kris and Ava are present, each a `maybe`
            // bucketed by their OWN score (Kris 0.67 edges Ava 0.66, so the headline
            // attribution is Kris). It appears in BOTH people's "Worth a look", each
            // boxing their own detected face.
            Candidate(
                id: "sample-both-1",
                photoKey: "sample/twin-ferns.png",
                fileName: "IMG_1888.PNG",
                imageResourceName: "sample-maybe-01",
                score: 0.67,
                bucket: .maybe,
                faceBoxes: [
                    CGRect(x: 0.22, y: 0.24, width: 0.26, height: 0.32),
                    CGRect(x: 0.56, y: 0.22, width: 0.24, height: 0.30),
                ],
                selectedFaceIndex: 0,
                matchedSubjectID: kris,
                subjectScores: [kris: 0.67, ava: 0.66],
                subjectBuckets: [kris: .maybe, ava: .maybe],
                selectedFaceIndexBySubject: [kris: 0, ava: 1]
            ),
        ] + additionalCandidates
    }

    func enroll(referenceURLs: [URL]) async throws -> [FaceEmbedding] {
        recordedEnrollments.append(referenceURLs)
        if let enrollDelay {
            try await Task.sleep(for: enrollDelay)
        }
        // One placeholder embedding per reference, so the persisted profile records
        // the right subject and reference count (no real inference in sample mode).
        return referenceURLs.enumerated().map { index, _ in FaceEmbedding([Float(index + 1)]) }
    }

    /// Returns a real bundled placeholder image (re-encoded to a bounded PNG) as the
    /// person's thumbnail. No detection or network — the sample path ships an
    /// on-disk asset so the multi-person UI has a real image to render.
    func enrollmentThumbnail(referenceURLs _: [URL]) async -> Data? {
        Self.placeholderThumbnailData()
    }

    /// Loads the bundled sample image and downsamples it to a ~256px PNG via the
    /// shared `FaceThumbnail` path (full-frame crop). `nil` only if the asset is
    /// missing from the bundle.
    static func placeholderThumbnailData() -> Data? {
        guard let url = Bundle.main.url(forResource: "sample-keep-01", withExtension: "png") else {
            return nil
        }
        return FaceThumbnail.croppedPNG(
            fromImageAt: url,
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            padding: 0
        )
    }

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        let all = candidates
        let total = all.count
        let delay = scanTickDelay
        let albumName = String(localized: "Sample Album")
        return AsyncStream { continuation in
            let task = Task {
                let steps = 4
                for step in 1 ... steps {
                    if Task.isCancelled { break }
                    let isFinal = step == steps
                    let matches = isFinal ? total : Int(Double(total) * Double(step) / Double(steps))
                    continuation.yield(
                        ScanProgress(
                            progress: Double(step) / Double(steps),
                            matchesSoFar: matches,
                            totalPhotos: 312,
                            statusText: String(localized: "\(matches) of \(total) · \(albumName)"),
                            candidates: isFinal ? all : [],
                            isFinal: isFinal
                        )
                    )
                    if !isFinal, let delay { try? await Task.sleep(for: delay) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func recordFeedback(photoKey: String, label: FeedbackLabel) async throws {
        recordedFeedback.append((photoKey, label))
    }

    /// Sample mode has no real embeddings, so selecting a face just echoes the
    /// candidate's existing score/bucket; the visible box change comes from the
    /// updated selected index in `AppModel`.
    func selectFace(photoKey: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        guard let candidate = candidates.first(where: { $0.photoKey == photoKey }) else {
            return FaceSelectionResult(score: 0, bucket: .other)
        }
        return FaceSelectionResult(score: candidate.score, bucket: candidate.bucket)
    }

    /// Deterministic keep-ish score the sample path assigns a manually-drawn region
    /// (no real embedding in sample mode), so `AppModel` tests are deterministic.
    static let manualFaceScore = 0.9

    /// Sample mode has no mutable manifest, so "appending" a manual face is modeled
    /// purely by the returned index: the new face would land at the current face
    /// count (1:1 with `faceBoxes`). Returns a fixed keep score/bucket; a degenerate
    /// rect returns `nil` with no result (mirroring the Live nil-guard).
    func addManualFace(photoKey: String, normalizedRect: CGRect) async throws -> ManualFaceResult? {
        guard isDrawableFaceRegion(normalizedRect) else { return nil }
        let appendedIndex = candidates.first { $0.photoKey == photoKey }?.faceBoxes.count ?? 0
        return ManualFaceResult(faceIndex: appendedIndex, score: Self.manualFaceScore, bucket: .keep)
    }

    /// Sample mode keeps no manifest, so dropping a manual face is a no-op — the
    /// `AppModel` owns the visible `faceBoxes` it re-indexes.
    func removeManualFace(photoKey _: String, faceIndex _: Int) async throws {}

    /// Sample mode has no real profile to teach, so re-scoring just echoes each
    /// candidate's existing match — no promotions are ever surfaced. `onlyPhotoKeys`
    /// (item 49) filters the echo to the requested keys (`nil` echoes all), matching
    /// the live engine's scoping so AppModel behaves identically in sample mode.
    func rescoreAll(onlyPhotoKeys: Set<String>?) async throws -> [String: RescoredPhoto] {
        let selected = candidates.filter { onlyPhotoKeys?.contains($0.photoKey) ?? true }
        // TEST-ONLY deterministic promotion hook (item 50): sample re-scoring can't
        // teach, so a live click of "Find new matches" never surfaces a promotion
        // without a fixture. When `KION_SAMPLE_PROMOTE_ON_RESCORE=<candidateId>` is set,
        // that candidate re-scores to `.keep` (a better bucket) — but ONLY when it is
        // actually in scope (`photoKey ∈ onlyPhotoKeys`, or `onlyPhotoKeys == nil`), so
        // item-49 scoping is preserved and the target is ABSENT when excluded. Inert
        // (echo-only) unless the env var is set, so normal sample UX is unchanged.
        let promoteId = ProcessInfo.processInfo.environment["KION_SAMPLE_PROMOTE_ON_RESCORE"]
        return Dictionary(uniqueKeysWithValues: selected.map { candidate in
            if let promoteId, candidate.id == promoteId {
                return (candidate.photoKey, RescoredPhoto(
                    score: max(candidate.score, 0.95),
                    bucket: .keep,
                    selectedFaceIndex: candidate.selectedFaceIndex
                ))
            }
            return (candidate.photoKey, RescoredPhoto(
                score: candidate.score,
                bucket: candidate.bucket,
                selectedFaceIndex: candidate.selectedFaceIndex
            ))
        })
    }

    /// Straight byte-for-byte copy of each kept candidate's bundled source image
    /// into the chosen folder, verifying the copy matches the source. Returns the
    /// number of files successfully exported. Originals are never modified.
    func export(photoKeys: [String], destination: ExportDestination) async throws -> Int {
        guard case let .folder(directory) = destination else {
            // Add-to-Photos isn't exercised in the sample/build path (it needs the
            // Photos permission); report the would-be count.
            return photoKeys.count
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var exported = 0
        for key in photoKeys {
            guard let candidate = candidates.first(where: { $0.photoKey == key }),
                  let source = Bundle.main.url(
                      forResource: candidate.imageResourceName, withExtension: "png"
                  )
            else { continue }
            let destination = directory.appendingPathComponent(candidate.fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            // Confirm the export is an exact byte-for-byte copy of the original.
            let sourceData = try Data(contentsOf: source)
            let copiedData = try Data(contentsOf: destination)
            if sourceData == copiedData { exported += 1 }
        }
        return exported
    }

    /// Sample mode reports the would-be export count for the given files without
    /// touching Photos (which needs the add-only permission). Deterministic so the
    /// library export test is hermetic: N input URLs ⇒ N.
    func export(fileURLs: [URL], destination _: ExportDestination) async throws -> Int {
        fileURLs.count
    }
}
