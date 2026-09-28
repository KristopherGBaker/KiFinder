import Foundation
@testable import KiFinder
import Testing

/// Item 75: resolution of the scan-concurrency preference (env → persisted → automatic),
/// and the clamping that keeps a hand-edited or hostile value from producing a
/// zero-width (nothing would ever start) or absurd fan-out.
@Suite("Scan workers preference")
struct ScanWorkersPreferenceTests {
    private func defaults(_ label: String = #function) -> UserDefaults {
        UserDefaults(suiteName: "scan-workers-\(label)-\(UUID().uuidString)")!
    }

    @Test("Automatic is half the cores, capped at 4 and floored at 1")
    func automaticScalesWithCores() {
        #expect(automaticScanWorkerCount(activeProcessorCount: 1) == 1)
        #expect(automaticScanWorkerCount(activeProcessorCount: 2) == 1)
        #expect(automaticScanWorkerCount(activeProcessorCount: 4) == 2)
        #expect(automaticScanWorkerCount(activeProcessorCount: 8) == 4)
        // The cap holds no matter how many cores the machine has.
        #expect(automaticScanWorkerCount(activeProcessorCount: 18) == 4)
        #expect(automaticScanWorkerCount(activeProcessorCount: 128) == 4)
        // Never zero, even for a nonsense core count — a 0-width scan would stall.
        #expect(automaticScanWorkerCount(activeProcessorCount: 0) == 1)
    }

    @Test("With nothing set, resolves to this machine's automatic count")
    func defaultsToAutomatic() {
        let store = defaults()
        #expect(
            resolveScanWorkerCount(env: [:], defaults: store, activeProcessorCount: 8) == 4
        )
        // Resolving is a pure read: it never writes the preference back.
        #expect(store.object(forKey: ScanWorkersPreference.countKey) == nil)
    }

    @Test("A persisted explicit choice wins over automatic")
    func persistedChoiceWins() {
        let store = defaults()
        store.set(2, forKey: ScanWorkersPreference.countKey)
        #expect(
            resolveScanWorkerCount(env: [:], defaults: store, activeProcessorCount: 18) == 2
        )
    }

    @Test("A persisted `automatic` (0) still means automatic, not zero workers")
    func persistedAutomaticResolves() {
        let store = defaults()
        store.set(ScanWorkersPreference.automatic, forKey: ScanWorkersPreference.countKey)
        #expect(
            resolveScanWorkerCount(env: [:], defaults: store, activeProcessorCount: 8) == 4
        )
    }

    @Test("KION_SCAN_WORKERS overrides the persisted choice")
    func envOverridesPersisted() {
        let store = defaults()
        store.set(2, forKey: ScanWorkersPreference.countKey)
        #expect(
            resolveScanWorkerCount(
                env: ["KION_SCAN_WORKERS": "6"], defaults: store, activeProcessorCount: 18
            ) == 6
        )
        // A non-numeric override is ignored rather than treated as 0.
        #expect(
            resolveScanWorkerCount(
                env: ["KION_SCAN_WORKERS": "lots"], defaults: store, activeProcessorCount: 18
            ) == 2
        )
    }

    @Test("Out-of-range values clamp to 1…maximum from either source")
    func clampsBothSources() {
        let store = defaults()
        store.set(-5, forKey: ScanWorkersPreference.countKey)
        #expect(resolveScanWorkerCount(env: [:], defaults: store, activeProcessorCount: 8) == 1)

        store.set(999, forKey: ScanWorkersPreference.countKey)
        #expect(
            resolveScanWorkerCount(env: [:], defaults: store, activeProcessorCount: 8)
                == ScanWorkersPreference.maximum
        )

        #expect(
            resolveScanWorkerCount(
                env: ["KION_SCAN_WORKERS": "999"], defaults: store, activeProcessorCount: 8
            ) == ScanWorkersPreference.maximum
        )
        #expect(
            resolveScanWorkerCount(
                env: ["KION_SCAN_WORKERS": "-1"], defaults: store, activeProcessorCount: 8
            ) == 1
        )
    }

    @Test("The picker offers Automatic plus every width up to the maximum")
    func selectableCounts() {
        #expect(ScanWorkersPreference.selectableCounts.first == ScanWorkersPreference.automatic)
        #expect(ScanWorkersPreference.selectableCounts.last == ScanWorkersPreference.maximum)
        #expect(ScanWorkersPreference.selectableCounts.count == ScanWorkersPreference.maximum + 1)
    }
}

/// The `AppModel` side of the same preference: the picked value round-trips, and the
/// effective value is the resolved one the next scan will actually use.
@Suite("App model scan workers")
@MainActor
struct AppModelScanWorkersTests {
    private func model(env: [String: String] = [:]) -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-scan-workers")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var environment = env
        environment["KION_PROFILE_STORE"] = dir.appendingPathComponent("store.json").path
        environment["KION_SAMPLE"] = "1"
        return AppModel(engine: SampleTriageEngine(), environment: environment)
    }

    @Test("Defaults to Automatic, and the effective count is a usable width")
    func defaultsToAutomatic() {
        let model = model()
        #expect(model.scanWorkerCount == ScanWorkersPreference.automatic)
        #expect(model.effectiveScanWorkerCount >= 1)
        #expect(model.effectiveScanWorkerCount <= ScanWorkersPreference.maximum)
    }

    @Test("Picking a width persists it and changes the effective count")
    func pickingPersists() {
        let model = model()
        model.scanWorkerCount = 3
        #expect(model.scanWorkerCount == 3)
        #expect(model.effectiveScanWorkerCount == 3)

        // Back to Automatic: the stored value is `automatic`, and the effective count
        // goes back to being derived rather than frozen at 3.
        model.scanWorkerCount = ScanWorkersPreference.automatic
        #expect(model.scanWorkerCount == ScanWorkersPreference.automatic)
        #expect(model.effectiveScanWorkerCount == automaticScanWorkerCount(
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount
        ))
    }

    @Test("The env override is reflected in what the model reports")
    func envOverrideReported() {
        let model = model(env: ["KION_SCAN_WORKERS": "5"])
        #expect(model.scanWorkerCount == 5)
        #expect(model.effectiveScanWorkerCount == 5)
    }
}
