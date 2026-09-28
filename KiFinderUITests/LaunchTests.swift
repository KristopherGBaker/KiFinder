import XCTest

final class LaunchTests: XCTestCase {
    private let timeout: TimeInterval = 15

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// A unique, fresh on-disk profile store inside the APP's own sandbox container (item
    /// 76). Combined with `KION_SEED_PROFILE=1`, the app persists an enrolled profile at
    /// launch and skips first-run enrollment, so the launch lands on Review rather
    /// than behind an `Enroll Kris` modal sheet.
    private func seededStoreArg() -> String {
        HarnessPaths.appWritable("launch-store").appendingPathComponent("store.json").path
    }

    private func makeApp(
        dark: Bool = false,
        dynamicType: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        // Seed an enrolled profile so launch lands on Review (no enrollment sheet).
        app.launchEnvironment["KION_PROFILE_STORE"] = seededStoreArg()
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        if let dynamicType {
            app.launchEnvironment["KION_DYNAMIC_TYPE"] = dynamicType
        }
        if dark {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        }
        return app
    }

    /// macOS surfaces SwiftUI text as the accessibility `value` (not `label`), so
    /// match across identifier, label, and value to stay robust to either mapping.
    private func element(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            string, string, string
        )
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func staticText(_ app: XCUIApplication, _ string: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            string, string, string
        )
        return app.descendants(matching: .staticText).matching(predicate).firstMatch
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

    /// Asserts the toolbar review title via its STABLE identifier (`review-title`)
    /// and confirms its visible copy is the person-parameterized "Review <name>
    /// candidates" — replacing the old query on the removed `Review Kris
    /// candidates` accessibility identifier.
    private func assertReviewTitle(
        _ app: XCUIApplication,
        person: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let title = byID(app, "review-title")
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "review-title missing", file: file, line: line)
        let text = title.label + " " + (title.value as? String ?? "")
        XCTAssertTrue(
            text.contains("Review \(person) candidates"),
            "review-title copy: \(text)",
            file: file,
            line: line
        )
    }

    private func assertExists(
        _ app: XCUIApplication,
        _ string: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element(app, string).waitForExistence(timeout: timeout),
            message,
            file: file,
            line: line
        )
    }

    /// Launch and bring the window forward; macOS XCUITest can otherwise miss the
    /// window until the app is explicitly activated.
    @discardableResult
    private func launch(_ app: XCUIApplication) -> Bool {
        app.launch()
        app.activate()
        let appeared = app.windows.firstMatch.waitForExistence(timeout: timeout)
        if appeared { app.zoomMainWindow() }
        return appeared
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openLightbox(_ app: XCUIApplication, fileName: String) {
        let tile = app.buttons[fileName]
        XCTAssertTrue(tile.waitForExistence(timeout: timeout), "tile \(fileName) missing")
        XCTAssertTrue(tile.isHittable, "tile \(fileName) not hittable")
        tile.click()
    }

    // MARK: - Review surface

    func testSampleReviewSurface() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        // Sidebar: the active person's row (stable id) carries the name.
        XCTAssertTrue(byID(app, "person-row-Kris").waitForExistence(timeout: timeout), "Kris row missing")
        assertExists(app, "Kris", "sidebar person name missing")
        assertExists(app, "Everything stays on your Mac", "privacy note missing")
        assertExists(app, "CURRENT SCAN", "current scan header missing")
        assertExists(app, "Sample Album", "current scan label missing")

        // Toolbar title + subtitle. Kris is the active person, so per-person
        // filtering shows just Kris's attributed candidates: one keep + one maybe.
        assertReviewTitle(app, person: "Kris")
        assertExists(
            app,
            "1 confident + 2 worth a look from 312 photos",
            "toolbar subtitle missing"
        )

        // Toolbar controls.
        for label in ["Keyboard", "Re-scan", "Export 1 Kept"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: timeout), "toolbar button \(label) missing")
            XCTAssertTrue(button.isHittable, "toolbar button \(label) not hittable")
        }

        // Both section headers; maybe section never auto-hidden. The keep bucket
        // header is now person-agnostic ("Found matches", was "Found her").
        assertExists(app, "Found matches", "keep header missing")
        assertExists(app, "Worth a look", "maybe header missing")

        // Representative keep + maybe tiles (Kris's attributed candidates).
        let keepTile = app.buttons["IMG_1842.PNG"]
        let maybeTile = app.buttons["IMG_1861.PNG"]
        XCTAssertTrue(keepTile.waitForExistence(timeout: timeout))
        XCTAssertTrue(maybeTile.waitForExistence(timeout: timeout))

        // Tile a11y label/value carry filename + bucket.
        let keepMeta = keepTile.label + " " + (keepTile.value as? String ?? "")
        XCTAssertTrue(keepMeta.contains("IMG_1842.PNG"), "keep tile meta: \(keepMeta)")
        XCTAssertTrue(keepMeta.contains("Found matches"), "keep tile meta: \(keepMeta)")
        let maybeMeta = maybeTile.label + " " + (maybeTile.value as? String ?? "")
        XCTAssertTrue(maybeMeta.contains("IMG_1861.PNG"), "maybe tile meta: \(maybeMeta)")
        XCTAssertTrue(maybeMeta.contains("Worth a look"), "maybe tile meta: \(maybeMeta)")

        // Representative tile target >= 44x44.
        XCTAssertGreaterThanOrEqual(keepTile.frame.width, 44)
        XCTAssertGreaterThanOrEqual(keepTile.frame.height, 44)

        // Activate keep tile -> inspector shows IMG_1842.PNG / 1 of 5: item 7 makes
        // every scanned photo visible under every person (Kris: keep IMG_1842, maybes
        // IMG_1861 + IMG_1888, then Ava's two in "The rest").
        openLightbox(app, fileName: "IMG_1842.PNG")
        XCTAssertTrue(staticText(app, "IMG_1842.PNG").waitForExistence(timeout: timeout))
        XCTAssertTrue(staticText(app, "1 of 5").waitForExistence(timeout: timeout))
        attach(app, named: "lightbox-keep")

        // Activate maybe tile -> inspector updates to IMG_1861.PNG / 2 of 5.
        openLightbox(app, fileName: "IMG_1861.PNG")
        XCTAssertTrue(staticText(app, "IMG_1861.PNG").waitForExistence(timeout: timeout))
        XCTAssertTrue(staticText(app, "2 of 5").waitForExistence(timeout: timeout))

        // Face box overlay present and queryable.
        XCTAssertTrue(byID(app, "lightboxFaceBox").waitForExistence(timeout: timeout))

        // Confidence chip exposes bucket + numeric score without hover.
        let chip = byID(app, "confidenceChip")
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        let chipText = chip.label + " " + (chip.value as? String ?? "")
        XCTAssertTrue(chipText.contains("Worth a look"), "chip missing bucket: \(chipText)")
        XCTAssertTrue(chipText.contains("0.68"), "chip missing score: \(chipText)")

        // Inspector controls hittable + >= 44x44.
        let skip = app.buttons["Skip"]
        let keep = app.buttons["Keep"]
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))
        XCTAssertTrue(keep.exists)
        XCTAssertTrue(skip.isHittable)
        XCTAssertTrue(keep.isHittable)
        XCTAssertGreaterThanOrEqual(skip.frame.width, 44)
        XCTAssertGreaterThanOrEqual(skip.frame.height, 44)
        XCTAssertGreaterThanOrEqual(keep.frame.width, 44)
        XCTAssertGreaterThanOrEqual(keep.frame.height, 44)

        // Keyboard hint.
        let hint = byID(app, "lightboxKeyboardHint")
        XCTAssertTrue(hint.waitForExistence(timeout: timeout))
        XCTAssertTrue(hint.isHittable, "keyboard hint not hittable")
        XCTAssertEqual(hint.label, "Left/right to move · Return to keep · Delete to skip")
    }

    // MARK: - Dark mode

    func testDarkLaunch() {
        let app = makeApp(dark: true)
        XCTAssertTrue(launch(app), "window did not appear in dark mode")

        assertExists(app, "Kris", "sidebar missing in dark mode")
        assertExists(app, "Found matches", "keep header missing in dark mode")
        assertExists(app, "Worth a look", "maybe header missing in dark mode")
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout))

        openLightbox(app, fileName: "IMG_1842.PNG")
        XCTAssertTrue(staticText(app, "1 of 5").waitForExistence(timeout: timeout))
        XCTAssertTrue(byID(app, "lightboxFaceBox").waitForExistence(timeout: timeout))
        attach(app, named: "dark-lightbox")
    }

    // MARK: - Dynamic Type

    func testDynamicTypeAccessibility5GrowsHeader() {
        let baseApp = makeApp()
        XCTAssertTrue(launch(baseApp), "base window did not appear")
        let baseHeader = staticText(baseApp, "Found matches")
        XCTAssertTrue(baseHeader.waitForExistence(timeout: timeout))
        let baseHeight = baseHeader.frame.height
        XCTAssertGreaterThan(baseHeight, 0)
        baseApp.terminate()

        let bigApp = makeApp(dynamicType: "accessibility5")
        XCTAssertTrue(launch(bigApp), "accessibility5 window did not appear")
        let bigHeader = staticText(bigApp, "Found matches")
        XCTAssertTrue(bigHeader.waitForExistence(timeout: timeout))
        let bigHeight = bigHeader.frame.height
        XCTAssertGreaterThanOrEqual(
            bigHeight,
            baseHeight * 1.15,
            "header did not grow >=15% (\(baseHeight) -> \(bigHeight))"
        )

        // Key controls remain visible and hittable at accessibility5.
        assertReviewTitle(bigApp, person: "Kris")
        let tile = bigApp.buttons["IMG_1842.PNG"]
        XCTAssertTrue(tile.waitForExistence(timeout: timeout))
        XCTAssertTrue(tile.isHittable)
        tile.click()
        let skip = bigApp.buttons["Skip"]
        let keep = bigApp.buttons["Keep"]
        XCTAssertTrue(skip.waitForExistence(timeout: timeout))
        XCTAssertTrue(skip.isHittable)
        XCTAssertTrue(keep.exists)
        XCTAssertTrue(keep.isHittable)
        attach(bigApp, named: "accessibility5")
    }
}
