import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-device face-crop thumbnailing. Given a source image and a detected face's
/// rectangle, it crops the face region and downsamples it to a bounded edge,
/// returning PNG `Data` ready to cache via `ProfileRepository.saveThumbnail`.
///
/// The crop rect is expressed the same way `KionEngine`'s `NormalizedRect` is —
/// normalized (0…1), **top-left** origin, in the image's raw (un-oriented) pixel
/// space — which matches `CGImage`'s top-left pixel coordinate system, so no
/// flip is needed. Everything runs through CoreGraphics/ImageIO; no network.
enum FaceThumbnail {
    /// Default longest-edge size of a produced thumbnail, in pixels.
    static let defaultMaxPixel: CGFloat = 256

    /// Crops `normalizedRect` (top-left, 0…1) from `image`, optionally padding the
    /// box outward so the crop frames the whole head, then downsamples the crop to
    /// `maxPixel` on its longest edge, rotates the result to upright per the source's
    /// EXIF `orientation`, and encodes it as PNG `Data`. Returns `nil` when the rect
    /// doesn't intersect the image or encoding fails.
    ///
    /// The `normalizedRect` is interpreted in the image's RAW (un-oriented) top-left
    /// pixel space and the crop is taken in that raw space — so detection geometry is
    /// unchanged. The `orientation` is applied only to the final cropped+downsampled
    /// image, turning a sideways source into an upright thumbnail. `.up` is a no-op.
    static func croppedPNG(
        from image: CGImage,
        normalizedRect: CGRect,
        maxPixel: CGFloat = defaultMaxPixel,
        padding: CGFloat = 0.15,
        orientation: CGImagePropertyOrientation = .up
    ) -> Data? {
        guard let cropped = crop(image, normalizedRect: normalizedRect, padding: padding) else {
            return nil
        }
        let scaled = downsample(cropped, maxPixel: maxPixel)
        let oriented = applyOrientation(scaled, orientation)
        return encodePNG(oriented)
    }

    /// Loads `url` via ImageIO and produces a cropped-face PNG (see `croppedPNG`).
    static func croppedPNG(
        fromImageAt url: URL,
        normalizedRect: CGRect,
        maxPixel: CGFloat = defaultMaxPixel,
        padding: CGFloat = 0.15
    ) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return croppedPNG(from: image, normalizedRect: normalizedRect, maxPixel: maxPixel, padding: padding)
    }

    /// Converts a normalized (top-left, 0…1) rect to integral pixels, pads it
    /// outward by `padding` of its size, clamps to the image bounds, and crops.
    static func crop(_ image: CGImage, normalizedRect: CGRect, padding: CGFloat = 0.15) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }

        let padX = normalizedRect.width * padding
        let padY = normalizedRect.height * padding
        var rect = CGRect(
            x: (normalizedRect.minX - padX) * width,
            y: (normalizedRect.minY - padY) * height,
            width: (normalizedRect.width + 2 * padX) * width,
            height: (normalizedRect.height + 2 * padY) * height
        )
        // Clamp to the image so a near-edge face still crops cleanly.
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }

        let pixelRect = CGRect(
            x: rect.minX.rounded(.down),
            y: rect.minY.rounded(.down),
            width: rect.width.rounded(.toNearestOrAwayFromZero),
            height: rect.height.rounded(.toNearestOrAwayFromZero)
        )
        return image.cropping(to: pixelRect)
    }

    /// Redraws `image` so its longest edge is at most `maxPixel`, preserving aspect
    /// ratio. Images already within bounds are returned unchanged.
    static func downsample(_ image: CGImage, maxPixel: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxPixel, maxPixel > 0 else { return image }

        let scale = maxPixel / longest
        let targetWidth = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(image.height) * scale).rounded()))

        // Force a standard 8-bit RGBA context so any source pixel format (RGB,
        // grayscale, indexed…) draws into a known, encodable layout.
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    /// Rotates/flips `image` to upright per its source EXIF `orientation`. `.up`
    /// returns the input untouched (a genuine no-op — identical bytes downstream);
    /// any other value is realized through CoreImage's `oriented(_:)` and rendered
    /// back to a `CGImage`. Falls back to the input if the render fails.
    static func applyOrientation(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let context = CIContext(options: nil)
        guard let result = context.createCGImage(oriented, from: oriented.extent) else {
            return image
        }
        return result
    }

    /// Encodes a `CGImage` to PNG `Data`.
    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
