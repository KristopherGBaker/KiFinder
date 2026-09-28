import CoreGraphics
import Foundation

/// The similarity metric a `FaceModelDescriptor` says its embeddings should be
/// compared with. Both cases are **higher-is-better**, so `FaceMatcher.bucket`'s
/// threshold semantics (`score >= threshold` ⇒ `.keep`) apply unchanged
/// regardless of which one a model uses.
///
/// `.euclidean` is deliberately NOT included yet: it is a *distance* (lower is
/// better), which would need `bucket`'s band comparisons inverted for that
/// metric — out of scope for this size-S seam declaration (§5 step 1). Add it
/// only alongside that inversion, in the unit that actually needs a
/// euclidean-scored model.
public enum SimilarityMetric: String, Codable, Equatable, Sendable {
    case cosine
    case dotProduct
}

/// The three tunables `FaceMatcher.bucket`/`adjustedScore` need to turn a raw
/// similarity score into keep/maybe/no. Declared here as part of the generic
/// model seam. The three enroll-seed call sites (the CLI's `main.swift`,
/// `EnrollmentModel.makeBundle`, and `AppModel.sampleProfile`) resolve this
/// through `FaceModelRegistry.standard.calibration(for:modelVersion:)` — keyed
/// on the model identity they stamp, not this type's `.arcface` case directly —
/// so a future second descriptor drives their seed calibration automatically
/// (item 69, §5 step 6).
public struct MatchCalibration: Codable, Equatable, Sendable {
    public var defaultThreshold: Float
    public var maybeMargin: Float
    public var negativeMargin: Float

    public init(defaultThreshold: Float, maybeMargin: Float, negativeMargin: Float) {
        self.defaultThreshold = defaultThreshold
        self.maybeMargin = maybeMargin
        self.negativeMargin = negativeMargin
    }
}

/// Describes a face-embedding model well enough to compare its embeddings
/// safely and calibrate a match against them: how big its vectors are, which
/// metric compares them, and the keep/maybe/no calibration tuned for it.
///
/// This is the generic seam a future `FaceEmbeddingProvider` conformer (Core
/// ML, Vision FeaturePrint, MLX, …) publishes so the rest of the engine can
/// work with "a face model" generically instead of assuming today's one ONNX
/// ArcFace model — declared now (§5 step 1) without wiring any new conformer.
///
/// `id`/`version` deliberately WRAP `ModelIdentity` (item 58's single source of
/// truth for the model stamp) rather than duplicating its role: `.arcface`
/// derives both from `ModelIdentity.canonical` so the two can never drift.
public struct FaceModelDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var embeddingDimension: Int
    public var similarityMetric: SimilarityMetric
    public var calibration: MatchCalibration

    public init(
        id: String,
        version: String,
        embeddingDimension: Int,
        similarityMetric: SimilarityMetric,
        calibration: MatchCalibration
    ) {
        self.id = id
        self.version = version
        self.embeddingDimension = embeddingDimension
        self.similarityMetric = similarityMetric
        self.calibration = calibration
    }

    /// The descriptor for today's (only) model: ONNX ArcFace ResNet100-8,
    /// 512-d embeddings compared by cosine similarity. `id`/`version` are
    /// DERIVED from `ModelIdentity.canonical` — never hand-typed here — so
    /// this descriptor can never disagree with the model stamp the rest of
    /// the engine persists and checks.
    public static let arcface = FaceModelDescriptor(
        id: ModelIdentity.canonical.modelId,
        version: ModelIdentity.canonical.modelVersion,
        embeddingDimension: 512,
        similarityMetric: .cosine,
        calibration: MatchCalibration(defaultThreshold: 0.45, maybeMargin: 0.20, negativeMargin: 0.0)
    )

    /// The descriptor for the second backend (§5 step 7, item 71): Apple Vision's
    /// built-in `VNGenerateImageFeaturePrintRequest` run on the SAME
    /// core-`FaceAligner`-produced 112×112 chip ArcFace embeds, yielding a 768-d
    /// Float32 feature print compared by cosine. Declared here (core), beside
    /// `.arcface`, so `FaceModelRegistry` can resolve it without importing the
    /// `KionVisionEmbedder` module — this descriptor is the data-only contract; the
    /// conforming provider lives in that opt-in target.
    ///
    /// `calibration` is a **placeholder, NOT tuned**: FeaturePrint cosine similarities
    /// run high and close together (prototype measurement: same-person ≈0.994,
    /// different-person ≈0.961 — a real but numerically small gap compared to
    /// ArcFace's), so `defaultThreshold`/`maybeMargin` here are a first guess picked
    /// to land roughly between those two observed values, not derived from any real
    /// calibration dataset. A future unit that collects genuine Vision-FeaturePrint
    /// match/no-match statistics should replace these three numbers; nothing else
    /// about this descriptor (id/version/dimension/metric) is expected to change.
    public static let visionFeaturePrint = FaceModelDescriptor(
        id: "vision-featureprint",
        version: "1",
        embeddingDimension: 768,
        similarityMetric: .cosine,
        calibration: MatchCalibration(defaultThreshold: 0.95, maybeMargin: 0.03, negativeMargin: 0.0)
    )

    /// The descriptor for the THIRD backend (§5 step 7, item 74a): AdaFace
    /// IR-18, a proper face-recognition model run via CoreML on the SAME
    /// core-`FaceAligner`-produced 112×112 chip the other two backends embed,
    /// yielding a 512-d, already-L2-normalized embedding compared by cosine.
    /// Declared here (core), beside `.arcface`/`.visionFeaturePrint`, so
    /// `FaceModelRegistry` can resolve it without importing the
    /// `KionCoreMLEmbedder` module — this descriptor is the data-only
    /// contract; the conforming provider lives in that opt-in target.
    ///
    /// `calibration` is a **placeholder, NOT tuned**: there is no labeled
    /// evaluation set yet, same honesty caveat as `.visionFeaturePrint`'s.
    /// A prototype measurement (rough resize, no proper 5-point alignment)
    /// measured cos(same)≈0.918 vs cos(diff)≈0.636/0.669 — a real ~0.25
    /// margin — so `0.40` is a starting point comfortably between those,
    /// expected to only improve once the real embedder's alignment is
    /// applied. A future unit that collects genuine AdaFace match/no-match
    /// statistics should replace these three numbers; nothing else about
    /// this descriptor (id/version/dimension/metric) is expected to change.
    public static let adaface = FaceModelDescriptor(
        id: "adaface-ir18",
        version: "1",
        embeddingDimension: 512,
        similarityMetric: .cosine,
        calibration: MatchCalibration(defaultThreshold: 0.40, maybeMargin: 0.08, negativeMargin: 0.0)
    )
}

/// A pluggable face-embedding backend, behind which any concrete model can
/// sit. Three conformers ship today: `KionONNXEmbedder.FaceEmbedder` (ONNX
/// ArcFace, 512-d cosine), `KionVisionEmbedder.VisionFeaturePrintEmbedder`
/// (Apple Vision's built-in feature print, 768-d cosine, item 71 — §5 step 7),
/// and `KionCoreMLEmbedder.AdaFaceEmbedder` (AdaFace IR-18 via CoreML, 512-d
/// cosine, item 74a — §5 step 7). All are opt-in modules that depend on
/// `KionEngine`, never the reverse.
public protocol FaceEmbeddingProvider: Sendable {
    /// Identifies this provider's model — its embedding dimension, similarity
    /// metric, and calibration — so a caller can compare/score without
    /// hardcoding assumptions about which model is behind the seam.
    var descriptor: FaceModelDescriptor { get }

    /// Embeds the single most prominent face (used for enrollment).
    func embedFace(_ image: CGImage) async throws -> DetectedFace?

    /// Embeds every detectable face in the image, each carrying its own
    /// bounding box (used for scanning, where the subject may not be the
    /// largest face).
    func embedAllFaces(_ image: CGImage) async throws -> [DetectedFace]

    /// Embeds an arbitrary user-drawn region as a face (manual face regions).
    func embedFace(in image: CGImage, regionBoundingBox: CGRect) async throws -> DetectedFace?
}

/// What's needed to download and install a `FaceEmbeddingProvider`'s backing
/// model file, verified by its checksum before use.
public struct ModelDownloadPlan: Sendable {
    public var url: URL
    public var expectedByteCount: Int
    public var expectedSHA256: String
    public var fileName: String

    public init(url: URL, expectedByteCount: Int, expectedSHA256: String, fileName: String) {
        self.url = url
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.fileName = fileName
    }
}

/// Knows how to provision a `FaceEmbeddingProvider` for one model: whether
/// it's already installed, what to download if not, and how to construct the
/// provider once it is. `KionVisionEmbedder.VisionFeaturePrintProvisioner`
/// (item 71, §5 step 7) is trivial — Vision needs no download, so its
/// `downloadPlan` is `nil`. `KionCoreMLEmbedder.AdaFaceProvisioner` (item 74a)
/// is the first conformer with a REAL, non-nil `downloadPlan` — the app-side
/// download→unzip→compile flow that drives it is a later step (item74b).
public protocol FaceModelProvisioner: Sendable {
    var descriptor: FaceModelDescriptor { get }
    var isInstalled: Bool { get }
    var downloadPlan: ModelDownloadPlan? { get }

    func makeProvider() throws -> any FaceEmbeddingProvider
}
