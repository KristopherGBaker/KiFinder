import CoreGraphics
import ImageIO
@testable import KiFinder
import Testing

/// Deterministic geometry tests for the shared `FaceBoxedImage` box-placement
/// math: `aspectFitRect` (normalized box → displayed rect) and `orient` (EXIF
/// orientation of a normalized rect). Every expected value is a literal constant
/// computed BY HAND in the comments — never recomputed by the functions under
/// test — so the tests catch a regression rather than mirroring the code.
@Suite("Face box geometry")
struct FaceBoxGeometryTests {
    /// Absolute tolerance for floating-point rect comparison. The inputs (0.1,
    /// 0.2, …) are not exactly representable in binary, so the transforms drift a
    /// few ulps off the round decimal literals below; this keeps the literals
    /// readable while staying strict.
    private static let tol: CGFloat = 1e-9

    private func isClose(_ actual: CGRect, _ expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) < Self.tol
            && abs(actual.minY - expected.minY) < Self.tol
            && abs(actual.width - expected.width) < Self.tol
            && abs(actual.height - expected.height) < Self.tol
    }

    private func expectClose(_ actual: CGRect, _ expected: CGRect) {
        #expect(isClose(actual, expected), "expected \(expected), got \(actual)")
    }

    // MARK: - aspectFitRect

    @Test("aspectFitRect: square photo in a wide container is centered horizontally")
    func aspectFitWideContainer() {
        // Container 400×200 (w/h = 2.0), photo aspect 1.0 (square). The square is
        // height-limited: fitted = 200×200, centered → x = (400−200)/2 = 100, y = 0.
        let fitted = FaceBoxedImage.aspectFitRect(
            aspect: 1.0,
            in: CGSize(width: 400, height: 200)
        )
        expectClose(fitted, CGRect(x: 100, y: 0, width: 200, height: 200))
        // Aspect preserved (square) and fully inside the container.
        #expect(fitted.width == fitted.height)
        #expect(fitted.minX >= 0 && fitted.maxX <= 400)
        #expect(fitted.minY >= 0 && fitted.maxY <= 200)
    }

    @Test("aspectFitRect: wide photo in a tall container is centered vertically")
    func aspectFitTallContainer() {
        // Container 200×400 (w/h = 0.5), photo aspect 2.0 (wide). The photo is
        // width-limited: fitted.width = 200, fitted.height = 200/2 = 100, centered
        // → x = 0, y = (400−100)/2 = 150.
        let fitted = FaceBoxedImage.aspectFitRect(
            aspect: 2.0,
            in: CGSize(width: 200, height: 400)
        )
        expectClose(fitted, CGRect(x: 0, y: 150, width: 200, height: 100))
        // Photo aspect (2.0) preserved and fully inside the container.
        #expect(fitted.width == fitted.height * 2)
        #expect(fitted.minX >= 0 && fitted.maxX <= 200)
        #expect(fitted.minY >= 0 && fitted.maxY <= 400)
    }

    @Test("aspectFitRect: non-positive aspect or size falls back to the full container")
    func aspectFitDegenerate() {
        let size = CGSize(width: 320, height: 240)
        expectClose(
            FaceBoxedImage.aspectFitRect(aspect: 0, in: size),
            CGRect(origin: .zero, size: size)
        )
        expectClose(
            FaceBoxedImage.aspectFitRect(aspect: 1.5, in: .zero),
            CGRect(origin: .zero, size: .zero)
        )
    }

    // MARK: - orient

    /// Fixed non-square, off-center normalized rect reused across orientations.
    /// minX 0.1, minY 0.2, maxX 0.4, maxY 0.6.
    private let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

    @Test("orient .up is the identity")
    func orientUp() {
        // .up maps every point to itself → the rect is unchanged.
        expectClose(
            FaceBoxedImage.orient(rect, .up),
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
    }

    @Test("orient .right rotates 90°: width/height swap, position moves")
    func orientRight() {
        // .right maps (x,y) → (1−y, x):
        //   (0.1,0.2) → (0.8,0.1),  (0.4,0.6) → (0.4,0.4)
        //   x = min(0.8,0.4) = 0.4, y = min(0.1,0.4) = 0.1
        //   w = |0.8−0.4| = 0.4,    h = |0.1−0.4| = 0.3
        expectClose(
            FaceBoxedImage.orient(rect, .right),
            CGRect(x: 0.4, y: 0.1, width: 0.4, height: 0.3)
        )
    }

    @Test("orient .down rotates 180°: size kept, corner mirrored")
    func orientDown() {
        // .down maps (x,y) → (1−x, 1−y):
        //   (0.1,0.2) → (0.9,0.8),  (0.4,0.6) → (0.6,0.4)
        //   x = min(0.9,0.6) = 0.6, y = min(0.8,0.4) = 0.4
        //   w = |0.9−0.6| = 0.3,    h = |0.8−0.4| = 0.4
        expectClose(
            FaceBoxedImage.orient(rect, .down),
            CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.4)
        )
    }

    @Test("isQuarterTurn is true only for the 90°/270° orientations")
    func quarterTurns() {
        #expect(FaceBoxedImage.isQuarterTurn(.left))
        #expect(FaceBoxedImage.isQuarterTurn(.right))
        #expect(FaceBoxedImage.isQuarterTurn(.leftMirrored))
        #expect(FaceBoxedImage.isQuarterTurn(.rightMirrored))
        #expect(!FaceBoxedImage.isQuarterTurn(.up))
        #expect(!FaceBoxedImage.isQuarterTurn(.down))
        #expect(!FaceBoxedImage.isQuarterTurn(.upMirrored))
        #expect(!FaceBoxedImage.isQuarterTurn(.downMirrored))
    }

    // MARK: - unorient (item 19, the displayed → raw inverse)

    @Test("unorient is the exact inverse of orient for .up (identity)")
    func unorientUpIdentity() {
        expectClose(
            FaceBoxedImage.unorient(rect, .up),
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
    }

    @Test("unorient .right inverts orient .right by hand")
    func unorientRightByHand() {
        // A displayed-space rect d (minX 0.2, minY 0.3, maxX 0.5, maxY 0.7). The
        // .right inverse map is (x,y) → (y, 1−x):
        //   (0.2,0.3) → (0.3,0.8),  (0.5,0.7) → (0.7,0.5)
        //   x = min(0.3,0.7) = 0.3, y = min(0.8,0.5) = 0.5
        //   w = |0.3−0.7| = 0.4,    h = |0.8−0.5| = 0.3
        let displayed = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)
        expectClose(
            FaceBoxedImage.unorient(displayed, .right),
            CGRect(x: 0.3, y: 0.5, width: 0.4, height: 0.3)
        )
    }

    @Test("unorient round-trips through orient for every non-.up orientation")
    func unorientRoundTrips() {
        let displayed = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)
        let orientations: [CGImagePropertyOrientation] = [
            .upMirrored, .down, .downMirrored, .left, .right, .leftMirrored, .rightMirrored,
        ]
        for orientation in orientations {
            let raw = FaceBoxedImage.unorient(displayed, orientation)
            // orient(unorient(d)) == d (both bijective on the corner set).
            expectClose(FaceBoxedImage.orient(raw, orientation), displayed)
        }
    }

    // MARK: - rawRegion (drag points → raw normalized, the tested model seam)

    @Test("rawRegion removes the letterbox and is identity under .up")
    func rawRegionUpWithLetterbox() {
        // Container 400×200, displayed aspect 1.0 (square) → fitted x:100,y:0,200×200.
        // A drag at points x:150,y:50,50×50 → displayed-normalized
        //   ((150−100)/200, (50−0)/200, 50/200, 50/200) = (0.25, 0.25, 0.25, 0.25).
        // .up is identity, so raw == that.
        let raw = FaceBoxedImage.rawRegion(
            fromDisplayedRect: CGRect(x: 150, y: 50, width: 50, height: 50),
            aspect: 1.0,
            orientation: .up,
            in: CGSize(width: 400, height: 200)
        )
        expectClose(raw, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
    }

    @Test("rawRegion converts a known drag under .right to the expected raw rect, round-tripping through orient")
    func rawRegionRightFullPipeline() {
        // Container 200×400, displayed aspect 0.5 → fitted is the full container.
        // A drag at points x:40,y:120,60×160 → displayed-normalized
        //   (40/200, 120/400, 60/200, 160/400) = (0.2, 0.3, 0.3, 0.4).
        // unorient(.right) of that is (0.3, 0.5, 0.4, 0.3) (see unorientRightByHand).
        let displayedNormalized = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.4)
        let raw = FaceBoxedImage.rawRegion(
            fromDisplayedRect: CGRect(x: 40, y: 120, width: 60, height: 160),
            aspect: 0.5,
            orientation: .right,
            in: CGSize(width: 200, height: 400)
        )
        expectClose(raw, CGRect(x: 0.3, y: 0.5, width: 0.4, height: 0.3))
        // Back through orient lands on the original displayed-normalized rect.
        expectClose(FaceBoxedImage.orient(raw, .right), displayedNormalized)
    }

    @Test("rawRegion clamps a drag that spills past the fitted photo into 0…1")
    func rawRegionClampsToUnit() {
        // Full-container fitted (aspect 0.5 in 200×400); a drag whose math would
        // exceed 1.0 is clamped. x:100,y:200,w:300,h:400 → normalized maxX would be
        // (100+300)/200 = 2.0; clamped to 1.0.
        let raw = FaceBoxedImage.rawRegion(
            fromDisplayedRect: CGRect(x: 100, y: 200, width: 300, height: 400),
            aspect: 0.5,
            orientation: .up,
            in: CGSize(width: 200, height: 400)
        )
        #expect(raw.minX >= 0 && raw.maxX <= 1 + Self.tol)
        #expect(raw.minY >= 0 && raw.maxY <= 1 + Self.tol)
    }
}
