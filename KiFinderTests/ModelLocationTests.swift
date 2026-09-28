import Foundation
@testable import KiFinder
import Testing

@Suite("Model location resolver")
struct ModelLocationTests {
    /// A small fixture descriptor so tests never need the real 249 MB file.
    private static let fixture = ModelAssetDescriptor(
        downloadURL: URL(string: "https://example.com/fixture.onnx")!,
        expectedByteCount: 8,
        expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
        fileName: "fixture.onnx"
    )

    /// A fresh, isolated temp directory.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `byteCount` bytes to `url`, creating intermediate directories.
    private func writeFile(at url: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
    }

    @Test("KION_MODEL_PATH override wins and skips the size check")
    func overrideWins() throws {
        let appSupport = try makeTempDir()
        let overrideURL = try makeTempDir().appendingPathComponent("custom-model.onnx")
        // Deliberately the WRONG size — an explicit override is trusted as-is.
        try writeFile(at: overrideURL, byteCount: 3)

        let resolved = resolveModelURL(
            env: ["KION_MODEL_PATH": overrideURL.path],
            locations: ModelLocations(appSupportRoot: appSupport),
            descriptor: Self.fixture
        )

        #expect(resolved == URL(fileURLWithPath: overrideURL.path))
    }

    @Test("Managed location returned when present with the correct size")
    func managedCorrectSize() throws {
        let appSupport = try makeTempDir()
        let managed = managedModelURL(appSupportRoot: appSupport, fileName: Self.fixture.fileName)
        try writeFile(at: managed, byteCount: Int(Self.fixture.expectedByteCount))

        let resolved = resolveModelURL(
            env: [:],
            locations: ModelLocations(appSupportRoot: appSupport),
            descriptor: Self.fixture
        )

        #expect(resolved == managed)
    }

    @Test("Wrong-size managed file is treated as not installed (resolves nil)")
    func wrongSizeManagedSkipped() throws {
        let appSupport = try makeTempDir()
        let managed = managedModelURL(appSupportRoot: appSupport, fileName: Self.fixture.fileName)
        try writeFile(at: managed, byteCount: 4) // wrong size → treated as NOT installed

        let resolved = resolveModelURL(
            env: [:],
            locations: ModelLocations(appSupportRoot: appSupport),
            descriptor: Self.fixture
        )

        #expect(resolved == nil)
    }

    @Test("nil when no source exists")
    func nilWhenNothingExists() throws {
        let appSupport = try makeTempDir()

        let resolved = resolveModelURL(
            env: [:],
            locations: ModelLocations(appSupportRoot: appSupport),
            descriptor: Self.fixture
        )

        #expect(resolved == nil)
    }
}
