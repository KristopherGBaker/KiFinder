import CryptoKit
import Foundation
import KionCoreMLEmbedder
import KionEngine
@testable import KiFinder
import Testing

/// Item 74b coverage: the AdaFace (CoreML) app-selectable backend — the third
/// `FaceBackend`, its unzip+compile install strategy, backend-aware model
/// resolution, and end-to-end `AppModel` wiring. Mirrors
/// `AppModelBackendSelectionTests`'s fixtures/conventions (item 72) and
/// `ModelDownloaderTests`'s injected-seam patterns (gate/cancel determinism).
@Suite("AdaFace (CoreML) app-selectable backend (item 74b)")
@MainActor
struct AppModelCoreMLBackendTests {
    // MARK: - Fixtures

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "kion-coreml-backend-tests-\(UUID().uuidString)")!
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-coreml-backend-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueStore() throws -> URL {
        try makeTempDir().appendingPathComponent("store.json")
    }

    /// A fake network seam that always succeeds, yielding the given bytes as a
    /// freshly-written temp file — mirrors `ModelDownloaderTests.FakeDownloadClient`'s
    /// `.yield` case, trimmed to what this suite needs.
    final class SingleYieldClient: ModelDownloadClient, @unchecked Sendable {
        private let data: Data
        init(_ data: Data) {
            self.data = data
        }

        func download(
            from _: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> URL {
            onProgress(Int64(data.count), Int64(data.count))
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("coreml-dl-\(UUID().uuidString)")
            try data.write(to: temp)
            return temp
        }
    }

    /// A fake network seam that copies a REAL file from disk (the provisioned
    /// AdaFace zip) into a fresh temp — used only by the model-gated install test.
    final class FileCopyClient: ModelDownloadClient, @unchecked Sendable {
        private let sourcePath: String
        init(sourcePath: String) {
            self.sourcePath = sourcePath
        }

        func download(
            from _: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> URL {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("coreml-dl-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(atPath: sourcePath, toPath: temp.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: temp.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            onProgress(size, size)
            return temp
        }
    }

    /// Coordinates an injected `installFile` seam with the test: signals when
    /// install begins and blocks it until released, so the test can cancel
    /// mid-install. Mirrors `ModelDownloaderTests.VerifyGate` exactly, retargeted
    /// at the install seam.
    actor InstallGate {
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var started = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var released = false

        func enterAndWait() async {
            started = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private struct InjectedInstallError: Error, LocalizedError {
        var errorDescription: String? { "injected install failure" }
    }

    /// A small fixture descriptor with `.adaface`'s `installKind`/`installedName`
    /// shape but a SHA/size matching the given small `data` — lets 4c/4d exercise
    /// the unzip-install ROUTING (state machine, cleanup) without a real zip.
    private func fixtureCoreMLDescriptor(for data: Data) -> ModelAssetDescriptor {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelAssetDescriptor(
            downloadURL: URL(string: "https://example.com/fixture.mlpackage.zip")!,
            expectedByteCount: Int64(data.count),
            expectedSHA256: hash,
            fileName: "fixture.mlpackage.zip",
            installedName: "fixture.mlmodelc",
            installKind: .unzipAndCompileMLModel
        )
    }

    /// Polls until the downloader reaches a terminal (installed/failed) state.
    private func waitForTerminal(_ downloader: ModelDownloader) async {
        await waitUntil {
            switch downloader.state {
            case .installed, .failed: true
            default: false
            }
        }
    }

    /// Polls `condition` on the main actor until true or a timeout elapses.
    private func waitUntil(timeoutMs: Int = 6000, _ condition: @MainActor () -> Bool) async {
        var elapsed = 0
        while !condition(), elapsed < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 10
        }
    }

    /// Resolves `KION_ADAFACE_ZIP_PATH` ONLY — no fallback to a bundled/managed
    /// path — so the install test deterministically skips unless it's exported.
    /// `nonisolated`: `.enabled(if:)` evaluates the trait from a `@Sendable`
    /// closure outside the suite's `@MainActor` isolation, so this must be
    /// reachable off-actor (it only reads the environment + filesystem).
    nonisolated static var adafaceZipAvailable: Bool {
        guard let path = ProcessInfo.processInfo.environment["KION_ADAFACE_ZIP_PATH"], !path.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Assertion 3: FaceBackend.coreml

    @Test("FaceBackend.coreml resolves to the AdaFace descriptor/asset and constructs a concrete AdaFaceEmbedder")
    func coreMLBackendShape() throws {
        #expect(FaceBackend.coreml.descriptor == .adaface)
        #expect(FaceBackend.coreml.needsModelDownload == true)
        #expect(!FaceBackend.coreml.displayName.isEmpty)
        #expect(FaceBackend.coreml.modelAsset == .adaface)

        // A file that merely EXISTS is enough for `AdaFaceEmbedder.init` (it
        // defers CoreML model load/compile to first use), so no real model is
        // needed to prove the concrete type it constructs.
        let dummyModel = try makeTempDir().appendingPathComponent("dummy.mlmodelc")
        try Data([0x00, 0x01]).write(to: dummyModel)
        let provider = try FaceBackend.coreml.makeProvider(modelURL: dummyModel)
        #expect(provider is AdaFaceEmbedder)

        #expect(FaceBackend.onnx.modelAsset == .production)
        #expect(FaceBackend.vision.modelAsset == nil)
    }

    // MARK: - Assertion 4: install strategy builds a loadable model (model-gated)

    @Test(
        "AdaFace install (real zip) reaches .installed and yields a loadable .mlmodelc",
        .enabled(if: AppModelCoreMLBackendTests.adafaceZipAvailable)
    )
    func adafaceInstallBuildsLoadableModel() async throws {
        let zipPath = try #require(ProcessInfo.processInfo.environment["KION_ADAFACE_ZIP_PATH"])
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: ModelAssetDescriptor.adaface.installedName)
        let downloader = ModelDownloader(
            descriptor: .adaface,
            client: FileCopyClient(sourcePath: zipPath),
            installURL: installURL
        )

        downloader.start()
        await waitForTerminal(downloader)

        #expect(downloader.state == .installed)
        #expect(FileManager.default.fileExists(atPath: installURL.path))

        // A loadable `.mlmodelc`: warm-up forces CoreML to actually load/compile
        // it, surfacing a diagnosable error instead of a silent nil if it isn't.
        let embedder = try AdaFaceEmbedder(modelURL: installURL)
        try await embedder.warmUp()
    }

    // MARK: - Assertion 4b: wrong-SHA → no install

    @Test("A zip whose SHA mismatches .adaface's → .failed, nothing at installURL")
    func wrongShaNeverInstalls() async throws {
        // Exact expected SIZE, wrong content → size check passes, hash check
        // fails — proves this is the hash gate, not a size mismatch.
        let bogusData = Data(repeating: 0, count: Int(ModelAssetDescriptor.adaface.expectedByteCount))
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: ModelAssetDescriptor.adaface.installedName)
        let downloader = ModelDownloader(descriptor: .adaface, client: SingleYieldClient(bogusData), installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)

        guard case .failed = downloader.state else {
            Issue.record("Expected .failed, got \(downloader.state)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
    }

    // MARK: - Assertion 4c: install-phase failure → .failed, no partial

    @Test("Injected installFile failure after a successful verify → .failed with a message, no partial at installURL")
    func installSeamFailureRoutesToFailed() async throws {
        let data = Data(repeating: 7, count: 256)
        let descriptor = fixtureCoreMLDescriptor(for: data)
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.installedName)
        let downloader = ModelDownloader(
            descriptor: descriptor,
            client: SingleYieldClient(data),
            installURL: installURL,
            install: { _, _, _ in .failure(InjectedInstallError()) }
        )

        downloader.start()
        await waitForTerminal(downloader)

        guard case let .failed(message) = downloader.state else {
            Issue.record("Expected .failed, got \(downloader.state)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
    }

    // MARK: - Assertion 4d: cancel during install cleans up

    @Test("Cancel during install (injected suspending seam) cleans up: state .idle, no artifact at installURL")
    func cancelDuringInstallCleansUp() async throws {
        let data = Data(repeating: 3, count: 256)
        let descriptor = fixtureCoreMLDescriptor(for: data)
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.installedName)
        let gate = InstallGate()
        // The seam returns success AFTER release — so WITHOUT the post-install
        // cancellation check, this would (wrongly) proceed to `.installed`.
        let downloader = ModelDownloader(
            descriptor: descriptor,
            client: SingleYieldClient(data),
            installURL: installURL,
            install: { _, _, _ in
                await gate.enterAndWait()
                return .success(())
            }
        )

        downloader.start()
        await gate.waitUntilStarted()

        downloader.cancel()
        await gate.release()

        await waitUntil { downloader.state == .idle }

        #expect(downloader.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
        // No leftover work dir from a REAL unzip/compile install (this test uses
        // the injected seam, which never touches the filesystem, so none should
        // exist — guards against a future default-install refactor leaking one).
        let tmpContents = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        #expect(!tmpContents.contains { $0.hasPrefix("kion-adaface-install-") })
    }

    // MARK: - Assertion 5: per-backend resolve

    @Test("resolveModelURL: .adaface resolves a DIRECTORY (no size check); .production stays file+exact-size")
    func perBackendResolve() throws {
        let appSupport = try makeTempDir()
        let locations = ModelLocations(appSupportRoot: appSupport)
        let managedAdaFace = managedModelURL(appSupportRoot: appSupport, fileName: ModelAssetDescriptor.adaface.installedName)

        // Absent → nil.
        #expect(resolveModelURL(env: [:], locations: locations, descriptor: .adaface) == nil)

        // A DIRECTORY at the installed name → resolved, no size check needed.
        // Compare `.path` (not URL `==`): `URL.appendingPathComponent(_:)` stats the
        // filesystem and appends a trailing slash once the directory EXISTS, so the
        // resolver's URL (built after createDirectory) carries a slash the pre-created
        // `managedAdaFace` lacks — same path, cosmetic-only difference.
        try FileManager.default.createDirectory(at: managedAdaFace, withIntermediateDirectories: true)
        #expect(resolveModelURL(env: [:], locations: locations, descriptor: .adaface)?.path == managedAdaFace.path)

        // `.production` (ONNX) resolution is UNCHANGED: file + exact size.
        let managedOnnx = managedModelURL(appSupportRoot: appSupport, fileName: ModelAssetDescriptor.production.installedName)
        try FileManager.default.createDirectory(at: managedOnnx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: managedOnnx) // wrong size
        #expect(resolveModelURL(env: [:], locations: locations, descriptor: .production) == nil)
    }

    // MARK: - Assertion 6: AppModel KION_BACKEND=coreml

    @Test("KION_BACKEND=coreml selects AdaFace end-to-end: session, seed stamp, installURL, needsOnboarding")
    func coreMLSelectedEndToEnd() throws {
        // Pure: the per-backend store filename convention (no live AppModel
        // needed) — mirrors `AppModelBackendSelectionTests.pathsAreDistinctPerBackend`.
        let base = try makeTempDir()
        let storeURL = resolveProfileStoreURL(descriptor: .adaface, appSupportRoot: base)
        #expect(storeURL.lastPathComponent == "profile-store-adaface-ir18.json")

        let store = try uniqueStore()
        let model = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
                "KION_BACKEND": "coreml",
            ],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: freshSuite()
        )

        #expect(model.faceBackend == .coreml)
        #expect(model.activeFaceBackend == .coreml)
        #expect(model.activeDescriptor == .adaface)

        let bundle = try #require(model.enrolledProfile)
        #expect(bundle.modelId == "adaface-ir18")
        #expect(bundle.modelVersion == "1")

        let readback = FileProfileRepository(
            storeURL: store,
            modelId: FaceModelDescriptor.adaface.id,
            modelVersion: FaceModelDescriptor.adaface.version
        )
        #expect(readback.loadProfile(subjectId: AppModel.legacySubjectID)?.modelId == "adaface-ir18")

        #expect(model.modelDownloader.installURL.lastPathComponent == "AdaFace_IR18.mlmodelc")

        let live = try #require(model.engine as? LiveTriageEngine)
        #expect(live.modelIdentityForTesting.modelId == "adaface-ir18")
        #expect(live.modelIdentityForTesting.modelVersion == "1")
    }

    @Test("KION_BACKEND=coreml: needsOnboarding is true over an empty root, false once the .mlmodelc dir exists")
    func coreMLNeedsOnboardingReflectsInstalledDirectory() throws {
        let appSupport = try makeTempDir()
        let store = try uniqueStore()
        let missingModel = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
                "KION_BACKEND": "coreml",
            ],
            modelLocations: ModelLocations(appSupportRoot: appSupport),
            libraryDefaults: freshSuite()
        )
        #expect(missingModel.needsOnboarding == true)

        let managed = managedModelURL(appSupportRoot: appSupport, fileName: ModelAssetDescriptor.adaface.installedName)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)

        let installedModel = AppModel(
            environment: [
                "KION_PROFILE_STORE": try uniqueStore().path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
                "KION_BACKEND": "coreml",
            ],
            modelLocations: ModelLocations(appSupportRoot: appSupport),
            libraryDefaults: freshSuite()
        )
        #expect(installedModel.needsOnboarding == false)
    }
}
