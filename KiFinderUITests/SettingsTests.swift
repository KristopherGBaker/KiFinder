import XCTest

/// The Settings "Photos at a time" scan-concurrency picker (item 75, owed; delivered
/// here with item 76). Launches in sample mode with a seeded profile so the app lands on
/// Review (no first-run enrollment sheet), opens the Settings scene with ⌘, and asserts
/// the picker + its caption are present by their OWN stable identifiers — reachable only
/// because item 76 removed the `Form`-level `librarySettings` identifier that on macOS 27
/// cascaded onto (and shadowed) every descendant. Existence + copy is the contract; the
/// popup menu's VALUE is deliberately not driven (a macOS `PopUpButton` menu is brittle
/// under XCUITest).
final class SettingsTests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A seeded profile store in the APP's own sandbox container (item 76), so the app
    /// persists an enrolled roster at launch and lands on Review rather than behind the
    /// mandatory first-run enrollment sheet.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_PROFILE_STORE"] = HarnessPaths.appWritable("settings-store")
            .appendingPathComponent("store.json").path
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

    private func byID(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSettingsScanWorkersPickerAndCaption() {
        let app = makeApp()
        XCTAssertTrue(launch(app), "window did not appear")

        // Open the Settings scene (⌘,). The picker lives in the library settings Form.
        app.typeKey(",", modifierFlags: .command)

        // The Picker surfaces as a descendant queryable by its OWN identifier (the
        // container `librarySettings` id was removed in item 76 to stop it cascading).
        let picker = byID(app, "scanWorkersPicker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: timeout),
            "Settings window / scanWorkersPicker did not appear within \(Int(timeout))s"
        )

        // The caption is present and its visible copy (label OR value — macOS surfaces
        // SwiftUI Text as the accessibility value) describes the resolved worker count.
        let caption = byID(app, "scanWorkersCaption")
        XCTAssertTrue(caption.waitForExistence(timeout: timeout), "scanWorkersCaption missing")
        let text = caption.label + " " + (caption.value as? String ?? "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("Scanning "), "caption copy did not start with 'Scanning ': \(text)")
        XCTAssertTrue(text.contains("photos at a time"), "caption copy missing 'photos at a time': \(text)")

        attach(app, named: "settings-scan-workers")
    }
}
