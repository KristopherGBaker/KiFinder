import CryptoKit
import Foundation
@testable import KiFinder
import Testing

@Suite("Onboarding readiness gate")
@MainActor
struct OnboardingGateTests {
    /// Minimal fake network seam for the post-install flip test.
    final class FakeDownloadClient: ModelDownloadClient, @unchecked Sendable {
        let data: Data
        init(_ data: Data) {
            self.data = data
        }

        func download(
            from _: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> URL {
            onProgress(Int64(data.count), Int64(data.count))
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("gate-dl-\(UUID().uuidString)")
            try data.write(to: temp)
            return temp
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds an AppModel with an isolated store + injected model roots/env, using
    /// the sample engine so no real model is touched at construction.
    private func makeModel(
        environment: [String: String],
        appSupportRoot: URL,
        downloader: ModelDownloader? = nil
    ) throws -> AppModel {
        let store = try makeTempDir().appendingPathComponent("store.json")
        var env = environment
        env["KION_PROFILE_STORE"] = store.path
        return try AppModel(
            engine: SampleTriageEngine(),
            environment: env,
            modelLocations: ModelLocations(appSupportRoot: appSupportRoot),
            modelDownloader: downloader
        )
    }

    @Test("Missing model + not sample → needsOnboarding true")
    func missingModelNeedsOnboarding() throws {
        let model = try makeModel(environment: [:], appSupportRoot: makeTempDir())
        #expect(model.needsOnboarding == true)
    }

    @Test("Valid KION_MODEL_PATH → needsOnboarding false")
    func overrideSkipsOnboarding() throws {
        let override = try makeTempDir().appendingPathComponent("model.onnx")
        try Data([1, 2, 3]).write(to: override)
        let model = try makeModel(
            environment: ["KION_MODEL_PATH": override.path],
            appSupportRoot: makeTempDir()
        )
        #expect(model.needsOnboarding == false)
    }

    @Test("Successful install flips the gate to false without relaunch")
    func installFlipsGate() async throws {
        let appSupport = try makeTempDir()
        let data = Data((0 ..< 4096).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = try ModelAssetDescriptor(
            downloadURL: #require(URL(string: "https://example.com/fixture.onnx")),
            expectedByteCount: Int64(data.count),
            expectedSHA256: hash,
            fileName: "fixture.onnx"
        )
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        let downloader = ModelDownloader(
            descriptor: descriptor,
            client: FakeDownloadClient(data),
            installURL: installURL
        )
        let model = try makeModel(environment: [:], appSupportRoot: appSupport, downloader: downloader)

        #expect(model.needsOnboarding == true)

        model.modelDownloader.start()
        for _ in 0 ..< 600 {
            if case .installed = model.modelDownloader.state { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.modelDownloader.state == .installed)
        #expect(model.needsOnboarding == false)
    }

    @Test("KION_SAMPLE=1 bypasses the gate with an empty root and no model")
    func sampleModeBypasses() throws {
        // Empty app-support root, no KION_MODEL_PATH, idle downloader — sample mode
        // must short-circuit to false without consulting either.
        let model = try makeModel(environment: ["KION_SAMPLE": "1"], appSupportRoot: makeTempDir())
        #expect(model.needsOnboarding == false)
        #expect(model.modelDownloader.state == .idle)
    }
}
