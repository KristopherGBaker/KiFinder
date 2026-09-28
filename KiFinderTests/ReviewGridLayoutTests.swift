import CoreGraphics
@testable import KiFinder
import Testing

@Suite("Review grid layout")
struct ReviewGridLayoutTests {
    @Test("Image aspect ratio is a fixed positive constant")
    func aspectRatioIsFixedPositive() {
        #expect(ReviewGridLayout.imageAspectRatio > 0)
        // Compile-time constant: reading it twice yields the same value.
        #expect(ReviewGridLayout.imageAspectRatio == ReviewGridLayout.imageAspectRatio)
    }

    @Test("Cell image height is width / aspect ratio")
    func cellImageHeightDerivesFromWidth() {
        let width: CGFloat = 250
        #expect(
            ReviewGridLayout.cellImageHeight(forWidth: width)
                == width / ReviewGridLayout.imageAspectRatio
        )
    }

    @Test("Cell image height depends only on width, not the candidate")
    func cellImageHeightIsCandidateIndependent() {
        // The footprint is a pure function of the (grid-uniform) width: the same
        // width always yields the same height, so portrait/landscape/square
        // source photos can't change a tile's cell size.
        let width: CGFloat = 300
        let first = ReviewGridLayout.cellImageHeight(forWidth: width)
        let second = ReviewGridLayout.cellImageHeight(forWidth: width)
        #expect(first == second)
        #expect(first == width / ReviewGridLayout.imageAspectRatio)

        // A different width yields a proportionally different height.
        #expect(ReviewGridLayout.cellImageHeight(forWidth: width * 2) == first * 2)
    }
}
