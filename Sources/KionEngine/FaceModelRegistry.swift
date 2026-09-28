import Foundation

/// Resolves a `FaceModelDescriptor` from a persisted `(modelId, modelVersion)` stamp —
/// the seam that lets scoring's similarity metric and enroll-seed calibration follow
/// whichever model a `ProfileBundle`/store is actually stamped with, instead of the
/// engine silently assuming today's one ArcFace model (§5 pluggable-model step 6).
///
/// A value type, no mutable global state: `.standard` is a `let` constant, and every
/// method is a pure lookup over the `descriptors` this instance was built with. A
/// second descriptor is added only by constructing a new registry (as the tests below
/// do), never by mutating `.standard`.
public struct FaceModelRegistry: Sendable {
    private let descriptors: [FaceModelDescriptor]

    public init(_ descriptors: [FaceModelDescriptor] = [.arcface]) {
        self.descriptors = descriptors
    }

    /// The descriptor whose identity matches this persisted stamp, or `nil` if the
    /// stamp names a model this registry doesn't know. A stamp matches a descriptor
    /// when `(modelId, modelVersion)` equals the descriptor's `(id, version)`, OR the
    /// descriptor's identity is `ModelIdentity.canonical` and the queried stamp
    /// `isCanonicalOrLegacyAlias` (item 58) — so a legacy "kion-local-enroll" store
    /// still resolves to the ArcFace descriptor. This rule is general (keyed off
    /// `ModelIdentity.canonical`), not arcface-special-cased by name, so it would
    /// apply identically to any future descriptor built from a canonical identity.
    public func descriptor(for modelId: String, modelVersion: String) -> FaceModelDescriptor? {
        let stamp = ModelIdentity(modelId: modelId, modelVersion: modelVersion)
        return descriptors.first { descriptor in
            let identity = ModelIdentity(modelId: descriptor.id, modelVersion: descriptor.version)
            if identity == stamp {
                return true
            }
            return identity == ModelIdentity.canonical && stamp.isCanonicalOrLegacyAlias
        }
    }

    /// The similarity metric for a persisted profile's model. Falls back to `.cosine`
    /// ONLY for a stamp this registry doesn't recognize — which the model-stamp gating
    /// (`FaceMatcher.checkManifestStamp` / `ProfileStore.load`) already rejects before
    /// any scoring runs, so in every shipped path this resolves a real descriptor. The
    /// fallback keeps a pre-item-58 nil-stamp path scoring as it always did (cosine).
    public func metric(for profile: ProfileBundle) -> SimilarityMetric {
        descriptor(for: profile.modelId, modelVersion: profile.modelVersion)?.similarityMetric ?? .cosine
    }

    /// The calibration to seed a NEW profile with for a given model stamp; falls back
    /// to `.arcface`'s calibration for an unrecognized stamp (the seed sites always
    /// seed for a known model, so the fallback is defensive).
    public func calibration(for modelId: String, modelVersion: String) -> MatchCalibration {
        descriptor(for: modelId, modelVersion: modelVersion)?.calibration ?? FaceModelDescriptor.arcface.calibration
    }

    /// The production registry: every model the engine can resolve a persisted
    /// stamp against. `.arcface`'s resolution (canonical identity + legacy
    /// aliases) is unaffected by `.visionFeaturePrint`/`.adaface`'s presence —
    /// resolution is by stamp identity, so adding another descriptor here does
    /// not change what an arcface- or vision-stamped profile resolves to
    /// (item 71, item 74a — §5 step 7).
    public static let standard = FaceModelRegistry([.arcface, .visionFeaturePrint, .adaface])
}
