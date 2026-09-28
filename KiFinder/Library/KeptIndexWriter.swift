import Foundation

/// Seam for persisting the library index off the main actor, coalescing a burst of
/// saves into far fewer disk writes (mirrors `ProfileStorePersisting`). `schedule`
/// synchronously records the latest full index snapshot and arms a debounce; `flush`
/// completes any pending write before returning. Injectable so a test can prove the
/// library schedules (rather than writes inline per save) and that a flush coalesces a
/// burst into exactly one write — with no real timing.
protocol KeptIndexWriting: Sendable {
    /// Stash the latest full index to be written; coalesces with any prior pending
    /// write (newest snapshot wins). Returns immediately — never blocks on disk I/O.
    func schedule(_ entries: [KeptEntry])
    /// Complete any pending write before returning.
    func flush() async
}

/// Production coalescing index writer. `schedule` synchronously stashes the latest
/// index snapshot and arms a debounce on a background queue; the encode + atomic file
/// write runs OFF the main actor. A burst of N `schedule` calls collapses to a single
/// write (most-recent-wins via a monotonically-increasing generation). A normal
/// `flush()` is the durability boundary (no crash/force-quit guarantee).
final class CoalescingKeptIndexWriter: KeptIndexWriting, @unchecked Sendable {
    private let indexURL: URL
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(
        label: "com.krisbaker.KiFinder.library-index-writer",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: [KeptEntry]?
    private var generation = 0

    init(indexURL: URL, debounce: DispatchTimeInterval = .milliseconds(500)) {
        self.indexURL = indexURL
        self.debounce = debounce
    }

    func schedule(_ entries: [KeptEntry]) {
        lock.lock()
        pending = entries
        generation &+= 1
        let generation = generation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.writeIfCurrent(generation)
        }
    }

    func flush() async {
        let entries: [KeptEntry]? = lock.withLock {
            let snapshot = pending
            pending = nil
            generation &+= 1
            return snapshot
        }
        guard let entries else { return }
        let url = indexURL
        await withCheckedContinuation { continuation in
            queue.async {
                Self.write(entries, to: url)
                continuation.resume()
            }
        }
    }

    private func writeIfCurrent(_ generation: Int) {
        lock.lock()
        guard generation == self.generation, let entries = pending else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        Self.write(entries, to: indexURL)
    }

    private static func write(_ entries: [KeptEntry], to url: URL) {
        let encoder = JSONEncoder()
        // Default (`.deferredToDate`) so `Date`s round-trip byte-exactly via the index;
        // an ISO-8601 string strategy would drop sub-second precision and break the
        // reload-equality / dedupe-survives-reload checks.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// Decodes a library index previously written by `CoalescingKeptIndexWriter` (or any
/// conforming writer). Returns an empty array when the file is absent/unreadable, so a
/// fresh library starts clean.
func loadKeptIndex(from url: URL) -> [KeptEntry] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([KeptEntry].self, from: data)) ?? []
}

/// Like `loadKeptIndex`, but when the file EXISTS and fails to decode, the corrupt
/// bytes are quarantined aside (preserving the dedupe evidence — losing it means
/// future keeps silently write duplicate copies of photos already saved) instead of
/// `loadKeptIndex`'s silent-discard, before falling back to an empty index. Returns
/// the loaded entries and a one-time plain-language notice when a quarantine
/// happened (`nil` otherwise — including the ordinary "no file yet" case).
func loadKeptIndexQuarantiningIfNeeded(from url: URL) -> (entries: [KeptEntry], notice: String?) {
    guard let data = try? Data(contentsOf: url) else { return ([], nil) }
    if let entries = try? JSONDecoder().decode([KeptEntry].self, from: data) {
        return (entries, nil)
    }
    guard (try? DataQuarantine.quarantineUnreadable(at: url)) != nil else { return ([], nil) }
    let notice = String(
        localized: "Your saved-photo index couldn't be read, so it was set aside instead of erased. Your saved photos are safe, but the app may re-save a few as duplicates until it re-learns which ones you already have.",
        comment: "Root-level notice shown once when the kept-photo library index file was corrupt and quarantined."
    )
    return ([], notice)
}
