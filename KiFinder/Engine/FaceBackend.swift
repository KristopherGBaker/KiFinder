import Foundation
import KionCoreMLEmbedder
import KionEngine
import KionONNXEmbedder
import KionVisionEmbedder

/// The face-embedding backends the app can be pointed at (§5 pluggable-model step
/// 7, part 2a — item 72; AdaFace added item74b). Lives in the APP layer (not
/// `KionEngine`) because it is the seam that links the three opt-in
/// binary/model targets — `KionONNXEmbedder` (ArcFace, needs a downloaded
/// model), `KionVisionEmbedder` (built into the OS, no download), and
/// `KionCoreMLEmbedder` (AdaFace, needs a downloaded+compiled model) — to the
/// generic `FaceModelDescriptor`/`FaceEmbeddingProvider` vocabulary `KionEngine`
/// declares. The engine core stays free of all three binary dependencies; only
/// the app links them.
enum FaceBackend: String, CaseIterable, Sendable {
    case onnx
    case vision
    case coreml

    /// The generic model descriptor this backend's embeddings are compared under —
    /// `.arcface` (512-d cosine) for `onnx`, `.visionFeaturePrint` (768-d cosine)
    /// for `vision`, `.adaface` (512-d cosine) for `coreml`. Threading this
    /// everywhere (store stamp, calibration, engine) is what keeps the backends'
    /// embeddings from ever being compared against each other.
    var descriptor: FaceModelDescriptor {
        switch self {
        case .onnx: .arcface
        case .vision: .visionFeaturePrint
        case .coreml: .adaface
        }
    }

    /// User-facing label for the Settings picker.
    var displayName: String {
        switch self {
        case .onnx: String(localized: "ArcFace (ONNX)", comment: "Face-matching backend picker option: the default on-device ArcFace model.")
        case .vision: String(localized: "Vision FeaturePrint", comment: "Face-matching backend picker option: Apple's built-in Vision feature print, no download needed.")
        case .coreml: String(localized: "AdaFace (CoreML)", comment: "Face-matching backend picker option: the AdaFace CoreML model.")
        }
    }

    /// Whether this backend needs a model file downloaded/installed before it can
    /// run. `onnx` and `coreml` do (a one-time download); `vision` never does — it
    /// ships with the OS. Drives `AppModel.needsOnboarding`'s Vision early-return.
    var needsModelDownload: Bool {
        switch self {
        case .onnx: true
        case .vision: false
        case .coreml: true
        }
    }

    /// The onboarding/download asset for this backend, or `nil` when it needs no
    /// download (`vision`). Threads through `AppModel`'s `ModelDownloader` +
    /// `resolveModelURL` so each backend downloads/verifies/installs/resolves its
    /// OWN asset.
    var modelAsset: ModelAssetDescriptor? {
        switch self {
        case .onnx: .production
        case .vision: nil
        case .coreml: .adaface
        }
    }

    /// Constructs the concrete `FaceEmbeddingProvider` for this backend. `onnx`
    /// and `coreml` need the resolved model URL (may be `nil`, in which case the
    /// provider itself reports `modelNotFound`); `vision` ignores it — Vision
    /// needs no model file.
    func makeProvider(modelURL: URL?) throws -> any FaceEmbeddingProvider {
        switch self {
        case .onnx: try FaceEmbedder(modelURL: modelURL)
        case .vision: VisionFeaturePrintEmbedder()
        case .coreml: try AdaFaceEmbedder(modelURL: modelURL)
        }
    }
}
