import Foundation
import KionEngine
import Testing
@testable import KiFinder

/// Item 36: the rescore scoring now runs OFF the @MainActor via the `nonisolated static`
/// `LiveTriageEngine.computeRescore`. This drives the REAL shipped function (not a copy)
/// over a Manifest/ProfileBundle fixture and pins the per-photo trio
/// (selectedFaceIndex / score / bucket) — including the multi-face re-pick — so the
/// off-actor extraction can't silently drift from the scoring semantics.
@Suite("LiveTriageEngine.computeRescore (off-actor rescore)")
struct LiveTriageEngineRescoreTests {
    private let modelId = "model-1"
    private let modelVersion = "v1"

    private func metrics() -> QualityMetrics {
        QualityMetrics(detectionScore: 0.9, boundingBoxArea: 0.4)
    }

    private func bundle() -> ProfileBundle {
        ProfileBundle(
            subjectId: "s",
            references: [FaceEmbedding([1, 0, 0])],
            threshold: 0.5,
            maybeMargin: 0.1,
            modelId: modelId,
            modelVersion: modelVersion
        )
    }

    @Test("Re-picks the matching face in a multi-face photo; a single maybe stays on face 0")
    func computeRescoreRepicksAndBuckets() {
        var manifest = Manifest(modelId: modelId, modelVersion: modelVersion)
        // Two-face photo: auto face 0 ([0,1,0]) doesn't match the reference [1,0,0],
        // but face 1 ([1,0,0]) does — the re-pick must move selection to face 1 (keep).
        let f0 = DetectedFace(embedding: FaceEmbedding([0, 1, 0]), qualityMetrics: metrics())
        let f1 = DetectedFace(embedding: FaceEmbedding([1, 0, 0]), qualityMetrics: metrics())
        manifest["multi.jpg"] = BestFace(
            embedding: f0.embedding, qualityMetrics: f0.qualityMetrics,
            subjectResults: [:], faces: [f0, f1]
        )
        // Single-face photo scoring in the "maybe" band ([0.4, 0.5)) — stays on face 0.
        let single = DetectedFace(embedding: FaceEmbedding([0.45, 0.893025, 0]), qualityMetrics: metrics())
        manifest["single.jpg"] = BestFace(
            embedding: single.embedding, qualityMetrics: single.qualityMetrics,
            subjectResults: [:], faces: [single]
        )

        let out = LiveTriageEngine.computeRescore(manifest: manifest, profile: bundle(), subjectId: "s")

        let multi = try! #require(out.results["multi.jpg"])
        #expect(multi.selectedFaceIndex == 1)
        #expect(abs(multi.score - 1.0) < 0.0001)
        #expect(multi.bucket == .keep)

        let one = try! #require(out.results["single.jpg"])
        #expect(one.selectedFaceIndex == 0)
        #expect(abs(one.score - 0.45) < 0.001)
        #expect(one.bucket == .maybe)

        // The returned manifest carries the re-picked selection forward for "multi.jpg".
        #expect(out.manifest["multi.jpg"]?.embedding == f1.embedding)
    }

    // MARK: - Item 56: the GUI's OWN rescore path must exclude fallback faces

    /// Investigation during item 56 found that `LiveTriageEngine`'s
    /// SCAN loop (`streamingScan`) does not call `ScanPipeline` at all — it
    /// reimplements per-photo attribution inline — so gating `ScanPipeline`
    /// alone left the shipped app's scan (and, mirrored here, its rescore) able
    /// to resurrect a face-less photo as a "match". This test drives the REAL
    /// shipped `computeRescore` (not a copy, matching the suite's existing
    /// convention) over a cached photo whose ONLY detected face is a
    /// blind-guess fallback that otherwise embeds a PERFECT match for the
    /// profile reference — proving the GUI's rescore path excludes it exactly
    /// like `ScanPipeline` does, landing `.other` (no match) rather than `.keep`.
    @Test("computeRescore excludes a fallback-only face from keep/maybe even on a perfect embedding match")
    func computeRescoreExcludesFallbackFace() {
        var manifest = Manifest(modelId: modelId, modelVersion: modelVersion)
        let fallback = DetectedFace(
            embedding: FaceEmbedding([1, 0, 0]),
            qualityMetrics: QualityMetrics(detectionScore: 0, boundingBoxArea: 10000, isFallback: true)
        )
        manifest["blind.jpg"] = BestFace(
            embedding: fallback.embedding, qualityMetrics: fallback.qualityMetrics,
            subjectResults: [:], faces: [fallback]
        )
        // Contrast, in the SAME rescore call: a genuine (non-fallback) face
        // with the identical embedding keeps matching normally — the exclusion
        // targets the fallback flag specifically, not embeddings that happen to
        // score perfectly.
        let genuine = DetectedFace(
            embedding: FaceEmbedding([1, 0, 0]),
            qualityMetrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 10000, isFallback: false)
        )
        manifest["genuine.jpg"] = BestFace(
            embedding: genuine.embedding, qualityMetrics: genuine.qualityMetrics,
            subjectResults: [:], faces: [genuine]
        )

        let out = LiveTriageEngine.computeRescore(manifest: manifest, profile: bundle(), subjectId: "s")

        let blind = try! #require(out.results["blind.jpg"])
        #expect(blind.bucket == .other)
        #expect(blind.score == 0.0)

        let matched = try! #require(out.results["genuine.jpg"])
        #expect(matched.bucket == .keep)
        #expect(abs(matched.score - 1.0) < 0.0001)
    }

    // MARK: - Item 49: scope the rescore to a subset of photos

    /// A two-photo manifest of single-face photos scoring in the "maybe" band.
    private func twoPhotoManifest() -> Manifest {
        var manifest = Manifest(modelId: modelId, modelVersion: modelVersion)
        let a = DetectedFace(embedding: FaceEmbedding([0.45, 0.893025, 0]), qualityMetrics: metrics())
        let b = DetectedFace(embedding: FaceEmbedding([0.40, 0.916515, 0]), qualityMetrics: metrics())
        manifest["a.jpg"] = BestFace(
            embedding: a.embedding, qualityMetrics: a.qualityMetrics, subjectResults: [:], faces: [a]
        )
        manifest["b.jpg"] = BestFace(
            embedding: b.embedding, qualityMetrics: b.qualityMetrics, subjectResults: [:], faces: [b]
        )
        return manifest
    }

    @Test("computeRescore(onlyPhotoKeys:) leaves non-selected photos untouched (item 49)")
    func computeRescoreScopesToSubset() {
        let manifest = twoPhotoManifest()

        // Subset: only "a.jpg" is re-scored — results carries EXACTLY that key, and the
        // returned manifest entry for the non-selected "b.jpg" is byte-for-byte the input.
        let subset = LiveTriageEngine.computeRescore(
            manifest: manifest, profile: bundle(), subjectId: "s", onlyPhotoKeys: ["a.jpg"]
        )
        #expect(Set(subset.results.keys) == ["a.jpg"])
        #expect(subset.manifest["b.jpg"] == manifest["b.jpg"])

        // nil scopes to ALL photos (back-compat).
        let all = LiveTriageEngine.computeRescore(
            manifest: manifest, profile: bundle(), subjectId: "s", onlyPhotoKeys: nil
        )
        #expect(Set(all.results.keys) == ["a.jpg", "b.jpg"])

        // Empty set re-scores nothing.
        let none = LiveTriageEngine.computeRescore(
            manifest: manifest, profile: bundle(), subjectId: "s", onlyPhotoKeys: []
        )
        #expect(none.results.isEmpty)
        #expect(none.manifest == manifest)
    }

    @MainActor
    private func liveEngine() -> LiveTriageEngine {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-live-rescore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LiveTriageEngine(
            environment: [:],
            storeURL: dir.appendingPathComponent("store.json"),
            subjectId: "s",
            modelId: modelId,
            modelVersion: modelVersion
        )
    }

    @MainActor
    @Test("LiveTriageEngine.rescoreAll(onlyPhotoKeys:) forwards the subset (item 49)")
    func liveRescoreAllScopesToSubset() async throws {
        let engine = liveEngine()
        var store = ProfileStore(modelId: modelId, modelVersion: modelVersion)
        store["s"] = bundle()
        engine.loadForTesting(store: store, manifest: twoPhotoManifest())

        let subset = try await engine.rescoreAll(onlyPhotoKeys: ["a.jpg"])
        #expect(Set(subset.keys) == ["a.jpg"])

        let all = try await engine.rescoreAll(onlyPhotoKeys: nil)
        #expect(Set(all.keys) == ["a.jpg", "b.jpg"])

        let none = try await engine.rescoreAll(onlyPhotoKeys: [])
        #expect(none.isEmpty)
    }
}
