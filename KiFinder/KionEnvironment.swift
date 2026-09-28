import AppKit
import Foundation

/// Central gate for the `KION_*` launch/test hooks.
///
/// The app exposes a family of `KION_*` environment variables (sample mode,
/// profile/app-support/library-root/feedback-log overrides, `KION_DYNAMIC_TYPE`,
/// `KION_TEST_SCAN`, `KION_MODEL_PATH`, `KION_BACKEND` — item 72's `"onnx"`/
/// `"vision"` face-backend override, see `resolveBackend`, …) so the test and
/// UI-test harness can drive the app deterministically. `KION_MODEL_PATH` even bypasses the managed
/// model's size/hash gate. None of that should affect a shipped app, so a
/// RELEASE build must see NO `KION_*` keys. Production reads all flow through the
/// three `ProcessInfo.processInfo.environment` entry points, and every one of
/// them routes through ``process`` here.
enum KionEnvironment {
    /// Test/UI-test hooks are honored only in DEBUG; a release build ignores
    /// every `KION_*` key.
    static let allowsTestHooks: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// Pure: strips every `KION_*` key unless test hooks are allowed. Non-`KION_`
    /// keys (e.g. `PATH`, `HOME`) are always preserved.
    static func sanitized(_ env: [String: String], allowingTestHooks: Bool) -> [String: String] {
        allowingTestHooks ? env : env.filter { !$0.key.hasPrefix("KION_") }
    }

    /// The process environment as production code should read it: unchanged in
    /// DEBUG, `KION_*`-free in a release build.
    static var process: [String: String] {
        sanitized(ProcessInfo.processInfo.environment, allowingTestHooks: allowsTestHooks)
    }

    /// The preference-suite name a launch should persist to, or `nil` for the real
    /// standard defaults.
    ///
    /// A harness-driven launch (any surviving `KION_*` key — a UI test, a scripted
    /// run) must NEVER write into the app's real preference domain. It used to: the
    /// root-picker UI test drives `KION_LIBRARY_PICK`, the app persisted a
    /// security-scoped bookmark for that throwaway runner temp dir to
    /// `UserDefaults.standard`, and every subsequent REAL launch then resolved its
    /// library root to a deleted/unwritable test folder — so every Keep silently
    /// failed to save. Isolating the suite makes that structurally impossible.
    ///
    /// A test that wants its own clean slate (or persistence across an in-test
    /// relaunch) passes `KION_DEFAULTS_SUITE=<name>`; otherwise harness launches
    /// share one non-production suite.
    static func defaultsSuiteName(env: [String: String]) -> String? {
        if let explicit = env["KION_DEFAULTS_SUITE"], !explicit.isEmpty { return explicit }
        guard env.keys.contains(where: { $0.hasPrefix("KION_") }) else { return nil }
        return "com.krisbaker.KiFinder.harness"
    }

    /// The `UserDefaults` the app itself should persist to: the standard domain for a
    /// real launch, an isolated suite for a `KION_*`-driven harness launch.
    static var appDefaults: UserDefaults {
        guard let suite = defaultsSuiteName(env: process),
              let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }

    /// Harness window policy (item 78). `NSWindow` frame autosave writes to
    /// `UserDefaults.standard` — NOT the isolated harness suite — so a `KION_*`
    /// launch would otherwise overwrite the user's real saved window frame with the
    /// test's (zoomed) frame on exit. For a harness launch this detaches every
    /// visible titled window from frame autosave so nothing is written back. It
    /// deliberately does not resize the window (a test that needs a specific size
    /// resizes it the way a user does). A no-op for a real launch.
    @MainActor
    static func applyHarnessWindowPolicy() {
        guard defaultsSuiteName(env: process) != nil else { return }
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.setFrameAutosaveName("")
        }
    }
}
