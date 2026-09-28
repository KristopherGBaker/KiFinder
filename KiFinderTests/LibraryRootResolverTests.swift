import Foundation
@testable import KiFinder
import Testing

/// Item-44 assertions 2–5: library-root resolution (env → security-scoped bookmark →
/// container default) through an injectable bookmark resolver, plus the model-level
/// store/clear behavior of a custom root.
@Suite("Library root resolver")
@MainActor
struct LibraryRootResolverTests {
    private func freshSuite() -> UserDefaults {
        let name = "kion-lib-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func locations() -> LibraryLocations {
        LibraryLocations(defaultRoot: LibraryFixtures.tempDir("default-root"))
    }

    /// A resolver that always returns a fixed URL with a chosen staleness.
    private func resolver(_ url: URL, stale: Bool = false) -> LibraryBookmarkResolver {
        { _ in (url, stale) }
    }

    /// Symlink-canonicalized path (temp dirs are `/var → /private/var`; bookmark
    /// resolution returns the canonical form).
    private func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func sampleModel(defaults: UserDefaults, locations: LibraryLocations, env extra: [String: String] = [:]) -> AppModel {
        var environment = ["KION_SAMPLE": "1", "KION_PROFILE_STORE": LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path]
        environment.merge(extra) { _, new in new }
        return AppModel(
            engine: SampleTriageEngine(),
            environment: environment,
            modelLocations: ModelLocations(appSupportRoot: LibraryFixtures.tempDir("appsupport")),
            libraryLocations: locations,
            libraryDefaults: defaults
        )
    }

    // MARK: - Assertion 2: container default (not ~/Pictures)

    @Test("no bookmark and no env resolves to the injected container-style default")
    func defaultFallback() {
        let suite = freshSuite()
        let locs = locations()
        let resolved = resolveLibraryRoot(env: [:], defaults: suite, locations: locs)
        #expect(resolved.url == locs.defaultRoot)
        #expect(resolved.isSecurityScoped == false)
        #expect(resolved.needsReselection == false)
        #expect(!resolved.url.path.contains("Pictures"))
    }

    @Test("the production default lives under Application Support/KiFinder/Library, not ~/Pictures")
    func productionDefaultIsContainer() {
        let root = LibraryLocations.production.defaultRoot
        #expect(root.path.hasSuffix("KiFinder/Library"))
        #expect(!root.path.contains("Pictures"))
    }

    // MARK: - Assertion 4: precedence + every branch

    @Test("env override wins over a stored bookmark and the default")
    func envWins() {
        let suite = freshSuite()
        suite.set(Data([1, 2, 3]), forKey: LibraryPreference.bookmarkKey)
        let resolved = resolveLibraryRoot(
            env: ["KION_LIBRARY_ROOT": "/env/root"],
            defaults: suite,
            locations: locations(),
            bookmarkResolver: resolver(URL(fileURLWithPath: "/bookmark/root"))
        )
        #expect(resolved.url == URL(fileURLWithPath: "/env/root", isDirectory: true))
        #expect(resolved.isSecurityScoped == false)
    }

    @Test("a valid non-stale bookmark wins over the default")
    func validBookmarkWins() {
        let suite = freshSuite()
        let custom = LibraryFixtures.tempDir("custom")
        suite.set(Data([9]), forKey: LibraryPreference.bookmarkKey)
        let resolved = resolveLibraryRoot(
            env: [:], defaults: suite, locations: locations(),
            bookmarkResolver: resolver(custom, stale: false)
        )
        #expect(resolved.url == custom)
        #expect(resolved.isSecurityScoped == true)
        #expect(resolved.needsBookmarkRefresh == false)
        #expect(resolved.needsReselection == false)
    }

    @Test("a stale bookmark still resolves to its URL and signals refresh — no fallback, no re-prompt")
    func staleBookmarkRefreshes() {
        let suite = freshSuite()
        let custom = LibraryFixtures.tempDir("custom")
        let locs = locations()
        suite.set(Data([9]), forKey: LibraryPreference.bookmarkKey)
        let resolved = resolveLibraryRoot(
            env: [:], defaults: suite, locations: locs,
            bookmarkResolver: resolver(custom, stale: true)
        )
        #expect(resolved.url == custom)
        #expect(resolved.url != locs.defaultRoot)
        #expect(resolved.needsBookmarkRefresh == true)
        #expect(resolved.needsReselection == false)
    }

    @Test("an un-decodable / gone bookmark falls back to the default and signals re-selection")
    func failedBookmarkFallsBack() {
        let suite = freshSuite()
        let locs = locations()
        suite.set(Data([0xFF, 0x00]), forKey: LibraryPreference.bookmarkKey)
        let resolved = resolveLibraryRoot(
            env: [:], defaults: suite, locations: locs,
            bookmarkResolver: { _ in nil }
        )
        #expect(resolved.url == locs.defaultRoot)
        #expect(resolved.isSecurityScoped == false)
        #expect(resolved.needsReselection == true)
    }

    @Test("no stored bookmark resolves to the container default")
    func noBookmarkIsDefault() {
        let suite = freshSuite()
        let locs = locations()
        let resolved = resolveLibraryRoot(
            env: [:], defaults: suite, locations: locs,
            bookmarkResolver: { _ in Issue.record("resolver must not run without stored data"); return nil }
        )
        #expect(resolved.url == locs.defaultRoot)
        #expect(resolved.needsReselection == false)
    }

    // MARK: - Assertion 3: bookmark seam round-trip

    @Test("the bookmark seam round-trips a folder URL directly and through the store")
    func bookmarkRoundTrips() {
        let dir = LibraryFixtures.tempDir("bookmarked")
        guard let data = try? makeLibraryBookmark(for: dir) else {
            Issue.record("bookmark creation failed")
            return
        }
        // Direct resolve.
        let resolved = resolveLibraryBookmark(data)
        #expect(resolved.map { canonical($0.url) } == canonical(dir))

        // Round-trip through a persisted UserDefaults store.
        let suite = freshSuite()
        suite.set(data, forKey: LibraryPreference.bookmarkKey)
        let stored = suite.data(forKey: LibraryPreference.bookmarkKey)
        #expect(stored != nil)
        let reResolved = stored.flatMap(resolveLibraryBookmark)
        #expect(reResolved.map { canonical($0.url) } == canonical(dir))
    }

    // MARK: - Assertion 5: choosing / resetting the root at the model level

    @Test("choosing a custom root stores a bookmark and resetting clears it")
    func customRootStoresAndResetClears() {
        let suite = freshSuite()
        let locs = locations()
        let chosen = LibraryFixtures.tempDir("chosen")

        let model = sampleModel(defaults: suite, locations: locs)
        #expect(model.libraryRoot == locs.defaultRoot)
        #expect(model.isUsingDefaultLibraryRoot)
        #expect(suite.data(forKey: LibraryPreference.bookmarkKey) == nil)

        model.setCustomLibraryRoot(chosen)
        #expect(canonical(model.libraryRoot) == canonical(chosen))
        #expect(suite.data(forKey: LibraryPreference.bookmarkKey) != nil)
        #expect(!model.isUsingDefaultLibraryRoot)
        // A fresh resolver over the same store resolves the stored bookmark to the dir.
        let reResolved = resolveLibraryRoot(env: [:], defaults: suite, locations: locs)
        #expect(canonical(reResolved.url) == canonical(chosen))
        #expect(reResolved.isSecurityScoped)

        // Reset-to-default (the shared entry point) removes the bookmark.
        model.resetLibraryRootToDefault()
        #expect(suite.data(forKey: LibraryPreference.bookmarkKey) == nil)
        #expect(model.libraryRoot == locs.defaultRoot)
        #expect(model.isUsingDefaultLibraryRoot)
        #expect(resolveLibraryRoot(env: [:], defaults: suite, locations: locs).url == locs.defaultRoot)
    }

    @Test("env override still wins at the model level and writes no bookmark")
    func envWinsAtModelLevel() {
        let suite = freshSuite()
        let env = LibraryFixtures.tempDir("env-root")
        let model = sampleModel(defaults: suite, locations: locations(), env: ["KION_LIBRARY_ROOT": env.path])
        #expect(model.libraryRoot.path == env.path)
        #expect(suite.data(forKey: LibraryPreference.bookmarkKey) == nil)
    }

    @Test("a failed stored bookmark surfaces the re-selection flag on the model")
    func modelSurfacesReselection() {
        let suite = freshSuite()
        let locs = locations()
        suite.set(Data([0xFF]), forKey: LibraryPreference.bookmarkKey)
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": LibraryFixtures.tempDir("store").appendingPathComponent("s.json").path],
            modelLocations: ModelLocations(appSupportRoot: LibraryFixtures.tempDir("appsupport")),
            libraryLocations: locs,
            libraryDefaults: suite,
            bookmarkResolver: { _ in nil }
        )
        #expect(model.libraryRoot == locs.defaultRoot)
        #expect(model.libraryRootNeedsReselection)
    }
}
