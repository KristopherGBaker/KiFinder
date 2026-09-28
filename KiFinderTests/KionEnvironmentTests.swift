import Foundation
@testable import KiFinder
import Testing

@Suite("KION_* env sanitizer (release ignores test hooks)")
struct KionEnvironmentTests {
    private static let fixture: [String: String] = [
        "KION_SAMPLE": "1",
        "KION_MODEL_PATH": "/tmp/model.onnx",
        "KION_APP_SUPPORT": "/tmp/support",
        "PATH": "/usr/bin",
    ]

    @Test("Release (hooks disallowed) strips every KION_* key, keeps non-KION")
    func stripsKionWhenHooksDisallowed() {
        let result = KionEnvironment.sanitized(Self.fixture, allowingTestHooks: false)
        // Only PATH survives; KION_MODEL_PATH gone (closes the managed-model gate bypass).
        #expect(result == ["PATH": "/usr/bin"])
        #expect(result["KION_SAMPLE"] == nil)
        #expect(result["KION_MODEL_PATH"] == nil)
        #expect(result["KION_APP_SUPPORT"] == nil)
    }

    @Test("DEBUG (hooks allowed) returns the environment unchanged")
    func keepsEnvironmentWhenHooksAllowed() {
        let result = KionEnvironment.sanitized(Self.fixture, allowingTestHooks: true)
        #expect(result == Self.fixture)
    }

    @Test("Non-KION keys are never stripped, even when hooks disallowed")
    func neverStripsNonKionKeys() {
        let env = ["HOME": "/Users/x", "LANG": "en_US", "KIONISH": "keep-me"]
        let result = KionEnvironment.sanitized(env, allowingTestHooks: false)
        // "KIONISH" does not start with the "KION_" prefix, so it stays.
        #expect(result == env)
    }

    @Test("allowsTestHooks is true in the DEBUG test build")
    func allowsTestHooksInDebug() {
        #expect(KionEnvironment.allowsTestHooks == true)
    }

    // MARK: - Preference-domain isolation for harness launches

    @Test("A real launch (no KION_* keys) persists to the standard domain")
    func realLaunchUsesStandardDefaults() {
        #expect(KionEnvironment.defaultsSuiteName(env: ["PATH": "/usr/bin"]) == nil)
        #expect(KionEnvironment.defaultsSuiteName(env: [:]) == nil)
        // "KIONISH" is not a KION_ hook, so it doesn't trip the isolation either.
        #expect(KionEnvironment.defaultsSuiteName(env: ["KIONISH": "1"]) == nil)
    }

    @Test("Any KION_* hook diverts prefs to a non-production suite")
    func harnessLaunchIsIsolated() {
        // The exact case that broke the real app: a UI test drove KION_LIBRARY_PICK and
        // the app wrote that throwaway folder's bookmark into the real preference domain.
        let suite = KionEnvironment.defaultsSuiteName(env: ["KION_LIBRARY_PICK": "/tmp/pick"])
        #expect(suite != nil)
        #expect(suite != "com.krisbaker.KiFinder")
        #expect(KionEnvironment.defaultsSuiteName(env: Self.fixture) == suite)
    }

    @Test("KION_DEFAULTS_SUITE names the suite explicitly; empty falls through")
    func explicitSuiteWins() {
        #expect(
            KionEnvironment.defaultsSuiteName(
                env: ["KION_DEFAULTS_SUITE": "my-suite", "KION_SAMPLE": "1"]
            ) == "my-suite"
        )
        // Empty is not a usable suite name: fall back to the shared harness suite,
        // NOT to the production domain (a KION_ key is still present).
        let fallback = KionEnvironment.defaultsSuiteName(env: ["KION_DEFAULTS_SUITE": ""])
        #expect(fallback != nil)
        #expect(fallback != "")
    }
}
