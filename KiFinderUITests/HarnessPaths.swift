import Foundation

/// The one place the UI-test harness encodes the macOS-27 sandbox layout (item 76).
///
/// VERIFIED sandbox facts (probed on macOS 27.0 / Xcode 27.0 27A266a; design
/// against these, do not re-derive):
///
///  1. The XCUITest **runner** is now App-Sandboxed (`KiFinderUITests-Runner.app` carries
///     `com.apple.security.app-sandbox`; its `NSHomeDirectory()` is
///     `~/Library/Containers/com.krisbaker.KiFinderUITests.xctrunner/Data`). It can write
///     ONLY inside its own container. Writes to `/tmp`, `/private/var/tmp`,
///     `/var/folders/…/T`, `/Users/Shared`, and the APP's container all fail
///     (`NSCocoaErrorDomain 513`).
///  2. The **app under test** is App-Sandboxed too. It can write ONLY its own container:
///     `~/Library/Containers/com.krisbaker.KiFinder/Data/tmp/…` and
///     `…/Data/Library/Application Support/…`. A `KION_PROFILE_STORE` under `/tmp`, the
///     runner's container, or `/var/folders` writes NOTHING — `bootstrapRoster`'s `try?`
///     seeding silently yields no people, so the mandatory "Enroll a person" sheet covers
///     Review (the old failure mode).
///  3. The runner CAN read the app's container (`fileExists`/`contentsOfDirectory` on an
///     app-written store all succeed from the runner).
///  4. The app CAN read the runner's container (`KION_LIBRARY_PICK` under the runner's
///     `NSTemporaryDirectory()` that the app bookmarks/reads works today).
///
/// So app-written harness files (`KION_PROFILE_STORE`, `KION_FEEDBACK_LOG`,
/// `KION_EXPORT_DEST`, `KION_APP_SUPPORT`, `KION_LIBRARY_ROOT`, `KION_LIBRARY_INDEX`) MUST
/// live in the APP's container via ``appWritable(_:)``; files the TEST authors that the
/// app only READS (`KION_LIBRARY_PICK`, a library seed staged into the app via
/// `KION_LIBRARY_SEED_DIR`) live in the runner's temp via ``runnerWritable(_:)``.
enum HarnessPaths {
    /// The app-under-test's bundle id (`project.yml`'s `PRODUCT_BUNDLE_IDENTIFIER`) — the
    /// only place the container layout is hard-coded.
    private static let appBundleID = "com.krisbaker.KiFinder"

    /// The REAL home directory. The runner is sandboxed, so its `NSHomeDirectory()` is
    /// `<realHome>/Library/Containers/<runner-id>.xctrunner/Data`; strip the
    /// `/Library/Containers/…` suffix to recover `<realHome>`. An unsandboxed runner on an
    /// older toolchain reports the real home directly. `getpwuid` is the last-resort
    /// fallback if `NSHomeDirectory()` is somehow empty.
    private static var realHome: String {
        let home = NSHomeDirectory()
        if let range = home.range(of: "/Library/Containers/") {
            return String(home[home.startIndex ..< range.lowerBound])
        }
        if !home.isEmpty {
            return home
        }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return home
    }

    /// A unique, NOT-pre-created directory URL inside the APP's own sandbox container temp,
    /// namely `<realHome>/Library/Containers/com.krisbaker.KiFinder/Data/tmp` under a
    /// `kion-ui-tests/<tag>-<UUID>` subtree. The runner CANNOT create it (fact 1) — the app
    /// creates the parents itself when it writes the store/index/export there (its
    /// repositories all use `createDirectory(withIntermediateDirectories:)`). File-valued
    /// env vars append a file name (`store.json`, `feedback.log`, `library-index.json`);
    /// directory-valued ones pass this URL as-is.
    static func appWritable(_ tag: String) -> URL {
        // The path components are kept as separate string literals (never one contiguous
        // literal) so the container temp subtree reads cleanly and stays distinct from the
        // retired world-shared temp roots.
        URL(fileURLWithPath: realHome, isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(appBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("kion-ui-tests", isDirectory: true)
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A unique directory under the RUNNER's `NSTemporaryDirectory()`, CREATED here and
    /// writable by the runner. For files the TEST authors that the app only needs to READ
    /// (library seeds staged via `KION_LIBRARY_SEED_DIR`, the `KION_LIBRARY_PICK` root the
    /// app bookmarks).
    static func runnerWritable(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-ui-tests", isDirectory: true)
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
