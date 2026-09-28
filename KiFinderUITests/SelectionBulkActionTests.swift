import XCTest

/// Drives item 17's grid multi-selection on the sample data: the section-header
/// "Select all"/"Skip all" buttons, the bulk-action bar (Skip Selected / Export
/// Selected), and the per-tile "selected" accessibility marker. Mirrors the
/// keyboard-culling test's launch + helper style.
final class SelectionBulkActionTests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func seededStoreArg() -> String {
        // App-written store in the app's own sandbox container (item 76).
        HarnessPaths.appWritable("selection-store").appendingPathComponent("store.json").path
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_REVIEW_COLUMNS"] = "2"
        app.launchEnvironment["KION_PROFILE_STORE"] = seededStoreArg()
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
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

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private static func isSelected(_ element: XCUIElement) -> Bool {
        let value = (element.value as? String) ?? ""
        return element.label.contains("selected") || value.contains("selected")
    }

    // MARK: - Section header "Select all" → bulk bar → "Skip all"

    func testSelectAllSurfacesBulkActionsAndMarksTiles() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        // Kris's "Worth a look" section owns IMG_1861 + IMG_1888.
        XCTAssertTrue(app.buttons["IMG_1861.PNG"].waitForExistence(timeout: timeout), "maybe tile missing")

        // No bulk-action bar before any selection.
        XCTAssertFalse(element(app, id: "skipSelectedButton").exists, "bulk bar present with no selection")

        // The maybe section's "Select all" header button selects its tiles.
        let selectAll = element(app, id: "selectAllButton-maybe")
        XCTAssertTrue(selectAll.waitForExistence(timeout: timeout), "Select all (maybe) missing")
        selectAll.click()

        // The selected tiles carry the "selected" accessibility marker.
        XCTAssertTrue(Self.isSelected(app.buttons["IMG_1861.PNG"]), "maybe tile not marked selected")

        // The bulk-action affordance appears once there is a selection.
        XCTAssertTrue(
            element(app, id: "skipSelectedButton").waitForExistence(timeout: timeout),
            "Skip Selected missing with a selection"
        )
        XCTAssertTrue(element(app, id: "exportSelectedButton").exists, "Export Selected missing with a selection")
        attach(app, named: "selection-bulk-bar")

        // Skip Selected clears the selection (bar disappears) and skips the tiles.
        element(app, id: "skipSelectedButton").click()
        XCTAssertTrue(
            element(app, id: "skipSelectedButton").waitForNonExistence(timeout: timeout),
            "bulk bar persisted after Skip Selected"
        )
    }

    // MARK: - "Skip all" in a section needs no prior selection

    func testSkipAllHeaderButtonSkipsSection() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        let skipAll = element(app, id: "skipAllButton-maybe")
        XCTAssertTrue(skipAll.waitForExistence(timeout: timeout), "Skip all (maybe) missing")
        skipAll.click()

        // The kept count is unaffected by skipping the maybe section.
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "kept export changed")

        // "Found matches" / "Skipped" sections never show the bulk header buttons.
        XCTAssertFalse(element(app, id: "selectAllButton-keep").exists, "keep section showed Select all")
        XCTAssertFalse(element(app, id: "skipAllButton-keep").exists, "keep section showed Skip all")
        attach(app, named: "skip-all-section")
    }
}
