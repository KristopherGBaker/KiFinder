import CryptoKit
import Foundation
@testable import KiFinder
import Testing

@Suite("Model integrity verification")
struct ModelIntegrityTests {
    /// Builds a fixture file at test time and a descriptor with its REAL size + sha.
    private func makeFixture(bytes: [UInt8]) throws -> (url: URL, descriptor: ModelAssetDescriptor) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.onnx")
        let data = Data(bytes)
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = ModelAssetDescriptor(
            downloadURL: URL(string: "https://example.com/fixture.onnx")!,
            expectedByteCount: Int64(data.count),
            expectedSHA256: hash,
            fileName: "fixture.onnx"
        )
        return (url, descriptor)
    }

    @Test("Matching size and hash → ok")
    func matchingIsOk() throws {
        // Multi-chunk content to exercise the streaming reader (> 1 MB chunk size).
        let bytes = (0 ..< (3 * (1 << 20) + 17)).map { UInt8($0 % 251) }
        let fixture = try makeFixture(bytes: bytes)

        #expect(verify(fileURL: fixture.url, against: fixture.descriptor) == .ok)
    }

    @Test("One tampered byte → wrongHash")
    func tamperedIsWrongHash() throws {
        let fixture = try makeFixture(bytes: Array(repeating: 0x10, count: 4096))
        // Flip one byte in place — same length, different content.
        var data = try Data(contentsOf: fixture.url)
        data[100] = data[100] &+ 1
        try data.write(to: fixture.url)

        #expect(verify(fileURL: fixture.url, against: fixture.descriptor) == .wrongHash)
    }

    @Test("Truncated file → wrongSize")
    func truncatedIsWrongSize() throws {
        let fixture = try makeFixture(bytes: Array(repeating: 0x20, count: 4096))
        // Truncate to fewer bytes than the descriptor expects.
        try Data(repeating: 0x20, count: 2048).write(to: fixture.url)

        #expect(verify(fileURL: fixture.url, against: fixture.descriptor) == .wrongSize)
    }

    @Test("Missing file → unreadable")
    func missingIsUnreadable() throws {
        let fixture = try makeFixture(bytes: [1, 2, 3, 4])
        try FileManager.default.removeItem(at: fixture.url)

        #expect(verify(fileURL: fixture.url, against: fixture.descriptor) == .unreadable)
    }
}
