import Foundation
@testable import KiFinder
import Testing

/// Proves the live engine resolves the model LAZILY (per use), so a first-run
/// onboarding install is picked up by the SAME engine instance with no relaunch
/// and no engine re-creation. The real enroll/scan (Vision + the 261 MB model)
/// stays an on-device check — here we assert at the resolution layer.
@Suite("Live engine model resolution")
@MainActor
struct LiveEngineModelResolutionTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEngine(appSupport: URL) throws -> LiveTriageEngine {
        try LiveTriageEngine(
            environment: [:], // KION_MODEL_PATH unset
            locations: ModelLocations(appSupportRoot: appSupport),
            storeURL: makeTempDir().appendingPathComponent("store.json"),
            subjectId: "Kris",
            modelId: "test-model",
            modelVersion: "test-version"
        )
    }

    /// Writes a file whose REPORTED size is exactly `byteCount` without actually
    /// writing that many bytes (a sparse/truncated file) — so the production
    /// 261 MB size check passes cheaply in a unit test.
    private func writeSizedFile(at url: URL, byteCount: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
    }

    @Test("Same engine re-resolves the model after install — no relaunch")
    func reResolvesAfterInstall() throws {
        let appSupport = try makeTempDir()
        let engine = try makeEngine(appSupport: appSupport)

        // 1. Empty roots, no override → nothing resolves (the first-run state, where
        //    the engine was built BEFORE onboarding downloaded the model).
        #expect(engine.modelURL == nil)

        // 2. Onboarding installs a correctly-sized model at the managed path AFTER
        //    the engine already exists.
        let managed = managedModelURL(appSupportRoot: appSupport)
        try writeSizedFile(at: managed, byteCount: ModelAssetDescriptor.production.expectedByteCount)

        // 3. The SAME instance now resolves it — lazy re-resolution, no relaunch.
        #expect(engine.modelURL == managed)
    }

    @Test("A wrong-size managed file is not resolved")
    func wrongSizeNotResolved() throws {
        let appSupport = try makeTempDir()
        let engine = try makeEngine(appSupport: appSupport)

        // A partial/wrong-size file at the managed path is treated as NOT installed.
        let managed = managedModelURL(appSupportRoot: appSupport)
        try writeSizedFile(at: managed, byteCount: ModelAssetDescriptor.production.expectedByteCount - 1)

        #expect(engine.modelURL == nil)
    }
}
