import XCTest

/// Item 78 regression guard for the exact squeeze the user hit: the review actions
/// used to live in an in-content capsule that needed ~600 pt but only got the
/// detail column's ~340–530 pt at the 1000 × 640 default window size, so the "Hide
/// reviewed" label wrapped one syllable per line and every button truncated.
///
/// Moving them into the native window `.toolbar` (which spans the whole window and
/// overflows to a menu itself) fixes it. This is the ONE UI test that deliberately
/// does NOT call `zoomMainWindow()`: it must observe the app at its unzoomed
/// 1000 × 640 `defaultSize`, which is precisely the size the regression appeared at.
/// A unique `KION_DEFAULTS_SUITE` guarantees no previously-saved window geometry (or
/// any other preference) can leak in and open the window at some other size.
final class ReviewToolbarLayoutTests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A fresh on-disk profile store inside the APP's own sandbox container (item 76),
    /// so `KION_SEED_PROFILE=1` lands the launch directly on Review (no enroll sheet).
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_PROFILE_STORE"] = HarnessPaths.appWritable("layout-store")
            .appendingPathComponent("store.json").path
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        // A UNIQUE isolated defaults suite: no persisted window frame (or any other
        // preference) can leak in, so the window opens at the pristine `.defaultSize`.
        app.launchEnvironment["KION_DEFAULTS_SUITE"] = "com.krisbaker.KiFinder.layout.\(UUID().uuidString)"
        return app
    }

    /// Launch WITHOUT `zoomMainWindow()` — see the class comment. Just bring the
    /// window forward so XCUITest can see it.
    @discardableResult
    private func launch(_ app: XCUIApplication) -> Bool {
        app.launch()
        app.activate()
        return app.windows.firstMatch.waitForExistence(timeout: timeout)
    }

    /// The review title now surfaces as a `StaticText` in the window's toolbar (item
    /// 78 — `navigationTitle`, which can't carry an accessibility id). Match it by its
    /// visible copy, scoped to the main window's toolbar with a window fallback.
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

    /// Drags the window's bottom-right corner so its frame becomes ~1000 × 640, and
    /// waits for the resize to settle. A no-op when the window is already that size.
    private func shrinkToDefaultSize(_ window: XCUIElement) {
        let frame = window.frame
        let dx = 1000 - frame.width
        let dy = 640 - frame.height
        guard abs(dx) > 10 || abs(dy) > 10 else { return }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: dx, dy: dy)))
        let settled = NSPredicate { _, _ in
            let f = window.frame
            return abs(f.width - 1000) <= 20 && abs(f.height - 640) <= 20
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5)
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testReviewActionsFitInToolbarAtDefaultWindowSize() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        // The window opened at the unzoomed default size (a restored or zoomed window
        // would fail here and invalidate the layout assertions below).
        let window = app.windows.firstMatch
        // The window opens at whatever frame the app last autosaved (a zoomed one, after
        // the other tests). Bring it to the 1000 × 640 default the way a user would —
        // drag the bottom-right resize corner — then verify the layout at that size.
        shrinkToDefaultSize(window)
        let frame = window.frame
        XCTAssertTrue(
            (980...1020).contains(frame.width),
            "window width \(frame.width) is not the ~1000 pt default (window was restored or zoomed)"
        )
        XCTAssertTrue(
            (620...660).contains(frame.height),
            "window height \(frame.height) is not the ~640 pt default (window was restored or zoomed)"
        )

        // The title is native window chrome and names the active person.
        let title = reviewTitleElement(app)
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "review title missing from window toolbar")
        let titleText = title.label + " " + (title.value as? String ?? "")
        XCTAssertTrue(
            titleText.contains("Review Kris candidates"),
            "window title copy: \(titleText)"
        )

        // Every review action is a native toolbar item that macOS laid out across the
        // full window width — at 1000 pt they all fit, so each is present AND hittable
        // (an item overflowed into the toolbar's "more" menu would NOT be hittable).
        for id in ["hideReviewedToggle", "Keyboard", "Re-scan", "Export 1 Kept"] {
            let control = app.descendants(matching: .any).matching(identifier: id).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: timeout), "toolbar item \(id) missing")
            XCTAssertTrue(control.isHittable, "toolbar item \(id) not hittable (overflowed?)")
        }

        // The old capsule wrapped the "Hide reviewed" switch label one syllable per
        // line (17 pt wide, 112 pt tall). As a native toolbar toggle button it stays a
        // compact single-line control: comfortably wide, never vertically stacked.
        let toggle = app.descendants(matching: .any).matching(identifier: "hideReviewedToggle").firstMatch
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 24, "Hide reviewed toggle too narrow: \(toggle.frame)")
        XCTAssertLessThanOrEqual(toggle.frame.height, 44, "Hide reviewed toggle wrapped vertically: \(toggle.frame)")

        attach(app, named: "review-toolbar-default-size")
    }
}
