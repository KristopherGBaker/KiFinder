import Foundation
import KionEngine

/// Seam for persisting the working `ProfileStore` off the main actor, coalescing a
/// burst of decisions into far fewer disk writes. `schedule` synchronously records
/// the latest store snapshot (most-recent-wins) and arms a debounce; `flush`
/// completes any pending write before returning. Injectable so tests can prove the
/// engine schedules (rather than writes inline) and that a flush coalesces — with no
/// real timing.
protocol ProfileStorePersisting: Sendable {
    /// Stash the latest store snapshot to be written; coalesces with any prior
    /// pending write (the newest snapshot wins). Returns immediately — never blocks
    /// on disk I/O.
    func schedule(_ store: ProfileStore)
    /// Complete any pending write before returning. Called at concrete boundaries
    /// (before a path that reloads the store from disk / a rescan, and on normal
    /// teardown) so taught feedback isn't dropped in normal use.
    func flush() async
    /// Cancels any armed debounce and returns the snapshot that was pending (`nil`
    /// if nothing was pending) WITHOUT writing it to disk. Bumps the generation so
    /// an already-in-flight `asyncAfter` for a superseded snapshot becomes a no-op.
    /// This is the write-side half of item 53's delete/rename-vs-coalesced-write
    /// invariant: a repository-write path calls this BEFORE it mutates the store on
    /// disk so a stale debounced write can never land afterward and clobber the
    /// change. The caller is responsible for re-`schedule`-ing a pruned/merged copy
    /// of the returned snapshot once its own write completes, so unrelated pending
    /// feedback (for people the write didn't touch) is never silently dropped.
    ///
    /// Ordering guarantee: this call is serialized against any write that is
    /// ALREADY encoding (i.e. one that already passed its own generation check) —
    /// it either observes the real pending snapshot (nothing has started writing
    /// yet) or blocks until that in-flight write, encode included, has fully
    /// landed before it can conclude "nothing was pending". A `nil` result
    /// therefore means either truly nothing was pending, OR a write already
    /// completed to disk before this returned — in the latter case the caller's
    /// own subsequent repository read is guaranteed to observe that write (not a
    /// stale pre-write copy), so its result is still correct. A generation bump
    /// alone cannot provide this: it only stops writes that haven't started yet.
    func cancelPending() -> ProfileStore?
}

/// Production coalescing writer. `schedule` synchronously stashes the latest store
/// snapshot and arms a debounce timer on a background queue; the `encode`+file write
/// runs OFF the main actor on that queue. A burst of N `schedule` calls collapses to
/// a single write (most-recent-wins via a monotonically-increasing generation). No
/// crash/force-quit durability is promised — a normal `flush()` is the durability
/// boundary.
final class CoalescingProfileStoreWriter: ProfileStorePersisting, @unchecked Sendable {
    private let storeURL: URL
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(
        label: "com.krisbaker.KiFinder.profile-store-writer",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: ProfileStore?
    /// Bumped on every `schedule`/`flush`/`cancelPending`/completed write so a
    /// debounce fired for a superseded snapshot is a no-op (the latest wins).
    private var generation = 0

    /// Test-only seam (item 53): invoked WHILE STILL HOLDING `lock`, immediately
    /// after `pending` is captured+cleared and immediately before `encode(to:)` —
    /// i.e. the exact window a residual race lived in when the lock was released
    /// before encoding. Lets a test pause an in-flight write right there and, from
    /// another thread, force `cancelPending()` to contend for the SAME lock,
    /// proving deterministically (no sleeps/polling) that it can never observe
    /// "nothing pending" while a stale snapshot can still reach disk afterward.
    /// `nil` in production: zero behavior change.
    var beforeEncodeForTesting: (() -> Void)?
    /// Test-only seam (item 53): invoked at the very start of `cancelPending()`,
    /// BEFORE it attempts to acquire `lock` — lets a test know the exact moment a
    /// concurrent cancel is about to contend for the lock a paused write (via
    /// `beforeEncodeForTesting`) is holding, so it can release that write
    /// deterministically once (and only once) the cancel is genuinely racing it.
    var beforeCancelLockForTesting: (() -> Void)?

    init(storeURL: URL, debounce: DispatchTimeInterval = .milliseconds(500)) {
        self.storeURL = storeURL
        self.debounce = debounce
    }

    func schedule(_ store: ProfileStore) {
        lock.lock()
        pending = store
        generation &+= 1
        let generation = generation
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.writeIfCurrent(generation)
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.writeAndClearPending(requiredGeneration: nil)
                continuation.resume()
            }
        }
    }

    func cancelPending() -> ProfileStore? {
        beforeCancelLockForTesting?()
        return lock.withLock {
            let snapshot = pending
            pending = nil
            // Invalidate any armed debounce so a stale `writeIfCurrent` firing later
            // for the cancelled generation is a no-op. NOTE: this alone does NOT
            // stop a write that has ALREADY passed its generation check and is
            // (or is about to be) encoding — that write no longer consults
            // `generation` at all. Safety against THAT case comes from
            // `writeAndClearPending` holding `lock` across the encode (below), so
            // this call either runs before that write starts (sees the real
            // pending value) or blocks until the write — encode included — has
            // fully completed before it can conclude "nothing was pending".
            generation &+= 1
            return snapshot
        }
    }

    private func writeIfCurrent(_ generation: Int) {
        writeAndClearPending(requiredGeneration: generation)
    }

    /// Test-only (item 53): synchronously runs the SAME write critical section a
    /// real debounce fire would, for whatever is CURRENTLY pending — bypassing
    /// `queue.asyncAfter`'s timer so a test can force it to run NOW rather than
    /// waiting out a real debounce. Performs synchronous disk I/O and may BLOCK
    /// (per `writeAndClearPending`'s locking) — call from a background thread/
    /// detached `Task`, never from the main actor.
    func fireForTesting() {
        writeAndClearPending(requiredGeneration: nil)
    }

    /// The single write critical section, used by both the debounce callback
    /// (`requiredGeneration` set, so a superseded fire is a no-op) and `flush()`
    /// (`nil`, so it writes whatever is currently pending regardless of
    /// generation). Item 53's residual-race fix: `lock` is held across the ENTIRE
    /// capture-then-encode, not just the capture. A pre-fix version released the
    /// lock before encoding, so `cancelPending()` could acquire it in the gap,
    /// see `pending == nil` (already cleared here) and correctly conclude
    /// "nothing to restore" — while THIS stale snapshot was still in flight to
    /// disk and would land AFTER the caller's repository transaction concluded,
    /// resurrecting whatever it had just deleted. Holding the lock across the
    /// encode makes that interleaving impossible: `cancelPending()` now either
    /// runs strictly before this section starts (and correctly captures/cancels
    /// the real pending snapshot) or blocks until this section — encode included
    /// — has fully finished, so by the time ANY subsequent repository write reads
    /// the store fresh from disk, this write (if it happened) has already landed
    /// and is what gets corrected. The main-actor-visible cost is a lock wait
    /// bounded by one disk write's duration (millisecond-scale for this store's
    /// size) — NOT the ~500ms debounce window assertion 6 targets, which only
    /// applies to the far more common "nothing pending" path where this lock is
    /// uncontended.
    private func writeAndClearPending(requiredGeneration: Int?) {
        lock.lock()
        defer { lock.unlock() }
        if let requiredGeneration, requiredGeneration != generation { return }
        guard let store = pending else { return }
        pending = nil
        generation &+= 1
        beforeEncodeForTesting?()
        try? store.encode(to: storeURL)
    }
}
