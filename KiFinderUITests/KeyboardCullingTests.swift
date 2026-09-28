import XCTest

/// Drives the keyboard-first review culling with Finder ergonomics (item 9):
/// focus ring, arrow navigation, Return=Keep, Delete/Backspace=Skip, Space=open
/// the full-size center preview (Space again or Esc closes it), immediate
/// count/export updates, idempotent + reversible decisions, and the
/// `KION_FEEDBACK_LOG` hook.
final class KeyboardCullingTests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Launch / helpers

    /// A unique feedback-log URL inside the APP's own sandbox container (item 76): on
    /// macOS 27 both the app and the runner are sandboxed to their own containers, so the
    /// log the APP writes must live where the app can write AND the runner can read — the
    /// app's container (fact 3). The path is unique per test, so no stale-run cleanup is
    /// needed (and the sandboxed runner couldn't perform one on the app's container
    /// anyway); the app creates the parent directory when it appends.
    private func feedbackLog() -> URL {
        HarnessPaths.appWritable("feedback").appendingPathComponent("feedback.log")
    }

    /// A unique, fresh on-disk profile store inside the APP's own sandbox container.
    /// Combined with `KION_SEED_PROFILE=1`, the app persists an enrolled profile at
    /// launch and therefore SKIPS first-run enrollment — landing directly on the
    /// keyboard-first Review surface instead of an `Enroll Kris` modal sheet that
    /// would otherwise cover Review and steal first responder from the grid.
    private func seededStoreArg() -> String {
        HarnessPaths.appWritable("keyboard-store").appendingPathComponent("store.json").path
    }

    private func makeApp(feedbackLog: URL?, reduceMotion: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        // Deterministic 2-column grid so arrow up/down land on the asserted tiles.
        app.launchEnvironment["KION_REVIEW_COLUMNS"] = "2"
        // Seed an enrolled profile so launch lands on Review (no enrollment sheet).
        app.launchEnvironment["KION_PROFILE_STORE"] = seededStoreArg()
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        if let feedbackLog {
            app.launchEnvironment["KION_FEEDBACK_LOG"] = feedbackLog.path
        }
        if reduceMotion {
            app.launchEnvironment["KION_REDUCE_MOTION"] = "1"
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

    private func assertExists(
        _ app: XCUIApplication,
        _ string: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            string, string, string
        )
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message, file: file, line: line)
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Polls `hasFocus` so a programmatic focus change has a beat to settle.
    @discardableResult
    private func waitForFocus(
        _ element: XCUIElement,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, Self.isFocused(element) { return true }
            usleep(80000)
        } while Date() < deadline
        XCTFail("focus not on element: \(message)", file: file, line: line)
        return false
    }

    /// macOS `XCUIElement` has no `hasFocus` (that is iOS/tvOS only), and
    /// `hasKeyboardFocus`/AXSelected do not surface reliably on a synthesized
    /// AXButton tile — especially after the tile re-parents into the Skipped
    /// section. The app therefore mirrors keyboard focus into the accessibility
    /// VALUE (a plain string macOS exposes dependably), so focus is observable on
    /// the tile queried by identifier no matter which section hosts it.
    private static func isFocused(_ element: XCUIElement) -> Bool {
        let value = (element.value as? String) ?? ""
        return element.label.contains("focused") || value.contains("focused")
    }

    private func feedbackLines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Polls the feedback log until a specific `photoKey,label` line appears
    /// exactly `expected` times (or the timeout elapses), returning the count.
    @discardableResult
    private func waitForFeedbackCount(
        at url: URL,
        line: String,
        expected: Int
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = 0
        repeat {
            count = feedbackLines(at: url).filter { $0 == line }.count
            if count == expected { return count }
            usleep(100_000)
        } while Date() < deadline
        return count
    }

    private func count(_ app: XCUIApplication, button identifier: String) -> Int {
        app.buttons.matching(identifier: identifier).count
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    // MARK: - Ordered keyboard culling

    func testKeyboardCulling() {
        let log = feedbackLog()
        let app = makeApp(feedbackLog: log)
        XCTAssertTrue(launch(app), "window did not appear")

        // Initial render: Review is filtered to the active person (Kris), who owns
        // three sample tiles — IMG_1842 (keep) + IMG_1861 (maybe) + IMG_1888 (the
        // both-people group photo, a maybe for Kris too). IMG_1851/IMG_1874 belong
        // only to the other person (Ava) and are not shown here.
        for name in ["IMG_1842.PNG", "IMG_1861.PNG", "IMG_1888.PNG"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: timeout), "tile \(name) missing")
        }
        assertExists(app, "1 confident + 2 worth a look from 312 photos", "initial subtitle missing")
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "initial export missing")
        attach(app, named: "keyboard-before")

        // Initial focus on the first tile.
        waitForFocus(app.buttons["IMG_1842.PNG"], "initial focus")

        // Right then left across the active person's tiles.
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "right -> IMG_1861")
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1842.PNG"], "left -> IMG_1842")

        // Down then up (2-column grid): the flat order is [IMG_1842, IMG_1861,
        // IMG_1888], so down from the first tile lands on the third (IMG_1888).
        app.typeKey(.downArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1888.PNG"], "down -> IMG_1888")
        app.typeKey(.upArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1842.PNG"], "up -> IMG_1842")

        // Focus IMG_1861.PNG, Return keeps it -> moves to "Found matches".
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "right -> IMG_1861 for keep")
        app.typeKey(.return, modifierFlags: [])
        assertExists(app, "2 confident + 1 worth a look from 312 photos", "subtitle after keep")
        XCTAssertTrue(app.buttons["Export 2 Kept"].waitForExistence(timeout: timeout), "export after keep")
        attach(app, named: "keyboard-after-keep")

        // Exactly one amber-path confirm recorded.
        XCTAssertEqual(
            waitForFeedbackCount(at: log, line: "sample/amber-path.png,confirm", expected: 1),
            1,
            "expected one amber-path confirm"
        )

        // Keeping advanced focus to the next photo to review (IMG_1888); navigate
        // back to the just-kept IMG_1861 to prove a repeated Return is idempotent.
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "left -> IMG_1861 for idempotent keep")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 2 Kept"].waitForExistence(timeout: timeout), "export unchanged on repeat")
        assertExists(app, "2 confident + 1 worth a look from 312 photos", "subtitle unchanged on repeat")
        // Give any erroneous second write a chance to land, then confirm still one.
        usleep(400_000)
        XCTAssertEqual(
            feedbackLines(at: log).filter { $0 == "sample/amber-path.png,confirm" }.count,
            1,
            "repeat Return produced a second confirm"
        )

        // Focus IMG_1842.PNG and Delete (forward delete) to skip it.
        app.typeKey(.upArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1842.PNG"], "up -> IMG_1842 for skip")
        app.typeKey(.forwardDelete, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "export after skip")
        attach(app, named: "keyboard-after-skip")

        XCTAssertEqual(
            waitForFeedbackCount(at: log, line: "sample/fern-window.png,reject", expected: 1),
            1,
            "expected one fern-window reject"
        )

        // Reversible re-keep. The skipped tile re-parents into the Skipped section
        // (last in the keep→maybe→skipped navigation order), so we NAVIGATE to it
        // via arrow keys rather than relying on focus being auto-retained across the
        // re-parent (that AX-on-reparent behavior is out of scope for this item).
        // Right-arrow clamps focus onto the final tile, so repeating it lands on the
        // skipped IMG_1842.PNG deterministically — and is robust to a dropped key.
        for _ in 0 ..< 5 {
            app.typeKey(.rightArrow, modifierFlags: [])
            usleep(60000)
        }
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 2 Kept"].waitForExistence(timeout: timeout), "export after re-keep")
        // The re-kept tile re-parents into "Found matches" at the TOP of the lazily
        // built grid while the view is scrolled to the Skipped section at the bottom,
        // so it is not materialized (nor in the accessibility tree) until scrolled
        // back into view. Scroll to the top before counting.
        // (Scroll at a point over the grid — `scrollViews.firstMatch` is the sidebar —
        // and try both wheel directions, since the sign convention is not documented.)
        let overGrid = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        overGrid.scroll(byDeltaX: 0, deltaY: 10_000)
        if !app.buttons["IMG_1842.PNG"].waitForExistence(timeout: 2) {
            overGrid.scroll(byDeltaX: 0, deltaY: -10_000)
        }
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout), "re-kept tile not materialized")
        XCTAssertEqual(count(app, button: "IMG_1842.PNG"), 1, "duplicate IMG_1842 tile")
        let reKept = app.buttons["IMG_1842.PNG"]
        let reKeptValue = (reKept.value as? String ?? "") + " " + reKept.label
        XCTAssertTrue(reKeptValue.contains("Found matches"), "re-kept tile not in Found matches: \(reKeptValue)")
    }

    // MARK: - Space = full Quick Look-style center preview (item 9)

    func testSpaceOpensCenterPreviewWithLiveInspector() {
        let app = makeApp(feedbackLog: nil)
        XCTAssertTrue(launch(app), "window did not appear")

        waitForFocus(app.buttons["IMG_1842.PNG"], "initial focus")

        // Space opens the full-size center preview over the grid; the right
        // inspector stays mounted with its keep/skip actions.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            element(app, id: "photoPreview").waitForExistence(timeout: timeout),
            "Space did not open the center preview"
        )
        XCTAssertTrue(app.buttons["Keep"].waitForExistence(timeout: timeout), "inspector Keep missing during preview")
        XCTAssertTrue(app.buttons["Skip"].exists, "inspector Skip missing during preview")
        // The grid is taken over while the preview is up.
        XCTAssertTrue(
            app.buttons["IMG_1842.PNG"].waitForNonExistence(timeout: timeout),
            "grid tile still present under preview"
        )
        attach(app, named: "preview-open")

        // Space again closes the preview and brings the grid back.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(
            element(app, id: "photoPreview").waitForNonExistence(timeout: timeout),
            "Space did not close the preview"
        )
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout), "grid did not return")

        // Esc also closes the preview.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(element(app, id: "photoPreview").waitForExistence(timeout: timeout), "preview reopen failed")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            element(app, id: "photoPreview").waitForNonExistence(timeout: timeout),
            "Esc did not close the preview"
        )
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout), "grid did not return after Esc")
    }

    // MARK: - Return = keep, Delete = skip (Finder ergonomics)

    func testReturnKeepsDeleteSkips() {
        let log = feedbackLog()
        let app = makeApp(feedbackLog: log)
        XCTAssertTrue(launch(app), "window did not appear")

        waitForFocus(app.buttons["IMG_1842.PNG"], "initial focus")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "right -> IMG_1861")

        // Return keeps the focused "Worth a look" tile.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 2 Kept"].waitForExistence(timeout: timeout), "export after Return keep")
        XCTAssertEqual(
            waitForFeedbackCount(at: log, line: "sample/amber-path.png,confirm", expected: 1),
            1,
            "expected one amber-path confirm from Return"
        )

        // Delete skips the remaining keep, dropping the export back to one.
        app.typeKey(.upArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1842.PNG"], "up -> IMG_1842 for skip")
        app.typeKey(.forwardDelete, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "export after Delete skip")
        XCTAssertEqual(
            waitForFeedbackCount(at: log, line: "sample/fern-window.png,reject", expected: 1),
            1,
            "expected one fern-window reject from Delete"
        )
    }

    // MARK: - Backspace skip (fresh launch)

    func testBackspaceSkips() {
        let log = feedbackLog()
        let app = makeApp(feedbackLog: log)
        XCTAssertTrue(launch(app), "window did not appear")

        waitForFocus(app.buttons["IMG_1842.PNG"], "initial focus")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "right -> IMG_1861")

        // ⌫ Backspace skips the focused "Worth a look" tile; the lone keep remains.
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "export after backspace skip")

        XCTAssertEqual(
            waitForFeedbackCount(at: log, line: "sample/amber-path.png,reject", expected: 1),
            1,
            "expected one amber-path reject"
        )
    }

    // MARK: - Reduce motion

    func testReduceMotionDecisionStillCompletes() {
        let log = feedbackLog()
        let app = makeApp(feedbackLog: log, reduceMotion: true)
        XCTAssertTrue(launch(app), "window did not appear under reduce motion")

        waitForFocus(app.buttons["IMG_1842.PNG"], "initial focus (reduce motion)")
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForFocus(app.buttons["IMG_1861.PNG"], "right -> IMG_1861 (reduce motion)")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            app.buttons["Export 2 Kept"].waitForExistence(timeout: timeout),
            "keep did not complete under reduce motion"
        )
        attach(app, named: "keyboard-reduce-motion-after-keep")
    }
}
