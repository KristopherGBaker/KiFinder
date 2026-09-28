import SwiftUI
@testable import KiFinder
import Testing

/// Item 77 coverage: `kionFont` must scale with the `dynamicTypeSize` environment
/// again on macOS 27, where `@ScaledMetric` (and semantic fonts) stopped deriving
/// a size from an environment override. Pins the `DynamicTypeSize.kionScale` ratio
/// table and proves the header actually grows via `NSHostingView.fittingSize`.
@Suite("kionFont environment scaling (item 77)")
@MainActor
struct KionScaledTextTests {
    // MARK: - Ratio table

    @Test("kionScale table matches Apple body pt / 17, monotonic, .large == 1")
    func kionScaleTable() {
        // .large is the anchor: exactly 1.0.
        #expect(DynamicTypeSize.kionScale(.large) == 1.0)

        // Every case equals its Apple body point size / 17.
        let expected: [(DynamicTypeSize, CGFloat)] = [
            (.xSmall, 14), (.small, 15), (.medium, 16), (.large, 17),
            (.xLarge, 19), (.xxLarge, 21), (.xxxLarge, 23),
            (.accessibility1, 28), (.accessibility2, 33), (.accessibility3, 40),
            (.accessibility4, 47), (.accessibility5, 53)
        ]
        for (size, pt) in expected {
            #expect(abs(DynamicTypeSize.kionScale(size) - pt / 17) < 0.001)
        }

        // accessibility5 specifically within 0.01 of 53/17.
        #expect(abs(DynamicTypeSize.kionScale(.accessibility5) - 53.0 / 17.0) < 0.01)

        // Monotonically non-decreasing across all cases in declaration order.
        let scales = DynamicTypeSize.allCases.map { DynamicTypeSize.kionScale($0) }
        for pair in zip(scales, scales.dropFirst()) {
            #expect(pair.1 >= pair.0)
        }
    }

    // MARK: - Rendering growth

    @Test("Header grows ≥ 1.15× at .accessibility5 via NSHostingView.fittingSize")
    func headerGrowsAtAccessibility5() {
        let base = Text("Found matches").kionFont(20, weight: .semibold)

        // Default-size height measured from the SAME view (no override).
        let defaultHeight = NSHostingView(rootView: base).fittingSize.height
        // The accessibility5-scaled height of that same view.
        let scaledHeight = NSHostingView(
            rootView: base.dynamicTypeSize(.accessibility5)
        ).fittingSize.height

        #expect(defaultHeight > 0)
        #expect(scaledHeight >= defaultHeight * 1.15)
    }
}
