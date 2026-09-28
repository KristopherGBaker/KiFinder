import Foundation

/// The single, truthful model stamp both the app and the CLI resolve to — item 58.
///
/// Before this item the app hand-typed `"kion-local-enroll"/"1"` while the CLI
/// hand-typed `"arcfaceresnet100-8"/"1"` for the exact same ArcFace model, making
/// their stores mutually incompatible for no real reason. `ModelIdentity.canonical`
/// is now the ONE origin both consult; `FileProfileRepository.modelId/modelVersion`
/// and the CLI's `activeModelId/activeModelVersion` both resolve to it.
///
/// This is intentionally small and additive — a value type with two `String`
/// fields, NOT a protocol — because it's meant to grow into the full
/// `FaceModelDescriptor` in a later unit (see the pluggable-model plan) once
/// `similarityMetric`/`embeddingDimension` land. Adding fields to a struct is
/// source-compatible; introducing a protocol here would be premature.
public struct ModelIdentity: Equatable, Hashable, Sendable {
    public let modelId: String
    public let modelVersion: String

    public init(modelId: String, modelVersion: String) {
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    /// The one true stamp: ArcFace ResNet100-8, version "1". Chosen deliberately to
    /// match what the CLI already writes (and the real model filename), so the
    /// migration surface is only the app's legacy `kion-local-enroll` stores.
    public static let canonical = ModelIdentity(modelId: "arcfaceresnet100-8", modelVersion: "1")

    /// The CLOSED set of stamps known to be the exact same model as `canonical`,
    /// just labeled differently by an earlier version of the app or CLI. A
    /// store/manifest carrying one of these is NOT a mismatch against `canonical` —
    /// it's accepted and re-stamped to canonical in place (`ProfileStore.load`,
    /// `FaceMatcher.checkManifestStamp`/`ScanPipeline.cachedFace`). Deliberately
    /// closed: a stamp NOT in this set (a foreign model id, or an incompatible
    /// version) still throws `ModelVersionMismatchError` exactly as before this
    /// item — aliasing must never become a blanket "accept anything".
    public static let legacyAliases: Set<ModelIdentity> = [
        ModelIdentity(modelId: "kion-local-enroll", modelVersion: "1"),
        ModelIdentity(modelId: "arcfaceresnet100-8", modelVersion: "1"),
    ]

    /// Whether `self` is a stamp that should be treated as compatible with
    /// `canonical` — i.e. `self` IS canonical, or is one of its recognized legacy
    /// aliases. Used to gate migration/cache-reuse; never used to accept an
    /// arbitrary stamp.
    public var isCanonicalOrLegacyAlias: Bool {
        Self.legacyAliases.contains(self)
    }
}

/// Thrown by `ProfileStore.load` when a recognized legacy-alias store is
/// successfully decoded and re-stamped to canonical in memory, but the one-time
/// atomic rewrite back to disk fails (e.g. a read-only store directory).
///
/// Deliberately distinct from `ModelVersionMismatchError` — a genuine mismatch
/// means "this store is for a different model, don't touch it"; this error means
/// "this store IS compatible and was about to self-heal, but the write failed" —
/// callers must not treat the two the same way. Because the write uses an atomic
/// temp-file-then-rename, a failure here leaves the original file byte-intact: no
/// empty/partial store is ever produced.
public struct ProfileStoreMigrationPersistError: Error, Equatable, Sendable {
    public let url: URL
    public let underlyingDescription: String

    public init(url: URL, underlyingDescription: String) {
        self.url = url
        self.underlyingDescription = underlyingDescription
    }
}
