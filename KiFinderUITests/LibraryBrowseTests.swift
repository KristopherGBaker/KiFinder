import XCTest

/// Item-18b/26a on-device flow: the sidebar **Library** destination swaps the detail
/// pane to `LibraryBrowseView`; a seeded library index renders a review-style saved photo
/// cell; clicking it FOCUSES (does not auto-open), Space opens the full photo IN-PLACE
/// (`libraryFullSizePreview`), and Esc/Back returns to the grid; an empty library shows
/// the empty state; and selecting a person returns to Review.
final class LibraryBrowseTests: XCTestCase {
    private let timeout: TimeInterval = 20

    /// A 1×1 PNG (decodable by ImageIO, so the thumbnail/viewer downsample succeeds).
    private let onePxPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A runner-authored SEED directory (item 76). On macOS 27 the app and the runner are
    /// sandboxed to their own containers: the runner can't write the app's container and
    /// the app can't write the runner's. So the runner STAGES the library tree here (in its
    /// own temp) and the app copies it into `KION_LIBRARY_ROOT` (its own container) via the
    /// `KION_LIBRARY_SEED_DIR` hook — where the app can then READ and WRITE it (Delete
    /// rewrites the index).
    private func seedDir(_ tag: String) -> URL {
        HarnessPaths.runnerWritable(tag)
    }

    /// The app's library ROOT + INDEX inside its own container (NOT pre-created — the app
    /// creates the parents and the seed copy lands here). When `seedDir` is non-nil, the app
    /// replaces the root's contents with a copy of that seed before the library loads.
    private func makeApp(libraryRoot: URL, indexURL: URL, seedDir: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["KION_SAMPLE"] = "1"
        app.launchEnvironment["KION_SEED_PROFILE"] = "1"
        app.launchEnvironment["KION_PROFILE_STORE"] = HarnessPaths.appWritable("library-store")
            .appendingPathComponent("store.json").path
        app.launchEnvironment["KION_LIBRARY_ROOT"] = libraryRoot.path
        app.launchEnvironment["KION_LIBRARY_INDEX"] = indexURL.path
        if let seedDir {
            app.launchEnvironment["KION_LIBRARY_SEED_DIR"] = seedDir.path
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

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        // Item 78: the review title is native window chrome (`navigationTitle`), which
        // cannot carry an accessibility identifier, so it surfaces as a `StaticText`
        // in the window's toolbar. Locate it by its visible copy, scoped to the main
        // window's toolbar and falling back to the window's own static texts if the
        // toolbar query is empty on this OS. Window-scoped (never `app.descendants`)
        // so the "Review" command menu in the menu bar can't shadow it.
        if id == "review-title" {
            // (A fresh NSPredicate per query: it is not Sendable, so reusing one across
            // two XCUIElementQuery builds trips Swift 6's region-isolation check.)
            func titlePredicate() -> NSPredicate {
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Review", "Review")
            }
            let window = app.windows.firstMatch
            let inToolbar = window.toolbars.firstMatch.staticTexts.matching(titlePredicate()).firstMatch
            return inToolbar.exists ? inToolbar : window.staticTexts.matching(titlePredicate()).firstMatch
        }
        return app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Writes a one-entry library index (hand-built JSON matching `KeptEntry`'s default
    /// `Codable` shape) and the backing image file under `root`.
    private func seedLibrary(root: URL, index: URL, sha: String, path: String) throws {
        let fileURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try XCTUnwrap(Data(base64Encoded: onePxPNG))
        try bytes.write(to: fileURL)

        // Default JSONEncoder dates are `timeIntervalSinceReferenceDate` (Double).
        let capture = Date(timeIntervalSince1970: 1_626_350_400).timeIntervalSinceReferenceDate // 2021-07-15
        let entry: [String: Any] = [
            "sha256": sha,
            "subjectId": "Kris",
            "personName": "Kris",
            "path": path,
            "sourcePath": "/src/IMG_1.jpg",
            "score": 0.91,
            "captureDate": capture,
            "savedAt": capture,
            "fileName": (path as NSString).lastPathComponent,
        ]
        let data = try JSONSerialization.data(withJSONObject: [entry])
        try data.write(to: index)
    }

    func testLibrarySidebarOpensBrowseAndInPlacePreview() throws {
        let seed = seedDir("seed")
        let sha = "abc12345def67890"
        // Author the seed in the runner's container; the app copies it into its own root.
        try seedLibrary(root: seed, index: seed.appendingPathComponent("library-index.json"), sha: sha, path: "Kris/2021-07/IMG_1.jpg")
        let root = HarnessPaths.appWritable("root")
        let index = root.appendingPathComponent("library-index.json")

        let app = makeApp(libraryRoot: root, indexURL: index, seedDir: seed)
        XCTAssertTrue(launch(app), "window did not appear")

        // Sidebar Library destination swaps the detail pane to the browse view.
        let libraryButton = element(app, id: "librarySidebarButton")
        XCTAssertTrue(libraryButton.waitForExistence(timeout: timeout), "librarySidebarButton missing")
        libraryButton.click()

        XCTAssertTrue(element(app, id: "libraryBrowseView").waitForExistence(timeout: timeout), "libraryBrowseView missing")

        // The seeded photo renders as a review-style cell (id = the entry id "<subject>/<sha>").
        let cell = element(app, id: "libraryPhoto-Kris/\(sha)")
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "library photo cell missing")
        attach(app, named: "library-browse")

        // Click FOCUSES the cell (it does NOT auto-open a viewer); Space opens the full
        // photo IN-PLACE over the grid region.
        cell.click()
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(element(app, id: "libraryFullSizePreview").waitForExistence(timeout: timeout), "in-place preview missing")
        attach(app, named: "library-in-place-preview")

        // The Back affordance returns to the grid (the cell is queryable again).
        let back = element(app, id: "libraryBackButton")
        XCTAssertTrue(back.waitForExistence(timeout: timeout), "libraryBackButton missing")
        back.click()
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "did not return to the grid")
    }

    /// Writes a multi-entry library index (review-style grid) so the Delete-key flow has a
    /// re-seat target. Each entry shares the subject "Kris" but carries a distinct sha /
    /// path / capture date (descending ⇒ a deterministic display order).
    private func seedLibrary(root: URL, index: URL, count: Int) throws -> [(sha: String, path: String)] {
        var entries: [[String: Any]] = []
        var out: [(sha: String, path: String)] = []
        let bytes = try XCTUnwrap(Data(base64Encoded: onePxPNG))
        for i in 0 ..< count {
            let sha = "sha\(i)0000000000"
            let path = "Kris/2021-07/IMG_\(i).png"
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: fileURL)
            // Descending capture date ⇒ IMG_0 first in the grid order.
            let capture = Date(timeIntervalSince1970: 1_626_350_400 - Double(i) * 86400).timeIntervalSinceReferenceDate
            entries.append([
                "sha256": sha,
                "subjectId": "Kris",
                "personName": "Kris",
                "path": path,
                "sourcePath": "/src/IMG_\(i).png",
                "score": 0.91,
                "captureDate": capture,
                "savedAt": capture,
                "fileName": (path as NSString).lastPathComponent,
            ])
            out.append((sha: sha, path: path))
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: index)
        return out
    }

    func testDeleteKeyRemovesFocusedCellWithConfirmation() throws {
        let seed = seedDir("seed")
        let seeded = try seedLibrary(root: seed, index: seed.appendingPathComponent("library-index.json"), count: 2)
        let root = HarnessPaths.appWritable("root")
        let index = root.appendingPathComponent("library-index.json")

        let app = makeApp(libraryRoot: root, indexURL: index, seedDir: seed)
        XCTAssertTrue(launch(app), "window did not appear")
        element(app, id: "librarySidebarButton").click()
        XCTAssertTrue(element(app, id: "libraryBrowseView").waitForExistence(timeout: timeout), "libraryBrowseView missing")

        let firstCell = element(app, id: "libraryPhoto-Kris/\(seeded[0].sha)")
        let secondCell = element(app, id: "libraryPhoto-Kris/\(seeded[1].sha)")
        XCTAssertTrue(firstCell.waitForExistence(timeout: timeout), "first cell missing")
        XCTAssertTrue(secondCell.waitForExistence(timeout: timeout), "second cell missing")

        // Focus the first cell and press Delete → a confirmation appears.
        firstCell.click()
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let confirm = element(app, id: "confirmRemoveFromLibraryButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "remove confirmation missing")
        attach(app, named: "library-delete-confirm")

        // Confirm → the focused photo is removed; the second remains.
        confirm.click()
        XCTAssertTrue(waitForDisappearance(firstCell), "removed cell still present")
        XCTAssertTrue(secondCell.waitForExistence(timeout: timeout), "surviving cell missing")
    }

    func testDeleteCancelKeepsTheCell() throws {
        let seed = seedDir("seed")
        let seeded = try seedLibrary(root: seed, index: seed.appendingPathComponent("library-index.json"), count: 2)
        let root = HarnessPaths.appWritable("root")
        let index = root.appendingPathComponent("library-index.json")

        let app = makeApp(libraryRoot: root, indexURL: index, seedDir: seed)
        XCTAssertTrue(launch(app), "window did not appear")
        element(app, id: "librarySidebarButton").click()
        XCTAssertTrue(element(app, id: "libraryBrowseView").waitForExistence(timeout: timeout), "libraryBrowseView missing")

        let firstCell = element(app, id: "libraryPhoto-Kris/\(seeded[0].sha)")
        XCTAssertTrue(firstCell.waitForExistence(timeout: timeout), "first cell missing")

        // Focus + Delete opens the confirmation; CANCEL preserves the photo.
        firstCell.click()
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        let cancelButton = element(app, id: "cancelRemoveFromLibraryButton")
        XCTAssertTrue(cancelButton.waitForExistence(timeout: timeout), "Cancel button missing")
        cancelButton.click()

        // Both cells survive — Cancel removed nothing.
        XCTAssertTrue(firstCell.waitForExistence(timeout: timeout), "focused cell wrongly removed on Cancel")
        XCTAssertTrue(element(app, id: "libraryPhoto-Kris/\(seeded[1].sha)").exists, "second cell missing after Cancel")
    }

    func testPreviewExposesRemoveAndRevealControls() throws {
        let seed = seedDir("seed")
        let seeded = try seedLibrary(root: seed, index: seed.appendingPathComponent("library-index.json"), count: 2)
        let root = HarnessPaths.appWritable("root")
        let index = root.appendingPathComponent("library-index.json")

        let app = makeApp(libraryRoot: root, indexURL: index, seedDir: seed)
        XCTAssertTrue(launch(app), "window did not appear")
        element(app, id: "librarySidebarButton").click()

        let cell = element(app, id: "libraryPhoto-Kris/\(seeded[0].sha)")
        XCTAssertTrue(cell.waitForExistence(timeout: timeout), "cell missing")
        cell.click()
        app.typeKey(.space, modifierFlags: [])

        let preview = element(app, id: "libraryFullSizePreview")
        XCTAssertTrue(preview.waitForExistence(timeout: timeout), "in-place preview missing")

        // Reveal + Remove are present SCOPED UNDER the preview (not just the grid cells).
        let revealInPreview = preview.descendants(matching: .any).matching(identifier: "libraryRevealButton").firstMatch
        let removeInPreview = preview.descendants(matching: .any).matching(identifier: "removeFromLibraryButton").firstMatch
        XCTAssertTrue(revealInPreview.waitForExistence(timeout: timeout), "preview Reveal control missing")
        XCTAssertTrue(removeInPreview.waitForExistence(timeout: timeout), "preview Remove control missing")
        attach(app, named: "library-preview-controls")

        // Remove from the preview → confirm → the preview closes back to the grid.
        removeInPreview.click()
        let confirm = element(app, id: "confirmRemoveFromLibraryButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "remove confirmation missing")
        confirm.click()
        XCTAssertTrue(waitForDisappearance(preview), "preview did not close after remove")
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testEmptyLibraryShowsEmptyStateAndPersonReturnsToReview() {
        let root = HarnessPaths.appWritable("root")
        // No seed and a non-existent index ⇒ the library loads empty. The root need not
        // exist yet (item 76).
        let index = root.appendingPathComponent("missing-index.json")

        let app = makeApp(libraryRoot: root, indexURL: index)
        XCTAssertTrue(launch(app), "window did not appear")

        element(app, id: "librarySidebarButton").click()
        XCTAssertTrue(element(app, id: "libraryEmptyState").waitForExistence(timeout: timeout), "libraryEmptyState missing")
        attach(app, named: "library-empty")

        // Selecting a person returns to Review.
        let person = element(app, id: "person-row-Kris")
        XCTAssertTrue(person.waitForExistence(timeout: timeout), "person row missing")
        person.click()
        XCTAssertTrue(element(app, id: "review-title").waitForExistence(timeout: timeout), "did not return to Review")
    }
}
