import Foundation

/// How many photos a scan embeds CONCURRENTLY (item 75).
///
/// A scan used to walk one photo at a time — decode → detect/align/embed → score —
/// with a single embedder instance, so a folder of 900 photos and three dropped zips
/// were equally serial. The worker count is the width of that fan-out: `n` workers
/// each own their OWN embedder instance (`FaceEmbedder`'s own documentation
/// encourages one actor per concurrent task; a single instance serializes every
/// call), so `n` photos are in flight at once.
///
/// The cost of a worker is roughly one resident model session, so this is deliberately
/// user-visible rather than "as many as there are cores": ONNX Runtime already
/// threads a single inference across cores, so past a handful of workers the machine
/// oversubscribes itself and the fans spin for very little wall-clock.
///
/// Resolution order matches every other preference here: (1) the `KION_SCAN_WORKERS`
/// env override (tests), (2) a persisted user choice, (3) `automatic` for this
/// machine. Pure reads — resolving NEVER writes the preference back.
enum ScanWorkersPreference {
    /// UserDefaults key under which the user's worker-count choice is persisted.
    static let countKey = "com.krisbaker.KiFinder.scanWorkerCount"

    /// The persisted/selected value meaning "decide from this machine's core count".
    /// Stored (rather than resolving to a number at pick time) so the same preference
    /// still means "auto" if the app later runs on different hardware.
    static let automatic = 0

    /// The highest worker count offered. A ceiling, not a recommendation: each worker
    /// holds its own model session, and inference is already internally threaded.
    static let maximum = 8

    /// The selectable values for the Settings picker: Automatic, then 1…`maximum`.
    static var selectableCounts: [Int] { [automatic] + Array(1 ... maximum) }
}

/// The automatic worker count for a machine with `activeProcessorCount` cores: half
/// the cores, capped at 4 and floored at 1.
///
/// Capped low on purpose. A single embed already spreads across cores (no ONNX
/// intra-op thread limit is set), so the fan-out multiplies memory and heat faster
/// than it multiplies throughput; leaving headroom also keeps the app responsive
/// while a scan runs, which matters because scanning is something you sit and watch.
/// Users who want to spend the whole machine can pick a higher value explicitly.
func automaticScanWorkerCount(activeProcessorCount: Int) -> Int {
    max(1, min(4, activeProcessorCount / 2))
}

/// Resolves the effective scan worker count (env → persisted → automatic), always
/// clamped to `1...ScanWorkersPreference.maximum` so a hand-edited preference or a
/// bad env value can never produce a zero-width (deadlocked) or absurd fan-out.
/// `ScanWorkersPreference.automatic` (0) — from either source — means "compute it".
func resolveScanWorkerCount(
    env: [String: String],
    defaults: UserDefaults,
    activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
) -> Int {
    let automatic = automaticScanWorkerCount(activeProcessorCount: activeProcessorCount)

    func clamped(_ value: Int) -> Int {
        value == ScanWorkersPreference.automatic
            ? automatic
            : max(1, min(ScanWorkersPreference.maximum, value))
    }

    if let raw = env["KION_SCAN_WORKERS"], let value = Int(raw) {
        return clamped(value)
    }
    if defaults.object(forKey: ScanWorkersPreference.countKey) != nil {
        return clamped(defaults.integer(forKey: ScanWorkersPreference.countKey))
    }
    return automatic
}
