import Foundation

public enum FaceMatcherError: Error, Equatable, Sendable {
    case unknownPhoto(String)
    case unknownSubject(String)
}

extension FaceMatcherError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownPhoto(let photoKey):
            return "unknown photo: \(photoKey)"
        case .unknownSubject(let subjectId):
            return "unknown subject: \(subjectId)"
        }
    }
}

/// Thrown instead of silently returning `0.0` when two embeddings can't be
/// compared — different lengths, or both empty. Before item 60 this was a
/// corruption trap: a dimension mismatch (which should be impossible once
/// item 58's model-stamp gating keeps a manifest/profile pair on the same
/// model) laundered into an innocent-looking `0.0` similarity instead of
/// surfacing the invariant violation. Carries both counts so a caller can
/// diagnose which side was wrong.
public struct FaceMatchDimensionError: Error, Equatable, Sendable {
    public let lhsCount: Int
    public let rhsCount: Int

    public init(lhsCount: Int, rhsCount: Int) {
        self.lhsCount = lhsCount
        self.rhsCount = rhsCount
    }
}

extension FaceMatchDimensionError: LocalizedError {
    public var errorDescription: String? {
        "face embeddings have mismatched dimensions: \(lhsCount) vs \(rhsCount)"
    }
}

public struct FaceMatcher: Sendable {
    public init() {}

    public static func score(
        embedding: FaceEmbedding,
        profile: ProfileBundle,
        metric: SimilarityMetric = .cosine
    ) throws -> Float {
        let scores = try (profile.references + profile.confirmedPositives)
            .map { try similarity(embedding.values, $0.values, metric: metric) }
        return scores.max() ?? 0.0
    }

    public static func adjustedScore(
        raw: Float,
        embedding: FaceEmbedding,
        negatives: [FaceEmbedding],
        negativeMargin: Float,
        metric: SimilarityMetric = .cosine
    ) throws -> Float {
        let negativeScores = try negatives.map { try similarity(embedding.values, $0.values, metric: metric) }
        guard let maxNegative = negativeScores.max() else {
            return raw
        }
        return raw - max(0.0, maxNegative - negativeMargin)
    }

    /// Among the faces detected in one photo, returns the index of the one that
    /// best matches the profile (highest adjusted score), considering only faces
    /// that pass the quality gate. This is what makes a group photo land in the
    /// right bucket even when the subject isn't the most prominent face.
    public static func bestMatchingFace(
        among faces: [DetectedFace],
        profile: ProfileBundle,
        minDetectionScore: Float,
        minBoundingBoxArea: Float,
        includeFallbackFaces: Bool = true,
        registry: FaceModelRegistry = .standard
    ) throws -> (index: Int, score: Float)? {
        let metric = registry.metric(for: profile)
        let candidates = try faces.enumerated()
            .compactMap { index, face -> (index: Int, score: Float)? in
                guard passesQualityGate(
                    metrics: face.qualityMetrics,
                    minDetectionScore: minDetectionScore,
                    minBoundingBoxArea: minBoundingBoxArea,
                    includeFallbackFaces: includeFallbackFaces
                ) else {
                    return nil
                }
                let raw = try score(embedding: face.embedding, profile: profile, metric: metric)
                let adjusted = try adjustedScore(
                    raw: raw,
                    embedding: face.embedding,
                    negatives: profile.negatives,
                    negativeMargin: profile.negativeMargin,
                    metric: metric
                )
                return (index, adjusted)
            }
        return candidates.max { $0.score < $1.score }
    }

    /// `includeFallbackFaces` gates on `QualityMetrics.isFallback` — a face from
    /// `FaceEmbedder`'s blind heuristic fallback — independently of
    /// `detectionScore`/`boundingBoxArea`: a fallback face fails this gate when
    /// `includeFallbackFaces` is `false` regardless of how high its reported score
    /// is, so a caller can't accidentally let a blind guess back in by loosening
    /// `minDetectionScore`. Defaults to `true` (unchanged legacy behavior) so
    /// every pre-item-56 caller of this function keeps its old semantics; callers
    /// that want the new default (excluding fallback faces) pass `false`
    /// explicitly — see `ScanPipeline.includeFallbackFaces`.
    public static func passesQualityGate(
        metrics: QualityMetrics,
        minDetectionScore: Float,
        minBoundingBoxArea: Float,
        includeFallbackFaces: Bool = true
    ) -> Bool {
        guard includeFallbackFaces || !metrics.isFallback else {
            return false
        }
        return metrics.detectionScore >= minDetectionScore
            && metrics.boundingBoxArea >= minBoundingBoxArea
    }

    public static func bucket(score: Float, threshold: Float, maybeMargin: Float) -> Bucket {
        if score >= threshold {
            return .keep
        }
        if score >= threshold - maybeMargin {
            return .maybe
        }
        return .no
    }

    public static func confirm(
        photoKey: String,
        subjectId: String,
        manifest: inout Manifest,
        store: inout ProfileStore
    ) throws {
        try applyFeedback(
            .confirm,
            photoKey: photoKey,
            subjectId: subjectId,
            manifest: &manifest,
            store: &store
        )
    }

    public static func reject(
        photoKey: String,
        subjectId: String,
        manifest: inout Manifest,
        store: inout ProfileStore
    ) throws {
        try applyFeedback(
            .reject,
            photoKey: photoKey,
            subjectId: subjectId,
            manifest: &manifest,
            store: &store
        )
    }

    public static func rescore(
        manifest: Manifest,
        profile: ProfileBundle,
        subjectId: String,
        minDetectionScore: Float,
        minBoundingBoxArea: Float,
        includeFallbackFaces: Bool = true,
        registry: FaceModelRegistry = .standard
    ) throws -> Manifest {
        guard subjectId == profile.subjectId else {
            throw FaceMatcherError.unknownSubject(subjectId)
        }
        try checkManifestStamp(manifest, modelId: profile.modelId, modelVersion: profile.modelVersion)

        let metric = registry.metric(for: profile)
        var rescored = manifest
        for photoKey in rescored.bestFacesByPhotoPath.keys {
            guard var bestFace = rescored.bestFacesByPhotoPath[photoKey] else {
                continue
            }

            let feedback = bestFace.subjectResults[subjectId]?.feedback
            let result: SubjectResult
            if passesQualityGate(
                metrics: bestFace.qualityMetrics,
                minDetectionScore: minDetectionScore,
                minBoundingBoxArea: minBoundingBoxArea,
                includeFallbackFaces: includeFallbackFaces
            ) {
                let raw = try score(embedding: bestFace.embedding, profile: profile, metric: metric)
                let adjusted = try adjustedScore(
                    raw: raw,
                    embedding: bestFace.embedding,
                    negatives: profile.negatives,
                    negativeMargin: profile.negativeMargin,
                    metric: metric
                )
                result = SubjectResult(
                    score: adjusted,
                    bucket: bucket(
                        score: adjusted,
                        threshold: profile.threshold,
                        maybeMargin: profile.maybeMargin
                    ),
                    feedback: feedback
                )
            } else {
                result = SubjectResult(score: 0.0, bucket: .no, feedback: feedback)
            }

            bestFace.subjectResults[subjectId] = result
            rescored.bestFacesByPhotoPath[photoKey] = bestFace
        }

        rescored.modelId = profile.modelId
        rescored.modelVersion = profile.modelVersion
        return rescored
    }

    /// Whether `manifest`'s stamp is compatible with the expected `modelId`/
    /// `modelVersion` — an exact match, no stamp at all (a legacy manifest written
    /// before stamping existed), or a recognized legacy alias of the canonical
    /// identity (item 58: e.g. a manifest stamped with the app's old
    /// `"kion-local-enroll"` is compatible with a canonical-expecting store).
    /// Shared by `checkManifestStamp` (throwing) and `ScanPipeline.cachedFace`
    /// (cache-gating) so the two never drift.
    static func manifestStampCompatible(
        _ manifest: Manifest,
        modelId: String,
        modelVersion: String
    ) -> Bool {
        guard let persistedModelId = manifest.modelId else {
            return true
        }
        let persistedModelVersion = manifest.modelVersion ?? ""
        if persistedModelId == modelId, persistedModelVersion == modelVersion {
            return true
        }
        let expected = ModelIdentity(modelId: modelId, modelVersion: modelVersion)
        let persisted = ModelIdentity(modelId: persistedModelId, modelVersion: persistedModelVersion)
        return expected == ModelIdentity.canonical && persisted.isCanonicalOrLegacyAlias
    }
}

private extension FaceMatcher {
    static func applyFeedback(
        _ feedback: FeedbackLabel,
        photoKey: String,
        subjectId: String,
        manifest: inout Manifest,
        store: inout ProfileStore
    ) throws {
        try checkManifestStamp(manifest, modelId: store.modelId, modelVersion: store.modelVersion)

        guard let bestFace = manifest[photoKey] else {
            throw FaceMatcherError.unknownPhoto(photoKey)
        }
        guard var profile = store[subjectId] else {
            throw FaceMatcherError.unknownSubject(subjectId)
        }

        var updatedFace = bestFace
        var result = updatedFace.subjectResults[subjectId] ?? SubjectResult(score: 0.0, bucket: .no)
        result.feedback = feedback
        updatedFace.subjectResults[subjectId] = result

        switch feedback {
        case .confirm:
            if !profile.confirmedPositives.contains(bestFace.embedding) {
                profile.confirmedPositives.append(bestFace.embedding)
            }
        case .reject:
            if !profile.negatives.contains(bestFace.embedding) {
                profile.negatives.append(bestFace.embedding)
            }
        }

        store[subjectId] = profile
        manifest[photoKey] = updatedFace
    }

    static func checkManifestStamp(
        _ manifest: Manifest,
        modelId: String,
        modelVersion: String
    ) throws {
        guard !manifestStampCompatible(manifest, modelId: modelId, modelVersion: modelVersion) else {
            return
        }
        throw ModelVersionMismatchError(
            persistedModelId: manifest.modelId ?? "",
            persistedModelVersion: manifest.modelVersion ?? "",
            expectedModelId: modelId,
            expectedModelVersion: modelVersion
        )
    }

    /// Compares two embeddings under `metric`. Both `.cosine` and `.dotProduct`
    /// share ONE guard: a length mismatch (or both-empty) is a "should be
    /// impossible" invariant violation — item 58's model-stamp gating is
    /// supposed to keep a manifest/profile pair on the same model, so this can
    /// only be reached by a real bug — and throws `FaceMatchDimensionError`
    /// rather than laundering it into a sentinel `0.0` (item 60). This is
    /// deliberately checked BEFORE either metric runs, so `.dotProduct` can't
    /// silently truncate-zip past a length mismatch either.
    static func similarity(_ lhs: [Float], _ rhs: [Float], metric: SimilarityMetric) throws -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            throw FaceMatchDimensionError(lhsCount: lhs.count, rhsCount: rhs.count)
        }

        switch metric {
        case .cosine:
            return cosineSimilarity(lhs, rhs)
        case .dotProduct:
            return dotProductSimilarity(lhs, rhs)
        }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0.0
        var lhsNorm: Float = 0.0
        var rhsNorm: Float = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }

        // A legitimate "no similarity" result — one or both vectors are the
        // zero vector, so cosine (which divides by the norms) is undefined.
        // This is NOT the dimension-mismatch invariant violation above: it's
        // reachable with perfectly well-formed, same-length embeddings, so it
        // stays a `0.0` return, never a throw.
        guard lhsNorm > 0.0, rhsNorm > 0.0 else {
            return 0.0
        }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }

    /// The dot product, without normalizing by the vectors' norms — a valid
    /// (higher-is-better) similarity ONLY when the model's embeddings are
    /// already unit-normalized upstream, unlike cosine which normalizes here.
    static func dotProductSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
        }
        return dot
    }
}
