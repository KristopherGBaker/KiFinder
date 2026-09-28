import XCTest

extension XCUIApplication {
    /// Zooms the main window to the display's visible frame (the standard
    /// Option-click on the green traffic light = "Zoom", never full screen).
    ///
    /// Why the harness needs it: a `KION_*` launch persists to an isolated defaults
    /// suite, so the app opens at its modest 1000 × 640 `defaultSize` instead of the
    /// window frame a real user last saved. The review grid is a `LazyVStack`, so
    /// sections below the fold ("The rest", "Skipped") are never built and their
    /// tiles are absent from the accessibility tree — a test that asserts on them
    /// would then depend on the window height rather than on app behavior. Zooming
    /// first makes the layout deterministic on any display large enough to run the
    /// suite.
    func zoomMainWindow() {
        let window = windows.firstMatch
        guard window.exists else { return }
        let before = window.frame
        // The main window's green traffic light is the full-screen button; Option-
        // clicking it performs Zoom (never full screen). Both identifiers are tried
        // because a plain (non-full-screen-capable) window exposes the zoom one.
        let green = window.buttons[XCUIIdentifierFullScreenWindow].exists
            ? window.buttons[XCUIIdentifierFullScreenWindow]
            : window.buttons[XCUIIdentifierZoomWindow]
        guard green.exists else { return }
        XCUIElement.perform(withKeyModifiers: .option) { green.click() }
        // Let the resize settle so subsequent queries see the final layout.
        let grew = NSPredicate { _, _ in
            let f = window.frame
            return f.width > before.width || f.height > before.height
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: grew, object: nil)], timeout: 3)
        // Hovering the traffic light opens macOS 26+'s window-tiling popover, which
        // stays up until something else is clicked — and while it is up it covers the
        // sidebar rows and swallows keystrokes (⌘, arrows). A click on the empty title
        // bar dismisses it without touching any control or the grid's key focus.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        let popoverGone = NSPredicate { _, _ in
            !self.menuItems["Full Screen"].exists
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: popoverGone, object: nil)], timeout: 3)
    }
}
