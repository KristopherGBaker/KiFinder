import Foundation

/// One persisted kept photo in the library index. Records enough to (a) dedupe by
/// content hash per person, (b) surface "already saved" cheaply from a source path,
/// and (c) drive the item-18b browse UI later. `path` is library-root-relative.
struct KeptEntry: Codable, Equatable, Identifiable {
    /// SHA-256 of the original file's bytes — the per-person dedupe key.
    var sha256: String
    /// The enrolled person this copy belongs to (the active person at Keep time).
    var subjectId: String
    /// The person's display name at save time (also drives the on-disk folder).
    var personName: String
    /// Library-root-relative path of the saved copy, e.g. `Ava/2021-07/IMG_1.jpg`.
    var path: String
    /// Absolute path of the original source the copy was made from.
    var sourcePath: String
    /// Match score recorded at Keep time.
    var score: Double
    /// The date that decided the `<YYYY-MM>` folder (EXIF → mtime → today).
    var captureDate: Date
    /// When the copy was written.
    var savedAt: Date
    /// The saved file's name (after any de-collision), e.g. `IMG_1-2.jpg`.
    var fileName: String

    /// Stable identity for SwiftUI lists: a subject's copies are unique by content.
    var id: String {
        "\(subjectId)/\(sha256)"
    }
}

/// Outcome of a library save.
enum KeptSaveResult: Equatable {
    /// A new copy was written; carries the recorded entry.
    case saved(KeptEntry)
    /// This subject already had this exact content; nothing new was written.
    case alreadySaved(KeptEntry)
    /// The source file did not exist; nothing was written.
    case sourceMissing
    /// The source existed but could not be hashed/copied; nothing was orphaned.
    case failed
}
