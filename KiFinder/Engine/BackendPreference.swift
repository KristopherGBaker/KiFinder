import Foundation

/// Whether the app uses the ONNX ArcFace backend or Apple Vision's FeaturePrint
/// backend (item 72). By DEFAULT the app uses `.onnx` — the ArcFace behavior it
/// has always had. The resolver consults, in priority order: (1) the
/// `KION_BACKEND` env override (tests; "onnx"/"vision", case-insensitive; any
/// other value falls through), (2) a persisted user preference (its own key), (3)
/// the default `.onnx`. ONLY a user-set value is ever written to the preference —
/// resolving via the env override or the default never persists anything (the
/// setter on `AppModel.faceBackend` is the only writer). Mirrors
/// `ManualRegionResizePreference`/`resolveManualRegionResizeEnabled`.
enum BackendPreference {
    /// UserDefaults key under which the user's chosen backend is persisted.
    static let key = "com.krisbaker.KiFinder.faceBackend"
}

/// Resolves which `FaceBackend` the app should use, in priority order (env →
/// persisted preference → default `.onnx`). Pure read: it NEVER writes a
/// preference, so resolving via the env override or the default leaves the
/// preference store untouched. An unrecognized `KION_BACKEND` value or an invalid
/// persisted string both fall through to the next source rather than being
/// treated as a hard error — the resolver always returns SOME backend.
func resolveBackend(
    env: [String: String],
    defaults: UserDefaults
) -> FaceBackend {
    if let raw = env["KION_BACKEND"]?.lowercased(), let backend = FaceBackend(rawValue: raw) {
        return backend
    }
    if let raw = defaults.string(forKey: BackendPreference.key), let backend = FaceBackend(rawValue: raw) {
        return backend
    }
    return .onnx
}

/// Whether the user has ALREADY made an explicit backend choice — via the
/// `KION_BACKEND` env override (any value, including an unrecognized or empty
/// string: this probes PRESENCE, not validity — `resolveBackend` is what
/// interprets the value) or a persisted preference under `BackendPreference.key`
/// (again, presence — even an invalid stored string still counts as "explicit").
/// Backs the item73 first-run chooser gate: once true, the chooser never asks
/// again. Pure read — mirrors `resolveBackend`, never writes.
func hasExplicitBackendChoice(env: [String: String], defaults: UserDefaults) -> Bool {
    env["KION_BACKEND"] != nil || defaults.object(forKey: BackendPreference.key) != nil
}
