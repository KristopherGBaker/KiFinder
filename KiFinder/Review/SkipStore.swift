import Foundation

/// The UserDefaults key under which the Review "Hide already reviewed" toggle's last
/// value persists (item 48). Absent ⇒ the default (`false`, filter off).
enum HideReviewedPreference {
    static let key = "com.krisbaker.KiFinder.hideAlreadyReviewed"
}

/// Where the persistent per-person skip index lives on disk. Test-injectable via
/// `KION_SKIPPED_STORE`; in runs that set it (a temp dir) the store never touches the
/// real Application Support. In production it lives under
/// `<appSupportRoot>/KiFinder/skipped-index.json`.
func resolveSkipStoreURL(env: [String: String], appSupportRoot: URL) -> URL {
    if let path = env["KION_SKIPPED_STORE"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    // In test runs that redirect the profile store to a temp dir, keep the skip index
    // beside it so the suite never writes the real Application Support (mirrors how the
    // library index falls back beside a `KION_LIBRARY_ROOT` temp dir).
    if let store = env["KION_PROFILE_STORE"], !store.isEmpty {
        return URL(fileURLWithPath: store)
            .deletingLastPathComponent()
            .appendingPathComponent("skipped-index.json")
    }
    return appSupportRoot
        .appendingPathComponent("KiFinder", isDirectory: true)
        .appendingPathComponent("skipped-index.json")
}

/// The write side of the persistent per-person skip store. `AppModel` holds one behind
/// this seam so tests can inject an in-memory spy (to prove skip records and keep clears,
/// off the keypress path) without a real filesystem. Mirrors `KeptLibrarySaving`: the
/// reads (`isSkipped`) are cheap synchronous main-actor calls, the writes coalesce off
/// the main actor, and `flush()` is the deterministic durability boundary tests await.
protocol SkipRecording: AnyObject, Sendable {
    /// Whether `sourcePath` was skipped by `subjectId` (this session or a prior scan).
    func isSkipped(sourcePath: String, subjectId: String) -> Bool
    /// Records that `subjectId` skipped `sourcePath` (idempotent). Written off the
    /// keypress path via the coalescing writer.
    func recordSkip(sourcePath: String, subjectId: String)
    /// Forgets a prior skip of `sourcePath` by `subjectId` — called on a keep so a
    /// previously-skipped photo that becomes kept is no longer remembered as skipped.
    func clearSkip(sourcePath: String, subjectId: String)
    /// Purges every skip belonging to a deleted subject (parity with the library purge).
    /// Default no-op so AppModel seam / spies stay conformant.
    func removeSubject(_ subjectId: String)
    /// Completes any pending (coalesced) write before returning.
    func flush() async
    /// A one-time, plain-language notice when the on-disk skip index couldn't be
    /// read and was quarantined aside at construction (item 57); `nil` otherwise.
    /// The app model reads this once right after construction to surface the
    /// root-level data-integrity alert. Default `nil` so spies stay conformant.
    var quarantineNotice: String? { get }
}

extension SkipRecording {
    func removeSubject(_: String) {}
    var quarantineNotice: String? { nil }
}

/// Seam for persisting the skip index off the main actor, coalescing a burst of
/// record/clear calls into far fewer disk writes (mirrors `KeptIndexWriting`). `schedule`
/// synchronously records the latest full index snapshot and arms a debounce; `flush`
/// completes any pending write before returning. Injectable so a test can prove the
/// store schedules (rather than writes inline per call) with no real timing.
protocol SkipIndexWriting: Sendable {
    /// Stash the latest full index to be written; coalesces with any prior pending write
    /// (newest snapshot wins). Returns immediately — never blocks on disk I/O.
    func schedule(_ skips: [String: Set<String>])
    /// Complete any pending write before returning.
    func flush() async
}

/// Production coalescing skip-index writer. `schedule` synchronously stashes the latest
/// snapshot and arms a debounce on a background queue; the encode + atomic file write
/// runs OFF the main actor. A burst of N `schedule` calls collapses to a single write
/// (most-recent-wins via a monotonically-increasing generation). A normal `flush()` is
/// the durability boundary. Mirrors `CoalescingKeptIndexWriter`.
final class CoalescingSkipIndexWriter: SkipIndexWriting, @unchecked Sendable {
    private let fileURL: URL
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(
        label: "com.krisbaker.KiFinder.skip-index-writer",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: [String: Set<String>]?
    private var generation = 0

    init(fileURL: URL, debounce: DispatchTimeInterval = .milliseconds(500)) {
        self.fileURL = fileURL
        self.debounce = debounce
    }

    func schedule(_ skips: [String: Set<String>]) {
        lock.lock()
        pending = skips
        generation &+= 1
        let generation = generation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.writeIfCurrent(generation)
        }
    }

    func flush() async {
        let skips: [String: Set<String>]? = lock.withLock {
            let snapshot = pending
            pending = nil
            generation &+= 1
            return snapshot
        }
        guard let skips else { return }
        let url = fileURL
        await withCheckedContinuation { continuation in
            queue.async {
                Self.write(skips, to: url)
                continuation.resume()
            }
        }
    }

    private func writeIfCurrent(_ generation: Int) {
        lock.lock()
        guard generation == self.generation, let skips = pending else {
            lock.unlock()
            return
        }
        pending = nil
        lock.unlock()
        Self.write(skips, to: fileURL)
    }

    private static func write(_ skips: [String: Set<String>], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skips) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// Decodes a skip index previously written by `CoalescingSkipIndexWriter` (or any
/// conforming writer). Returns an empty map when the file is absent/unreadable, so a
/// fresh store starts clean.
func loadSkipIndex(from url: URL) -> [String: Set<String>] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONDecoder().decode([String: Set<String>].self, from: data)) ?? [:]
}

/// Like `loadSkipIndex`, but when the file EXISTS and fails to decode, the corrupt
/// bytes are quarantined aside (preserving every prior skip a user recorded) instead
/// of `loadSkipIndex`'s silent-discard, before falling back to an empty index.
/// Returns the loaded skips and a one-time plain-language notice when a quarantine
/// happened (`nil` otherwise — including the ordinary "no file yet" case).
func loadSkipIndexQuarantiningIfNeeded(from url: URL) -> (skips: [String: Set<String>], notice: String?) {
    guard let data = try? Data(contentsOf: url) else { return ([:], nil) }
    if let skips = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
        return (skips, nil)
    }
    guard (try? DataQuarantine.quarantineUnreadable(at: url)) != nil else { return ([:], nil) }
    let notice = String(
        localized: "Your skipped-photo history couldn't be read, so it was set aside instead of erased. Photos you'd already skipped may show up for review again.",
        comment: "Root-level notice shown once when the skipped-photo store file was corrupt and quarantined."
    )
    return ([:], notice)
}

/// App-layer store that durably records which photo source paths each person has skipped,
/// keyed `[subjectId: Set<sourcePath>]`, persisted as JSON with a coalesced off-actor
/// writer. Loaded at init so a re-scan/relaunch remembers prior skips.
///
/// Concurrency: the in-memory map is guarded by a lock and file work runs on the writer's
/// private queue, so writes are safe from any task while `isSkipped` is a cheap
/// synchronous read from the main actor. `@unchecked Sendable` is justified by the lock
/// guarding all mutable state.
final class SkipStore: SkipRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var skips: [String: Set<String>]
    private let indexWriter: any SkipIndexWriting
    /// See `SkipRecording.quarantineNotice`. Set once at `init` when the index file
    /// existed but failed to decode (item 57).
    private(set) var quarantineNotice: String?

    /// - Parameters:
    ///   - fileURL: where the index JSON is read from (init) and written to.
    ///   - indexWriter: persistence seam; defaults to the production coalescing writer
    ///     over `fileURL`.
    init(fileURL: URL, indexWriter: (any SkipIndexWriting)? = nil) {
        self.indexWriter = indexWriter ?? CoalescingSkipIndexWriter(fileURL: fileURL)
        let loaded = loadSkipIndexQuarantiningIfNeeded(from: fileURL)
        skips = loaded.skips
        quarantineNotice = loaded.notice
    }

    func isSkipped(sourcePath: String, subjectId: String) -> Bool {
        lock.withLock { skips[subjectId]?.contains(sourcePath) ?? false }
    }

    func recordSkip(sourcePath: String, subjectId: String) {
        let snapshot: [String: Set<String>] = lock.withLock {
            skips[subjectId, default: []].insert(sourcePath)
            return skips
        }
        indexWriter.schedule(snapshot)
    }

    func clearSkip(sourcePath: String, subjectId: String) {
        let snapshot: [String: Set<String>] = lock.withLock {
            skips[subjectId]?.remove(sourcePath)
            if skips[subjectId]?.isEmpty == true { skips[subjectId] = nil }
            return skips
        }
        indexWriter.schedule(snapshot)
    }

    func removeSubject(_ subjectId: String) {
        let snapshot: [String: Set<String>] = lock.withLock {
            skips[subjectId] = nil
            return skips
        }
        indexWriter.schedule(snapshot)
    }

    func flush() async {
        await indexWriter.flush()
    }
}
