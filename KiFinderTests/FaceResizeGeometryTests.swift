import CoreGraphics
import ImageIO
@testable import KiFinder
import Testing

/// Deterministic geometry tests for item 21's `FaceBoxedImage.resizedRect` (handle
/// drags → new container-point rect) and the resized→raw inverse. Every expected
/// value is computed BY HAND in the comments and written as a literal — never
/// recomputed by the function under test — so a regression is caught, not mirrored.
@Suite("Face resize geometry")
struct FaceResizeGeometryTests {
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

    /// A 200×200 photo filling its container (no letterbox), and a centered start box.
    private let fitted = CGRect(x: 0, y: 0, width: 200, height: 200)
    /// minX 50, maxX 150, minY 50, maxY 150.
    private let start = CGRect(x: 50, y: 50, width: 100, height: 100)
    private let minSize: CGFloat = 24

    // MARK: - Corners move two edges

    @Test("top-left corner moves left+top edges only")
    func topLeftCorner() {
        // translation (−20,−30): minX 50−20=30, minY 50−30=20; right/bottom fixed.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .topLeft, translation: CGSize(width: -20, height: -30),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 30, y: 20, width: 120, height: 130))
    }

    @Test("bottom-right corner moves right+bottom edges only")
    func bottomRightCorner() {
        // translation (20,30): maxX 150+20=170, maxY 150+30=180; left/top fixed.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .bottomRight, translation: CGSize(width: 20, height: 30),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 50, y: 50, width: 120, height: 130))
    }

    @Test("top-right corner moves right+top edges only")
    func topRightCorner() {
        // translation (10,−10): maxX 150+10=160, minY 50−10=40; left/bottom fixed.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .topRight, translation: CGSize(width: 10, height: -10),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 50, y: 40, width: 110, height: 110))
    }

    @Test("bottom-left corner moves left+bottom edges only")
    func bottomLeftCorner() {
        // translation (−10,10): minX 50−10=40, maxY 150+10=160; right/top fixed.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .bottomLeft, translation: CGSize(width: -10, height: 10),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 40, y: 50, width: 110, height: 110))
    }

    // MARK: - Edge handles move one edge

    @Test("right edge handle moves only the right edge (y unchanged)")
    func rightEdge() {
        // translation (40,99): maxX 150+40=190; left/top/bottom fixed (y ignored).
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .right, translation: CGSize(width: 40, height: 99),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 50, y: 50, width: 140, height: 100))
    }

    @Test("top edge handle moves only the top edge (x unchanged)")
    func topEdge() {
        // translation (99,−20): minY 50−20=30; left/right/bottom fixed (x ignored).
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .top, translation: CGSize(width: 99, height: -20),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 50, y: 30, width: 100, height: 120))
    }

    // MARK: - Body translates without resizing

    @Test("body handle translates the whole rect without resizing")
    func bodyTranslate() {
        // translation (10,−15): x 50+10=60, y 50−15=35; size kept 100×100.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .body, translation: CGSize(width: 10, height: -15),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 60, y: 35, width: 100, height: 100))
    }

    @Test("body translate clamps inside the fitted bounds")
    func bodyTranslateClamps() {
        // A big push down-right pins the rect's far edge at fitted.maxX/maxY:
        // x = 200−100 = 100, y = 200−100 = 100.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .body, translation: CGSize(width: 999, height: 999),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    // MARK: - Clamps: min-size (no inversion) and fitted bounds

    @Test("dragging an edge past the opposite edge stops at minSize (no inversion)")
    func minSizeNoInversion() {
        // Left handle dragged far right: minX clamps to maxX − minSize = 150−24 = 126,
        // width = 24 (never negative, never below minSize).
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .left, translation: CGSize(width: 500, height: 0),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 126, y: 50, width: 24, height: 100))
        #expect(r.width >= minSize - Self.tol)
    }

    @Test("a corner dragged inward stops at minSize on both axes")
    func cornerMinSizeBothAxes() {
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .topLeft, translation: CGSize(width: 500, height: 500),
            clampedTo: fitted, minSize: minSize
        )
        // minX 150−24=126, minY 150−24=126, both extents = minSize.
        expectClose(r, CGRect(x: 126, y: 126, width: 24, height: 24))
    }

    @Test("dragging an edge outward clamps at the fitted bounds")
    func clampsAtFittedBounds() {
        // Left handle dragged far left: minX clamps to fitted.minX = 0, width = 150.
        let r = FaceBoxedImage.resizedRect(
            from: start, handle: .left, translation: CGSize(width: -500, height: 0),
            clampedTo: fitted, minSize: minSize
        )
        expectClose(r, CGRect(x: 0, y: 50, width: 150, height: 100))
        #expect(r.minX >= fitted.minX - Self.tol)
    }

    @Test("a letterboxed fitted rect keeps the box out of the letterbox")
    func clampsWithLetterbox() {
        // Fitted offset by a 30pt letterbox on each side; dragging the right edge way
        // out pins maxX at fitted.maxX = 170, never into the surrounding container.
        let letterboxed = CGRect(x: 30, y: 30, width: 140, height: 140)
        let box = CGRect(x: 60, y: 60, width: 50, height: 50)
        let r = FaceBoxedImage.resizedRect(
            from: box, handle: .right, translation: CGSize(width: 999, height: 0),
            clampedTo: letterboxed, minSize: minSize
        )
        #expect(abs(r.maxX - letterboxed.maxX) < Self.tol)
        #expect(r.maxX <= letterboxed.maxX + Self.tol)
    }

    // MARK: - Resized → raw inverse (assertion 2)

    @Test("a resized rect under .right round-trips to the expected raw region")
    func resizedToRawRight() {
        // Full-container fitted (aspect 0.5 in 200×400). Start box (40,120,60,160):
        //   minX 40, maxX 100, minY 120, maxY 280.
        // bottom-right drag (20,40): maxX 100+20=120, maxY 280+40=320 → (40,120,80,200).
        let container = CGSize(width: 200, height: 400)
        let fittedFull = FaceBoxedImage.aspectFitRect(aspect: 0.5, in: container)
        let resized = FaceBoxedImage.resizedRect(
            from: CGRect(x: 40, y: 120, width: 60, height: 160),
            handle: .bottomRight, translation: CGSize(width: 20, height: 40),
            clampedTo: fittedFull, minSize: minSize
        )
        expectClose(resized, CGRect(x: 40, y: 120, width: 80, height: 200))

        // displayed-normalized (40/200,120/400,80/200,200/400) = (0.2,0.3,0.4,0.5);
        // unorient(.right) maps (x,y)→(y,1−x) → raw (0.3,0.4,0.5,0.4).
        let raw = FaceBoxedImage.rawRegion(
            fromDisplayedRect: resized, aspect: 0.5, orientation: .right, in: container
        )
        expectClose(raw, CGRect(x: 0.3, y: 0.4, width: 0.5, height: 0.4))
        #expect(raw.minX >= 0 && raw.maxX <= 1 + Self.tol)
        #expect(raw.minY >= 0 && raw.maxY <= 1 + Self.tol)
        // Back through orient lands on the original displayed-normalized rect.
        expectClose(
            FaceBoxedImage.orient(raw, .right),
            CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        )
    }

    // MARK: - Handle positions

    @Test("handlePosition places each handle on the right corner/edge midpoint")
    func handlePositions() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 40) // mid (60,40)
        #expect(FaceBoxedImage.handlePosition(.topLeft, in: rect) == CGPoint(x: 10, y: 20))
        #expect(FaceBoxedImage.handlePosition(.top, in: rect) == CGPoint(x: 60, y: 20))
        #expect(FaceBoxedImage.handlePosition(.topRight, in: rect) == CGPoint(x: 110, y: 20))
        #expect(FaceBoxedImage.handlePosition(.left, in: rect) == CGPoint(x: 10, y: 40))
        #expect(FaceBoxedImage.handlePosition(.right, in: rect) == CGPoint(x: 110, y: 40))
        #expect(FaceBoxedImage.handlePosition(.bottomLeft, in: rect) == CGPoint(x: 10, y: 60))
        #expect(FaceBoxedImage.handlePosition(.bottom, in: rect) == CGPoint(x: 60, y: 60))
        #expect(FaceBoxedImage.handlePosition(.bottomRight, in: rect) == CGPoint(x: 110, y: 60))
        #expect(FaceBoxedImage.handlePosition(.body, in: rect) == CGPoint(x: 60, y: 40))
    }

    @Test("edges enumerates exactly the eight non-body handles")
    func edgesAreTheEight() {
        #expect(FaceBoxedImage.ResizeHandle.edges.count == 8)
        #expect(!FaceBoxedImage.ResizeHandle.edges.contains(.body))
    }
}
