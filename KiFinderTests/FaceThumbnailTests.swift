import CoreGraphics
import Foundation
import ImageIO
@testable import KiFinder
import Testing
import UniformTypeIdentifiers

@Suite("Face-crop thumbnail")
struct FaceThumbnailTests {
    /// Builds a known solid-color RGBA image of the given pixel size.
    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test("Crops a known rect and returns a bounded, decodable PNG")
    func croppedPNGIsDecodableAndBounded() throws {
        let image = try solidImage(width: 1000, height: 800)
        // A centered face box (normalized, top-left origin).
        let rect = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)

        let data = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: rect, padding: 0))
        #expect(!data.isEmpty)

        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source))
        #expect((type as String) == "public.png")
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Crop is 400×400 px → within the 256 cap and aspect-preserved (square).
        #expect(max(decoded.width, decoded.height) <= 256)
        #expect(decoded.width == decoded.height)
        #expect(decoded.width > 0)
    }

    @Test("Small crop is not upscaled past its source pixels")
    func smallCropIsNotUpscaled() throws {
        let image = try solidImage(width: 300, height: 300)
        // 30×30 px region — already under the 256 cap, so it stays its own size.
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)

        let data = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: rect, padding: 0))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 30)
        #expect(decoded.height == 30)
    }

    @Test("A rect outside the image yields nil rather than garbage")
    func outOfBoundsRectReturnsNil() throws {
        let image = try solidImage(width: 100, height: 100)
        let offscreen = CGRect(x: 2.0, y: 2.0, width: 0.5, height: 0.5)
        #expect(FaceThumbnail.croppedPNG(from: image, normalizedRect: offscreen, padding: 0) == nil)
    }

    // MARK: - EXIF orientation of the crop OUTPUT

    /// Side of an image, divided into quadrants for the orientation assertions.
    private enum Quadrant: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// Fractional (top-left origin) center of this quadrant, kept WELL inside it
        /// so `.high` downsample interpolation near the midlines can't flip a sample.
        var center: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0.25, y: 0.25)
            case .topRight: CGPoint(x: 0.75, y: 0.25)
            case .bottomLeft: CGPoint(x: 0.25, y: 0.75)
            case .bottomRight: CGPoint(x: 0.75, y: 0.75)
            }
        }
    }

    /// Builds a square `CGImage`, asymmetric in BOTH axes: a bright white marker
    /// fills ONLY the top-left quadrant of an otherwise near-black image. Created
    /// directly from a top-left-first RGBA byte buffer (canonical `CGImage` layout)
    /// so the marker's pixel position is unambiguous.
    private func topLeftMarkerImage(side n: Int = 200) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for row in 0 ..< n {
            for col in 0 ..< n {
                let off = (row * n + col) * 4
                let bright = row < n / 2 && col < n / 2
                let v: UInt8 = bright ? 255 : 0
                bytes[off + 0] = v // R
                bytes[off + 1] = v // G
                bytes[off + 2] = v // B
                bytes[off + 3] = 255 // A (opaque everywhere)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: n,
            height: n,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    /// Mean brightness (0…1) of a small box at fractional (top-left origin) `point`,
    /// read by cropping that box in the image's own top-left pixel space and
    /// averaging it into a single pixel — orientation- and format-agnostic.
    private func brightness(of image: CGImage, at point: CGPoint) -> CGFloat {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let bw = max(1, w * 0.12)
        let bh = max(1, h * 0.12)
        let rect = CGRect(x: point.x * w - bw / 2, y: point.y * h - bh / 2, width: bw, height: bh)
        guard let sub = image.cropping(to: rect) else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &px,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.interpolationQuality = .high
        ctx?.draw(sub, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(px[0]) + CGFloat(px[1]) + CGFloat(px[2])) / (3 * 255)
    }

    /// Decodes PNG `Data` back to a `CGImage`.
    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Returns the quadrant carrying the brightest sample.
    private func brightestQuadrant(of image: CGImage) -> Quadrant {
        Quadrant.allCases.max(by: { brightness(of: image, at: $0.center) < brightness(of: image, at: $1.center) })!
    }

    @Test("orientation: .right rotates the OUTPUT upright; top-left marker lands top-right")
    func rightOrientationRotatesOutput() throws {
        let image = try topLeftMarkerImage()
        // Frame the WHOLE image so the crop keeps the both-axis asymmetry.
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

        let upData = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: whole, padding: 0, orientation: .up))
        let rightData = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: whole, padding: 0, orientation: .right))

        // (b) The oriented output must differ from the un-oriented one.
        #expect(rightData != upData)

        let up = try decode(upData)
        let right = try decode(rightData)

        // Sanity: the un-oriented render keeps the marker in the top-left quadrant.
        #expect(brightestQuadrant(of: up) == .topLeft)

        // (a) Hand-computed for EXIF .right (value 6, "Right, Top" pixel semantics):
        // stored (col,row) → display (H-1-row, col), so a top-left marker maps to the
        // TOP-RIGHT quadrant. This discriminates .right from .up (top-left),
        // .left/90°CCW (bottom-left) and 180° (bottom-right).
        #expect(brightness(of: right, at: Quadrant.topRight.center) > 0.5)
        #expect(brightness(of: right, at: Quadrant.topLeft.center) < 0.5)
        #expect(brightness(of: right, at: Quadrant.bottomLeft.center) < 0.5)
        #expect(brightness(of: right, at: Quadrant.bottomRight.center) < 0.5)
        #expect(brightestQuadrant(of: right) == .topRight)
    }

    @Test("orientation: .up / default is a genuine no-op (equals the un-oriented composition)")
    func upOrientationIsNoOp() throws {
        let image = try topLeftMarkerImage()
        let rect = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)

        // The explicit un-oriented composition the .up path must bypass orientation to equal.
        let cropped = try #require(FaceThumbnail.crop(image, normalizedRect: rect, padding: 0.15))
        let scaled = FaceThumbnail.downsample(cropped, maxPixel: FaceThumbnail.defaultMaxPixel)
        let baseline = try #require(FaceThumbnail.encodePNG(scaled))

        let upExplicit = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: rect, orientation: .up))
        let defaulted = try #require(FaceThumbnail.croppedPNG(from: image, normalizedRect: rect))

        #expect(upExplicit == baseline)
        #expect(defaulted == baseline)
    }

    // MARK: - EXIF read helper (ImageIO only, no model)

    /// Writes `image` to a temp JPEG, optionally tagging an EXIF orientation.
    private func writeJPEG(_ image: CGImage, orientation: UInt32?) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-orient-\(UUID().uuidString).jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test("orientation(at:) reads EXIF orientation 6 as .right and a no-EXIF image as .up")
    func orientationHelperReadsExif() throws {
        let image = try solidImage(width: 40, height: 60)

        let tagged = try writeJPEG(image, orientation: 6)
        defer { try? FileManager.default.removeItem(at: tagged) }
        #expect(LiveTriageEngine.orientation(at: tagged) == .right)

        let untagged = try writeJPEG(image, orientation: nil)
        defer { try? FileManager.default.removeItem(at: untagged) }
        #expect(LiveTriageEngine.orientation(at: untagged) == .up)
    }
}
