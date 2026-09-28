import Foundation
import ImageIO

/// The write side of the persistent kept-photo library. `AppModel` holds one behind
/// this seam so tests can inject a suspending save spy (to prove Keep is off the
/// keypress path) without a real filesystem.
protocol KeptLibrarySaving: AnyObject, Sendable {
    /// Saves the full-res original for a subject (see `KeptLibrary.save`).
    func save(originalAt source: URL, subjectId: String, personName: String, score: Double) async -> KeptSaveResult
    /// Cheap "already saved" hint for a candidate's source under a subject (matches a
    /// recorded `sourcePath`). Distinct from the authoritative hash dedupe at save.
    func isSaved(sourcePath: String, subjectId: String) -> Bool
    /// A snapshot of the current index (drives the item-18b browse UI / grouping).
    var allEntries: [KeptEntry] { get }
    /// Removes a saved copy + its index entry, re-enabling a future re-save of the same
    /// bytes for that subject (see `KeptLibrary.remove`).
    func remove(_ entry: KeptEntry) async -> Bool
    /// Redirects future saves to a new root (existing index untouched). Default no-op.
    func updateRoot(_ url: URL)
    /// Migrates a renamed subject's saved copies + index entries to the new display
    /// name (per-entry move + index rewrite; see `KeptLibrary.renameSubject`).
    /// Default no-op so the AppModel seam / save spies stay conformant.
    func renameSubject(_ subjectId: String, to newName: String) async
    /// Purges EVERY saved copy + index entry belonging to a deleted subject, re-enabling
    /// a future re-save of the same bytes for that subject (see `KeptLibrary.removeSubject`).
    /// Default no-op so the AppModel seam / save spies stay conformant.
    func removeSubject(_ subjectId: String) async
    /// Completes any pending (coalesced) index write before returning.
    func flush() async
    /// A one-time, plain-language notice when the on-disk index couldn't be read
    /// and was quarantined aside at construction (item 57); `nil` otherwise. The
    /// app model reads this once right after construction to surface the
    /// root-level data-integrity alert. Default `nil` so save spies/test doubles
    /// stay conformant without opting in.
    var quarantineNotice: String? { get }
}

extension KeptLibrarySaving {
    func updateRoot(_: URL) {}
    func renameSubject(_: String, to _: String) async {}
    func removeSubject(_: String) async {}
    var quarantineNotice: String? { nil }
}

/// App-layer store that durably copies a kept photo's full-res original into a
/// persistent on-disk library organized `<root>/<sanitized person>/<YYYY-MM>/<file>`,
/// deduped by per-person content hash, with a coalesced off-actor metadata index.
///
/// Concurrency: the in-memory index is guarded by a lock and file work runs on a
/// private serial queue, so `save` is safe to call from any task while `isSaved` is a
/// cheap synchronous read from the main actor. `@unchecked Sendable` is justified by
/// the lock guarding all mutable state.
final class KeptLibrary: KeptLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL
    private let indexWriter: any KeptIndexWriting
    /// In-memory index (authoritative for dedupe); persisted via `indexWriter`.
    private var entries: [KeptEntry]
    private let queue = DispatchQueue(label: "com.krisbaker.KiFinder.kept-library", qos: .utility)
    /// See `KeptLibrarySaving.quarantineNotice`. Set once at `init` when the index
    /// file existed but failed to decode (item 57).
    private(set) var quarantineNotice: String?

    /// - Parameters:
    ///   - root: the library root copies are written under.
    ///   - indexURL: where the metadata index is read from (init) and written to.
    ///   - indexWriter: persistence seam; defaults to the production coalescing writer
    ///     over `indexURL`.
    init(root: URL, indexURL: URL, indexWriter: (any KeptIndexWriting)? = nil) {
        self.root = root
        self.indexWriter = indexWriter ?? CoalescingKeptIndexWriter(indexURL: indexURL)
        let loaded = loadKeptIndexQuarantiningIfNeeded(from: indexURL)
        entries = loaded.entries
        quarantineNotice = loaded.notice
    }

    /// A snapshot of the current index (for the future browse UI / assertions).
    var allEntries: [KeptEntry] {
        lock.withLock { entries }
    }

    func updateRoot(_ url: URL) {
        lock.withLock { root = url }
    }

    func save(originalAt source: URL, subjectId: String, personName: String, score: Double) async -> KeptSaveResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: performSave(source: source, subjectId: subjectId, personName: personName, score: score))
            }
        }
    }

    func isSaved(sourcePath: String, subjectId: String) -> Bool {
        lock.withLock {
            entries.contains { $0.subjectId == subjectId && $0.sourcePath == sourcePath }
        }
    }

    /// Deletes the saved copy at `<root>/<entry.path>` (a missing file is fine), drops
    /// the matching entry from the in-memory index, and schedules a coalesced index
    /// write. Always reports success — removing the index entry is the durable effect,
    /// so a stale entry whose file already vanished is still cleaned up. Because the
    /// per-person hash dedupe checks the in-memory index, removing an entry re-enables
    /// re-saving the same bytes for that subject on a future Keep.
    func remove(_ entry: KeptEntry) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: performRemove(entry))
            }
        }
    }

    private func performRemove(_ entry: KeptEntry) -> Bool {
        let url = (lock.withLock { root }).appendingPathComponent(entry.path)
        // A missing-on-disk file is not an error — the index entry is the thing we must
        // drop (and the user may be removing a stale entry whose file is already gone).
        try? FileManager.default.removeItem(at: url)
        let snapshot: [KeptEntry] = lock.withLock {
            entries.removeAll { $0.id == entry.id }
            return entries
        }
        indexWriter.schedule(snapshot)
        return true
    }

    func flush() async {
        await indexWriter.flush()
    }

    // MARK: - Subject purge (person delete; off the main actor)

    /// Removes EVERY entry belonging to `subjectId`: deletes each backing file at
    /// `<root>/<entry.path>` (a missing file is tolerated), drops the entries from the
    /// in-memory index, then schedules the coalesced index write. Mirrors `remove(_:)`
    /// over a whole subject. Other subjects' files/entries are untouched. Because the
    /// per-person hash dedupe checks the in-memory index, dropping the entries re-enables
    /// re-saving the same bytes for that subject on a future Keep. Only the library's
    /// SAVED COPIES under the root are deleted — never the user's original sources.
    func removeSubject(_ subjectId: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                performRemoveSubject(subjectId)
                continuation.resume()
            }
        }
    }

    private func performRemoveSubject(_ subjectId: String) {
        let currentRoot = lock.withLock { root }
        // Snapshot the doomed entries under the lock; only this serial queue mutates
        // `entries`, so the file deletes below can run without holding it.
        let doomed = lock.withLock { entries.filter { $0.subjectId == subjectId } }
        for entry in doomed {
            // A missing-on-disk file is not an error — the index entry is the thing we
            // must drop, and the user's original source is never touched.
            try? FileManager.default.removeItem(at: currentRoot.appendingPathComponent(entry.path))
        }
        let snapshot: [KeptEntry] = lock.withLock {
            entries.removeAll { $0.subjectId == subjectId }
            return entries
        }
        indexWriter.schedule(snapshot)
    }

    // MARK: - Rename migration (off the main actor)

    /// Migrates every index entry belonging to `subjectId` so its saved copy lives under
    /// the new display name. Per-entry (NOT a blind folder move): only this subject's
    /// own entries move, so two people sharing a sanitized folder are unaffected. For
    /// each matching entry it moves the file from `<root>/<entry.path>` to
    /// `<root>/<sanitized newName>/<month>/<fileName>` (de-collided so distinct content
    /// is never overwritten), tolerates a missing source (still rewrites the entry), and
    /// rewrites the entry's `personName` + `path`. Month is the existing `path`'s middle
    /// segment when it is a valid `YYYY-MM`, else derived from `captureDate`. Replaces
    /// the entries under the lock, then schedules the coalesced index write.
    func renameSubject(_ subjectId: String, to newName: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                performRename(subjectId: subjectId, newName: newName)
                continuation.resume()
            }
        }
    }

    private func performRename(subjectId: String, newName: String) {
        let fileManager = FileManager.default
        let currentRoot = lock.withLock { root }
        let sanitizedNew = Self.sanitized(newName)

        // Snapshot under the lock, do the (slow) file moves WITHOUT holding it (only this
        // serial queue mutates `entries`, so no other write races us), then swap atomically.
        let original = lock.withLock { entries }
        var oldDirs: Set<String> = []
        let migrated: [KeptEntry] = original.map { entry in
            guard entry.subjectId == subjectId else { return entry }

            let month = Self.monthSegment(for: entry)
            let destFolder = currentRoot
                .appendingPathComponent(sanitizedNew, isDirectory: true)
                .appendingPathComponent(month, isDirectory: true)
            let source = currentRoot.appendingPathComponent(entry.path)
            oldDirs.insert(source.deletingLastPathComponent().path)

            let plainDest = destFolder.appendingPathComponent(entry.fileName)
            var dest: URL
            if source.standardizedFileURL == plainDest.standardizedFileURL {
                // In-place (e.g. a same-sanitized-folder rename): keep our own path, no move.
                dest = plainDest
            } else {
                // A real move OR a missing-on-disk source being re-homed: take a FREE,
                // de-collided slot so we never ADOPT an unrelated file already sitting at the
                // plain destination — a missing-source entry must keep `fileExists == false`.
                dest = Self.deCollidedURL(in: destFolder, fileName: entry.fileName, fileManager: fileManager)
                if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
                    try? fileManager.moveItem(at: source, to: dest)
                }
            }

            var updated = entry
            updated.personName = newName
            updated.path = [sanitizedNew, month, dest.lastPathComponent].joined(separator: "/")
            updated.fileName = dest.lastPathComponent
            return updated
        }

        // Best-effort: remove now-empty old per-subject directories (out of scope to
        // guarantee, but tidy). An empty check protects a folder another subject still uses.
        for dir in oldDirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir), contents.isEmpty {
                try? fileManager.removeItem(atPath: dir)
            }
        }

        let snapshot: [KeptEntry] = lock.withLock {
            entries = migrated
            return entries
        }
        indexWriter.schedule(snapshot)
    }

    /// The `<YYYY-MM>` folder for a migrated entry: the existing `path`'s middle segment
    /// when it parses as a valid month, otherwise derived from the entry's `captureDate`.
    private static func monthSegment(for entry: KeptEntry) -> String {
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
        if components.count >= 3, isValidMonth(String(components[components.count - 2])) {
            return String(components[components.count - 2])
        }
        return monthFolder(for: entry.captureDate)
    }

    /// True for a strict `YYYY-MM` string (4-digit year, `-`, month 01–12).
    private static func isValidMonth(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), year > 0,
              let month = Int(parts[1]), (1 ... 12).contains(month)
        else { return false }
        return true
    }

    // MARK: - Save implementation (off the main actor)

    private func performSave(source: URL, subjectId: String, personName: String, score: Double) -> KeptSaveResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return .sourceMissing }
        // An existing-but-undecodable / non-image source is rejected BEFORE any copy
        // or index write, so a corrupt/non-photo file never lands in the library or
        // leaves an orphan index entry (assertion 8).
        guard Self.isDecodableImage(at: source) else { return .failed }
        guard let hash = sha256(ofFileAt: source) else { return .failed }

        // Per-person dedupe: same subject + same content ⇒ nothing new.
        if let existing = (lock.withLock { entries.first { $0.subjectId == subjectId && $0.sha256 == hash } }) {
            return .alreadySaved(existing)
        }

        let captureDate = Self.captureDate(for: source, fileManager: fileManager)
        let month = Self.monthFolder(for: captureDate)
        let folder = (lock.withLock { root })
            .appendingPathComponent(Self.sanitized(personName), isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed
        }

        // De-collide distinct content sharing a filename; never overwrite.
        let dest = Self.deCollidedURL(in: folder, fileName: source.lastPathComponent, fileManager: fileManager)
        do {
            try fileManager.copyItem(at: source, to: dest)
        } catch {
            return .failed
        }

        let relativePath = [Self.sanitized(personName), month, dest.lastPathComponent].joined(separator: "/")
        let entry = KeptEntry(
            sha256: hash,
            subjectId: subjectId,
            personName: personName,
            path: relativePath,
            sourcePath: source.path,
            score: score,
            captureDate: captureDate,
            savedAt: Date(),
            fileName: dest.lastPathComponent
        )

        let snapshot: [KeptEntry] = lock.withLock {
            entries.append(entry)
            return entries
        }
        indexWriter.schedule(snapshot)
        return .saved(entry)
    }

    // MARK: - Naming / dates

    /// Sanitizes a person name to a filesystem-safe, non-empty folder component:
    /// strips path separators / colons / control characters, trims leading dots and
    /// whitespace, and falls back to a neutral name when nothing usable remains.
    static func sanitized(_ name: String) -> String {
        var illegal = CharacterSet(charactersIn: "/:\\")
        illegal.formUnion(.controlCharacters)
        let replaced = String(name.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) })
        let trimmed = replaced
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "." }
        let result = String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Unknown" : result
    }

    /// `<YYYY-MM>` for the capture date, locale-independent.
    static func monthFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// EXIF `DateTimeOriginal` → file modification date → today. Reads the EXIF date
    /// via ImageIO (like `FaceBoxedImage.rawGeometry` reads image properties).
    static func captureDate(for url: URL, fileManager: FileManager = .default) -> Date {
        if let exif = exifDateTimeOriginal(for: url) {
            return exif
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date
        {
            return modified
        }
        return Date()
    }

    private static func exifDateTimeOriginal(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    /// True when `url` is a decodable image (ImageIO recognizes a type and can decode
    /// at least one frame). Guards the library from copying/indexing a corrupt or
    /// non-image file that merely exists on disk.
    static func isDecodableImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return false }
        return true
    }

    /// A non-colliding destination URL in `folder` for `fileName`: returns it as-is
    /// when free, else inserts `-2`, `-3`, … before the extension. Distinct content is
    /// never silently overwritten.
    static func deCollidedURL(in folder: URL, fileName: String, fileManager: FileManager = .default) -> URL {
        let name = firstAvailableName(fileName) { candidate in
            fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        return folder.appendingPathComponent(name)
    }

    /// The `-2`, `-3`, … de-collision numbering shared by every save/export path
    /// (item 54: folder export reuses this exact algorithm for intra-batch
    /// collisions rather than a second routine): `fileName` as-is when `isOccupied`
    /// reports it free, else the first `base-N.ext` `isOccupied` reports free.
    /// `isOccupied` is a closure (not a hardcoded disk check) so a caller can widen
    /// "occupied" to include names already claimed in-memory this batch, not just
    /// what's actually on disk yet.
    static func firstAvailableName(_ fileName: String, isOccupied: (String) -> Bool) -> String {
        guard isOccupied(fileName) else { return fileName }

        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            if !isOccupied(name) { return name }
            index += 1
        }
    }
}
