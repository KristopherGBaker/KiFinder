import SwiftUI

struct LiquidGlassChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(DesignColor.surface)
        } else if #available(macOS 26, *) {
            GlassEffectContainer {
                content
                    .glassEffect()
            }
        } else {
            content
                .background(.regularMaterial)
        }
    }
}

extension View {
    func liquidGlassChrome() -> some View {
        modifier(LiquidGlassChrome())
    }
}
