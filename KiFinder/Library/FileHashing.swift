import CryptoKit
import Foundation

/// Reusable, memory-bounded SHA-256 of a file's bytes, hashing in 1 MB chunks so the
/// whole file is never loaded into memory (mirrors `ModelIntegrity.verify`'s chunked
/// hashing, decoupled from any model descriptor). Returns the lowercase hex digest,
/// or `nil` when the file is missing/unreadable.
func sha256(ofFileAt url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    var hasher = SHA256()
    let chunkSize = 1 << 20 // 1 MB
    while true {
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: chunkSize)
        } catch {
            return nil
        }
        guard let chunk, !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
