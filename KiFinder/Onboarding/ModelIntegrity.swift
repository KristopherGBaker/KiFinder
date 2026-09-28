import CryptoKit
import Foundation

/// Outcome of verifying a downloaded file against a `ModelAssetDescriptor`.
enum ModelIntegrityResult: Equatable {
    /// Size and SHA-256 both match.
    case ok
    /// The file exists but its byte count differs from the expected count.
    case wrongSize
    /// The size matched but the streamed SHA-256 differs from the expected hash.
    case wrongHash
    /// The file is missing or could not be read.
    case unreadable
}

/// Pure integrity check: verifies `fileURL` against the descriptor's
/// `expectedByteCount` + `expectedSHA256`, hashing in 1 MB chunks so the whole
/// file is never loaded into memory. Size is checked first (cheap) before the hash.
func verify(fileURL: URL, against descriptor: ModelAssetDescriptor = .production) -> ModelIntegrityResult {
    let fileManager = FileManager.default
    guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
          let size = (attributes[.size] as? NSNumber)?.int64Value
    else { return .unreadable }

    guard size == descriptor.expectedByteCount else { return .wrongSize }

    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unreadable }
    defer { try? handle.close() }

    var hasher = SHA256()
    let chunkSize = 1 << 20 // 1 MB
    while true {
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: chunkSize)
        } catch {
            return .unreadable
        }
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }

    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return hex == descriptor.expectedSHA256.lowercased() ? .ok : .wrongHash
}
