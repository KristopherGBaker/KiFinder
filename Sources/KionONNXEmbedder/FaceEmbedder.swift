import CoreGraphics
import CoreImage
import Darwin
import Foundation
import KionEngine
import KionORTShim
import Vision

/// Embeds detected faces to 512-d ArcFace vectors.
///
/// Concurrency contract (item 64): `FaceEmbedder` is an `actor`, so the compiler
/// serializes every call into it — two `embedFace`/`warmUp` calls on the SAME
/// instance (from any number of concurrent tasks) run one at a time, in FIFO-ish
/// actor-hop order, never overlapping. That closes the pre-item-64 documented
/// race in `ensureSession()`: the lazy ONNX Runtime session (`ortHandle`) used to
/// be guarded by a hand-rolled lock so two threads racing the first `embed()`
/// call couldn't both create (and leak) a session; actor isolation now makes
/// that guarantee for free, so the lock is gone. It is still safe — and
/// encouraged for throughput — to create MULTIPLE `FaceEmbedder` actors and use
/// each from its own task concurrently; the one piece of remaining
/// process-global mutable state is guarded separately:
///   - the CoreML execution provider's `TMPDIR` scratch dir is prepared exactly
///     ONCE per process (a run-once `static`), not per instance, since `setenv`
///     mutates process-global state and doing it per-embedder would itself race
///     across concurrently-constructed embedders.
public actor FaceEmbedder: FaceEmbeddingProvider {
    private let modelURL: URL
    private let runtimeURL: URL
    /// `nonisolated(unsafe)`: `KionORTSessionHandle` (a raw `UnsafeMutableRawPointer`)
    /// isn't `Sendable`, and `deinit` is always `nonisolated` on an actor — without
    /// this, the compiler can't let `deinit` read `ortHandle` to tear the session
    /// down. Safe by construction: every WRITE to `ortHandle` happens only inside
    /// this actor's own isolated methods (`ensureSession()`), so normal actor
    /// serialization is what actually protects it while the instance is alive;
    /// `deinit` itself only runs once the last reference is gone, when no
    /// concurrent access is possible at all.
    private nonisolated(unsafe) var ortHandle: KionORTSessionHandle?
    /// The shared, ONNX-free alignment pipeline (item 62): Vision detection,
    /// landmark selection, and the 112×112 warp, driven by `.arcface`'s spec.
    /// A different embedding model would compose `FaceAligner` with its own
    /// `AlignmentSpec` instead.
    private let aligner = FaceAligner(spec: .arcface)

    /// Today's (only) model this actor embeds: ONNX ArcFace ResNet100-8, 512-d,
    /// cosine-scored. `nonisolated` — it's a constant, so reading it never needs
    /// to hop onto the actor.
    public nonisolated var descriptor: FaceModelDescriptor { .arcface }

    /// Synchronous and `nonisolated` on purpose: constructing a `FaceEmbedder`
    /// never touches actor-isolated state or ONNX Runtime, so the many
    /// `try FaceEmbedder(modelURL:)` call sites throughout the app/CLI stay
    /// unchanged — no `await` needed to create one.
    public init(
        modelURL: URL?,
        envLookup: @escaping (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) throws {
        let resolvedURL: URL?
        if let modelURL {
            resolvedURL = FileManager.default.fileExists(atPath: modelURL.path) ? modelURL : nil
        } else if let path = envLookup("KION_MODEL_PATH"), FileManager.default.fileExists(atPath: path) {
            resolvedURL = URL(fileURLWithPath: path)
        } else {
            resolvedURL = nil
        }

        guard let resolvedURL else {
            throw FaceEmbedderError.modelNotFound
        }

        guard let runtimeURL = Bundle.module.url(
            forResource: "libonnxruntime.1.27.0",
            withExtension: "dylib"
        ) else {
            throw FaceEmbedderError.runtime("bundled ONNX Runtime dylib not found")
        }

        self.modelURL = resolvedURL
        self.runtimeURL = runtimeURL
    }

    deinit {
        if let ortHandle {
            KionORTDestroy(ortHandle)
        }
    }

    /// Forces ONNX Runtime session creation now, surfacing a diagnosable
    /// `FaceEmbedderError.runtime` for a corrupt/incompatible model instead of the
    /// silent `nil` every subsequent `embedFace` call would otherwise return.
    /// `init` stays lazy — constructing a `FaceEmbedder` never touches ONNX
    /// Runtime — so callers that want to fail fast (e.g. right after enrollment,
    /// before a long scan) can opt in by calling this explicitly. Actor-isolated:
    /// a `warmUp` racing concurrent `embedFace` calls on the same instance is
    /// serialized by the actor, not a hand-rolled lock.
    public func warmUp() async throws {
        _ = try ensureSession()
    }

    /// Embeds the single most prominent face (used for enrollment, where the
    /// reference photo is of one subject). `async throws` to satisfy
    /// `FaceEmbeddingProvider`; this actor's implementation never actually
    /// throws (a failed alignment/embed still resolves to `nil`, exactly as
    /// before item 64) — the `throws` is there so a future provider that CAN
    /// fail (e.g. a remote model call) has somewhere to put it.
    public func embedFace(_ image: CGImage) async throws -> DetectedFace? {
        guard let aligned = try? aligner.alignedFace(in: image) else {
            return nil
        }
        return detectedFace(from: aligned)
    }

    /// Embeds every detectable face in the image — not just the most prominent —
    /// each carrying its own bounding box. The caller picks the best-matching face
    /// (or lets the user choose), which is essential for group photos where the
    /// subject isn't the largest face.
    public func embedAllFaces(_ image: CGImage) async throws -> [DetectedFace] {
        let aligned = (try? aligner.alignedFaces(in: image)) ?? []
        return aligned.compactMap { detectedFace(from: $0) }
    }

    /// Embeds a batch, keeping only the images a face was detected in (the
    /// per-image `nil` — no throw — is swallowed here exactly as before, since
    /// `embedFace`'s `throws` is a never-fired protocol formality for this
    /// implementation).
    public func embedFaces(_ images: [CGImage]) async -> [DetectedFace] {
        var results: [DetectedFace] = []
        for image in images {
            if let face = try? await embedFace(image) {
                results.append(face)
            }
        }
        return results
    }

    /// Embeds an arbitrary region — a user-drawn box (item 19) — as a face, reusing
    /// the item-8 bounding-box→landmark fallback: derives 5 alignment points from the
    /// box alone, warps the 112×112 chip, and embeds it. `boundingBox` is a
    /// normalized, **bottom-left-origin** Vision rect (the same convention as
    /// `VNFaceObservation.boundingBox`). The returned `DetectedFace` carries a
    /// **top-left** `faceBoundingBox` (Y-flipped), matching every other detected
    /// face. Returns `nil` for a degenerate box (zero/negative size or no image
    /// overlap — the `boundingBoxLandmarks` nil-guard) or when embedding fails.
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

    /// Runs the aligned 112×112 chip through ArcFace and returns its 512-d embedding.
    private func embed(_ alignedImage: CGImage) -> FaceEmbedding? {
        guard let input = try? aligner.rgbInputTensor(from112x112: alignedImage) else {
            return nil
        }
        guard let ortHandle = try? ensureSession() else {
            return nil
        }

        var output = [Float](repeating: 0, count: 512)
        var error = [CChar](repeating: 0, count: 4096)
        let inputCount = input.count
        let outputCount = output.count
        let status = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                KionORTRun(
                    ortHandle,
                    inputBuffer.baseAddress,
                    inputCount,
                    outputBuffer.baseAddress,
                    outputCount,
                    &error,
                    error.count
                )
            }
        }

        guard status == 0 else {
            return nil
        }
        return FaceEmbedding(output)
    }

    /// Lazily creates (or returns the cached) ONNX Runtime session. Race-free by
    /// construction (item 64): actor isolation serializes every call into this
    /// instance, so two tasks racing the first `embed()` call can't both reach
    /// `KionORTCreate` — the second simply runs after the first has already
    /// stored `ortHandle`. This used to be guarded by a hand-rolled
    /// `OSAllocatedUnfairLock`; the actor conversion makes that lock redundant.
    private func ensureSession() throws -> KionORTSessionHandle {
        if let ortHandle {
            return ortHandle
        }

        let handle = try Self.createSession(runtimeURL: runtimeURL, modelURL: modelURL)
        ortHandle = handle
        return handle
    }

    /// The actual `KionORTCreate` call, factored into a `static` (non-isolated)
    /// function: the C shim's out-parameter pattern mutates a local `var handle`
    /// through nested `withCString` closures, which the compiler's data-race
    /// checker analyzes as a "region" — doing that inside an ACTOR-isolated method
    /// directly trips a false-positive "sending risks data race" diagnostic on the
    /// local var, even though this is plain synchronous, single-threaded code. A
    /// `static` function has no actor isolation to reconcile with those nested
    /// closures, so the exact same logic here has no such region to conflict with;
    /// `ensureSession()` just calls this and assigns the returned handle.
    private static func createSession(runtimeURL: URL, modelURL: URL) throws -> KionORTSessionHandle {
        try prepareCoreMLTemporaryDirectory()

        var handle: KionORTSessionHandle?
        var error = [CChar](repeating: 0, count: 4096)
        let status = runtimeURL.path.withCString { runtimePath in
            modelURL.path.withCString { modelPath in
                KionORTCreate(runtimePath, modelPath, &handle, &error, error.count)
            }
        }
        guard status == 0, let handle else {
            throw FaceEmbedderError.runtime(Self.string(fromCStringBuffer: error))
        }
        return handle
    }
}

extension FaceEmbedder {
    static func string(fromCStringBuffer buffer: [CChar]) -> String {
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return buffer[..<end].withUnsafeBufferPointer {
            String(decoding: UnsafeRawBufferPointer($0), as: UTF8.self)
        }
    }

    /// Sandbox-safe scratch dir for the ONNX Runtime CoreML execution provider (which
    /// compiles the model into `TMPDIR`). It MUST live inside the process's temporary
    /// directory — `NSTemporaryDirectory()` is the app's sandbox-container tmp when App
    /// Sandbox is enabled — NOT a hardcoded `/private/tmp/...`, which the sandbox blocks:
    /// under the sandbox, writing outside the container makes CoreML session creation fail,
    /// so every embed returns nil (no faces detected, no photos scored).
    static var coreMLTemporaryDirectoryURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kifinder-coreml", isDirectory: true)
    }

    /// Runs the directory-create + `setenv("TMPDIR", ...)` exactly ONCE per
    /// process. `setenv` mutates process-global state (`TMPDIR` isn't
    /// per-instance or per-thread), so doing it inside `ensureSession()` on every
    /// embedder's first `embed()` call would race across concurrently-constructed
    /// `FaceEmbedder`s. `static let` initializers run under Swift's one-time
    /// guarantee, so this is race-free with no additional locking, and — since a
    /// `static let` only evaluates on first access — it stays out of the hot path
    /// for every session after the process-wide first.
    private static let coreMLTemporaryDirectoryPreparation: Result<Void, Error> = Result {
        let url = coreMLTemporaryDirectoryURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("TMPDIR", url.path + "/", 1)
    }

    static func prepareCoreMLTemporaryDirectory() throws {
        try coreMLTemporaryDirectoryPreparation.get()
    }
}
