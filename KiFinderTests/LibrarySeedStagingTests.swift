import Foundation
@testable import KiFinder
import Testing

/// Item 76: the `KION_LIBRARY_SEED_DIR` app hook (`stageLibrarySeed`). On macOS 27 both
/// the app and the XCUITest runner are sandboxed to their own containers, so a library
/// fixture the app must READ and WRITE can't live in the runner's temp — the runner
/// stages it and the app copies it into `KION_LIBRARY_ROOT`. These pin the pure copy /
/// replace / no-op / throw behavior against temp dirs (no real sandbox needed).
@Suite("Library seed staging (KION_LIBRARY_SEED_DIR)")
struct LibrarySeedStagingTests {
    private let fm = FileManager.default

    private func tempDir(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-seed-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Authors a seed with a nested image + an index, mirroring `LibraryBrowseTests`.
    @discardableResult
    private func writeSeedTree(at seed: URL) throws -> (image: URL, index: URL, imageBytes: Data, indexBytes: Data) {
        let image = seed.appendingPathComponent("Kris/2021-07/IMG_0.png")
        try fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imageBytes = Data("PNG-fixture-bytes-\(UUID().uuidString)".utf8)
        try imageBytes.write(to: image)

        let index = seed.appendingPathComponent("library-index.json")
        let indexBytes = Data("[{\"sha256\":\"deadbeef\",\"path\":\"Kris/2021-07/IMG_0.png\"}]".utf8)
        try indexBytes.write(to: index)
        return (image, index, imageBytes, indexBytes)
    }

    // MARK: - Assertion 5: copies a nested tree into the destination byte-for-byte

    @Test("copies a nested tree + index into the destination, byte-identical to source")
    func copiesNestedTree() throws {
        let seed = tempDir("seed")
        let source = try writeSeedTree(at: seed)
        let dest = tempDir("root-parent").appendingPathComponent("root", isDirectory: true) // not yet created

        let env = ["KION_LIBRARY_SEED_DIR": seed.path, "KION_LIBRARY_ROOT": dest.path]
        let staged = try stageLibrarySeed(env: env)

        #expect(staged == dest)
        let copiedImage = dest.appendingPathComponent("Kris/2021-07/IMG_0.png")
        let copiedIndex = dest.appendingPathComponent("library-index.json")
        #expect(try Data(contentsOf: copiedImage) == source.imageBytes)
        #expect(try Data(contentsOf: copiedIndex) == source.indexBytes)
    }

    // MARK: - Assertion 6: replaces an existing root

    @Test("replaces an existing root (a stale file is gone; only the seed tree remains)")
    func replacesExistingRoot() throws {
        let seed = tempDir("seed")
        try writeSeedTree(at: seed)
        let dest = tempDir("root")
        // Pre-populate the destination with a stale file that must NOT survive.
        let stale = dest.appendingPathComponent("OLD.txt")
        try Data("stale".utf8).write(to: stale)

        let env = ["KION_LIBRARY_SEED_DIR": seed.path, "KION_LIBRARY_ROOT": dest.path]
        _ = try stageLibrarySeed(env: env)

        #expect(!fm.fileExists(atPath: stale.path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("Kris/2021-07/IMG_0.png").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("library-index.json").path))
    }

    // MARK: - Assertion 7: no-op without both keys (nothing on disk changes)

    @Test("returns nil and touches nothing when the seed key is unset (root set)")
    func noOpWithoutSeedKey() throws {
        let seed = tempDir("seed")
        try writeSeedTree(at: seed)
        let dest = tempDir("root")
        try Data("existing".utf8).write(to: dest.appendingPathComponent("KEEP.txt"))

        let beforeSeed = try listing(seed)
        let beforeDest = try listing(dest)

        let staged = try stageLibrarySeed(env: ["KION_LIBRARY_ROOT": dest.path])
        #expect(staged == nil)
        #expect(try listing(seed) == beforeSeed)
        #expect(try listing(dest) == beforeDest)
    }

    @Test("returns nil and touches nothing when the root key is unset (seed set)")
    func noOpWithoutRootKey() throws {
        let seed = tempDir("seed")
        try writeSeedTree(at: seed)
        let beforeSeed = try listing(seed)

        let staged = try stageLibrarySeed(env: ["KION_LIBRARY_SEED_DIR": seed.path])
        #expect(staged == nil)
        #expect(try listing(seed) == beforeSeed)
    }

    // MARK: - Assertion 8: throws when both keys are set but the seed is absent

    @Test("throws when both keys are set but the seed directory is absent")
    func throwsOnAbsentSeed() {
        let missingSeed = tempDir("seed").appendingPathComponent("does-not-exist", isDirectory: true)
        let dest = tempDir("root")
        let env = ["KION_LIBRARY_SEED_DIR": missingSeed.path, "KION_LIBRARY_ROOT": dest.path]
        #expect(throws: (any Error).self) {
            _ = try stageLibrarySeed(env: env)
        }
    }

    @Test("throws when the seed path points at a file, not a directory")
    func throwsWhenSeedIsAFile() throws {
        let seedFile = tempDir("seed").appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: seedFile)
        let dest = tempDir("root")
        let env = ["KION_LIBRARY_SEED_DIR": seedFile.path, "KION_LIBRARY_ROOT": dest.path]
        #expect(throws: (any Error).self) {
            _ = try stageLibrarySeed(env: env)
        }
    }

    /// A snapshot of every file under `dir`: root-relative path → file bytes (directories
    /// map to an empty value), sorted by path so before/after comparisons are
    /// order-independent AND catch a rewritten file, not just an added/removed one.
    private func listing(_ dir: URL) throws -> [String: Data] {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: Data] = [:]
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: dir.path, with: "")
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            out[relative] = isFile ? try Data(contentsOf: url) : Data()
        }
        return out
    }
}
