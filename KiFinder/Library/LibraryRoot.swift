import Foundation

/// Where the persistent kept-photo library lives on disk. The resolver consults, in
/// priority order: (1) the `KION_LIBRARY_ROOT` env override (tests), (2) a persisted
/// user-chosen root recorded as an app-scoped SECURITY-SCOPED BOOKMARK, (3) the app's
/// sandbox-container default (`Application Support/KiFinder/Library`). The DEFAULT root
/// is the container, which needs no bookmark or entitlement; only a user-chosen custom
/// folder is stored as a bookmark so the sandbox can reach it across launches.
enum LibraryPreference {
    /// Legacy UserDefaults key that held a plain library-root PATH string (item 18a).
    /// Retained only so a reset can clear a stale value written by an older build; the
    /// resolver no longer reads it (a plain path is unreachable under App Sandbox).
    static let rootKey = "com.krisbaker.KiFinder.libraryRoot"

    /// UserDefaults key under which a user-chosen custom root is persisted as
    /// app-scoped security-scoped bookmark `Data` (item 44). Absent ⇒ the container
    /// default is used (no bookmark needed).
    static let bookmarkKey = "com.krisbaker.KiFinder.libraryRootBookmark"
}

/// Injectable filesystem default for the library root, so resolver tests never touch
/// the user's real disk.
struct LibraryLocations {
    /// The platform default root used when neither the env override nor a persisted
    /// bookmark is present. Under App Sandbox this resolves to the app's own container;
    /// non-sandboxed it is the real `Application Support/KiFinder/Library` (both fine).
    var defaultRoot: URL

    /// The real production default: `<Application Support>/KiFinder/Library`. Under the
    /// sandbox this is automatically the app container; non-sandboxed it is the user's
    /// real Application Support — either way it is a path the app can always reach with
    /// no bookmark or entitlement.
    static var production: LibraryLocations {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = appSupport
            .appendingPathComponent("KiFinder", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        return LibraryLocations(defaultRoot: root)
    }
}

// MARK: - Security-scoped bookmark seam

/// Resolves app-scoped bookmark `Data` back to a URL. `nil` = the data is un-decodable
/// OR the target folder is gone (`URL(resolvingBookmarkData:)` throws). Injectable so
/// the resolver's valid / stale / failure branches are testable without a real sandbox.
typealias LibraryBookmarkResolver = (Data) -> (url: URL, isStale: Bool)?

/// Creates app-scoped security-scoped bookmark `Data` for a user-chosen folder. Falls
/// back to a plain bookmark when the security-scoped variant is unavailable (a
/// non-sandboxed run, or missing entitlement) so the same code path works everywhere —
/// security scope is simply a no-op off the sandbox.
func makeLibraryBookmark(for url: URL) throws -> Data {
    do {
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    } catch {
        return try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

/// The production bookmark resolver: resolves as a security-scoped bookmark, falling
/// back to a plain resolve (so plain bookmark data, or a non-sandboxed run, still
/// locates the folder). Returns `nil` only when the data can't be decoded at all or the
/// folder no longer exists.
func resolveLibraryBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
    var isStale = false
    if let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
    ) {
        return (url, isStale)
    }
    isStale = false
    if let url = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
    ) {
        return (url, isStale)
    }
    return nil
}

/// The outcome of resolving the library root: the URL plus the signals the caller acts
/// on (start security-scoped access, refresh a stale bookmark, or re-prompt after a
/// failed bookmark).
struct LibraryRootResolution: Equatable {
    /// The resolved library root.
    var url: URL
    /// True when `url` came from a resolved bookmark and therefore needs
    /// `startAccessingSecurityScopedResource()` before file access. The env override and
    /// the container default are `false` (no scope needed).
    var isSecurityScoped: Bool
    /// True when a bookmark resolved with `isStale == true`: the URL is valid but the
    /// caller must RE-CREATE the bookmark from it (Apple's `bookmarkDataIsStale`
    /// contract). Never a fallback / re-prompt.
    var needsBookmarkRefresh: Bool
    /// True when a STORED bookmark FAILED to resolve (un-decodable, or the folder is
    /// gone): the root fell back to the container default and the UI should re-prompt.
    var needsReselection: Bool

    /// A plain, non-scoped resolution (env override or default) with no signals raised.
    static func plain(_ url: URL) -> LibraryRootResolution {
        LibraryRootResolution(url: url, isSecurityScoped: false, needsBookmarkRefresh: false, needsReselection: false)
    }
}

/// Resolves the library root in priority order: `KION_LIBRARY_ROOT` env → a resolvable
/// stored app-scoped bookmark → the container default. Follows Apple's
/// `bookmarkDataIsStale` contract: a bookmark that resolves stale STILL wins (with a
/// refresh signal); only a resolution FAILURE falls back to the default (with a
/// re-select signal). Pure read: it never writes a preference.
func resolveLibraryRoot(
    env: [String: String],
    defaults: UserDefaults,
    locations: LibraryLocations,
    bookmarkResolver: LibraryBookmarkResolver = resolveLibraryBookmark
) -> LibraryRootResolution {
    if let path = env["KION_LIBRARY_ROOT"], !path.isEmpty {
        return .plain(URL(fileURLWithPath: path, isDirectory: true))
    }
    if let data = defaults.data(forKey: LibraryPreference.bookmarkKey) {
        if let resolved = bookmarkResolver(data) {
            return LibraryRootResolution(
                url: resolved.url,
                isSecurityScoped: true,
                needsBookmarkRefresh: resolved.isStale,
                needsReselection: false
            )
        }
        // The bookmark exists but no longer resolves (data un-decodable or folder gone):
        // use the container default and signal the UI to re-prompt.
        return LibraryRootResolution(
            url: locations.defaultRoot,
            isSecurityScoped: false,
            needsBookmarkRefresh: false,
            needsReselection: true
        )
    }
    return .plain(locations.defaultRoot)
}

/// Resolves where the library metadata index JSON is written. Test-injectable via
/// `KION_LIBRARY_INDEX`; in test runs that set `KION_LIBRARY_ROOT` (a temp dir) the
/// index defaults beside that root so the suite never writes the real Application
/// Support. In production it lives under `<appSupportRoot>/KiFinder/library-index.json`.
func resolveLibraryIndexURL(env: [String: String], appSupportRoot: URL) -> URL {
    if let path = env["KION_LIBRARY_INDEX"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    if let root = env["KION_LIBRARY_ROOT"], !root.isEmpty {
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("library-index.json")
    }
    return appSupportRoot
        .appendingPathComponent("KiFinder", isDirectory: true)
        .appendingPathComponent("library-index.json")
}

// MARK: - Library seed staging (test harness)

/// Raised when the `KION_LIBRARY_SEED_DIR` hook is asked to stage a seed that is not a
/// readable directory — surfaced (never swallowed) so a broken seed is LOUD in a DEBUG
/// harness run rather than masquerading as an empty library.
enum LibrarySeedError: Error, CustomStringConvertible {
    case seedUnavailable(String)

    var description: String {
        switch self {
        case let .seedUnavailable(path):
            return "KION_LIBRARY_SEED_DIR is not a readable directory: \(path)"
        }
    }
}

/// Copies a runner-authored library seed into the app's own sandbox container so the
/// on-device library flow can then READ and WRITE it (item 76). Under macOS 27 both the
/// app and the XCUITest runner are App-Sandboxed to their own containers: the runner
/// can't write the app's container and the app can't write the runner's, so a library
/// fixture that the app must mutate (Delete rewrites the index) can't simply live under
/// the runner's temp. Instead the runner stages the tree under its own temp
/// (`KION_LIBRARY_SEED_DIR`) and the app copies it into `KION_LIBRARY_ROOT` here, before
/// `resolveLibraryRoot`/`KeptLibrary` run.
///
/// Pure and injectable (`fileManager`) so `KiFinderTests` can cover copy / replace /
/// no-op with temp dirs. Reads env through the same dictionary `AppModel.init` receives,
/// which `KionEnvironment.process` has already stripped of every `KION_*` key in a
/// RELEASE build — so the hook is a structural no-op in production with no extra gate.
///
/// - Returns: the staged root URL when BOTH `KION_LIBRARY_SEED_DIR` and
///   `KION_LIBRARY_ROOT` are set (and the copy succeeds); `nil` when either key is
///   absent/empty (a total no-op — nothing on disk is touched).
/// - Throws: `LibrarySeedError.seedUnavailable` when both keys are set but the seed is
///   absent or not a directory, and re-throws any `FileManager` copy failure — so a
///   broken seed is never silently swallowed.
func stageLibrarySeed(
    env: [String: String],
    fileManager: FileManager = .default
) throws -> URL? {
    guard let seedPath = env["KION_LIBRARY_SEED_DIR"], !seedPath.isEmpty,
          let rootPath = env["KION_LIBRARY_ROOT"], !rootPath.isEmpty
    else {
        return nil
    }
    let seed = URL(fileURLWithPath: seedPath, isDirectory: true)
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)

    // Verify the seed is a real directory BEFORE mutating the destination, so a bad
    // seed throws cleanly rather than leaving a half-cleared root.
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: seed.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw LibrarySeedError.seedUnavailable(seed.path)
    }

    // Replace any existing root so a relaunch against the same path is deterministic.
    if fileManager.fileExists(atPath: root.path) {
        try fileManager.removeItem(at: root)
    }
    try fileManager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.copyItem(at: seed, to: root)
    return root
}
