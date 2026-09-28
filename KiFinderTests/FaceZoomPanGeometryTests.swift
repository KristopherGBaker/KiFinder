import CoreGraphics
import ImageIO
@testable import KiFinder
import Testing

/// Deterministic geometry tests for item 38's zoom/pan transform on `FaceBoxedImage`:
/// the pure `containerToFitted`/`fittedToContainer` maps, the zoom/pan-aware `rawRegion`
/// (draw + resize inverse), and the `clampZoom`/`clampPan` bounds. Expected values are
/// hand-computed literals (frozen) or mutual-inverse round-trips — never a function
/// compared to itself — so a broken transform is caught, not mirrored.
@Suite("Face zoom/pan geometry")
struct FaceZoomPanGeometryTests {
    private static let tol: CGFloat = 1e-9
    /// Looser tolerance for multi-step round-trips (forward + inverse accumulate ulps).
    private static let looseTol: CGFloat = 1e-6

    private func isClose(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol
            && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }

    private func isClose(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    private func expectClose(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = FaceZoomPanGeometryTests.tol) {
        #expect(isClose(a, b, tol), "expected \(b), got \(a)")
    }

    private func expectClose(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = FaceZoomPanGeometryTests.tol) {
        #expect(isClose(a, b, tol), "expected \(b), got \(a)")
    }

    // MARK: - Assertion 1: container ↔ fitted transform

    @Test("at zoom 1 / pan .zero both maps are the identity")
    func identityAtUnitZoom() {
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 200)
        let p = CGPoint(x: 137, y: 42)
        expectClose(FaceBoxedImage.containerToFitted(p, fitted: fitted, zoom: 1, pan: .zero), p)
        expectClose(FaceBoxedImage.fittedToContainer(p, fitted: fitted, zoom: 1, pan: .zero), p)
    }

    @Test("known mapping at zoom 2 with pan, hand-computed, and its inverse")
    func knownMappingZoom2() {
        // fitted 200×200 → center (100,100). zoom 2, pan (10, 0).
        // fittedToContainer(150,100) = 100 + (150−100)*2 + 10 = 210; y = 100 + 0 + 0 = 100.
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 200)
        let pan = CGSize(width: 10, height: 0)
        let mapped = FaceBoxedImage.fittedToContainer(CGPoint(x: 150, y: 100), fitted: fitted, zoom: 2, pan: pan)
        expectClose(mapped, CGPoint(x: 210, y: 100))
        // containerToFitted(210,100) = 100 + (210 − 10 − 100)/2 = 150; y = 100.
        let back = FaceBoxedImage.containerToFitted(CGPoint(x: 210, y: 100), fitted: fitted, zoom: 2, pan: pan)
        expectClose(back, CGPoint(x: 150, y: 100))
    }

    @Test("round-trip: fittedToContainer(containerToFitted(p)) ≈ p at zoom > 1 with pan")
    func roundTripZoomPan() {
        let fitted = CGRect(x: 20, y: 35, width: 180, height: 240) // off-origin, non-square
        let pan = CGSize(width: 33, height: -27)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 120), CGPoint(x: 200, y: 275)] {
            let there = FaceBoxedImage.containerToFitted(p, fitted: fitted, zoom: 2.5, pan: pan)
            let back = FaceBoxedImage.fittedToContainer(there, fitted: fitted, zoom: 2.5, pan: pan)
            expectClose(back, p, Self.looseTol)
        }
    }

    // MARK: - Assertion 2: draw inverse pinned to FROZEN legacy values (regression)

    @Test("rawRegion defaults reproduce the FROZEN legacy raw rects (.up and a quarter-turn)")
    func rawRegionDefaultsMatchFrozenLegacy() {
        // FROZEN literal captured from the pre-item-38 implementation: container 400×200,
        // aspect 1.0, .up, drag (150,50,50,50) → raw (0.25,0.25,0.25,0.25).
        let up = FaceBoxedImage.rawRegion(
            fromDisplayedRect: CGRect(x: 150, y: 50, width: 50, height: 50),
            aspect: 1.0, orientation: .up, in: CGSize(width: 400, height: 200)
        )
        expectClose(up, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))

        // FROZEN literal: container 200×400, aspect 0.5, .right, drag (40,120,60,160) →
        // raw (0.3,0.5,0.4,0.3).
        let right = FaceBoxedImage.rawRegion(
            fromDisplayedRect: CGRect(x: 40, y: 120, width: 60, height: 160),
            aspect: 0.5, orientation: .right, in: CGSize(width: 200, height: 400)
        )
        expectClose(right, CGRect(x: 0.3, y: 0.5, width: 0.4, height: 0.3))
    }

    // MARK: - Assertion 3: draw-while-zoomed lands on the same raw region

    /// Forward-transform a fitted-space (un-zoomed displayed) rect to its on-screen
    /// container rect under zoom/pan, by mapping the two corners.
    private func toContainerRect(_ rect: CGRect, fitted: CGRect, zoom: CGFloat, pan: CGSize) -> CGRect {
        let a = FaceBoxedImage.fittedToContainer(CGPoint(x: rect.minX, y: rect.minY), fitted: fitted, zoom: zoom, pan: pan)
        let b = FaceBoxedImage.fittedToContainer(CGPoint(x: rect.maxX, y: rect.maxY), fitted: fitted, zoom: zoom, pan: pan)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    @Test("draw-while-zoomed (.up): zoomed/panned displayed rect inverts to the un-zoomed raw rect")
    func drawWhileZoomedUp() {
        let container = CGSize(width: 400, height: 200)
        let aspect: CGFloat = 1.0
        let fitted = FaceBoxedImage.aspectFitRect(aspect: aspect, in: container)
        let zoom: CGFloat = 2
        let pan = CGSize(width: 20, height: -10)

        // The un-zoomed displayed rect the user means to draw, and its legacy raw.
        let displayed = CGRect(x: 150, y: 50, width: 50, height: 50)
        let rawUnzoomed = FaceBoxedImage.rawRegion(fromDisplayedRect: displayed, aspect: aspect, orientation: .up, in: container)

        // Where that rect appears on screen when zoomed/panned, then invert WITH zoom/pan.
        let onScreen = toContainerRect(displayed, fitted: fitted, zoom: zoom, pan: pan)
        let rawZoomed = FaceBoxedImage.rawRegion(
            fromDisplayedRect: onScreen, aspect: aspect, orientation: .up, in: container, zoom: zoom, pan: pan
        )
        expectClose(rawZoomed, rawUnzoomed, Self.looseTol)

        // A zoom-IGNORING inverse of the on-screen rect lands somewhere else (would fail).
        let rawIgnoringZoom = FaceBoxedImage.rawRegion(fromDisplayedRect: onScreen, aspect: aspect, orientation: .up, in: container)
        #expect(!isClose(rawIgnoringZoom, rawUnzoomed, 1e-3))
    }

    @Test("draw-while-zoomed (.right quarter-turn): same raw region with zoom/pan")
    func drawWhileZoomedRight() {
        let container = CGSize(width: 200, height: 400)
        let aspect: CGFloat = 0.5
        let fitted = FaceBoxedImage.aspectFitRect(aspect: aspect, in: container)
        let zoom: CGFloat = 3
        let pan = CGSize(width: -25, height: 40)

        let displayed = CGRect(x: 40, y: 120, width: 60, height: 160)
        let rawUnzoomed = FaceBoxedImage.rawRegion(fromDisplayedRect: displayed, aspect: aspect, orientation: .right, in: container)

        let onScreen = toContainerRect(displayed, fitted: fitted, zoom: zoom, pan: pan)
        let rawZoomed = FaceBoxedImage.rawRegion(
            fromDisplayedRect: onScreen, aspect: aspect, orientation: .right, in: container, zoom: zoom, pan: pan
        )
        expectClose(rawZoomed, rawUnzoomed, Self.looseTol)
    }

    // MARK: - Assertion 4: resize-while-zoomed commits the same raw region

    @Test("resize-while-zoomed (.up): a handle drag commits the same raw rect as un-zoomed")
    func resizeWhileZoomedUp() {
        let container = CGSize(width: 400, height: 200)
        let aspect: CGFloat = 1.0
        let fitted = FaceBoxedImage.aspectFitRect(aspect: aspect, in: container)
        let minSize: CGFloat = 24

        // Un-zoomed: a manual box in fitted/display space, dragged by its bottom-right.
        let startDisplay = CGRect(x: 150, y: 40, width: 60, height: 60)
        let resizedDisplay = FaceBoxedImage.resizedRect(
            from: startDisplay, handle: .bottomRight, translation: CGSize(width: 30, height: 20),
            clampedTo: fitted, minSize: minSize
        )
        let rawUnzoomed = FaceBoxedImage.rawRegion(fromDisplayedRect: resizedDisplay, aspect: aspect, orientation: .up, in: container)

        // Zoomed: the SAME geometry on screen. The start box and its clamp region scale by
        // zoom; the gesture translation appears `zoom×` larger on screen. The committed
        // raw rect must match the un-zoomed commit.
        let zoom: CGFloat = 2
        let pan = CGSize(width: 15, height: -8)
        let startOnScreen = toContainerRect(startDisplay, fitted: fitted, zoom: zoom, pan: pan)
        let fittedOnScreen = toContainerRect(fitted, fitted: fitted, zoom: zoom, pan: pan)
        let resizedOnScreen = FaceBoxedImage.resizedRect(
            from: startOnScreen, handle: .bottomRight, translation: CGSize(width: 30 * zoom, height: 20 * zoom),
            clampedTo: fittedOnScreen, minSize: minSize * zoom
        )
        let rawZoomed = FaceBoxedImage.rawRegion(
            fromDisplayedRect: resizedOnScreen, aspect: aspect, orientation: .up, in: container, zoom: zoom, pan: pan
        )
        expectClose(rawZoomed, rawUnzoomed, Self.looseTol)
    }

    @Test("resize-while-zoomed (.right quarter-turn): committed raw rect matches un-zoomed")
    func resizeWhileZoomedRight() {
        let container = CGSize(width: 200, height: 400)
        let aspect: CGFloat = 0.5
        let fitted = FaceBoxedImage.aspectFitRect(aspect: aspect, in: container)
        let minSize: CGFloat = 24

        let startDisplay = CGRect(x: 40, y: 120, width: 60, height: 160)
        let resizedDisplay = FaceBoxedImage.resizedRect(
            from: startDisplay, handle: .topLeft, translation: CGSize(width: -10, height: -20),
            clampedTo: fitted, minSize: minSize
        )
        let rawUnzoomed = FaceBoxedImage.rawRegion(fromDisplayedRect: resizedDisplay, aspect: aspect, orientation: .right, in: container)

        let zoom: CGFloat = 2.5
        let pan = CGSize(width: -18, height: 22)
        let startOnScreen = toContainerRect(startDisplay, fitted: fitted, zoom: zoom, pan: pan)
        let fittedOnScreen = toContainerRect(fitted, fitted: fitted, zoom: zoom, pan: pan)
        let resizedOnScreen = FaceBoxedImage.resizedRect(
            from: startOnScreen, handle: .topLeft, translation: CGSize(width: -10 * zoom, height: -20 * zoom),
            clampedTo: fittedOnScreen, minSize: minSize * zoom
        )
        let rawZoomed = FaceBoxedImage.rawRegion(
            fromDisplayedRect: resizedOnScreen, aspect: aspect, orientation: .right, in: container, zoom: zoom, pan: pan
        )
        expectClose(rawZoomed, rawUnzoomed, Self.looseTol)
    }

    // MARK: - Assertion 5: forward placement and the inverse share ONE transform

    /// Forward-place a raw box to its on-screen container rect: raw → orient (display) →
    /// un-letterbox to fitted points → zoom/pan to container.
    private func placeRawBox(
        _ raw: CGRect, aspect: CGFloat, orientation: CGImagePropertyOrientation,
        container: CGSize, zoom: CGFloat, pan: CGSize
    ) -> CGRect {
        let fitted = FaceBoxedImage.aspectFitRect(aspect: aspect, in: container)
        let display = FaceBoxedImage.orient(raw, orientation)
        let onFitted = CGRect(
            x: fitted.minX + display.minX * fitted.width,
            y: fitted.minY + display.minY * fitted.height,
            width: display.width * fitted.width,
            height: display.height * fitted.height
        )
        return toContainerRect(onFitted, fitted: fitted, zoom: zoom, pan: pan)
    }

    @Test("box placement and rawRegion are mutual inverses at zoom > 1 (.up and a quarter-turn)")
    func placementInverseSharesTransform() {
        let cases: [(CGSize, CGFloat, CGImagePropertyOrientation)] = [
            (CGSize(width: 400, height: 200), 1.0, .up),
            (CGSize(width: 200, height: 400), 0.5, .right),
        ]
        let raw = CGRect(x: 0.3, y: 0.2, width: 0.25, height: 0.35)
        let zoom: CGFloat = 2.5
        let pan = CGSize(width: 22, height: -14)
        for (container, aspect, orientation) in cases {
            let placed = placeRawBox(raw, aspect: aspect, orientation: orientation, container: container, zoom: zoom, pan: pan)
            let inverted = FaceBoxedImage.rawRegion(
                fromDisplayedRect: placed, aspect: aspect, orientation: orientation, in: container, zoom: zoom, pan: pan
            )
            expectClose(inverted, raw, Self.looseTol)
        }
    }

    // MARK: - Assertion 6: clampZoom / clampPan bounds

    @Test("clampZoom keeps zoom within [1, maxZoom]")
    func clampZoomBounds() {
        #expect(FaceBoxedImage.clampZoom(0.3, max: 6) == 1)
        #expect(FaceBoxedImage.clampZoom(1, max: 6) == 1)
        #expect(FaceBoxedImage.clampZoom(3.5, max: 6) == 3.5)
        #expect(FaceBoxedImage.clampZoom(99, max: 6) == 6)
    }

    @Test("clampPan is .zero at zoom 1 and clamps to the per-axis overscan at zoom 2")
    func clampPanBounds() {
        // Square photo filling its container: fitted 200×200 in a 200×200 container.
        let container = CGSize(width: 200, height: 200)
        let fitted = CGRect(x: 0, y: 0, width: 200, height: 200)

        // At zoom 1 the scaled photo equals the container → overscan 0 → pan pinned to .zero.
        let atUnit = FaceBoxedImage.clampPan(CGSize(width: 50, height: -50), zoom: 1, fitted: fitted, container: container)
        #expect(atUnit == .zero)

        // At zoom 2 scaled = 400; overscan per axis = (400 − 200)/2 = 100.
        let overLarge = FaceBoxedImage.clampPan(CGSize(width: 500, height: -500), zoom: 2, fitted: fitted, container: container)
        #expect(abs(overLarge.width - 100) < Self.tol)
        #expect(abs(overLarge.height - -100) < Self.tol)
        // A within-bounds pan is left untouched.
        let inside = FaceBoxedImage.clampPan(CGSize(width: 40, height: -30), zoom: 2, fitted: fitted, container: container)
        #expect(abs(inside.width - 40) < Self.tol && abs(inside.height - -30) < Self.tol)
    }

    @Test("clampPan leaves a letterboxed axis (overscan 0) pinned even at zoom > 1")
    func clampPanLetterboxedAxis() {
        // A wide photo (aspect 2) in a 200×200 container: fitted 200×100 (letterboxed
        // vertically). At zoom 1.5: scaledW = 300 → boundX = 50; scaledH = 150 < 200 →
        // boundY = max(0, (150−200)/2) = 0 → vertical pan pinned.
        let container = CGSize(width: 200, height: 200)
        let fitted = FaceBoxedImage.aspectFitRect(aspect: 2, in: container) // (0,50,200,100)
        let clamped = FaceBoxedImage.clampPan(CGSize(width: 999, height: 999), zoom: 1.5, fitted: fitted, container: container)
        #expect(abs(clamped.width - 50) < Self.tol)
        #expect(clamped.height == 0)
    }

    // MARK: - Button / scroll-wheel zoom controls

    @Test("steppedZoom multiplies and clamps to [1, maxZoom]")
    func steppedZoomClamps() {
        let maxZ = FaceBoxedImage.maxZoom
        // In from fit, out back toward fit.
        #expect(abs(FaceBoxedImage.steppedZoom(1, by: 1.5, max: maxZ) - 1.5) < Self.tol)
        #expect(abs(FaceBoxedImage.steppedZoom(1.5, by: 1 / 1.5, max: maxZ) - 1) < Self.tol)
        // Never below fit, never past max.
        #expect(FaceBoxedImage.steppedZoom(1, by: 0.5, max: maxZ) == 1)
        #expect(FaceBoxedImage.steppedZoom(maxZ, by: 1.5, max: maxZ) == maxZ)
    }

    @Test("scrollZoom: scroll up zooms in, down zooms out, clamped")
    func scrollZoomDirectionAndClamp() {
        let maxZ = FaceBoxedImage.maxZoom
        #expect(FaceBoxedImage.scrollZoom(2, deltaY: 10, max: maxZ) > 2)   // up → in
        #expect(FaceBoxedImage.scrollZoom(2, deltaY: -10, max: maxZ) < 2)  // down → out
        #expect(FaceBoxedImage.scrollZoom(1, deltaY: -1000, max: maxZ) == 1)     // can't go below fit
        #expect(FaceBoxedImage.scrollZoom(maxZ, deltaY: 1000, max: maxZ) == maxZ) // can't exceed max
    }
}
