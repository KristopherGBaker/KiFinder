import Foundation
@testable import KionEngine
import Testing

/// Item 69 — proves `FaceModelRegistry` resolves a `FaceModelDescriptor` from a
/// persisted `(modelId, modelVersion)` stamp, and that the resolved
/// `similarityMetric`/`calibration` are genuinely THREADED through
/// `FaceMatcher.bestMatchingFace`/`rescore` and the enroll-seed sites — not just
/// arithmetically correct in isolation. `.standard` stays `[.arcface]` (cosine),
/// so today's shipped behavior is unchanged; the non-vacuous proof below injects a
/// second, distinct descriptor to show the metric actually drives selection.
@Suite("Descriptor threading (item 69)")
struct DescriptorThreadingTests {
    // MARK: - Assertion 1: registry resolution

    @Test("standard registry resolves the canonical stamp to .arcface")
    func standardResolvesCanonical() {
        let resolved = FaceModelRegistry.standard.descriptor(
            for: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(resolved == .arcface)
    }

    @Test("standard registry resolves every legacy alias stamp to .arcface")
    func standardResolvesLegacyAliases() {
        for alias in ModelIdentity.legacyAliases {
            let resolved = FaceModelRegistry.standard.descriptor(for: alias.modelId, modelVersion: alias.modelVersion)
            #expect(resolved == .arcface, "legacy alias \(alias) should resolve to .arcface")
        }
    }

    @Test("standard registry resolves an unknown stamp to nil")
    func standardResolvesUnknownToNil() {
        let resolved = FaceModelRegistry.standard.descriptor(for: "foo", modelVersion: "9")
        #expect(resolved == nil)
    }

    @Test("a custom registry resolves its own descriptor's identity AND still resolves canonical/aliases")
    func customRegistryResolvesOwnDescriptorAndCanonical() {
        let dp = FaceModelDescriptor(
            id: "test-dp",
            version: "1",
            embeddingDimension: 3,
            similarityMetric: .dotProduct,
            calibration: MatchCalibration(defaultThreshold: 0.7, maybeMargin: 0.15, negativeMargin: 0.05)
        )
        let registry = FaceModelRegistry([.arcface, dp])

        #expect(registry.descriptor(for: "test-dp", modelVersion: "1") == dp)
        #expect(registry.descriptor(
            for: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        ) == .arcface)
        for alias in ModelIdentity.legacyAliases {
            #expect(registry.descriptor(for: alias.modelId, modelVersion: alias.modelVersion) == .arcface)
        }
        #expect(registry.descriptor(for: "bar", modelVersion: "42") == nil)
    }

    // MARK: - Assertion 2: metric(for:) mapping + fallback

    @Test("metric(for:) returns .cosine for a canonical-stamped profile and for an unknown-stamped profile")
    func metricFallsBackToCosine() {
        let canonicalProfile = profile(
            references: [FaceEmbedding([1, 0, 0])],
            modelId: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(FaceModelRegistry.standard.metric(for: canonicalProfile) == .cosine)

        let unknownProfile = profile(
            references: [FaceEmbedding([1, 0, 0])],
            modelId: "foo",
            modelVersion: "9"
        )
        #expect(FaceModelRegistry.standard.metric(for: unknownProfile) == .cosine)
    }

    @Test("metric(for:) resolves a registered .dotProduct descriptor's stamp to .dotProduct")
    func metricResolvesDotProductDescriptor() {
        let dp = FaceModelDescriptor(
            id: "test-dp",
            version: "1",
            embeddingDimension: 3,
            similarityMetric: .dotProduct,
            calibration: MatchCalibration(defaultThreshold: 0.7, maybeMargin: 0.15, negativeMargin: 0.05)
        )
        let registry = FaceModelRegistry([.arcface, dp])
        let dpProfile = profile(references: [FaceEmbedding([1, 0, 0])], modelId: "test-dp", modelVersion: "1")
        #expect(registry.metric(for: dpProfile) == .dotProduct)
    }

    // MARK: - Assertion 3: non-vacuous threading proof (SELECTION, not just arithmetic)

    /// Reference `[1,0,0]`. Face A `[0.9,0,0]` is EXACTLY colinear with the
    /// reference, so cosine(A) = 1.0 — the maximum possible cosine value — while
    /// its raw dot product is only 0.9. Face B `[10,0,1]` has a much larger
    /// magnitude but is slightly off-axis, so dot(B) = 10.0 (far larger than A's
    /// 0.9) while cosine(B) ≈ 0.995 (slightly less than A's 1.0). This makes the
    /// ranking FLIP: cosine picks A, dot product picks B — so a caller that
    /// threads the resolved metric selects a different face than one that
    /// silently stays hardcoded `.cosine`.
    private static let referenceEmbedding = FaceEmbedding([1, 0, 0])
    private static let faceAEmbedding = FaceEmbedding([0.9, 0, 0]) // cosine winner
    private static let faceBEmbedding = FaceEmbedding([10, 0, 1]) // dot-product winner

    private static let dotProductDescriptor = FaceModelDescriptor(
        id: "test-dp",
        version: "1",
        embeddingDimension: 3,
        similarityMetric: .dotProduct,
        calibration: MatchCalibration(defaultThreshold: 0.7, maybeMargin: 0.15, negativeMargin: 0.05)
    )

    @Test("bestMatchingFace threads the persisted model's metric to select the dot-product winner, not the cosine winner")
    func bestMatchingFaceThreadsPersistedModelMetric() throws {
        let registry = FaceModelRegistry([.arcface, Self.dotProductDescriptor])
        let dpProfile = profile(references: [Self.referenceEmbedding], modelId: "test-dp", modelVersion: "1")

        let faceA = DetectedFace(
            embedding: Self.faceAEmbedding,
            qualityMetrics: QualityMetrics(detectionScore: 0.95, boundingBoxArea: 10000)
        )
        let faceB = DetectedFace(
            embedding: Self.faceBEmbedding,
            qualityMetrics: QualityMetrics(detectionScore: 0.95, boundingBoxArea: 10000)
        )

        // Sanity: under cosine (the default/unthreaded metric), index 0 (face A) wins.
        let cosineResult = try #require(try FaceMatcher.bestMatchingFace(
            among: [faceA, faceB],
            profile: dpProfile,
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ))
        #expect(cosineResult.index == 0)

        // With the registry threading the persisted model's .dotProduct metric,
        // index 1 (face B) wins instead — the ranking FLIPS.
        let threadedResult = try #require(try FaceMatcher.bestMatchingFace(
            among: [faceA, faceB],
            profile: dpProfile,
            minDetectionScore: 0,
            minBoundingBoxArea: 0,
            registry: registry
        ))
        #expect(threadedResult.index == 1)
        #expect(threadedResult.index != cosineResult.index)

        // The winning score equals the independently-computed dot product: [10,0,1]·[1,0,0] = 10.
        #expect(abs(threadedResult.score - 10.0) < 0.0001)
    }

    @Test("rescore threads the persisted model's metric to produce the dot-product score, distinct from cosine")
    func rescoreThreadsPersistedModelMetric() throws {
        let registry = FaceModelRegistry([.arcface, Self.dotProductDescriptor])
        let dpProfile = profile(references: [Self.referenceEmbedding], modelId: "test-dp", modelVersion: "1")

        let manifest = Manifest(
            [
                "photo-001": BestFace(
                    embedding: Self.faceBEmbedding,
                    qualityMetrics: QualityMetrics(detectionScore: 0.95, boundingBoxArea: 10000),
                    subjectResults: [:]
                ),
            ],
            modelId: nil,
            modelVersion: nil
        )

        let cosineRescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: dpProfile,
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let cosineScore = try #require(cosineRescored["photo-001"]?.subjectResults["subject-a"]?.score)
        #expect(abs(cosineScore - 0.9950) < 0.001)

        let threadedRescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: dpProfile,
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0,
            registry: registry
        )
        let threadedScore = try #require(threadedRescored["photo-001"]?.subjectResults["subject-a"]?.score)
        #expect(abs(threadedScore - 10.0) < 0.0001)
        #expect(abs(threadedScore - cosineScore) > 1.0) // clearly distinct, not coincidentally equal
    }

    // MARK: - Assertion 4: seed calibration via registry

    @Test("standard registry's calibration(for:) for the canonical stamp equals FaceModelDescriptor.arcface.calibration")
    func standardCalibrationMatchesArcface() {
        let calibration = FaceModelRegistry.standard.calibration(
            for: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(calibration == FaceModelDescriptor.arcface.calibration)
        #expect(calibration == MatchCalibration(defaultThreshold: 0.45, maybeMargin: 0.20, negativeMargin: 0.0))
    }

    @Test("standard registry's calibration(for:) falls back to arcface's calibration for an unknown stamp")
    func unknownStampCalibrationFallsBackToArcface() {
        let calibration = FaceModelRegistry.standard.calibration(for: "foo", modelVersion: "9")
        #expect(calibration == FaceModelDescriptor.arcface.calibration)
    }
}

// MARK: - Local test helpers (this file's own, not shared with KionEngineTests.swift)

private func profile(
    subjectId: String = "subject-a",
    references: [FaceEmbedding],
    negatives: [FaceEmbedding] = [],
    threshold: Float = 0.5,
    maybeMargin: Float = 0.1,
    negativeMargin: Float = 0.0,
    modelId: String,
    modelVersion: String
) -> ProfileBundle {
    ProfileBundle(
        subjectId: subjectId,
        references: references,
        negatives: negatives,
        threshold: threshold,
        maybeMargin: maybeMargin,
        negativeMargin: negativeMargin,
        modelId: modelId,
        modelVersion: modelVersion
    )
}
