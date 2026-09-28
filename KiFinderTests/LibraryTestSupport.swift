import CoreGraphics
import Foundation
import ImageIO
@testable import KiFinder
import UniformTypeIdentifiers

/// Shared fixtures + test doubles for the item-18a kept-photo library suites.
enum LibraryFixtures {
    /// A fresh, isolated temp directory.
    static func tempDir(_ tag: String = "kion-lib") -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a small JPEG with a distinct color (so distinct `red` ⇒ distinct bytes)
    /// and an optional EXIF `DateTimeOriginal` (format `yyyy:MM:dd HH:mm:ss`).
    @discardableResult
    static func writeImage(to url: URL, red: CGFloat = 0.5, exifDate: String? = nil) -> Bool {
        let side = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        var props: [CFString: Any] = [:]
        if let exifDate {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A sample candidate carrying a `sourceURL` (so the keep-hook can save it).
    static func candidate(id: String, source: URL, fileName: String = "IMG.jpg") -> Candidate {
        Candidate(
            id: id,
            photoKey: "lib/\(id).jpg",
            fileName: fileName,
            imageResourceName: "",
            score: 0.91,
            bucket: .other,
            sourceURL: source
        )
    }
}

/// Counts `schedule` vs materialized writes so a test can prove coalescing: a burst of
/// saves schedules N times with 0 writes, then `flush()` performs exactly one write
/// carrying the latest full index.
final class SpyKeptIndexWriter: KeptIndexWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var scheduledCount = 0
    private(set) var materializedWrites = 0
    private(set) var lastScheduled: [KeptEntry] = []
    private(set) var lastWritten: [KeptEntry] = []

    func schedule(_ entries: [KeptEntry]) {
        lock.withLock {
            scheduledCount += 1
            lastScheduled = entries
        }
    }

    func flush() async {
        lock.withLock {
            materializedWrites += 1
            lastWritten = lastScheduled
        }
    }
}

/// A save seam whose `save` suspends until `release()` is called, then delegates to a
/// real `KeptLibrary` so the copy actually lands. Proves Keep runs off the keypress
/// path: the decision is recorded before `save` completes.
final class SuspendingSaveSpy: KeptLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let wrapped: KeptLibrary

    init(wrapping wrapped: KeptLibrary) {
        self.wrapped = wrapped
    }

    var completedSaves: Int {
        lock.withLock { _completedSaves }
    }

    private var _completedSaves = 0

    var savedEntries: [KeptEntry] {
        wrapped.allEntries
    }

    var allEntries: [KeptEntry] {
        wrapped.allEntries
    }

    func remove(_ entry: KeptEntry) async -> Bool {
        await wrapped.remove(entry)
    }

    func save(originalAt source: URL, subjectId: String, personName: String, score: Double) async -> KeptSaveResult {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        let result = await wrapped.save(originalAt: source, subjectId: subjectId, personName: personName, score: score)
        lock.withLock { _completedSaves += 1 }
        return result
    }

    func isSaved(sourcePath: String, subjectId: String) -> Bool {
        wrapped.isSaved(sourcePath: sourcePath, subjectId: subjectId)
    }

    func flush() async {
        await wrapped.flush()
    }

    /// Lets every suspended (and future) `save` proceed.
    func release() {
        lock.lock()
        released = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// An in-memory `SkipRecording` spy for the item-48 "hide already reviewed" AppModel
/// tests: records every `recordSkip`/`clearSkip` call (so a test can prove the skip is
/// recorded once and cleared on a keep) and can be pre-loaded with prior-scan skips
/// (`[subjectId: {sourcePath}]`) to exercise the persistent-skip hide path without disk.
final class SpySkipStore: SkipRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var skips: [String: Set<String>]
    private var _recordCalls: [(sourcePath: String, subjectId: String)] = []
    private var _clearCalls: [(sourcePath: String, subjectId: String)] = []

    init(preloaded: [String: Set<String>] = [:]) {
        skips = preloaded
    }

    var recordCalls: [(sourcePath: String, subjectId: String)] {
        lock.withLock { _recordCalls }
    }

    var clearCalls: [(sourcePath: String, subjectId: String)] {
        lock.withLock { _clearCalls }
    }

    func isSkipped(sourcePath: String, subjectId: String) -> Bool {
        lock.withLock { skips[subjectId]?.contains(sourcePath) ?? false }
    }

    func recordSkip(sourcePath: String, subjectId: String) {
        lock.withLock {
            _recordCalls.append((sourcePath, subjectId))
            skips[subjectId, default: []].insert(sourcePath)
        }
    }

    func clearSkip(sourcePath: String, subjectId: String) {
        lock.withLock {
            _clearCalls.append((sourcePath, subjectId))
            skips[subjectId]?.remove(sourcePath)
        }
    }

    func flush() async {}
}

/// A `KeptLibrarySaving` whose `renameSubject` suspends until `release()` is called.
/// Records the id/name it was called with so a test can prove `AppModel.renamePerson`
/// runs the migration off the keypress path (returns before the spy is released) and
/// passes through the right arguments.
final class SuspendingRenameSpy: KeptLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private let wrapped: KeptLibrary

    init(wrapping wrapped: KeptLibrary) {
        self.wrapped = wrapped
    }

    private var _calls: [(subjectId: String, newName: String)] = []
    var calls: [(subjectId: String, newName: String)] {
        lock.withLock { _calls }
    }

    var renameStarted: Bool {
        lock.withLock { !_calls.isEmpty }
    }

    var allEntries: [KeptEntry] {
        wrapped.allEntries
    }

    func save(originalAt source: URL, subjectId: String, personName: String, score: Double) async -> KeptSaveResult {
        await wrapped.save(originalAt: source, subjectId: subjectId, personName: personName, score: score)
    }

    func isSaved(sourcePath: String, subjectId: String) -> Bool {
        wrapped.isSaved(sourcePath: sourcePath, subjectId: subjectId)
    }

    func remove(_ entry: KeptEntry) async -> Bool {
        await wrapped.remove(entry)
    }

    func renameSubject(_ subjectId: String, to newName: String) async {
        lock.withLock { _calls.append((subjectId: subjectId, newName: newName)) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        await wrapped.renameSubject(subjectId, to: newName)
    }

    func flush() async {
        await wrapped.flush()
    }

    /// Lets the suspended (and any future) `renameSubject` proceed.
    func release() {
        lock.lock()
        released = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
