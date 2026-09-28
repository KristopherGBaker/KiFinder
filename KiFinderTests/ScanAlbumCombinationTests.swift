import CoreGraphics
import Foundation
import ImageIO
@testable import KiFinder
import KionEngine
import Testing
import UniformTypeIdentifiers

/// A scan may mix folders and zip files in one call. This locks in the
/// model-independent first pass: each album is resolved by its own type (a folder
/// is enumerated in place; a `.zip` is extracted to a cache dir first) and every
/// album's images are enumerated.
@Suite("Scan accepts a combination of folders and zips")
struct ScanAlbumCombinationTests {
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kifinder-scan-combo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes VALID, decodable images (a 2×2 fill encoded as PNG or JPEG to match the
    /// extension) so the fixtures are real images — if a parent dir were wrongly
    /// enumerated, the sibling really would be a scannable candidate.
    private func writeImageFiles(_ names: [String], into dir: URL) throws {
        for name in names {
            let url = dir.appendingPathComponent(name)
            let ext = (name as NSString).pathExtension.lowercased()
            let utType: UTType = (ext == "png") ? .png : .jpeg
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Zips the contents of `dir` into a fresh `.zip` and returns its URL.
    private func makeZip(of dir: URL) throws -> URL {
        let zipURL = try makeTempDir().appendingPathComponent("album.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zipURL.path, "."]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zipURL
    }

    @Test("A single scan resolves a folder in place and a zip extracted, enumerating both")
    func folderAndZipTogether() throws {
        // Folder album with two images — scanned in place.
        let folder = try makeTempDir()
        try writeImageFiles(["a.jpg", "b.png"], into: folder)

        // Zip album built from a separate dir of two images.
        let zipSource = try makeTempDir()
        try writeImageFiles(["c.jpg", "d.jpg"], into: zipSource)
        let zip = try makeZip(of: zipSource)

        // A pipeline with a no-op embedder: enumeration is model-independent.
        let pipeline = ScanPipeline(embedFace: { _ in nil }, minDetectionScore: 0, minBoundingBoxArea: 0)
        let resolved = try LiveTriageEngine.resolveAndEnumerate(
            albums: [folder, zip],
            enumerate: pipeline.enumerateImages
        )

        // Both albums are present, in the order supplied.
        #expect(resolved.count == 2)

        // The folder is scanned IN PLACE (its root is the folder) with its 2 images.
        #expect(resolved[0].root.path == folder.path)
        #expect(Set(resolved[0].keys) == ["a.jpg", "b.png"])

        // The zip is EXTRACTED elsewhere (root is NOT the .zip, NOR the folder) with
        // its 2 images.
        #expect(resolved[1].root.path != zip.path)
        #expect(resolved[1].root.path != folder.path)
        #expect(Set(resolved[1].keys) == ["c.jpg", "d.jpg"])

        // Counts aggregate across the mixed batch.
        #expect(resolved.reduce(0) { $0 + $1.keys.count } == 4)
    }

    @Test("A loose image file merges with a folder, contributing only itself")
    func looseImageMergesWithFolder() throws {
        // Folder album with two images — scanned in place.
        let folder = try makeTempDir()
        try writeImageFiles(["a.jpg", "b.png"], into: folder)

        // A loose image file in a directory that ALSO holds a sibling image which must
        // NOT appear (a loose file scans as just itself).
        let looseDir = try makeTempDir()
        try writeImageFiles(["chosen.jpg", "neighbor.jpg"], into: looseDir)
        let looseImage = looseDir.appendingPathComponent("chosen.jpg")

        let pipeline = ScanPipeline(embedFace: { _ in nil }, minDetectionScore: 0, minBoundingBoxArea: 0)
        let resolved = try LiveTriageEngine.resolveAndEnumerate(
            albums: [looseImage, folder],
            enumerate: pipeline.enumerateImages
        )

        #expect(resolved.count == 2)

        // Loose image: root is its PARENT dir, the only key is its name; the sibling
        // ("neighbor.jpg") is absent.
        #expect(resolved[0].root.path == looseDir.path)
        #expect(resolved[0].keys == ["chosen.jpg"])
        #expect(!resolved[0].keys.contains("neighbor.jpg"))

        // Folder still contributes ALL its image keys, in place.
        #expect(resolved[1].root.path == folder.path)
        #expect(Set(resolved[1].keys) == ["a.jpg", "b.png"])

        // The resolved SOURCE for the loose key (root + key) is the ORIGINAL file URL,
        // so a later Keep→library / export acts on the real file.
        let looseSource = resolved[0].root.appendingPathComponent(resolved[0].keys[0])
        #expect(looseSource.path == looseImage.path)
    }

    @Test("An all-folders selection is unchanged: each folder in place, order preserved")
    func allFoldersRegressionRootNameKeysOrder() throws {
        let folder1 = try makeTempDir()
        try writeImageFiles(["a.jpg", "b.png"], into: folder1)
        let folder2 = try makeTempDir()
        try writeImageFiles(["c.png"], into: folder2)

        let pipeline = ScanPipeline(embedFace: { _ in nil }, minDetectionScore: 0, minBoundingBoxArea: 0)
        let resolved = try LiveTriageEngine.resolveAndEnumerate(
            albums: [folder1, folder2],
            enumerate: pipeline.enumerateImages
        )

        // Two folders, in the supplied order (folder1 then folder2).
        #expect(resolved.count == 2)
        #expect(resolved[0].root.path == folder1.path)
        #expect(resolved[0].name == folder1.lastPathComponent)
        #expect(Set(resolved[0].keys) == ["a.jpg", "b.png"])
        #expect(resolved[1].root.path == folder2.path)
        #expect(resolved[1].name == folder2.lastPathComponent)
        #expect(resolved[1].keys == ["c.png"])
    }
}
