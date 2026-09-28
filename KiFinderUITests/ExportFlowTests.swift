import XCTest

/// Drives the export flow: keep a candidate via the keyboard, export the kept set
/// to a folder, and confirm the success summary. The export destination is the
/// unsandboxed app's to write (the XCUITest runner is sandboxed and can't read
/// it), so verification is the app-reported count — which the engine only
/// increments after confirming each copy is byte-identical to its source.
final class ExportFlowTests: XCTestCase {
    private let timeout: TimeInterval = 30

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func makeApp(exportDest: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        // App-written store lives in the app's own sandbox container (item 76); the app
        // creates the parents itself.
        app.launchEnvironment["KION_PROFILE_STORE"] = HarnessPaths.appWritable("export-store")
            .appendingPathComponent("store.json").path
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        // Deterministic 2-column grid for arrow navigation.
        app.launchEnvironment["KION_REVIEW_COLUMNS"] = "2"
        // Export straight to this dir (no system folder picker under XCUITest).
        app.launchEnvironment["KION_EXPORT_DEST"] = exportDest
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

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testExportKeptToFolderShowsSuccess() {
        // Export destination the APP writes: its own container, NOT pre-created — the
        // sandboxed runner can't make it, and the export path creates it (item 76).
        let dest = HarnessPaths.appWritable("export-dest").path
        let app = makeApp(exportDest: dest)
        XCTAssertTrue(launch(app), "window did not appear")

        // The active person (Kris) starts with one confident candidate; keep a
        // second via the keyboard. (Review is filtered to the active person.)
        XCTAssertTrue(app.buttons["IMG_1842.PNG"].waitForExistence(timeout: timeout), "grid not loaded")
        XCTAssertTrue(app.buttons["Export 1 Kept"].waitForExistence(timeout: timeout), "initial export label wrong")
        app.typeKey(.downArrow, modifierFlags: []) // focus a "Worth a look" tile
        app.typeKey(.return, modifierFlags: []) // Return keeps it -> 2 kept

        // The export control reflects the new count.
        let exportButton = element(app, "Export 2 Kept")
        XCTAssertTrue(exportButton.waitForExistence(timeout: timeout), "export button did not update to 3")
        attach(app, named: "export-before")
        exportButton.click()

        // Choose "Export to Folder…" from the destination chooser.
        let folderItem = element(app, "Export to Folder…")
        XCTAssertTrue(folderItem.waitForExistence(timeout: timeout), "Export to Folder option missing")
        folderItem.click()

        // Success summary reports the byte-verified count.
        assertExists(app, "export-success", "export success summary missing")
        assertExists(app, "Exported 2 photos", "export count not shown")
        attach(app, named: "export-success")
    }

    func testExportMenuOffersBothDestinations() {
        // Export destination the APP writes: its own container, NOT pre-created — the
        // sandboxed runner can't make it, and the export path creates it (item 76).
        let dest = HarnessPaths.appWritable("export-dest").path
        let app = makeApp(exportDest: dest)
        XCTAssertTrue(launch(app), "window did not appear")

        let exportButton = element(app, "Export 1 Kept")
        XCTAssertTrue(exportButton.waitForExistence(timeout: timeout), "export button missing")
        exportButton.click()

        XCTAssertTrue(element(app, "Export to Folder…").waitForExistence(timeout: timeout), "folder option missing")
        XCTAssertTrue(element(app, "Add to Photos").waitForExistence(timeout: timeout), "photos option missing")
    }
}
