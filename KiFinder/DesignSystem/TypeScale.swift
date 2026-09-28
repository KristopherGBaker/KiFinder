import SwiftUI

extension View {
    /// A system font whose point size scales with the environment's Dynamic Type
    /// size, so text enlarges for a real user's accessibility text-size setting —
    /// and under the `KION_DYNAMIC_TYPE` UI-test launch hook, which drives the very
    /// same `dynamicTypeSize` environment (see `KiFinderApp`). At the default
    /// `.large` size the point size is returned unchanged, so this is a no-op for
    /// existing layouts until the size is increased.
    func kionFont(
        _ base: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(KionScaledText(base: base, weight: weight, design: design))
    }
}

/// Dynamic Type scaling ratios relative to `.large` (= 1.0), derived from Apple's
/// documented body point sizes divided by the `.large` body size (17 pt). Kept
/// `internal` so a unit test can pin the exact table.
extension DynamicTypeSize {
    /// The point size Apple uses for the `.body` text style at this Dynamic Type
    /// size, in points. Source: Apple's Dynamic Type size tables.
    private var kionBodyPointSize: CGFloat {
        switch self {
        case .xSmall: 14
        case .small: 15
        case .medium: 16
        case .large: 17
        case .xLarge: 19
        case .xxLarge: 21
        case .xxxLarge: 23
        case .accessibility1: 28
        case .accessibility2: 33
        case .accessibility3: 40
        case .accessibility4: 47
        case .accessibility5: 53
        @unknown default: 17
        }
    }

    /// Scaling ratio relative to the default `.large` size (17 pt = 1.0). Multiply
    /// a base point size by this to derive an environment-scaled size.
    static func kionScale(_ size: DynamicTypeSize) -> CGFloat {
        size.kionBodyPointSize / 17
    }
}

private struct KionScaledText: ViewModifier {
    /// `@ScaledMetric` scales `base` relative to `.body` per the active
    /// `dynamicTypeSize`. On macOS ≤ 26 this alone tracked a `dynamicTypeSize`
    /// environment override; macOS 27 stopped scaling `@ScaledMetric` from an
    /// environment override (it may still track the SYSTEM setting, so we keep it).
    @ScaledMetric private var size: CGFloat
    /// The Dynamic Type environment value, read directly so we can derive a scaled
    /// size from it via `DynamicTypeSize.kionScale`. This is what restores
    /// environment-driven scaling on macOS 27 — driving both the `KION_DYNAMIC_TYPE`
    /// hook and any environment-propagated system Text-Size setting.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let base: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(base: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: base, relativeTo: .body)
        self.base = base
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        // Both paths exist because neither is sufficient alone on every macOS: take
        // whichever the OS actually honors. At `.large` both terms equal `base`
        // (kionScale(.large) == 1), so default rendering is byte-identical.
        let envSize = base * DynamicTypeSize.kionScale(dynamicTypeSize)
        content.font(.system(size: max(size, envSize), weight: weight, design: design))
    }
}
