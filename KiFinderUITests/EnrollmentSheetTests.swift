import XCTest

/// Drives the enrollment sheet end-to-end: first-run presentation over Review,
/// seeded-profile gating, reference collection (counts, 5/12 bounds, limit
/// feedback), the in-progress enroll lock, persistence across relaunch, and
/// re-enroll from Review. Each test uses a unique temp profile store so the
/// suite is order-independent.
final class EnrollmentSheetTests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Fixtures / isolation

    /// A unique, fresh on-disk profile store inside the APP's own sandbox container (item
    /// 76): on macOS 27 the sandboxed app can write ONLY its container, so a store the app
    /// must persist to lives under `HarnessPaths.appWritable` — the app creates the parents
    /// itself. The runner never touches this path.
    private func storeArg() -> String {
        HarnessPaths.appWritable("enroll-store").appendingPathComponent("store.json").path
    }

    // MARK: - Launch

    private func makeApp(
        storePath: String,
        reset: Bool = true,
        seed: Bool = false,
        referenceCount: Int = 0,
        enrollDelayMs: Int? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_PROFILE_STORE"] = storePath
        if reset { app.launchEnvironment["KION_RESET"] = "1" }
        if seed { app.launchEnvironment["KION_SEED_PROFILE"] = "1" }
        if referenceCount > 0 {
            // The app (unsandboxed) synthesizes the reference files itself: the
            // XCUITest runner is sandboxed and cannot place files the app can read.
            app.launchEnvironment["KION_TEST_REFERENCE_COUNT"] = String(referenceCount)
        }
        if let enrollDelayMs {
            app.launchEnvironment["KION_ENROLL_DELAY_MS"] = String(enrollDelayMs)
        }
        return app
    }

    @discardableResult
    private func launch(_ app: XCUIApplication) -> Bool {
        app.launch()
        app.activate()
        let appeared = app.windows.firstMatch.waitForExistence(timeout: timeout)
        if appeared { app.zoomMainWindow() }
        return appeared
    }

    // MARK: - Queries

    private func element(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        // Item 78: the review title is native window chrome (`navigationTitle`), which
        // cannot carry an accessibility identifier, so it surfaces as a `StaticText`
        // in the window's toolbar. Locate it by its visible copy, scoped to the main
        // window's toolbar and falling back to the window's own static texts if the
        // toolbar query is empty on this OS. Window-scoped (never `app.descendants`)
        // so the "Review" command menu in the menu bar can't shadow it.
        if string == "review-title" {
            // (A fresh NSPredicate per query: it is not Sendable, so reusing one across
            // two XCUIElementQuery builds trips Swift 6's region-isolation check.)
            func titlePredicate() -> NSPredicate {
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review", "Review")
            }
            let window = app.windows.firstMatch
            let inToolbar = window.toolbars.firstMatch.staticTexts.matching(titlePredicate()).firstMatch
            return inToolbar.exists ? inToolbar : window.staticTexts.matching(titlePredicate()).firstMatch
        }
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            string, string, string
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func assertExists(
        _ app: XCUIApplication,
        _ string: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element(app, string).waitForExistence(timeout: timeout), message, file: file, line: line)
    }

    private func assertAbsent(
        _ app: XCUIApplication,
        _ string: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element(app, string).waitForNonExistence(timeout: timeout), message, file: file, line: line)
    }

    private func previewCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "reference-preview").count
    }

    /// Enrolling requires a display name (`EnrollmentModel.canEnroll` gates on a
    /// non-empty trimmed name), so the first-run flows type one before expecting
    /// Enroll to enable — exactly what a user does.
    private func typeName(_ app: XCUIApplication, _ name: String = "Kris") {
        let field = app.textFields["enroll-name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "enroll-name-field missing")
        field.click()
        field.typeText(name)
    }

    private func addReferences(_ app: XCUIApplication) {
        let button = app.buttons["add-test-references"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "add-test-references button missing")
        XCTAssertTrue(button.isHittable, "add-test-references not hittable")
        button.click()
    }

    /// Polls the deterministic count label until it reads the expected total.
    private func waitForReferenceCount(
        _ app: XCUIApplication,
        _ count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let label = app.descendants(matching: .any).matching(identifier: "reference-count").firstMatch
        let expected = "References: \(count)"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if label.exists {
                let text = label.label + " " + (label.value as? String ?? "")
                if text.contains(expected) { return }
            }
            usleep(120_000)
        } while Date() < deadline
        XCTFail(
            "reference count != \(count) (label=\(label.label), value=\(String(describing: label.value)))",
            file: file,
            line: line
        )
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - First run

    func testFirstRunPresentsEnrollmentOverReview() {
        let app = makeApp(storePath: storeArg())
        XCTAssertTrue(launch(app), "window did not appear")

        // Sheet content.
        assertExists(app, "enroll-title", "enrollment title missing")
        assertExists(app, "LOCAL-ONLY", "LOCAL-ONLY badge missing")
        assertExists(app, "enrollment-age-guidance", "age-spread guidance missing")
        assertExists(app, "enrollment-step-1", "step 1 missing")
        assertExists(app, "enrollment-step-2", "step 2 missing")
        assertExists(app, "enrollment-step-3", "step 3 missing")

        // Empty state: no previews, Enroll disabled.
        waitForReferenceCount(app, 0)
        XCTAssertEqual(previewCount(app), 0, "expected 0 previews on first run")
        let enroll = app.buttons["Enroll"]
        XCTAssertTrue(enroll.waitForExistence(timeout: timeout), "Enroll button missing")
        XCTAssertFalse(enroll.isEnabled, "Enroll should be disabled when empty")

        // Review is present behind the sheet.
        assertExists(app, "review-title", "Review surface not behind sheet")
        attach(app, named: "enrollment-sheet-empty")
    }

    func testSeededProfileLandsOnReviewWithoutSheet() {
        let app = makeApp(storePath: storeArg(), reset: false, seed: true)
        XCTAssertTrue(launch(app), "window did not appear")

        assertExists(app, "review-title", "Review surface missing for seeded profile")
        assertExists(app, "enrolled-profile", "enrolled profile badge missing")
        assertAbsent(app, "enroll-title", "enrollment sheet should not present for a seeded profile")
    }

    // MARK: - Reference collection

    func testFourReferencesKeepEnrollDisabled() {
        let app = makeApp(storePath: storeArg(), referenceCount: 4)
        XCTAssertTrue(launch(app), "window did not appear")

        assertExists(app, "enroll-title", "enrollment title missing")
        addReferences(app)

        waitForReferenceCount(app, 4)
        XCTAssertEqual(previewCount(app), 4, "expected 4 previews")
        XCTAssertFalse(app.buttons["Enroll"].isEnabled, "Enroll should stay disabled at 4 references")
    }

    func testFiveReferencesEnableEnroll() {
        let app = makeApp(storePath: storeArg(), referenceCount: 5)
        XCTAssertTrue(launch(app), "window did not appear")

        assertExists(app, "enroll-title", "enrollment title missing")
        typeName(app)
        addReferences(app)

        waitForReferenceCount(app, 5)
        XCTAssertEqual(previewCount(app), 5, "expected 5 previews")
        XCTAssertTrue(app.buttons["Enroll"].isEnabled, "Enroll should be enabled at 5 references")
        attach(app, named: "enrollment-sheet-populated")
    }

    func testThirteenReferencesCapAtTwelve() {
        let app = makeApp(storePath: storeArg(), referenceCount: 13)
        XCTAssertTrue(launch(app), "window did not appear")

        assertExists(app, "enroll-title", "enrollment title missing")
        typeName(app)
        addReferences(app)

        waitForReferenceCount(app, 12)
        XCTAssertEqual(previewCount(app), 12, "expected exactly 12 previews")
        assertExists(app, "reference-limit-feedback", "limit feedback missing")
        XCTAssertTrue(app.buttons["Enroll"].isEnabled, "Enroll should be enabled at the cap")
    }

    // MARK: - Enroll + persistence

    func testEnrollPersistsAndReturnsToReview() {
        let storePath = storeArg()
        let app = makeApp(
            storePath: storePath,
            referenceCount: 5,
            enrollDelayMs: 3000
        )
        XCTAssertTrue(launch(app), "window did not appear")

        assertExists(app, "enroll-title", "enrollment title missing")
        typeName(app)
        addReferences(app)
        waitForReferenceCount(app, 5)

        let enroll = app.buttons["Enroll"]
        XCTAssertTrue(enroll.isEnabled, "Enroll should be enabled at 5 references")
        enroll.click()

        // In-progress: indicator visible, Enroll + add disabled until completion.
        assertExists(app, "enrolling-indicator", "enrolling indicator missing")
        XCTAssertFalse(app.buttons["Enroll"].isEnabled, "Enroll should disable while enrolling")
        XCTAssertFalse(app.buttons["add-test-references"].isEnabled, "drop input should disable while enrolling")

        // Dismisses back to Review, exposing enrolled state.
        assertAbsent(app, "enroll-title", "sheet did not dismiss after enroll")
        assertExists(app, "review-title", "did not return to Review")
        assertExists(app, "Enrolled · 5 references", "enrolled profile state not exposed")
        attach(app, named: "enrollment-returned-to-review")
        app.terminate()

        // Fresh launch against the same store, no reset → Review, no sheet.
        let relaunch = makeApp(storePath: storePath, reset: false)
        XCTAssertTrue(launch(relaunch), "relaunch window did not appear")
        assertExists(relaunch, "review-title", "persistence did not gate relaunch to Review")
        assertExists(relaunch, "enrolled-profile", "persisted profile badge missing on relaunch")
        assertAbsent(relaunch, "enroll-title", "enrollment sheet presented despite persisted profile")
    }

    func testReEnrollFromReviewUpdatesProfile() {
        let app = makeApp(
            storePath: storeArg(),
            reset: false,
            seed: true,
            referenceCount: 6
        )
        XCTAssertTrue(launch(app), "window did not appear")

        // Seeded → Review with the 5-reference badge, no sheet.
        assertExists(app, "review-title", "Review surface missing")
        assertExists(app, "Enrolled · 5 references", "seeded badge missing")

        // Re-enroll opens the same sheet (per-person sidebar action).
        let reEnroll = app.buttons["re-enroll-person"].firstMatch
        XCTAssertTrue(reEnroll.waitForExistence(timeout: timeout), "Re-enroll button missing")
        reEnroll.click()
        assertExists(app, "enroll-title", "re-enroll did not open the sheet")

        addReferences(app)
        waitForReferenceCount(app, 6)
        let enroll = app.buttons["Enroll"]
        XCTAssertTrue(enroll.isEnabled, "Enroll should enable at 6 references")
        enroll.click()

        // Returns to Review with the updated, persisted reference count.
        assertAbsent(app, "enroll-title", "re-enroll sheet did not dismiss")
        assertExists(app, "review-title", "did not return to Review after re-enroll")
        assertExists(app, "Enrolled · 6 references", "re-enroll did not update the persisted bundle")
        attach(app, named: "enrollment-re-enroll")
    }

    // MARK: - Mandatory first-run gate

    func testFirstRunEnrollmentCannotBeCancelledOrDismissed() {
        let app = makeApp(storePath: storeArg())
        XCTAssertTrue(launch(app), "window did not appear")

        // The mandatory first-run sheet offers no Cancel escape hatch.
        assertExists(app, "enroll-title", "enrollment title missing")
        assertAbsent(app, "Cancel", "mandatory first-run enrollment should hide Cancel")

        // Escape / interactive dismissal must not drop the user onto an empty Review.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        assertExists(app, "enroll-title", "Escape dismissed the mandatory enrollment sheet")
    }
}
