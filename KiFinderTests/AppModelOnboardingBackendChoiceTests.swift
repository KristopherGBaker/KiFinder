import Foundation
import KionEngine
@testable import KiFinder
import Testing

/// Item 73 coverage: the first-run backend chooser, shown BEFORE the onboarding
/// download gate. `hasExplicitBackendChoice` is pure and directly testable; the
/// `AppModel`-level tests build REAL `AppModel`s (no `KION_SAMPLE`, no injected
/// engine) over an EMPTY app-support root so the ONNX model is genuinely absent
/// and onboarding is otherwise in play — proving the chooser gate, not merely
/// that onboarding was already bypassed some other way. Mirrors
/// `AppModelBackendSelectionTests`'s fixtures/conventions.
@Suite("First-run backend chooser (item 73)")
@MainActor
struct AppModelOnboardingBackendChoiceTests {
    // MARK: - Fixtures

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "kion-backend-choice-tests-\(UUID().uuidString)")!
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-backend-choice-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueStore() throws -> URL {
        try makeTempDir().appendingPathComponent("store.json")
    }

    /// A default-ONNX first-run `AppModel`: no `KION_BACKEND`, no persisted
    /// preference, and an EMPTY app-support root (no ONNX model installed) — so
    /// onboarding is genuinely in play and the chooser has something to gate.
    private func firstRunModel(defaults: UserDefaults, extraEnv: [String: String] = [:]) throws -> AppModel {
        var env = extraEnv
        env["KION_PROFILE_STORE"] = try uniqueStore().path
        return AppModel(
            environment: env,
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: defaults
        )
    }

    // MARK: - Assertion 1: first run shows the chooser

    @Test("A fresh default-ONNX first run shows the chooser AND still needs onboarding")
    func firstRunShowsChooser() throws {
        let model = try firstRunModel(defaults: freshSuite())

        #expect(model.needsBackendChoice == true)
        #expect(model.needsOnboarding == true)
    }

    // MARK: - Assertion 2: every existing bypass suppresses the chooser

    @Test("KION_SAMPLE=1 suppresses the chooser")
    func sampleModeSuppressesChooser() throws {
        let model = try firstRunModel(defaults: freshSuite(), extraEnv: ["KION_SAMPLE": "1"])
        #expect(model.needsBackendChoice == false)
    }

    @Test("Explicit KION_BACKEND=onnx suppresses the chooser but leaves onboarding needed")
    func explicitOnnxEnvSuppressesChooser() throws {
        let model = try firstRunModel(defaults: freshSuite(), extraEnv: ["KION_BACKEND": "onnx"])

        #expect(model.needsBackendChoice == false)
        // Non-vacuous: proves suppression is the explicit-choice probe, not that
        // onboarding was already bypassed for some other reason.
        #expect(model.needsOnboarding == true)
    }

    @Test("Explicit KION_BACKEND=vision suppresses the chooser (and onboarding is moot)")
    func explicitVisionEnvSuppressesChooser() throws {
        let model = try firstRunModel(defaults: freshSuite(), extraEnv: ["KION_BACKEND": "vision"])

        #expect(model.needsBackendChoice == false)
        #expect(model.needsOnboarding == false)
    }

    @Test("A persisted preference (no KION_BACKEND) suppresses the chooser but leaves onboarding needed")
    func persistedPreferenceSuppressesChooser() throws {
        let suite = freshSuite()
        suite.set("onnx", forKey: BackendPreference.key)
        let model = try firstRunModel(defaults: suite)

        #expect(model.needsBackendChoice == false)
        // Non-vacuous: the ONNX model is still absent, so only the
        // persisted-choice probe suppresses the chooser here.
        #expect(model.needsOnboarding == true)
    }

    @Test("An INVALID persisted preference string still counts as an explicit choice")
    func invalidPersistedPreferenceStillSuppressesChooser() throws {
        let suite = freshSuite()
        suite.set("bogus", forKey: BackendPreference.key)
        let model = try firstRunModel(defaults: suite)

        #expect(model.needsBackendChoice == false)
        #expect(model.needsOnboarding == true) // resolves to .onnx, model still absent
        #expect(model.faceBackend == .onnx)
    }

    @Test("A valid KION_MODEL_PATH suppresses the chooser (onboarding is moot)")
    func validModelPathSuppressesChooser() throws {
        let dummyModel = try makeTempDir().appendingPathComponent("dummy.onnx")
        try Data([0x00, 0x01]).write(to: dummyModel)
        let suite = freshSuite()
        let model = try firstRunModel(defaults: suite, extraEnv: ["KION_MODEL_PATH": dummyModel.path])

        #expect(model.needsOnboarding == false)
        #expect(model.needsBackendChoice == false)
    }

    // MARK: - Assertion 3: hasExplicitBackendChoice truth table (pure)

    @Test("hasExplicitBackendChoice: false for empty env + empty suite")
    func explicitChoiceFalseWhenNothingSet() {
        #expect(hasExplicitBackendChoice(env: [:], defaults: freshSuite()) == false)
    }

    @Test("hasExplicitBackendChoice: true when KION_BACKEND is set to a valid value")
    func explicitChoiceTrueForValidEnvValue() {
        #expect(hasExplicitBackendChoice(env: ["KION_BACKEND": "vision"], defaults: freshSuite()) == true)
    }

    @Test("hasExplicitBackendChoice: true when KION_BACKEND is a bogus value")
    func explicitChoiceTrueForBogusEnvValue() {
        #expect(hasExplicitBackendChoice(env: ["KION_BACKEND": "bogus-backend"], defaults: freshSuite()) == true)
    }

    @Test("hasExplicitBackendChoice: true for KION_BACKEND=\"\" (probes presence, not validity) and never mutates the suite")
    func explicitChoiceTrueForEmptyStringAndDoesNotMutate() {
        let suite = freshSuite()
        #expect(hasExplicitBackendChoice(env: ["KION_BACKEND": ""], defaults: suite) == true)
        // Pure: the probe itself never writes to the suite.
        #expect(suite.object(forKey: BackendPreference.key) == nil)
    }

    @Test("hasExplicitBackendChoice: true when the persisted key exists, even with an invalid string")
    func explicitChoiceTrueForPersistedInvalidValue() {
        let suite = freshSuite()
        suite.set("not-a-real-backend", forKey: BackendPreference.key)
        #expect(hasExplicitBackendChoice(env: [:], defaults: suite) == true)
    }

    // MARK: - Assertion 4: choosing ArcFace does not rebuild

    @Test("chooseFirstRunBackend(.onnx) returns false, persists onnx, and leaves the live ArcFace session untouched")
    func choosingArcFaceDoesNotRequestRebuild() throws {
        let suite = freshSuite()
        let model = try firstRunModel(defaults: suite)
        let liveBefore = try #require(model.engine as? LiveTriageEngine)
        #expect(model.activeFaceBackend == .onnx)

        let mustRebuild = model.chooseFirstRunBackend(.onnx)

        #expect(mustRebuild == false)
        #expect(suite.string(forKey: BackendPreference.key) == FaceBackend.onnx.rawValue)
        #expect(model.needsBackendChoice == false)
        #expect(model.needsOnboarding == true) // still no model on disk
        #expect(model.activeFaceBackend == .onnx)
        let liveAfter = try #require(model.engine as? LiveTriageEngine)
        #expect(liveBefore === liveAfter) // nothing was rebuilt
    }

    // MARK: - Assertion 5: choosing Vision requests a rebuild but doesn't re-aim in place

    @Test("chooseFirstRunBackend(.vision) returns true, persists vision, but the LIVE session stays ArcFace")
    func choosingVisionRequestsRebuildWithoutLiveReaim() throws {
        let suite = freshSuite()
        let model = try firstRunModel(defaults: suite)
        #expect(model.activeFaceBackend == .onnx)

        let mustRebuild = model.chooseFirstRunBackend(.vision)

        #expect(mustRebuild == true)
        #expect(suite.string(forKey: BackendPreference.key) == FaceBackend.vision.rawValue)
        #expect(model.needsBackendChoice == false)
        // item72 no-live-re-aim: the ALREADY-RUNNING session stays on ArcFace.
        #expect(model.activeFaceBackend == .onnx)
        #expect(model.activeDescriptor == .arcface)
    }

    // MARK: - Assertion 6: reconstruction lands on a working Vision session

    @Test("A fresh AppModel sharing the same suite after choosing Vision resolves to a working Vision session")
    func reconstructionAfterVisionChoiceLandsOnVision() throws {
        let suite = freshSuite()
        let firstRun = try firstRunModel(defaults: suite)
        #expect(firstRun.chooseFirstRunBackend(.vision) == true)

        // The App's reconstruction: a FRESH AppModel over the SAME suite (the
        // persisted choice) and another empty app-support root (no ONNX model
        // anywhere) — proving Vision needs none.
        let rebuilt = AppModel(
            environment: ["KION_PROFILE_STORE": try uniqueStore().path],
            modelLocations: ModelLocations(appSupportRoot: try makeTempDir()),
            libraryDefaults: suite
        )

        #expect(rebuilt.activeFaceBackend == .vision)
        #expect(rebuilt.activeDescriptor == .visionFeaturePrint)
        #expect(rebuilt.needsOnboarding == false)
        #expect(rebuilt.needsBackendChoice == false)
    }
}
