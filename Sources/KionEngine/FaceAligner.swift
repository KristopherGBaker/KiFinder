import CoreGraphics
import CoreImage
import Foundation
import Vision

/// How raw `[0, 255]` pixel bytes become the model's input tensor values.
/// Only `.raw` (an identity `Float(byte)` pass-through) is wired today —
/// what ArcFace's `arcfaceresnet100-8` expects, since it has no input-
/// normalization layer of its own (see `FaceAligner.rgbInputTensor`). A
/// future non-ArcFace provider that DOES expect e.g. `(x - mean) / std`
/// would add a case here rather than touching `FaceAligner`'s packing loop.
public enum PixelNormalization: Sendable, Equatable {
    case raw
}

/// A model-parameterized description of an alignment pipeline: the aligned
/// chip's size, the canonical (destination) landmark template a detected
/// face's own landmarks are warped onto, and how raw pixel bytes become
/// tensor values. `FaceAligner` reads a spec rather than hardcoding ArcFace's
/// numbers, so a different embedding model (e.g. a Vision-FeaturePrint
/// provider) can supply its own spec — or skip alignment entirely — without
/// changing a line of `FaceAligner`'s geometry.
public struct AlignmentSpec: Sendable {
    public var chipSize: Int
    public var canonicalLandmarks: [CGPoint]
    public var pixelNormalization: PixelNormalization

    public init(chipSize: Int, canonicalLandmarks: [CGPoint], pixelNormalization: PixelNormalization) {
        self.chipSize = chipSize
        self.canonicalLandmarks = canonicalLandmarks
        self.pixelNormalization = pixelNormalization
    }

    /// ArcFace's (`arcfaceresnet100-8`) 112×112 chip and 5-point canonical
    /// template — today's only wired spec, and byte-identical to the
    /// constants `FaceEmbedder` hardcoded before this extraction.
    public static let arcface = AlignmentSpec(
        chipSize: 112,
        canonicalLandmarks: [
            CGPoint(x: 38.2946, y: 51.6963),
            CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366),
            CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041),
        ],
        pixelNormalization: .raw
    )
}

/// The shared Vision-detection → landmark-selection → warp → normalize
/// pipeline, extracted out of `FaceEmbedder` (item 62) so it is reusable and
/// model-parameterized rather than ONNX-specific. `FaceAligner` touches NO
/// ONNX symbol — it is pure geometry over a `CGImage`, driven entirely by its
/// immutable `AlignmentSpec` — which is what lets a non-ArcFace embedding
/// provider reuse it (or bring its own spec, or skip alignment) without
/// depending on the ONNX-runtime shim module `FaceEmbedder` links against.
///
/// This is a byte-identical extraction: every function body below is the
/// verbatim code that used to live directly on `FaceEmbedder`, with exactly
/// two substitutions — the literal `112` reads `spec.chipSize`, and the
/// literal 5-point template reads `spec.canonicalLandmarks` — plus
/// `rgbInputTensor` now switches over `spec.pixelNormalization` instead of
/// hardcoding `Float(byte)` (the wired `.raw` case IS that exact pass-through,
/// so today's embeddings are unaffected).
public struct FaceAligner: Sendable {
    public let spec: AlignmentSpec

    public init(spec: AlignmentSpec = .arcface) {
        self.spec = spec
    }

    public struct AlignedFace {
        public var image: CGImage
        public var qualityMetrics: QualityMetrics
    }

    /// The single most prominent face, for enrollment.
    public func alignedFace(in image: CGImage) throws -> AlignedFace? {
        try alignedFaces(in: image)
            .max { $0.qualityMetrics.detectionScore < $1.qualityMetrics.detectionScore }
    }

    /// Every detectable face, aligned. Prefers Vision (which finds all faces);
    /// falls back to a single Core Image face, then the blind heuristic.
    public func alignedFaces(in image: CGImage) throws -> [AlignedFace] {
        if let faces = try? visionAlignedFaces(in: image), !faces.isEmpty {
            return faces
        }
        if let face = try? coreImageAlignedFace(in: image) {
            return [face]
        }
        if let face = try heuristicAlignedFace(in: image) {
            return [face]
        }
        return []
    }

    func visionAlignedFaces(in image: CGImage) throws -> [AlignedFace] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([faceRequest])

        guard let faceObservations = faceRequest.results, !faceObservations.isEmpty else {
            return []
        }

        // One landmark pass for all detected faces.
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        landmarkRequest.inputFaceObservations = faceObservations
        try handler.perform([landmarkRequest])

        let rgba = try Self.rgbaPixels(from: image)
        return (landmarkRequest.results ?? []).compactMap { observation in
            // Detect landmarks if available, but never drop a detected face just
            // because they are incomplete: fall back to box-derived alignment so
            // every detected rectangle still yields a selectable, scorable face.
            let landmarks = Self.fiveLandmarks(
                from: observation,
                imageWidth: image.width,
                imageHeight: image.height
            )
            guard let sourceLandmarks = Self.alignmentPoints(
                landmarks: landmarks,
                boundingBox: observation.boundingBox,
                imageWidth: image.width,
                imageHeight: image.height
            ) else {
                // Only reached for a degenerate bounding box.
                return nil
            }
            guard let aligned = try? warp(
                rgba: rgba,
                width: image.width,
                height: image.height,
                sourceLandmarks: sourceLandmarks
            ) else {
                return nil
            }

            let boundingBoxArea = Float(observation.boundingBox.width * CGFloat(image.width)
                * observation.boundingBox.height * CGFloat(image.height))
            return AlignedFace(
                image: aligned,
                qualityMetrics: QualityMetrics(
                    detectionScore: observation.confidence,
                    boundingBoxArea: boundingBoxArea,
                    // Vision reports a normalized, bottom-left-origin box; flip Y to the
                    // top-left convention used by NormalizedRect.
                    faceBoundingBox: NormalizedRect(
                        x: Float(observation.boundingBox.minX),
                        y: Float(1 - observation.boundingBox.maxY),
                        width: Float(observation.boundingBox.width),
                        height: Float(observation.boundingBox.height)
                    )
                )
            )
        }
    }

    /// Pure selector seam for per-observation alignment points. Returns the
    /// supplied landmark set when it is a complete 5-point set; otherwise the
    /// bounding-box-derived fallback; otherwise `nil` only when the box is
    /// degenerate. Keeps the no-drop rule testable without running Vision.
    static func alignmentPoints(
        landmarks: [CGPoint]?,
        boundingBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> [CGPoint]? {
        if let landmarks, landmarks.count == 5 {
            return landmarks
        }
        return boundingBoxLandmarks(
            for: boundingBox,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    /// Derives the 5 canonical alignment points (leftEye, rightEye, nose,
    /// mouthLeft, mouthRight) from a detected bounding box alone, used when
    /// Vision fails to produce complete landmarks. The box is a normalized,
    /// bottom-left-origin `VNFaceObservation.boundingBox`; points are returned
    /// in top-left image-pixel coordinates. Proportions mirror
    /// `heuristicAlignedFace`, scaled/translated to the detected box. Returns
    /// `nil` for a degenerate box (zero/negative size or no image overlap).
    static func boundingBoxLandmarks(
        for boundingBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> [CGPoint]? {
        // CGRect.width/.height return the standardized (always non-negative)
        // extent, so a negative-size box would slip through; check the raw,
        // sign-preserving size to reject negatives as degenerate.
        guard boundingBox.size.width > 0, boundingBox.size.height > 0,
              imageWidth > 0, imageHeight > 0
        else {
            return nil
        }

        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)

        // Convert the normalized, bottom-left box to a top-left pixel rect,
        // matching the Y-flip used to derive `faceBoundingBox`.
        let originX = boundingBox.minX * width
        let originY = (1 - boundingBox.maxY) * height
        let boxWidth = boundingBox.width * width
        let boxHeight = boundingBox.height * height
        let pixelBox = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)

        // Reject a box with no overlap with the image rect.
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard pixelBox.intersects(imageRect) else {
            return nil
        }

        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: originX + fx * boxWidth, y: originY + fy * boxHeight)
        }

        return [
            point(0.40, 0.42),
            point(0.60, 0.42),
            point(0.50, 0.54),
            point(0.43, 0.66),
            point(0.57, 0.66),
        ]
    }

    func coreImageAlignedFace(in image: CGImage) throws -> AlignedFace? {
        let ciImage = CIImage(cgImage: image)
        let detector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) as? [CIFaceFeature] ?? []
        guard let feature = features.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            return nil
        }
        guard feature.hasLeftEyePosition,
              feature.hasRightEyePosition,
              feature.hasMouthPosition
        else {
            throw FaceEmbedderError.landmarkDetectionFailed
        }

        let leftEye = Self.topLeftPoint(feature.leftEyePosition, imageHeight: image.height)
        let rightEye = Self.topLeftPoint(feature.rightEyePosition, imageHeight: image.height)
        let mouthCenter = Self.topLeftPoint(feature.mouthPosition, imageHeight: image.height)
        let eyeMidpoint = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        let eyeDelta = CGPoint(x: rightEye.x - leftEye.x, y: rightEye.y - leftEye.y)
        let eyeDistance = max(hypot(eyeDelta.x, eyeDelta.y), 1)
        let mouthHalfWidth = eyeDistance * 0.32
        let eyeUnit = CGPoint(x: eyeDelta.x / eyeDistance, y: eyeDelta.y / eyeDistance)
        let nose = CGPoint(
            x: eyeMidpoint.x + (mouthCenter.x - eyeMidpoint.x) * 0.55,
            y: eyeMidpoint.y + (mouthCenter.y - eyeMidpoint.y) * 0.55
        )
        let mouthLeft = CGPoint(
            x: mouthCenter.x - eyeUnit.x * mouthHalfWidth,
            y: mouthCenter.y - eyeUnit.y * mouthHalfWidth
        )
        let mouthRight = CGPoint(
            x: mouthCenter.x + eyeUnit.x * mouthHalfWidth,
            y: mouthCenter.y + eyeUnit.y * mouthHalfWidth
        )

        let rgba = try Self.rgbaPixels(from: image)
        let aligned = try warp(
            rgba: rgba,
            width: image.width,
            height: image.height,
            sourceLandmarks: [leftEye, rightEye, nose, mouthLeft, mouthRight]
        )

        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        return AlignedFace(
            image: aligned,
            qualityMetrics: QualityMetrics(
                detectionScore: 1,
                boundingBoxArea: Float(feature.bounds.width * feature.bounds.height),
                // CIFaceFeature bounds are in raw pixels with a bottom-left origin;
                // normalize and flip Y to the top-left convention.
                faceBoundingBox: NormalizedRect(
                    x: Float(feature.bounds.minX / imageWidth),
                    y: Float((imageHeight - feature.bounds.maxY) / imageHeight),
                    width: Float(feature.bounds.width / imageWidth),
                    height: Float(feature.bounds.height / imageHeight)
                )
            )
        )
    }

    func heuristicAlignedFace(in image: CGImage) throws -> AlignedFace? {
        let rgba = try Self.rgbaPixels(from: image)
        guard Self.isLikelyNonBlank(rgba) else {
            return nil
        }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let sourceLandmarks = [
            CGPoint(x: width * 0.40, y: height * 0.42),
            CGPoint(x: width * 0.60, y: height * 0.42),
            CGPoint(x: width * 0.50, y: height * 0.54),
            CGPoint(x: width * 0.43, y: height * 0.66),
            CGPoint(x: width * 0.57, y: height * 0.66),
        ]
        let aligned = try warp(
            rgba: rgba,
            width: image.width,
            height: image.height,
            sourceLandmarks: sourceLandmarks
        )

        // A blind guess, not a detection: no detector localized a face, so there is
        // no real confidence to report. `detectionScore: 0` says exactly that
        // (rather than the old `1`, which lied that this was a maximum-confidence
        // detection); `isFallback: true` is the authoritative, unguessable signal
        // consumers should gate on — see `QualityMetrics.isFallback`.
        return AlignedFace(
            image: aligned,
            qualityMetrics: QualityMetrics(
                detectionScore: 0,
                boundingBoxArea: Float(width * height * 0.25),
                isFallback: true
            )
        )
    }

    /// Reproduces the manual-region (item 19) inline align sequence for an
    /// arbitrary user-drawn box, with no landmark detector involved: derives 5
    /// alignment points from the box alone (`alignmentPoints`), then warps the
    /// chip. Returns `nil` for a degenerate box (the `alignmentPoints`
    /// nil-guard); a thrown error surfaces an image-conversion or geometry
    /// failure, which `FaceEmbedder.embedFace(in:regionBoundingBox:)` flattens
    /// to `nil` via `try?`, exactly as it did before this extraction.
    public func alignedChip(in image: CGImage, regionBoundingBox boundingBox: CGRect) throws -> CGImage? {
        guard let sourceLandmarks = Self.alignmentPoints(
            landmarks: nil,
            boundingBox: boundingBox,
            imageWidth: image.width,
            imageHeight: image.height
        ) else {
            return nil
        }
        let rgba = try Self.rgbaPixels(from: image)
        return try warp(
            rgba: rgba,
            width: image.width,
            height: image.height,
            sourceLandmarks: sourceLandmarks
        )
    }

    public func rgbInputTensor(from112x112 image: CGImage) throws -> [Float] {
        guard image.width == spec.chipSize, image.height == spec.chipSize else {
            throw FaceEmbedderError.imageConversionFailed
        }
        let rgba = try Self.rgbaPixels(from: image)
        let chip = spec.chipSize
        let planeSize = chip * chip
        var tensor = [Float](repeating: 0, count: 3 * planeSize)

        // arcfaceresnet100-8 has no input-normalization layer: it is trained on
        // and expects raw planar RGB pixel values in [0, 255] (CHW), exactly as
        // in the ONNX model-zoo reference preprocessing. Pre-scaling to [-1, 1]
        // starves the first convolution and collapses every embedding onto a
        // shared direction (cosine ~0.99 for all faces), so the raw RGB bytes
        // are passed through unchanged — via `spec.pixelNormalization`, which
        // makes that choice an explicit, model-parameterized fact rather than a
        // hardcoded assumption.
        for y in 0 ..< chip {
            for x in 0 ..< chip {
                let pixelIndex = (y * chip + x) * 4
                let tensorIndex = y * chip + x
                tensor[tensorIndex] = normalizedValue(rgba[pixelIndex])
                tensor[planeSize + tensorIndex] = normalizedValue(rgba[pixelIndex + 1])
                tensor[2 * planeSize + tensorIndex] = normalizedValue(rgba[pixelIndex + 2])
            }
        }

        return tensor
    }

    /// Selects the per-pixel tensor value for `spec.pixelNormalization`. Only
    /// `.raw` is wired: the exact `Float(byte)` pass-through, byte-identical to
    /// what `FaceEmbedder.rgbInputTensor` hardcoded before this extraction.
    private func normalizedValue(_ byte: UInt8) -> Float {
        switch spec.pixelNormalization {
        case .raw:
            return Float(byte)
        }
    }

    static func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Context creation AND the draw must both happen inside the same
        // `withUnsafeMutableBytes` closure: that's the only scope for which Swift
        // guarantees the buffer pointer stays valid. Passing `&pixels` directly to
        // `CGContext(data:)` (the prior approach) only guarantees the pointer for the
        // duration of that single call — the following `context.draw(...)` would then
        // write through a pointer with no lifetime guarantee. It happened to work
        // because the array's allocation wasn't moved, but that's undefined behavior,
        // not a guarantee.
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw FaceEmbedderError.imageConversionFailed
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    static func fiveLandmarks(from observation: VNFaceObservation, imageWidth: Int, imageHeight: Int) -> [CGPoint]? {
        guard let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye
        else {
            return nil
        }

        let nosePoint: CGPoint?
        if let noseCrest = landmarks.noseCrest, let last = noseCrest.normalizedPoints.last {
            nosePoint = convert(last, in: observation.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight)
        } else if let nose = landmarks.nose {
            nosePoint = center(of: nose, in: observation.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight)
        } else {
            nosePoint = nil
        }

        guard let nosePoint else {
            return nil
        }

        let mouthCorners: (CGPoint, CGPoint)?
        if let outerLips = landmarks.outerLips {
            let points = outerLips.normalizedPoints.map {
                convert($0, in: observation.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight)
            }
            guard let left = points.min(by: { $0.x < $1.x }),
                  let right = points.max(by: { $0.x < $1.x })
            else {
                return nil
            }
            mouthCorners = (left, right)
        } else {
            mouthCorners = nil
        }

        guard let mouthCorners else {
            return nil
        }

        return [
            center(of: leftEye, in: observation.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight),
            center(of: rightEye, in: observation.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight),
            nosePoint,
            mouthCorners.0,
            mouthCorners.1,
        ]
    }

    static func center(
        of region: VNFaceLandmarkRegion2D,
        in boundingBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGPoint {
        let points = region.normalizedPoints
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return convert(
            CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count)),
            in: boundingBox,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    static func convert(_ point: CGPoint, in boundingBox: CGRect, imageWidth: Int, imageHeight: Int) -> CGPoint {
        let x = (boundingBox.minX + point.x * boundingBox.width) * CGFloat(imageWidth)
        let yBottom = (boundingBox.minY + point.y * boundingBox.height) * CGFloat(imageHeight)
        return CGPoint(x: x, y: CGFloat(imageHeight) - yBottom)
    }

    static func topLeftPoint(_ point: CGPoint, imageHeight: Int) -> CGPoint {
        CGPoint(x: point.x, y: CGFloat(imageHeight) - point.y)
    }

    static func isLikelyNonBlank(_ rgba: [UInt8]) -> Bool {
        var minimum = UInt8.max
        var maximum = UInt8.min
        var index = 0
        while index < rgba.count {
            minimum = min(minimum, rgba[index], rgba[index + 1], rgba[index + 2])
            maximum = max(maximum, rgba[index], rgba[index + 1], rgba[index + 2])
            index += 4 * 97
        }
        return Int(maximum) - Int(minimum) > 20
    }

    func warp(rgba: [UInt8], width: Int, height: Int, sourceLandmarks: [CGPoint]) throws -> CGImage {
        let chip = spec.chipSize
        let transform = try Self.affineTransform(from: spec.canonicalLandmarks, to: sourceLandmarks)
        var aligned = [UInt8](repeating: 0, count: chip * chip * 4)

        for y in 0 ..< chip {
            for x in 0 ..< chip {
                let source = Self.apply(transform, to: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let sampled = Self.bilinearSample(rgba: rgba, width: width, height: height, x: source.x, y: source.y)
                let index = (y * chip + x) * 4
                aligned[index] = sampled.0
                aligned[index + 1] = sampled.1
                aligned[index + 2] = sampled.2
                aligned[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(aligned) as CFData),
              let image = CGImage(
                  width: chip,
                  height: chip,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: chip * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            throw FaceEmbedderError.imageConversionFailed
        }

        return image
    }

    static func affineTransform(from source: [CGPoint], to destination: [CGPoint]) throws -> [CGFloat] {
        guard source.count == destination.count, source.count >= 3 else {
            throw FaceEmbedderError.landmarkDetectionFailed
        }

        var normal = Array(repeating: Array(repeating: CGFloat(0), count: 3), count: 3)
        var rhsX = Array(repeating: CGFloat(0), count: 3)
        var rhsY = Array(repeating: CGFloat(0), count: 3)

        for index in source.indices {
            let row = [source[index].x, source[index].y, CGFloat(1)]
            for r in 0 ..< 3 {
                rhsX[r] += row[r] * destination[index].x
                rhsY[r] += row[r] * destination[index].y
                for c in 0 ..< 3 {
                    normal[r][c] += row[r] * row[c]
                }
            }
        }

        let xCoefficients = try solve(normal, rhsX)
        let yCoefficients = try solve(normal, rhsY)
        return xCoefficients + yCoefficients
    }

    static func solve(_ matrix: [[CGFloat]], _ rhs: [CGFloat]) throws -> [CGFloat] {
        var augmented = matrix.enumerated().map { index, row in row + [rhs[index]] }

        for pivot in 0 ..< 3 {
            let maxRow = (pivot ..< 3).max { abs(augmented[$0][pivot]) < abs(augmented[$1][pivot]) }!
            if abs(augmented[maxRow][pivot]) < 1e-8 {
                throw FaceEmbedderError.landmarkDetectionFailed
            }
            if maxRow != pivot {
                augmented.swapAt(maxRow, pivot)
            }

            let divisor = augmented[pivot][pivot]
            for column in pivot ..< 4 {
                augmented[pivot][column] /= divisor
            }

            for row in 0 ..< 3 where row != pivot {
                let factor = augmented[row][pivot]
                for column in pivot ..< 4 {
                    augmented[row][column] -= factor * augmented[pivot][column]
                }
            }
        }

        return (0 ..< 3).map { augmented[$0][3] }
    }

    static func apply(_ transform: [CGFloat], to point: CGPoint) -> CGPoint {
        CGPoint(
            x: transform[0] * point.x + transform[1] * point.y + transform[2],
            y: transform[3] * point.x + transform[4] * point.y + transform[5]
        )
    }

    static func bilinearSample(
        rgba: [UInt8],
        width: Int,
        height: Int,
        x: CGFloat,
        y: CGFloat
    ) -> (UInt8, UInt8, UInt8) {
        if x < 0 || y < 0 || x >= CGFloat(width - 1) || y >= CGFloat(height - 1) {
            return (0, 0, 0)
        }

        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let xWeight = Float(x - CGFloat(x0))
        let yWeight = Float(y - CGFloat(y0))

        let p00 = pixel(rgba, width: width, x: x0, y: y0)
        let p10 = pixel(rgba, width: width, x: x0 + 1, y: y0)
        let p01 = pixel(rgba, width: width, x: x0, y: y0 + 1)
        let p11 = pixel(rgba, width: width, x: x0 + 1, y: y0 + 1)

        func interpolate(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 {
            let top = Float(a) * (1 - xWeight) + Float(b) * xWeight
            let bottom = Float(c) * (1 - xWeight) + Float(d) * xWeight
            return UInt8(max(0, min(255, top * (1 - yWeight) + bottom * yWeight)).rounded())
        }

        return (
            interpolate(p00.0, p10.0, p01.0, p11.0),
            interpolate(p00.1, p10.1, p01.1, p11.1),
            interpolate(p00.2, p10.2, p01.2, p11.2)
        )
    }

    static func pixel(_ rgba: [UInt8], width: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (rgba[index], rgba[index + 1], rgba[index + 2])
    }
}
