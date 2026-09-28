import Foundation

/// Shared quarantine seam for the app's three hand-decoded persistence files (the
/// people roster, the kept-photo index, and the skip store): when a read finds bytes
/// on disk that fail to decode, the file is renamed ASIDE instead of being silently
/// discarded and overwritten by the next debounced write (item 57). Every call site
/// falls back to an empty/rebuilt in-memory state afterward — quarantining only
/// changes what happens to the UNREADABLE bytes, never the app's ability to keep
/// running with a sane empty state.
enum DataQuarantine {
    /// Renames `url` aside to a `<name>.corrupt-<token>` sibling in the same
    /// directory, preserving the original bytes untouched. Collision-safe: if a
    /// sibling already sits at that exact name (e.g. two quarantines land with the
    /// same injected token), a numeric suffix is appended so neither blob is ever
    /// overwritten. Returns the destination URL, or `nil` when `url` doesn't exist
    /// (nothing to preserve — the normal "no file yet" first-run path).
    ///
    /// - Parameter token: injectable seam for deterministic tests (collision +
    ///   naming); defaults to a real, filesystem-safe ISO8601-ish timestamp so
    ///   production quarantines land at a unique, inspectable name.
    @discardableResult
    static func quarantineUnreadable(
        at url: URL,
        token: @autoclosure () -> String = DataQuarantine.defaultToken(),
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(token())"
        var destination = directory.appendingPathComponent(base)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    /// A filesystem-safe, roughly-ISO8601 timestamp token (colons aren't legal in
    /// most filenames, so they're swapped for `-`): `2026-07-16T12-34-56Z`.
    static func defaultToken(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
