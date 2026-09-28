import XCTest

/// Drives the album-scan moment: open the dark scan sheet, start a scan via the
/// deterministic test affordance, observe live progress (bar, matches, on-device
/// badge, time-left, Stop), and confirm it routes back to a populated Review.
final class ScanMomentTests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func seededStoreArg() -> String {
        // App-written store in the app's own sandbox container (item 76).
        HarnessPaths.appWritable("scan-store").appendingPathComponent("store.json").path
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        // Seed a profile so launch lands on Review (no enrollment sheet).
        app.launchEnvironment["KION_PROFILE_STORE"] = seededStoreArg()
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        // Show the deterministic "Scan Sample Album" affordance (no system picker).
        app.launchEnvironment["KION_TEST_SCAN"] = "1"
        // Slow the scan ticks generously so every in-progress assertion lands
        // while the card is still up (it dismisses the instant the scan finishes).
        app.launchEnvironment["KION_SCAN_DELAY_MS"] = "2500"
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

    private func element(_ app: XCUIApplication, _ string: String) -> XCUIElement {
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

    /// Locates the review title. Item 78 made the title native window chrome
    /// (`navigationTitle`), which cannot carry an accessibility identifier, so it
    /// surfaces as a `StaticText` in the window's toolbar. Match it by its visible
    /// copy, scoped to the main window's toolbar and falling back to the window's own
    /// static texts if the toolbar query is empty on this OS. Window-scoped (never
    /// `app.descendants`) so the "Review" command menu in the menu bar can't shadow it.
    private func reviewTitleElement(_ app: XCUIApplication) -> XCUIElement {
        // (A fresh NSPredicate per query: it is not Sendable, so reusing one across
        // two XCUIElementQuery builds trips Swift 6's region-isolation check.)
        func titlePredicate() -> NSPredicate {
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review", "Review")
        }
        let window = app.windows.firstMatch
        let inToolbar = window.toolbars.firstMatch.staticTexts.matching(titlePredicate()).firstMatch
        return inToolbar.exists ? inToolbar : window.staticTexts.matching(titlePredicate()).firstMatch
    }

    /// Asserts the toolbar title and confirms its visible copy names the active
    /// person ("Review <name> candidates"), replacing the removed `Review Kris
    /// candidates` identifier.
    private func assertReviewTitle(
        _ app: XCUIApplication,
        person: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let title = reviewTitleElement(app)
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "review-title missing", file: file, line: line)
        let text = title.label + " " + (title.value as? String ?? "")
        XCTAssertTrue(
            text.contains("Review \(person) candidates"),
            "review-title copy: \(text)",
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

    func testScanShowsProgressThenRoutesToReview() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        // Open the scan sheet from the Review toolbar.
        let rescan = app.buttons["Re-scan"]
        XCTAssertTrue(rescan.waitForExistence(timeout: timeout), "Re-scan button missing")
        rescan.click()

        // Dark scan moment is presented.
        assertExists(app, "Scan an album", "scan sheet title missing")
        let start = app.buttons["scan-sample-album"]
        XCTAssertTrue(start.waitForExistence(timeout: timeout), "scan-sample-album affordance missing")
        XCTAssertTrue(start.isHittable, "scan-sample-album not hittable")
        start.click()

        // Live in-progress card: album name, progress, matches, on-device badge,
        // time-left, and Stop — all present before the scan completes.
        assertExists(app, "scan-album-name", "scan album name missing")
        assertExists(app, "scan-progress", "scan progress label missing")
        assertExists(app, "scan-matches", "matches-so-far stat missing")
        assertExists(app, "On-device · 100%", "on-device privacy badge missing")
        XCTAssertTrue(app.buttons["Stop"].exists, "Stop button missing")
        attach(app, named: "scan-in-progress")

        // Scan completes → sheet dismisses → Review is populated again.
        assertReviewTitle(app, person: "Kris")
        assertExists(app, "Found matches", "keep section missing after scan")
        assertExists(app, "Worth a look", "maybe section missing after scan")
        XCTAssertTrue(
            app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout),
            "candidate tiles not populated after scan"
        )
        attach(app, named: "scan-routed-to-review")
    }

    func testScanSheetCancels() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        app.buttons["Re-scan"].click()
        assertExists(app, "Scan an album", "scan sheet title missing")

        let cancel = app.buttons["scan-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout), "scan cancel missing")
        cancel.click()

        // Back on Review, scan sheet gone.
        assertReviewTitle(app, person: "Kris")
        XCTAssertTrue(
            element(app, "Scan an album").waitForNonExistence(timeout: timeout),
            "scan sheet did not dismiss on cancel"
        )
    }
}
