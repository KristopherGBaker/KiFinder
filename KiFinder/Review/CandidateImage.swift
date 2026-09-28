import AppKit
import ImageIO
import SwiftUI

/// Renders a candidate's image. A live candidate loads a downsampled thumbnail
/// from its on-disk source URL off the main thread (so large real albums stay
/// responsive and memory-bounded); a sample candidate renders its bundled asset.
struct CandidateImage: View {
    let candidate: Candidate
    var maxPixel: CGFloat = 600

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if candidate.sourceURL != nil {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if failed {
                    placeholder
                } else {
                    placeholder.redacted(reason: .placeholder)
                }
            } else if !candidate.imageResourceName.isEmpty {
                ResourceImage(resourceName: candidate.imageResourceName, contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: candidate.sourceURL) { await load() }
    }

    private var placeholder: some View {
        DesignColor.hairline
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(DesignColor.inkSecondary)
            }
    }

    private func load() async {
        guard let url = candidate.sourceURL else { return }
        let px = maxPixel
        let loaded = await Task.detached(priority: .userInitiated) {
            CandidateImage.downsample(url: url, maxPixel: px)
        }.value
        if let loaded {
            image = loaded
        } else {
            failed = true
        }
    }

    /// Loads a thumbnail capped at `maxPixel` on its longest edge via ImageIO —
    /// never decoding the full-resolution image into memory.
    nonisolated static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
