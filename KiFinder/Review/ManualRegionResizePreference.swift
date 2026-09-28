import Foundation

/// Whether the item-21 drag-handle resize of a drawn manual face region is offered.
/// By DEFAULT the resize handles are HIDDEN (item 25): the user draws a region (item
/// 19) and, to change it, removes it and draws again. The resolver consults, in
/// priority order: (1) the `KION_MANUAL_RESIZE` env override (tests; "1"/"true" ⇒ on),
/// (2) a persisted user preference (its own key), (3) the default `false`. ONLY a
/// user-set value is ever written to the preference — resolving via the env override
/// or the default never persists anything (the setter on
/// `AppModel.manualRegionResizeEnabled` is the only writer).
enum ManualRegionResizePreference {
    /// UserDefaults key under which the user's resize-enabled choice is persisted.
    static let enabledKey = "com.krisbaker.KiFinder.manualRegionResizeEnabled"
}

/// Resolves whether manual-region resize handles are enabled, in priority order
/// (env → persisted preference → default `false`). Pure read: it NEVER writes a
/// preference, so resolving via the env override or the default leaves the preference
/// store untouched.
func resolveManualRegionResizeEnabled(
    env: [String: String],
    defaults: UserDefaults
) -> Bool {
    if let raw = env["KION_MANUAL_RESIZE"]?.lowercased() {
        return raw == "1" || raw == "true"
    }
    if defaults.object(forKey: ManualRegionResizePreference.enabledKey) != nil {
        return defaults.bool(forKey: ManualRegionResizePreference.enabledKey)
    }
    return false
}
