import Foundation
import ImageIO

/// Decides whether a dropped or injected file URL is an acceptable enrollment
/// reference: it must point at a local file that ImageIO can actually decode as
/// an image. Pure and synchronous so the drop handler and `EnrollmentModelTests`
/// exercise the exact same gate — no UI, no async, no mocks.
enum ReferenceImageValidator {
    static func isReferenceImage(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            return false
        }
        return true
    }
}
