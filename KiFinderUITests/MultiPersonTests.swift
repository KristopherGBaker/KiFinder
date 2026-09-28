import XCTest

/// Multi-person UI coverage (item 5). With `KION_SAMPLE=1` the app enrolls two
/// people — "Kris" (active) and "Ava" — each with their own attributed sample
/// candidates. These tests assert the sidebar shows both rows with names, that
/// selecting Ava makes her active (review title + visible candidate set update),
/// and that a renamed person's name survives a relaunch against the same store.
///
/// Stable, name-/locale-independent identifiers only: rows are queried by
/// `person-row-<id>` (the engine subject id, never the display name), titles by
/// `review-title`, and the display name is asserted as visible copy.
final class MultiPersonTests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Fixtures

    /// A fresh on-disk profile store inside the APP's own sandbox container (item 76):
    /// on macOS 27 the sandboxed app can write only its container, and the runner can
    /// still read it there. The app creates the parents itself.
    private func storeArg() -> String {
        HarnessPaths.appWritable("multiperson-store").appendingPathComponent("store.json").path
    }

    /// `KION_SAMPLE=1` enrolls BOTH sample people (Kris + Ava), so launch lands
    /// directly on a genuinely multi-person Review (no first-run enrollment sheet).
    private func makeApp(store: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_PROFILE_STORE"] = store
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

    private func byID(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        // Item 78: the review title/subtitle are native window chrome
        // (`navigationTitle`/`navigationSubtitle`), which cannot carry an
        // accessibility identifier, so they surface as `StaticText`s in the window's
        // toolbar. Locate the title by its visible copy, scoped to the main window's
        // toolbar and falling back to the window's own static texts if the toolbar
        // query is empty on this OS. Window-scoped (never `app.descendants`) so the
        // "Review" command menu in the menu bar can't shadow it.
        if identifier == "review-title" {
            // (A fresh NSPredicate per query: it is not Sendable, so reusing one across
            // two XCUIElementQuery builds trips Swift 6's region-isolation check.)
            func titlePredicate() -> NSPredicate {
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review", "Review")
            }
            let window = app.windows.firstMatch
            let inToolbar = window.toolbars.firstMatch.staticTexts.matching(titlePredicate()).firstMatch
            return inToolbar.exists ? inToolbar : window.staticTexts.matching(titlePredicate()).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Combined label+value text of the toolbar `review-title` (macOS surfaces
    /// SwiftUI `Text` content as the accessibility value).
    private func reviewTitleText(_ app: XCUIApplication) -> String {
        let title = byID(app, "review-title")
        guard title.exists else { return "" }
        return title.label + " " + (title.value as? String ?? "")
    }

    /// Polls the `review-title` until its visible copy names the expected person.
    @discardableResult
    private func waitForReviewTitle(
        _ app: XCUIApplication,
        person: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let title = byID(app, "review-title")
        let expected = "Review \(person) candidates"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if title.exists, reviewTitleText(app).contains(expected) { return true }
            usleep(120_000)
        } while Date() < deadline
        XCTFail("review-title never named \(person) (got: \(reviewTitleText(app)))", file: file, line: line)
        return false
    }

    private func hasVisibleText(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            string, string, string
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Two rows + switching

    func testTwoPeopleRowsAndSwitchingChangesReview() {
        let app = makeApp(store: storeArg())
        XCTAssertTrue(launch(app), "window did not appear")

        // The people section lists BOTH rows by their stable subject-id ids.
        XCTAssertTrue(byID(app, "people-section").waitForExistence(timeout: timeout), "people section missing")
        let krisRow = byID(app, "person-row-Kris")
        let avaRow = byID(app, "person-row-Ava")
        XCTAssertTrue(krisRow.waitForExistence(timeout: timeout), "Kris row missing")
        XCTAssertTrue(avaRow.waitForExistence(timeout: timeout), "Ava row missing")

        // Each row carries a name label, and both display names are visible.
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "person-name").count,
            2,
            "expected a person-name label per row"
        )
        XCTAssertTrue(hasVisibleText(app, "Kris").waitForExistence(timeout: timeout), "Kris name missing")
        XCTAssertTrue(hasVisibleText(app, "Ava").waitForExistence(timeout: timeout), "Ava name missing")

        // Kris is the default active person: title names Kris and their keep tile
        // (IMG_1842) shows in "Found matches". Item 7 makes every scanned photo
        // visible under every person, so Ava's match (IMG_1851) is also present —
        // it now lands in Kris's "The rest", not hidden.
        waitForReviewTitle(app, person: "Kris")
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout), "Kris keep tile missing")
        XCTAssertTrue(
            app.buttons["IMG_1851.PNG"].waitForExistence(timeout: timeout),
            "Ava's candidate should be visible in Kris's 'The rest' (item 7)"
        )
        attach(app, named: "multiperson-kion-active")

        // Select Ava -> she becomes the active person.
        XCTAssertTrue(avaRow.isHittable, "Ava row not hittable")
        avaRow.click()

        // Title updates to Ava and her keep tile (IMG_1851) now leads "Found
        // matches". Sectioning is per-person, but every scanned photo stays visible:
        // Kris's match (IMG_1842) is still present — now in Ava's "The rest".
        waitForReviewTitle(app, person: "Ava")
        XCTAssertTrue(app.buttons["IMG_1851.PNG"].waitForExistence(timeout: timeout), "Ava keep tile missing")
        XCTAssertTrue(
            app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout),
            "Kris's candidate should remain visible in Ava's 'The rest' (item 7)"
        )
        attach(app, named: "multiperson-ava-active")
    }

    // MARK: - Rename persists across relaunch

    func testRenamedPersonNamePersistsAcrossRelaunch() {
        let store = storeArg()
        let app = makeApp(store: store)
        XCTAssertTrue(launch(app), "window did not appear")

        // Kris's row (stable id) hosts the first rename affordance.
        XCTAssertTrue(byID(app, "person-row-Kris").waitForExistence(timeout: timeout), "Kris row missing")
        let rename = app.buttons.matching(identifier: "rename-person").firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: timeout), "rename button missing")
        rename.click()

        // Replace the prefilled name and commit with Return.
        let field = app.textFields.matching(identifier: "rename-person-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "rename field missing")
        field.click()
        field.typeKey("a", modifierFlags: .command) // select-all
        field.typeText("Kiana\n")

        // The id stays stable (person-row-Kris); only the visible name changes.
        XCTAssertTrue(byID(app, "person-row-Kris").waitForExistence(timeout: timeout), "row id changed after rename")
        XCTAssertTrue(hasVisibleText(app, "Kiana").waitForExistence(timeout: timeout), "renamed name not shown")
        attach(app, named: "multiperson-renamed")
        app.terminate()

        // Relaunch against the SAME store (no reset): the rename persisted.
        let relaunch = makeApp(store: store)
        XCTAssertTrue(launch(relaunch), "relaunch window did not appear")
        XCTAssertTrue(byID(relaunch, "person-row-Kris").waitForExistence(timeout: timeout), "Kris row missing on relaunch")
        XCTAssertTrue(
            hasVisibleText(relaunch, "Kiana").waitForExistence(timeout: timeout),
            "renamed name did not persist across relaunch"
        )
        attach(relaunch, named: "multiperson-renamed-relaunch")
    }
}
