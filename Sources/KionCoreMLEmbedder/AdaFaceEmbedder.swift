import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import KionEngine

/// The THIRD `FaceEmbeddingProvider` conformer (§5 step 7, item 74a): AdaFace
/// IR-18, a proper face-recognition model shipped as a CoreML `.mlpackage`.
/// Reuses the exact same core `FaceAligner` detect/align/quality-gate pipeline
/// `FaceEmbedder` (ONNX) and `VisionFeaturePrintEmbedder` use — the AdaFace
/// model was trained with the SAME ArcFace 112×112 5-point alignment, so
/// `.arcface`'s `AlignmentSpec` is reused here for chip geometry, not because
/// this is somehow the ArcFace model. The three backends differ only in the
/// embedding step.
///
/// An `actor`, mirroring `FaceEmbedder`'s concurrency contract: the CoreML
/// `MLModel` is loaded lazily and every access to it is serialized by actor
/// isolation — `MLModel` isn't `Sendable`, so a plain `struct` (like
/// `VisionFeaturePrintEmbedder`, which has no model handle to guard) won't do
/// here. Construction stays cheap and synchronous (no CoreML touched in
/// `init`); the model itself is loaded on first use, exactly like
/// `FaceEmbedder.ensureSession()`.
public actor AdaFaceEmbedder: FaceEmbeddingProvider {
    private let modelURL: URL
    /// The shared, model-agnostic alignment pipeline: Vision detection,
    /// landmark selection, and the 112×112 warp. AdaFace uses the SAME
    /// ArcFace alignment geometry, so `.arcface`'s spec is reused verbatim.
    private let aligner = FaceAligner(spec: .arcface)
    /// The lazily-loaded CoreML model, cached after first use. Plain
    /// actor-isolated storage: unlike `FaceEmbedder`'s ONNX handle (which a
    /// `nonisolated deinit` must reach to destroy the session), `MLModel` is
    /// ARC-managed and needs no manual teardown, so there is no `deinit` and
    /// hence no need for a `nonisolated(unsafe)` escape — actor isolation
    /// serializes every read/write on its own.
    private var model: MLModel?

    /// This provider's model identity: AdaFace IR-18, 512-d embeddings
    /// (already L2-normalized by the model graph) compared by cosine.
    /// `nonisolated` — it's a constant, so reading it never needs to hop onto
    /// the actor.
    public nonisolated var descriptor: FaceModelDescriptor { .adaface }

    /// Synchronous and `nonisolated` on purpose, mirroring `FaceEmbedder.init`:
    /// constructing an `AdaFaceEmbedder` never touches actor-isolated state or
    /// CoreML, so callers can create one without `await`. Resolves `modelURL`
    /// (must exist) else `envLookup("KION_ADAFACE_MODEL_PATH")` (a DISTINCT
    /// env var from the ONNX backend's `KION_MODEL_PATH` — they name different
    /// files), else throws `FaceEmbedderError.modelNotFound`.
    public init(
        modelURL: URL?,
        envLookup: @escaping (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) throws {
        let resolvedURL: URL?
        if let modelURL {
            resolvedURL = FileManager.default.fileExists(atPath: modelURL.path) ? modelURL : nil
        } else if let path = envLookup("KION_ADAFACE_MODEL_PATH"), FileManager.default.fileExists(atPath: path) {
            resolvedURL = URL(fileURLWithPath: path)
        } else {
            resolvedURL = nil
        }

        guard let resolvedURL else {
            throw FaceEmbedderError.modelNotFound
        }

        self.modelURL = resolvedURL
    }

    /// Forces CoreML model load/compile now, surfacing a diagnosable
    /// `FaceEmbedderError.runtime` for a corrupt/incompatible model instead of
    /// the silent `nil` every subsequent `embedFace` call would otherwise
    /// return. Mirrors `FaceEmbedder.warmUp()`.
    public func warmUp() async throws {
        _ = try ensureModel()
    }

    /// Embeds the single most prominent face (used for enrollment). Mirrors
    /// `FaceEmbedder.embedFace(_:)`: a failed alignment/embed resolves to
    /// `nil` via `try?`, never throws.
    public func embedFace(_ image: CGImage) async throws -> DetectedFace? {
        guard let aligned = try? aligner.alignedFace(in: image) else {
            return nil
        }
        return detectedFace(from: aligned)
    }

    /// Embeds every detectable face in the image, each carrying its own
    /// bounding box (used for scanning). Mirrors `FaceEmbedder.embedAllFaces(_:)`.
    public func embedAllFaces(_ image: CGImage) async throws -> [DetectedFace] {
        let aligned = (try? aligner.alignedFaces(in: image)) ?? []
        return aligned.compactMap { detectedFace(from: $0) }
    }

    /// Embeds an arbitrary user-drawn region as a face (manual face regions).
    /// `boundingBox` is a normalized, bottom-left-origin Vision rect — the
    /// same convention `FaceEmbedder.embedFace(in:regionBoundingBox:)` accepts.
    /// Mirrors that implementation's `DetectedFace`/`QualityMetrics`
    /// construction verbatim.
    public func embedFace(in image: CGImage, regionBoundingBox boundingBox: CGRect) async throws -> DetectedFace? {
        guard let aligned = try? aligner.alignedChip(in: image, regionBoundingBox: boundingBox),
              let embedding = embed(aligned)
        else {
            return nil
        }

        let area = Float(
            boundingBox.width * CGFloat(image.width)
                * boundingBox.height * CGFloat(image.height)
        )
        return DetectedFace(
            embedding: embedding,
            qualityMetrics: QualityMetrics(
                detectionScore: 1,
                boundingBoxArea: area,
                // Vision box is bottom-left; flip Y to the top-left convention.
                faceBoundingBox: NormalizedRect(
                    x: Float(boundingBox.minX),
                    y: Float(1 - boundingBox.maxY),
                    width: Float(boundingBox.width),
                    height: Float(boundingBox.height)
                )
            )
        )
    }

    private func detectedFace(from aligned: FaceAligner.AlignedFace) -> DetectedFace? {
        guard let embedding = embed(aligned.image) else {
            return nil
        }
        return DetectedFace(embedding: embedding, qualityMetrics: aligned.qualityMetrics)
    }

    /// Runs the aligned 112×112 chip through AdaFace and returns its 512-d,
    /// already-L2-normalized embedding. Preprocessing (scale to [-1,1]) is
    /// BAKED into the model graph — no manual normalization/channel-swap is
    /// applied here; the raw chip pixels are fed straight in as a 32BGRA
    /// pixel buffer, which CoreML's Image input extracts as BGR.
    private func embed(_ alignedImage: CGImage) -> FaceEmbedding? {
        guard let model = try? ensureModel() else {
            return nil
        }
        guard let pixelBuffer = Self.pixelBuffer112(alignedImage) else {
            return nil
        }
        guard let featureValue = try? MLDictionaryFeatureProvider(
            dictionary: ["face_image": MLFeatureValue(pixelBuffer: pixelBuffer)]
        ) else {
            return nil
        }
        guard let output = try? model.prediction(from: featureValue),
              let multiArray = output.featureValue(for: "embedding")?.multiArrayValue
        else {
            return nil
        }

        let values = (0..<multiArray.count).map { Float(truncating: multiArray[$0]) }
        return FaceEmbedding(values)
    }

    /// Lazily loads (or returns the cached) CoreML model. Race-free by
    /// construction: actor isolation serializes every call into this
    /// instance, so two tasks racing the first `embed()` call can't both
    /// reach `MLModel(contentsOf:)` — the second simply runs after the first
    /// has already stored `model`, mirroring `FaceEmbedder.ensureSession()`.
    ///
    /// Handles both a pre-compiled `.mlmodelc` (loaded directly) and an
    /// uncompiled `.mlpackage`/`.mlmodel` (compiled first via
    /// `MLModel.compileModel(at:)`), throwing `FaceEmbedderError.runtime` on
    /// any failure.
    private func ensureModel() throws -> MLModel {
        if let model {
            return model
        }

        let loaded: MLModel
        do {
            if modelURL.pathExtension == "mlmodelc" {
                loaded = try MLModel(contentsOf: modelURL)
            } else {
                let compiledURL = try MLModel.compileModel(at: modelURL)
                loaded = try MLModel(contentsOf: compiledURL)
            }
        } catch {
            throw FaceEmbedderError.runtime("AdaFace model load failed: \(error.localizedDescription)")
        }

        model = loaded
        return loaded
    }

    /// Converts a 112×112 aligned face chip into a 112×112 32BGRA
    /// `CVPixelBuffer` CoreML's `face_image` Image input expects. Drawing
    /// with `premultipliedFirst` + `byteOrder32Little` over
    /// `CGColorSpaceCreateDeviceRGB` yields BGRA byte order in memory —
    /// verified against the prototype run on the repo fixtures.
    private static func pixelBuffer112(_ image: CGImage) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer
        ) == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: 112,
            height: 112,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        return buffer
    }
}
