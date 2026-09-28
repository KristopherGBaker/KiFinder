import CoreGraphics
import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Item-25 coverage: the manual-region resize handles are opt-in (default OFF). The
/// resolver priority (env → persisted preference → default `false`), that only a
/// user-set value persists, and that the resize preference NEVER affects the item-19
/// draw/remove (add/replace-in-place/remove) model.
@Suite("Manual region resize preference")
@MainActor
struct ManualRegionResizePreferenceTests {
    private let kris = SampleTriageEngine.primarySubjectID
    private let key = ManualRegionResizePreference.enabledKey

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "kion-resize-\(UUID().uuidString)")!
    }

    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-resize-pref")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func sampleModel(defaults: UserDefaults, env extra: [String: String] = [:]) -> AppModel {
        var environment = ["KION_SAMPLE": "1", "KION_PROFILE_STORE": uniqueStore().path]
        environment.merge(extra) { _, new in new }
        return AppModel(
            engine: SampleTriageEngine(),
            environment: environment,
            libraryDefaults: defaults
        )
    }

    // MARK: - Resolver

    @Test("absent env and preference resolves to false")
    func defaultIsFalse() {
        let suite = freshSuite()
        #expect(resolveManualRegionResizeEnabled(env: [:], defaults: suite) == false)
    }

    @Test("env override forces true for 1 / true, wins over a false preference")
    func envForcesTrue() {
        let suite = freshSuite()
        suite.set(false, forKey: key)
        #expect(resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "1"], defaults: suite) == true)
        #expect(resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "true"], defaults: suite) == true)
        #expect(resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "TRUE"], defaults: suite) == true)
    }

    @Test("env override of 0 / other forces false, wins over a true preference")
    func envForcesFalse() {
        let suite = freshSuite()
        suite.set(true, forKey: key)
        #expect(resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "0"], defaults: suite) == false)
        #expect(resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "no"], defaults: suite) == false)
    }

    @Test("absent env falls back to the persisted preference")
    func preferenceFallback() {
        let suite = freshSuite()
        suite.set(true, forKey: key)
        #expect(resolveManualRegionResizeEnabled(env: [:], defaults: suite) == true)
    }

    @Test("resolving via env or default writes no preference")
    func resolutionDoesNotPersist() {
        let suite = freshSuite()
        _ = resolveManualRegionResizeEnabled(env: [:], defaults: suite) // default
        _ = resolveManualRegionResizeEnabled(env: ["KION_MANUAL_RESIZE": "1"], defaults: suite) // env
        #expect(suite.object(forKey: key) == nil)
    }

    // MARK: - AppModel

    @Test("AppModel.manualRegionResizeEnabled defaults to false")
    func appModelDefaultFalse() {
        let suite = freshSuite()
        let model = sampleModel(defaults: suite)
        #expect(model.manualRegionResizeEnabled == false)
        #expect(suite.object(forKey: key) == nil) // get resolves, never persists
    }

    @Test("setting AppModel.manualRegionResizeEnabled persists across a fresh resolver and AppModel")
    func appModelSetPersists() {
        let suite = freshSuite()
        let model = sampleModel(defaults: suite)
        model.manualRegionResizeEnabled = true
        #expect(suite.bool(forKey: key) == true)
        // A fresh resolver and a fresh AppModel over the same store see it.
        #expect(resolveManualRegionResizeEnabled(env: [:], defaults: suite) == true)
        #expect(sampleModel(defaults: suite).manualRegionResizeEnabled == true)
    }

    // MARK: - Draw/remove unaffected by the preference

    private let region = CGRect(x: 0.40, y: 0.45, width: 0.18, height: 0.22)
    private let region2 = CGRect(x: 0.10, y: 0.12, width: 0.14, height: 0.16)

    /// Runs add → replace-in-place → remove and returns the observable box counts so a
    /// caller can assert two models (flag off vs on) behave identically.
    private func exercise(_ model: AppModel) throws -> (base: Int, afterAdd: Int, afterReplace: Int, replaceIndex: Int, afterRemove: Int) {
        let base = try #require(model.candidate(for: "sample-keep-1"))
        let baseCount = base.faceBoxes.count

        model.addManualRegion(to: base, normalizedRect: region)
        let added = try #require(model.candidate(for: "sample-keep-1"))
        let manualIndex = try #require(model.manualFaceIndex(for: added))

        model.addManualRegion(to: added, normalizedRect: region2)
        let replaced = try #require(model.candidate(for: "sample-keep-1"))

        model.removeManualRegion(from: replaced)
        let removed = try #require(model.candidate(for: "sample-keep-1"))

        return (baseCount, added.faceBoxes.count, replaced.faceBoxes.count, manualIndex, removed.faceBoxes.count)
    }

    @Test("add/replace/remove behave identically with the resize preference off vs on")
    func drawRemoveUnaffectedByPreference() throws {
        let off = sampleModel(defaults: freshSuite()) // default false
        let on = sampleModel(defaults: freshSuite(), env: ["KION_MANUAL_RESIZE": "1"])
        #expect(off.manualRegionResizeEnabled == false)
        #expect(on.manualRegionResizeEnabled == true)

        let offResult = try exercise(off)
        let onResult = try exercise(on)

        // Identical model behavior regardless of the resize preference.
        #expect(offResult == onResult)
        // And the actual replace-in-place / remove invariants hold in both.
        #expect(offResult.afterAdd == offResult.base + 1)
        #expect(offResult.afterReplace == offResult.base + 1) // replaced in place
        #expect(offResult.afterRemove == offResult.base) // removed
    }
}
