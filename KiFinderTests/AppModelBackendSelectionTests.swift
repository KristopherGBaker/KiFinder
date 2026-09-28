import Foundation
import KionEngine
import KionONNXEmbedder
import KionVisionEmbedder
@testable import KiFinder
import Testing

/// Item 72 coverage: the app-selectable face backend. `FaceBackend`/
/// `BackendPreference`/`resolveBackend` are pure and directly testable; the
/// AppModel-level tests build a REAL `AppModel` (no injected engine, no
/// `KION_SAMPLE`) so the `else` branch of its engine selection constructs an
/// actual `LiveTriageEngine` — cheap at `init` (no model/disk I/O until
/// enroll/scan), so this proves the real wiring rather than a stand-in spy.
@Suite("App-selectable face backend (item 72)")
@MainActor
struct AppModelBackendSelectionTests {
    // MARK: - Fixtures

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "kion-backend-tests-\(UUID().uuidString)")!
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-backend-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueStore() throws -> URL {
        try makeTempDir().appendingPathComponent("store.json")
    }

    // MARK: - Assertion 1: ONNX default unchanged

    @Test("Default (no KION_BACKEND, no persisted preference) resolves ONNX/arcface end-to-end")
    func defaultIsOnnxArcface() throws {
        let store = try uniqueStore()
        let model = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
            ],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: freshSuite()
        )

        #expect(model.faceBackend == .onnx)
        #expect(model.activeFaceBackend == .onnx)
        #expect(model.activeDescriptor == .arcface)

        let bundle = try #require(model.enrolledProfile)
        #expect(bundle.modelId == "arcfaceresnet100-8")
        #expect(bundle.modelVersion == "1")
        // EXACT calibration (the seeded sample profile's margins), not just "some value".
        #expect(bundle.threshold == 0.45)
        #expect(bundle.maybeMargin == 0.20)
        #expect(bundle.negativeMargin == 0.0)

        // The store ON DISK is stamped arcface too (read back through a fresh,
        // arcface-expecting repository over the SAME file).
        let readback = FileProfileRepository(storeURL: store)
        #expect(readback.loadProfile(subjectId: AppModel.legacySubjectID)?.modelId == "arcfaceresnet100-8")

        // A real LiveTriageEngine was built (the `else` branch), stamped arcface —
        // the ONNX provider factory, not a stand-in.
        let live = try #require(model.engine as? LiveTriageEngine)
        #expect(live.modelIdentityForTesting.modelId == "arcfaceresnet100-8")
        #expect(live.modelIdentityForTesting.modelVersion == "1")
    }

    // MARK: - Assertion 2: Vision selectable end-to-end

    @Test("KION_BACKEND=vision selects Vision end-to-end: session, seed stamp, needsOnboarding, engine stamp")
    func visionSelectedEndToEnd() throws {
        let store = try uniqueStore()
        let model = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
                "KION_BACKEND": "vision",
            ],
            // An empty temp root: no ONNX model installed anywhere the resolver
            // would look, proving `needsOnboarding` is false for a reason OTHER
            // than "the model happens to be there".
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: freshSuite()
        )

        #expect(model.faceBackend == .vision)
        #expect(model.activeFaceBackend == .vision)
        #expect(model.activeDescriptor == .visionFeaturePrint)

        let bundle = try #require(model.enrolledProfile)
        #expect(bundle.modelId == "vision-featureprint")
        #expect(bundle.modelVersion == "1")

        // No ONNX model installed anywhere — Vision never blocks on it.
        #expect(model.needsOnboarding == false)

        // The store on disk is stamped vision too (read back with a
        // vision-expecting repository — a vision stamp is exact-match, no alias).
        let readback = FileProfileRepository(
            storeURL: store,
            modelId: FaceModelDescriptor.visionFeaturePrint.id,
            modelVersion: FaceModelDescriptor.visionFeaturePrint.version
        )
        #expect(readback.loadProfile(subjectId: AppModel.legacySubjectID)?.modelId == "vision-featureprint")

        let live = try #require(model.engine as? LiveTriageEngine)
        #expect(live.modelIdentityForTesting.modelId == "vision-featureprint")
        #expect(live.modelIdentityForTesting.modelVersion == "1")
    }

    @Test("KION_PROFILE_STORE is honored VERBATIM — no per-backend suffix appended")
    func explicitStoreOverrideIsVerbatim() throws {
        let store = try uniqueStore()
        let model = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
                "KION_BACKEND": "vision",
            ],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: freshSuite()
        )
        _ = model.enrolledProfile // force load
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(store.lastPathComponent == "store.json") // unchanged from the caller's literal name
    }

    // MARK: - Assertion 3: provider selection is concretely observable

    @Test("FaceBackend.makeProvider returns the CONCRETE provider type per backend")
    func makeProviderReturnsConcreteType() throws {
        // A file that merely EXISTS is enough for `FaceEmbedder.init` (it defers
        // ONNX Runtime session creation to first use), so no real 249 MB model is
        // needed to prove the concrete type it constructs.
        let dummyModel = try makeTempDir().appendingPathComponent("dummy.onnx")
        try Data([0x00, 0x01]).write(to: dummyModel)

        let onnxProvider = try FaceBackend.onnx.makeProvider(modelURL: dummyModel)
        #expect(onnxProvider is FaceEmbedder)

        let visionProvider = try FaceBackend.vision.makeProvider(modelURL: nil)
        #expect(visionProvider is VisionFeaturePrintEmbedder)
    }

    // MARK: - Assertion 4: per-backend store paths + migration

    @Test("The onnx and vision production paths are DISTINCT filenames")
    func pathsAreDistinctPerBackend() throws {
        let base = try makeTempDir()
        let onnxURL = resolveProfileStoreURL(descriptor: .arcface, appSupportRoot: base)
        let visionURL = resolveProfileStoreURL(descriptor: .visionFeaturePrint, appSupportRoot: base)

        #expect(onnxURL.lastPathComponent == "profile-store-arcfaceresnet100-8.json")
        #expect(visionURL.lastPathComponent == "profile-store-vision-featureprint.json")
        #expect(onnxURL != visionURL)
    }

    @Test("A legacy profile-store.json is MOVED to the arcface-suffixed path when that path is absent")
    func legacyStoreMigratesWhenSuffixedAbsent() throws {
        let base = try makeTempDir()
        let directory = base.appendingPathComponent("KiFinder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("profile-store.json")
        try Data("legacy-arcface-store".utf8).write(to: legacy)

        let resolved = resolveProfileStoreURL(descriptor: .arcface, appSupportRoot: base)

        #expect(resolved.lastPathComponent == "profile-store-arcfaceresnet100-8.json")
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path)) // MOVED, not copied
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "legacy-arcface-store")
    }

    @Test("A legacy profile-store.json is left UNTOUCHED when the arcface-suffixed path already exists")
    func legacyStoreUntouchedWhenSuffixedPresent() throws {
        let base = try makeTempDir()
        let directory = base.appendingPathComponent("KiFinder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("profile-store.json")
        try Data("legacy-should-stay".utf8).write(to: legacy)
        let suffixed = directory.appendingPathComponent("profile-store-arcfaceresnet100-8.json")
        try Data("existing-arcface-store".utf8).write(to: suffixed)

        _ = resolveProfileStoreURL(descriptor: .arcface, appSupportRoot: base)

        #expect(FileManager.default.fileExists(atPath: legacy.path)) // untouched, no data loss
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-should-stay")
        #expect(try String(contentsOf: suffixed, encoding: .utf8) == "existing-arcface-store") // not overwritten
    }

    @Test("Resolving the VISION path never moves or consumes the legacy profile-store.json")
    func visionResolutionNeverTouchesLegacyStore() throws {
        let base = try makeTempDir()
        let directory = base.appendingPathComponent("KiFinder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("profile-store.json")
        try Data("legacy-untouched-by-vision".utf8).write(to: legacy)

        let visionResolved = resolveProfileStoreURL(descriptor: .visionFeaturePrint, appSupportRoot: base)

        #expect(visionResolved.lastPathComponent == "profile-store-vision-featureprint.json")
        #expect(!FileManager.default.fileExists(atPath: visionResolved.path)) // never created/moved into
        #expect(FileManager.default.fileExists(atPath: legacy.path)) // legacy untouched
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy-untouched-by-vision")
    }

    // MARK: - Assertion 5: preference round-trip + fallback

    @Test("Setting AppModel.faceBackend persists under BackendPreference.key; resolveBackend reads it back; KION_BACKEND overrides it")
    func preferenceRoundTripAndEnvPrecedence() throws {
        let suite = freshSuite()
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": try uniqueStore().path],
            libraryDefaults: suite
        )

        #expect(model.faceBackend == .onnx) // default, nothing persisted yet
        #expect(suite.object(forKey: BackendPreference.key) == nil)

        model.faceBackend = .vision

        #expect(suite.string(forKey: BackendPreference.key) == FaceBackend.vision.rawValue)
        #expect(resolveBackend(env: [:], defaults: suite) == .vision)
        #expect(model.faceBackend == .vision) // the getter resolves fresh, reflects the new pref

        // KION_BACKEND overrides the now-persisted "vision" preference.
        #expect(resolveBackend(env: ["KION_BACKEND": "onnx"], defaults: suite) == .onnx)
    }

    @Test("An unrecognized KION_BACKEND value falls back to onnx")
    func unknownEnvValueFallsBackToOnnx() {
        let suite = freshSuite() // nothing persisted
        #expect(resolveBackend(env: ["KION_BACKEND": "bogus-backend"], defaults: suite) == .onnx)
    }

    @Test("An invalid persisted preference string falls back to onnx")
    func invalidPersistedValueFallsBackToOnnx() {
        let suite = freshSuite()
        suite.set("not-a-real-backend", forKey: BackendPreference.key)
        #expect(resolveBackend(env: [:], defaults: suite) == .onnx)
    }

    @Test("Resolving via env or default never writes the preference")
    func resolutionNeverPersists() {
        let suite = freshSuite()
        _ = resolveBackend(env: [:], defaults: suite) // default
        _ = resolveBackend(env: ["KION_BACKEND": "vision"], defaults: suite) // env
        #expect(suite.object(forKey: BackendPreference.key) == nil)
    }

    // MARK: - Assertion 6: no live re-aim

    @Test("Setting faceBackend on a running ONNX AppModel persists the preference but does NOT re-aim the live session")
    func noLiveReaimUntilNewInstance() throws {
        let suite = freshSuite()
        let store = try uniqueStore()
        let model = AppModel(
            environment: [
                "KION_PROFILE_STORE": store.path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
            ],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: suite
        )
        #expect(model.activeFaceBackend == .onnx)
        #expect(model.activeDescriptor == .arcface)
        let liveBefore = try #require(model.engine as? LiveTriageEngine)
        #expect(liveBefore.modelIdentityForTesting.modelId == "arcfaceresnet100-8")

        model.faceBackend = .vision // ONLY persists — no live re-aim

        // The preference read reflects the new choice...
        #expect(model.faceBackend == .vision)
        // ...but the ACTIVE (already-running) session stays exactly on ArcFace:
        // descriptor, store stamp, and the SAME engine instance, unchanged.
        #expect(model.activeFaceBackend == .onnx)
        #expect(model.activeDescriptor == .arcface)
        #expect(model.enrolledProfile?.modelId == "arcfaceresnet100-8")
        let liveAfter = try #require(model.engine as? LiveTriageEngine)
        #expect(liveAfter.modelIdentityForTesting.modelId == "arcfaceresnet100-8")
        #expect(liveBefore === liveAfter) // nothing was rebuilt

        // A NEW AppModel constructed now picks up the persisted "vision" choice —
        // this is what "relaunch to apply" means.
        let fresh = AppModel(
            environment: [
                "KION_PROFILE_STORE": try uniqueStore().path,
                "KION_SEED_PROFILE": "1",
                "KION_RESET": "1",
            ],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: suite
        )
        #expect(fresh.activeFaceBackend == .vision)
        #expect(fresh.activeDescriptor == .visionFeaturePrint)
    }
}
