import CoreGraphics
import Foundation
import KionEngine
import Vision

/// The second `FaceEmbeddingProvider` conformer (§5 step 7, item 71): Apple
/// Vision's built-in `VNGenerateImageFeaturePrintRequest`, needing no model
/// file/download — it ships with the OS. Reuses the exact same core
/// `FaceAligner` detect/align/quality-gate pipeline `FaceEmbedder` (the ONNX
/// backend) uses, so the two backends differ ONLY in the embedding step: this
/// one feature-prints the aligned 112×112 chip instead of running it through
/// ONNX Runtime.
///
/// A plain `struct`, not an `actor`: `VNGenerateImageFeaturePrintRequest` is
/// stateless (no session/handle to serialize access to, unlike ONNX Runtime's
/// `ortHandle`), so there is nothing here that needs actor isolation. Every
/// stored property is an immutable value, which is what makes this safely
/// `Sendable` — the compiler verifies it for free.
public struct VisionFeaturePrintEmbedder: FaceEmbeddingProvider {
    /// The number of Float32 values `VNFeaturePrintObservation` produces for an
    /// image feature print — matches `FaceModelDescriptor.visionFeaturePrint`'s
    /// `embeddingDimension`. Checked defensively in `featurePrint(_:)` rather
    /// than assumed, since a future OS could change it.
    private static let expectedElementCount = 768

    /// Reuses the SAME core alignment pipeline (Vision detection, landmark
    /// selection, the 112×112 warp, and quality-gate metrics) as the ONNX
    /// backend — driven by the ArcFace spec purely for its chip geometry, not
    /// because this embedder is ArcFace-specific. A different chip size would
    /// work just as well; `.arcface`'s 112×112 square is simply a convenient,
    /// already-tested crop to feature-print.
    private let aligner = FaceAligner(spec: .arcface)

    /// This provider's model identity: 768-d Vision feature prints, compared
    /// by cosine. `nonisolated` isn't needed here (no actor to hop off of) —
    /// present anyway to satisfy `FaceEmbeddingProvider`'s `descriptor`
    /// requirement.
    public var descriptor: FaceModelDescriptor { .visionFeaturePrint }

    public init() {}

    /// Embeds the single most prominent face (used for enrollment). Mirrors
    /// `FaceEmbedder.embedFace(_:)`: a failed/undetected alignment (Vision
    /// finds no face) resolves to `nil` via `try?`, exactly as the ONNX
    /// backend does — only the feature-print step itself can genuinely throw.
    public func embedFace(_ image: CGImage) async throws -> DetectedFace? {
        guard let aligned = try? aligner.alignedFace(in: image) else {
            return nil
        }
        let values = try featurePrint(aligned.image)
        return DetectedFace(embedding: FaceEmbedding(values), qualityMetrics: aligned.qualityMetrics)
    }

    /// Embeds every detectable face in the image, each carrying its own
    /// bounding box (used for scanning). Mirrors
    /// `FaceEmbedder.embedAllFaces(_:)`: no faces detected yields `[]`.
    public func embedAllFaces(_ image: CGImage) async throws -> [DetectedFace] {
        let aligned = (try? aligner.alignedFaces(in: image)) ?? []
        return try aligned.map { face in
            let values = try featurePrint(face.image)
            return DetectedFace(embedding: FaceEmbedding(values), qualityMetrics: face.qualityMetrics)
        }
    }

    /// Embeds an arbitrary user-drawn region as a face (manual face regions).
    /// `boundingBox` is a normalized, bottom-left-origin Vision rect — the same
    /// convention `FaceEmbedder.embedFace(in:regionBoundingBox:)` accepts.
    public func embedFace(in image: CGImage, regionBoundingBox boundingBox: CGRect) async throws -> DetectedFace? {
        guard let chip = try? aligner.alignedChip(in: image, regionBoundingBox: boundingBox) else {
            return nil
        }
        let values = try featurePrint(chip)

        let area = Float(
            boundingBox.width * CGFloat(image.width)
                * boundingBox.height * CGFloat(image.height)
        )
        return DetectedFace(
            embedding: FaceEmbedding(values),
            qualityMetrics: QualityMetrics(
                detectionScore: 1,
                boundingBoxArea: area,
                // Vision box is bottom-left; flip Y to the top-left convention,
                // mirroring FaceEmbedder's own region-embed quality metrics.
                faceBoundingBox: NormalizedRect(
                    x: Float(boundingBox.minX),
                    y: Float(1 - boundingBox.maxY),
                    width: Float(boundingBox.width),
                    height: Float(boundingBox.height)
                )
            )
        )
    }

    /// Runs an aligned chip through `VNGenerateImageFeaturePrintRequest` and
    /// returns its raw 768-d Float32 values. Throws the REUSED core
    /// `FaceEmbedderError.runtime` (not a new error type) on any failure, for
    /// the same error discipline `FaceEmbedder` follows.
    private func featurePrint(_ chip: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: chip, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.runtime("Vision produced no feature print observation")
        }
        guard observation.elementType == .float else {
            throw FaceEmbedderError.runtime(
                "unexpected VNFeaturePrintObservation elementType: \(observation.elementType)"
            )
        }

        let elementCount = observation.elementCount
        guard elementCount == Self.expectedElementCount else {
            throw FaceEmbedderError.runtime(
                "unexpected VNFeaturePrintObservation elementCount: \(elementCount) (expected \(Self.expectedElementCount))"
            )
        }

        var values = [Float](repeating: 0, count: elementCount)
        values.withUnsafeMutableBytes { buffer in
            observation.data.copyBytes(to: buffer)
        }
        return values
    }
}

/// The first real `FaceModelProvisioner` conformer (the protocol was
/// declaration-only since item 60): Vision FeaturePrint needs no download —
/// it's built into the OS Vision framework — so `isInstalled` is always `true`
/// and `downloadPlan` is always `nil`.
public struct VisionFeaturePrintProvisioner: FaceModelProvisioner {
    public var descriptor: FaceModelDescriptor { .visionFeaturePrint }
    public var isInstalled: Bool { true }
    public var downloadPlan: ModelDownloadPlan? { nil }

    public init() {}

    public func makeProvider() throws -> any FaceEmbeddingProvider {
        VisionFeaturePrintEmbedder()
    }
}
