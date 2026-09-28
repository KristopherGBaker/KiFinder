import XCTest

/// Item-18a assertion 9 on-device smoke: onboarding shows a library-root control
/// (`libraryRootField`) pre-filled with the default, the "Choose…" button
/// (`libraryRootChooseButton`) honors the `KION_LIBRARY_PICK` test override and the
/// chosen root persists, and the root control never gates the onboarding readiness.
///
/// Skips gracefully when a model is already installed on the host (so onboarding is
/// bypassed) — the persisted-root resolver is the unit-tested seam; this is the
/// documented manual/on-device step.
final class LibraryRootSmokeTests: XCTestCase {
    private let timeout: TimeInterval = 15

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testOnboardingLibraryRootControl() throws {
        // The pick target is a folder the APP only READS/bookmarks (item 76), so it stays
        // a runner-created dir under the runner's temp — the app can read the runner's
        // container (fact 4) and this test passes today. The app-WRITTEN store + app-support
        // roots live in the app's own container via `HarnessPaths.appWritable`.
        let pick = HarnessPaths.runnerWritable("pick").path
        let app = XCUIApplication()
        // No KION_SAMPLE so the onboarding gate is in play; a fresh profile store; and
        // a test-dir pick so "Choose…" doesn't open the system folder panel. KION_APP_SUPPORT
        // points the model location at an EMPTY temp root so onboarding is shown regardless
        // of the host's real installed model (otherwise this test skips).
        app.launchEnvironment["KION_PROFILE_STORE"] = HarnessPaths.appWritable("store")
            .appendingPathComponent("store.json").path
        app.launchEnvironment["KION_APP_SUPPORT"] = HarnessPaths.appWritable("appsupport").path
        app.launchEnvironment["KION_LIBRARY_PICK"] = pick
        app.launchEnvironment["KION_BACKEND"] = "onnx"
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: timeout), "no window")
        app.zoomMainWindow()

        let onboarding = app.descendants(matching: .any).matching(identifier: "onboardingView").firstMatch
        XCTAssertTrue(onboarding.waitForExistence(timeout: timeout), "onboarding not shown (KION_APP_SUPPORT should force it)")

        // The library-root field is shown and pre-filled (non-empty default path).
        let field = app.descendants(matching: .any).matching(identifier: "libraryRootField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "libraryRootField missing")
        let before = (field.value as? String ?? "") + field.label
        XCTAssertFalse(before.isEmpty, "library root field is empty (no default)")

        // The readiness gate (download button) is still present — the root is non-gating.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "onboardingDownloadButton").firstMatch.exists,
            "download gate missing — root control should not replace it"
        )

        // Choosing a folder (test override) updates the field to the picked path.
        let choose = app.descendants(matching: .any).matching(identifier: "libraryRootChooseButton").firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: timeout), "libraryRootChooseButton missing")
        choose.click()

        let updated = app.descendants(matching: .any).matching(identifier: "libraryRootField").firstMatch
        let expectation = expectation(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", pick, pick), evaluatedWith: updated)
        wait(for: [expectation], timeout: timeout)
    }
}
