import Foundation

/// Errors surfaced by a face-embedding provider (e.g. `FaceEmbedder` in the
/// opt-in `KionONNXEmbedder` module). Lives in `KionEngine` core — not the
/// ONNX-specific module — because `FaceAligner` (core) throws
/// `.landmarkDetectionFailed` / `.imageConversionFailed`, and the app catches
/// this type without needing to link any concrete embedding backend.
public enum FaceEmbedderError: Error, Equatable, Sendable {
    case modelNotFound
    case imageConversionFailed
    case landmarkDetectionFailed
    case runtime(String)
}
