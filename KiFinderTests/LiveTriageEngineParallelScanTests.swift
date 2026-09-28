import CoreGraphics
import Foundation
import ImageIO
@testable import KiFinder
import KionEngine
import Testing
import UniformTypeIdentifiers

/// Item 75: the scan fans out across `n` workers instead of walking one photo at a
/// time. The property that has to survive that change is that the RESULT doesn't
/// depend on how the workers interleave — a scan at 4 workers must produce exactly
/// what the same scan at 1 worker produces, candidate for candidate.
///
/// The fake embedder below deliberately finishes photos OUT OF ORDER (later photos
/// return sooner), so a parallel implementation that merged results in completion
/// order — or let a shared mutable counter race — would fail these tests rather than
/// pass by luck.
@Suite("LiveTriageEngine parallel scan (item 75)")
@MainActor
struct LiveTriageEngineParallelScanTests {
    // MARK: - Fixture

    private let modelId = "test-model"
    private let modelVersion = "v1"

    private func tempDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-parallel-scan-\(label)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `count` distinct 1×`n`-pixel PNGs, so every photo decodes to a
    /// different height — the fake embedder turns that height into the photo's
    /// embedding, giving each photo a distinct, deterministic score.
    @discardableResult
    private func writePhotos(_ count: Int, into dir: URL, prefix: String = "photo") throws -> [URL] {
        try (0 ..< count).map { index in
            let height = index + 1
            let url = dir.appendingPathComponent("\(prefix)-\(String(format: "%03d", index)).png")
            let context = CGContext(
                data: nil,
                width: 8,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: height))
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return url
        }
    }

    /// A deterministic stand-in for the real embedder: the "face" it returns is a
    /// function of the image's HEIGHT alone, so a photo always embeds to the same
    /// vector no matter which worker (or how many) handled it.
    ///
    /// `staggered` makes completion order deliberately differ from work order: taller
    /// images (later photos) sleep LESS, so with several workers in flight the later
    /// photos finish first. That's the interleaving a correct implementation has to be
    /// indifferent to.
    private struct StaggeredEmbedder: FaceEmbeddingProvider {
        let staggered: Bool
        /// Counts photos this INSTANCE embedded, so a test can prove the work was
        /// actually spread over separate embedders rather than funnelled through one.
        let counter: EmbedCounter

        var descriptor: FaceModelDescriptor { .arcface }

        /// The faces "detected" in an image, decided ENTIRELY by its height, so the
        /// same photo always yields the same faces on any worker. The rules give the
        /// fixture the shapes a real album has — photos with no face, group photos
        /// where the subject isn't face 0, and blind-fallback "detections" that the
        /// item-56 gate must exclude — so a parallel-vs-serial comparison covers the
        /// real attribution paths, not just one happy case.
        private func faces(for image: CGImage) -> [DetectedFace] {
            let height = Float(image.height)
            func metrics(_ isFallback: Bool = false) -> QualityMetrics {
                QualityMetrics(
                    detectionScore: 0.9,
                    boundingBoxArea: 0.5,
                    faceBoundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                    isFallback: isFallback
                )
            }
            if image.height % 5 == 0 {
                return [] // no detectable face
            }
            if image.height % 11 == 0 {
                // Only a blind fallback "face": must not be scored as a match.
                return [DetectedFace(embedding: FaceEmbedding([height, 1, 0]), qualityMetrics: metrics(true))]
            }
            if image.height % 7 == 0 {
                // Group photo: face 0 belongs to nobody enrolled, face 1 matches the
                // SECOND subject — the representative-face re-pick has to handle it.
                return [
                    DetectedFace(embedding: FaceEmbedding([0, 0, height]), qualityMetrics: metrics()),
                    DetectedFace(embedding: FaceEmbedding([1, height, 0]), qualityMetrics: metrics()),
                ]
            }
            return [DetectedFace(embedding: FaceEmbedding([height, 1, 0]), qualityMetrics: metrics())]
        }

        func embedFace(_ image: CGImage) async throws -> DetectedFace? {
            try await embedAllFaces(image).first
        }

        func embedAllFaces(_ image: CGImage) async throws -> [DetectedFace] {
            await counter.enter()
            if staggered {
                // Later (taller) photos return sooner.
                let milliseconds = max(1, 40 - image.height)
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            let detected = faces(for: image)
            await counter.leave()
            return detected
        }

        func embedFace(in image: CGImage, regionBoundingBox _: CGRect) async throws -> DetectedFace? {
            faces(for: image).first
        }
    }

    /// Embed tally plus the PEAK number of embeds in flight at once — the observable
    /// proof that the fan-out is both real (peak > 1 when workers > 1) and BOUNDED
    /// (peak never exceeds the configured worker count, so memory can't run away on a
    /// 900-photo album).
    private actor EmbedCounter {
        private(set) var count = 0
        private(set) var inFlight = 0
        private(set) var peakInFlight = 0

        func enter() {
            count += 1
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
        }

        func leave() { inFlight -= 1 }
    }

    /// A one-shot completion flag. Deliberately POLLED rather than awaited: awaiting the
    /// consuming task directly (even inside a task group racing a timer) cannot bound a
    /// hang, because a task group still awaits every child on exit — so a stuck
    /// `await task.value` would hang the test it was supposed to fail.
    private actor Signal {
        private(set) var isSet = false
        func send() { isSet = true }
    }

    /// A thread-safe int box: counts `makeProvider` calls (the factory the engine calls
    /// is synchronous and `@Sendable`, so it can't await an actor), and doubles as the
    /// mutable worker width in the re-read-per-scan test.
    private final class ProviderCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func set(_ newValue: Int) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A BARRIER over album resolution — not a sleep. Each resolution registers itself
    /// and then blocks until `releaseAt` of them are simultaneously inside; the one that
    /// completes the quorum releases everybody.
    ///
    /// That makes overlap a decided fact rather than a timing observation: if the
    /// implementation resolved albums serially, the first entrant would sit at the
    /// barrier alone until the (generous) deadline and the recorded peak would stay at
    /// 1 — a deterministic failure, not a flaky one. `releaseAt: 1` is the serial
    /// control, which never blocks.
    private final class ResolutionBarrier: @unchecked Sendable {
        private let condition = NSCondition()
        private let releaseAt: Int
        private var inFlight = 0
        private var released = false
        private(set) var peak = 0
        /// True when a waiter gave up at the deadline — i.e. the quorum never formed.
        private(set) var timedOut = false

        init(releaseAt: Int) {
            self.releaseAt = releaseAt
        }

        func enumerate(_ album: URL) throws -> [String] {
            condition.lock()
            inFlight += 1
            peak = max(peak, inFlight)
            if inFlight >= releaseAt {
                released = true
                condition.broadcast()
            }
            let deadline = Date().addingTimeInterval(5)
            while !released {
                if !condition.wait(until: deadline) {
                    timedOut = true
                    break
                }
            }
            inFlight -= 1
            condition.unlock()
            return try ScanPipeline.enumerateImages(in: album)
        }
    }

    /// Enrolls one subject, or two when `people == 2` — the second matching the OTHER
    /// axis, so a group photo's face 1 attributes to them and per-person bucketing has
    /// something to get wrong.
    private func store(at url: URL, people: Int = 1) throws {
        func bundle(_ id: String, reference: FaceEmbedding) -> ProfileBundle {
            ProfileBundle(
                subjectId: id,
                // Matches a tall photo far better than a short one, so photos spread
                // across keep/maybe/other rather than all landing in one bucket.
                references: [reference],
                threshold: 0.9,
                maybeMargin: 0.3,
                modelId: modelId,
                modelVersion: modelVersion
            )
        }
        var profiles = ["subject-1": bundle("subject-1", reference: FaceEmbedding([20, 1, 0]))]
        if people == 2 {
            profiles["subject-2"] = bundle("subject-2", reference: FaceEmbedding([1, 20, 0]))
        }
        let store = ProfileStore(
            modelId: modelId,
            modelVersion: modelVersion,
            profiles: profiles
        )
        try store.encode(to: url)
    }

    /// Runs a full scan and returns the final progress tick plus every tick seen.
    private func scan(
        albums: [URL],
        storeURL: URL,
        workers: Int,
        staggered: Bool = true
    ) async -> (final: ScanProgress, ticks: [ScanProgress], embeds: EmbedCounter, providers: Int) {
        // One counter shared by every embedder the engine constructs, so the totals are
        // "photos embedded" and "peak concurrent embeds" across the whole fan-out.
        let embeds = EmbedCounter()
        let providers = ProviderCount()
        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: "subject-1",
            modelId: modelId,
            modelVersion: modelVersion,
            makeProvider: { _ in
                providers.increment()
                return StaggeredEmbedder(staggered: staggered, counter: embeds)
            },
            workerCount: { workers }
        )
        var ticks: [ScanProgress] = []
        for await progress in engine.scan(albums: albums) {
            ticks.append(progress)
        }
        return (ticks.last ?? ScanProgress(progress: 0), ticks, embeds, providers.count)
    }

    // MARK: - The core property: parallel == serial

    @Test("A 4-worker scan produces exactly the same candidates as a 1-worker scan")
    func parallelMatchesSerial() async throws {
        let album = try tempDir("album")
        try writePhotos(24, into: album)
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        let serial = await scan(albums: [album], storeURL: storeURL, workers: 1)
        let parallel = await scan(albums: [album], storeURL: storeURL, workers: 4)

        #expect(serial.final.isFinal)
        #expect(parallel.final.isFinal)
        #expect(serial.final.candidates.count == 24)
        // Identical ordering AND identical per-candidate scoring/bucketing.
        #expect(parallel.final.candidates.map(\.id) == serial.final.candidates.map(\.id))
        #expect(parallel.final.candidates.map(\.score) == serial.final.candidates.map(\.score))
        #expect(parallel.final.candidates.map(\.bucket) == serial.final.candidates.map(\.bucket))
        #expect(parallel.final.candidates.map(\.matchedSubjectID) == serial.final.candidates.map(\.matchedSubjectID))
        #expect(parallel.final.candidates.map(\.subjectScores) == serial.final.candidates.map(\.subjectScores))
        // Non-vacuous: the fixture really does spread across buckets, so the
        // comparison above is testing bucketing, not 24 identical "other"s.
        #expect(Set(serial.final.candidates.map(\.bucket)).count > 1)
    }

    @Test("Identity holds for the MESSY cases too: two people, group photos, no-face, fallback-only, undecodable")
    func mixedContentParallelMatchesSerial() async throws {
        let album = try tempDir("mixed")
        // Heights 1…24 hit every rule in the fake embedder: %5 no face, %7 a group
        // photo whose face 1 belongs to subject-2, %11 a fallback-only "detection".
        try writePhotos(24, into: album)
        // Plus a file that is not a decodable image at all.
        try Data("this is not a png".utf8).write(to: album.appendingPathComponent("broken.png"))
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL, people: 2)

        let serial = await scan(albums: [album], storeURL: storeURL, workers: 1)
        let parallel = await scan(albums: [album], storeURL: storeURL, workers: 4)

        let a = serial.final.candidates
        let b = parallel.final.candidates
        #expect(a.count == 25) // every photo surfaces, including the undecodable one
        #expect(b.map(\.id) == a.map(\.id))
        #expect(b.map(\.score) == a.map(\.score))
        #expect(b.map(\.bucket) == a.map(\.bucket))
        #expect(b.map(\.matchedSubjectID) == a.map(\.matchedSubjectID))
        #expect(b.map(\.subjectScores) == a.map(\.subjectScores))
        // The per-person attribution surfaces (item 7) survive the fan-out too.
        #expect(b.map(\.subjectBuckets) == a.map(\.subjectBuckets))
        #expect(b.map(\.selectedFaceIndexBySubject) == a.map(\.selectedFaceIndexBySubject))
        #expect(b.map(\.selectedFaceIndex) == a.map(\.selectedFaceIndex))
        #expect(b.map(\.faceBoxes.count) == a.map(\.faceBoxes.count))

        // Per-fixture expectations, so "each shape is present" is pinned to the SPECIFIC
        // photo that embodies it rather than to an aggregate that could be satisfied by
        // the wrong file. (Heights are index+1; the embedder's rules key off height.)
        func candidate(_ fileName: String) throws -> Candidate {
            try #require(a.first { $0.fileName == fileName })
        }

        // Undecodable file: surfaces as a candidate, but nothing was detected or scored.
        let broken = try candidate("broken.png")
        #expect(broken.bucket == .other)
        #expect(broken.faceBoxes.isEmpty)
        #expect(broken.selectedFaceIndex == nil)
        #expect(broken.matchedSubjectID == nil)
        #expect(broken.subjectScores.isEmpty)

        // Height 5: decodes fine, no face detected. Same observable shape, different cause.
        let noFace = try candidate("photo-004.png")
        #expect(noFace.bucket == .other)
        #expect(noFace.faceBoxes.isEmpty)
        #expect(noFace.selectedFaceIndex == nil)
        #expect(noFace.subjectScores.isEmpty)

        // Height 11: a face WAS detected, but only as a blind fallback — the item-56
        // gate must keep it out of matching. So: one face box, yet no match and a zero
        // score for every person (not merely "bucket .other").
        let fallbackOnly = try candidate("photo-010.png")
        #expect(fallbackOnly.faceBoxes.count == 1)
        #expect(fallbackOnly.bucket == .other)
        #expect(fallbackOnly.matchedSubjectID == nil)
        // Both people must be PRESENT and scored zero. Asserting only
        // `values.allSatisfy { $0 == 0 }` would pass vacuously on an empty dictionary —
        // i.e. it would also accept "nobody was scored at all", which is a different
        // (and wrong) behavior than "the fallback face was excluded from matching".
        #expect(Set(fallbackOnly.subjectScores.keys) == ["subject-1", "subject-2"])
        #expect(fallbackOnly.subjectScores["subject-1"] == 0)
        #expect(fallbackOnly.subjectScores["subject-2"] == 0)

        // Height 7: a group photo whose face 1 is subject-2 — the representative face
        // must be re-picked to index 1, and the photo attributed to subject-2.
        let group = try candidate("photo-006.png")
        #expect(group.faceBoxes.count == 2)
        #expect(group.selectedFaceIndexBySubject["subject-2"] == 1)
        #expect(group.matchedSubjectID == "subject-2")

        // Both enrolled people matched something, so the multi-profile path is live.
        #expect(Set(a.compactMap(\.matchedSubjectID)) == ["subject-1", "subject-2"])
    }

    @Test("The same holds across MULTIPLE albums scanned in one pass")
    func parallelMatchesSerialAcrossAlbums() async throws {
        let first = try tempDir("album-a")
        let second = try tempDir("album-b")
        let third = try tempDir("album-c")
        try writePhotos(6, into: first, prefix: "a")
        try writePhotos(7, into: second, prefix: "b")
        try writePhotos(5, into: third, prefix: "c")
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        let albums = [first, second, third]
        let serial = await scan(albums: albums, storeURL: storeURL, workers: 1)
        let parallel = await scan(albums: albums, storeURL: storeURL, workers: 6)

        #expect(serial.final.candidates.count == 18)
        #expect(parallel.final.candidates.map(\.id) == serial.final.candidates.map(\.id))
        #expect(parallel.final.candidates.map(\.score) == serial.final.candidates.map(\.score))
        #expect(parallel.final.totalPhotos == serial.final.totalPhotos)
    }

    // MARK: - Progress

    @Test("Progress counts stay monotonic and reach every photo exactly once")
    func progressIsMonotonicAndComplete() async throws {
        let album = try tempDir("album")
        try writePhotos(12, into: album)
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        let run = await scan(albums: [album], storeURL: storeURL, workers: 4)

        // Determinate ticks only (the first tick is the indeterminate "Preparing…").
        let determinate = run.ticks.filter { !$0.indeterminate && !$0.isFinal }
        #expect(determinate.count == 12) // one per photo, none lost to a race
        let fractions = determinate.map(\.progress)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1.0)
        // The running match count never goes backwards either.
        let matches = determinate.map(\.matchesSoFar)
        #expect(matches == matches.sorted())
    }

    // MARK: - The fan-out is real

    @Test("In-flight embeds never exceed the worker count, and one worker stays serial")
    func fanOutIsBounded() async throws {
        let album = try tempDir("album")
        try writePhotos(20, into: album)
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        let serial = await scan(albums: [album], storeURL: storeURL, workers: 1)
        // One worker = one embedder = one photo at a time: byte-for-byte the old
        // behavior, including its memory profile.
        #expect(await serial.embeds.peakInFlight == 1)
        #expect(serial.providers == 1)
        #expect(await serial.embeds.count == 20)

        let parallel = await scan(albums: [album], storeURL: storeURL, workers: 3)
        // Bounded: never more than the configured width in flight, no matter that
        // there are 20 photos queued...
        #expect(await parallel.embeds.peakInFlight <= 3)
        // ...and genuinely concurrent: more than one really was in flight at once.
        #expect(await parallel.embeds.peakInFlight > 1)
        // One embedder per worker — sharing one would re-serialize everything behind
        // its actor, and one per PHOTO would mean 20 model sessions.
        #expect(parallel.providers == 3)
        #expect(await parallel.embeds.count == 20)
    }

    // NOTE: an earlier draft asserted a wall-clock RATIO here (4 workers finishing a
    // staggered album in under serial/1.5). That was a flaky benchmark dressed as a
    // correctness test — `fanOutIsBounded`'s peak-in-flight counter proves the same
    // overlap deterministically, so the timing test was removed rather than tuned.

    // MARK: - The width is re-read per scan

    @Test("Changing the worker count applies to the NEXT scan on the same engine")
    func workerCountIsReReadPerScan() async throws {
        let album = try tempDir("album")
        try writePhotos(12, into: album)
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        // A mutable width behind the same seam `AppModel` injects (which reads the
        // preference), so this exercises re-resolution, not engine reconstruction.
        let width = ProviderCount() // reused as a plain thread-safe int box
        width.set(1)
        let firstEmbeds = EmbedCounter()
        let secondEmbeds = EmbedCounter()
        let useSecond = ProviderCount()
        let providers = ProviderCount()

        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: "subject-1",
            modelId: modelId,
            modelVersion: modelVersion,
            makeProvider: { _ in
                providers.increment()
                return StaggeredEmbedder(
                    staggered: true,
                    counter: useSecond.count == 0 ? firstEmbeds : secondEmbeds
                )
            },
            workerCount: { width.count }
        )

        for await _ in engine.scan(albums: [album]) {}
        #expect(providers.count == 1) // width 1 ⇒ one embedder
        #expect(await firstEmbeds.peakInFlight == 1)

        // Same engine, no relaunch, no reconstruction: just a wider preference.
        useSecond.set(1)
        width.set(3)
        providers.set(0)
        for await _ in engine.scan(albums: [album]) {}
        #expect(providers.count == 3) // the SECOND scan fanned out
        #expect(await secondEmbeds.peakInFlight > 1)
        #expect(await secondEmbeds.peakInFlight <= 3)
    }

    // MARK: - Cancellation

    @Test("Abandoning the scan stream stops the workers instead of running to completion")
    func cancellationStopsWork() async throws {
        let album = try tempDir("album")
        try writePhotos(60, into: album)
        let storeURL = try tempDir("store").appendingPathComponent("store.json")
        try store(at: storeURL)

        let embeds = EmbedCounter()
        let engine = LiveTriageEngine(
            environment: [:],
            storeURL: storeURL,
            subjectId: "subject-1",
            modelId: modelId,
            modelVersion: modelVersion,
            makeProvider: { _ in StaggeredEmbedder(staggered: true, counter: embeds) },
            workerCount: { 3 }
        )

        // Drive it exactly the way `ScanController` does: the stream is consumed by its
        // own Task, which is then CANCELLED from outside. Cancelling that task ends the
        // iteration, which fires the stream's `onTermination` and cancels the scan.
        let ticks = EmbedCounter()
        let consumerFinished = Signal()
        let consumer = Task {
            for await progress in engine.scan(albums: [album]) where !progress.indeterminate {
                await ticks.enter()
                await ticks.leave()
            }
            // Reached only if the iteration actually ENDS — i.e. the scan terminated.
            await consumerFinished.send()
        }

        // Wait until the scan is demonstrably under way, then cancel.
        for _ in 0 ..< 100 where await ticks.count < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await ticks.count >= 5)
        let startedAtCancel = await embeds.count
        consumer.cancel()

        // TERMINATION, not just quiescence: the consumer's iteration must actually END,
        // within a deadline. The completion SIGNAL is polled rather than awaiting
        // `consumer.value` — a stuck coordinator would leave that await hung, and no
        // task-group timer can rescue it (a group awaits all its children on exit), so
        // awaiting the task would hang the very test meant to catch the hang. Polling a
        // flag turns "never terminated" into a failed expectation instead.
        var finished = false
        for _ in 0 ..< 200 where !finished {
            if await consumerFinished.isSet {
                finished = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finished) // ⇒ the scan stream ended after cancellation; no hang

        // Now the invariant: once the coordinator observes cancellation it queues no
        // further photos, so the only work that may still land is what was already in
        // flight — at most one photo per worker.
        let embedded = await embeds.count
        #expect(embedded <= startedAtCancel + 3) // 3 workers ⇒ at most 3 in flight

        // And nothing is still churning in the background: the count is stable across a
        // further interval, i.e. the pipeline stopped rather than merely detaching from
        // its output.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await embeds.count == embedded)
        #expect(embedded < 60) // the 60-photo queue was abandoned, not drained
    }

    // MARK: - Album resolution

    @Test("Concurrent album resolution preserves album ORDER")
    func concurrentResolutionKeepsOrder() async throws {
        let first = try tempDir("resolve-a")
        let second = try tempDir("resolve-b")
        let third = try tempDir("resolve-c")
        try writePhotos(2, into: first, prefix: "a")
        try writePhotos(3, into: second, prefix: "b")
        try writePhotos(1, into: third, prefix: "c")
        let albums = [first, second, third]

        let serial = try LiveTriageEngine.resolveAndEnumerate(
            albums: albums,
            enumerate: ScanPipeline.enumerateImages(in:)
        )
        let concurrent = try await LiveTriageEngine.resolveAndEnumerateConcurrently(
            albums: albums,
            workers: 4,
            enumerate: ScanPipeline.enumerateImages(in:)
        )

        #expect(concurrent.map(\.name) == serial.map(\.name))
        #expect(concurrent.map(\.root) == serial.map(\.root))
        #expect(concurrent.map(\.keys) == serial.map(\.keys))
        #expect(concurrent.map(\.keys.count) == [2, 3, 1])
    }

    @Test("Album resolutions genuinely OVERLAP, bounded by the worker count")
    func concurrentResolutionOverlaps() async throws {
        var albums: [URL] = []
        for index in 0 ..< 4 {
            let dir = try tempDir("overlap-\(index)")
            try writePhotos(1, into: dir, prefix: "p\(index)")
            albums.append(dir)
        }

        // Serial control: a barrier of 1 never blocks, and one worker can never have
        // two resolutions inside it at once.
        let serial = ResolutionBarrier(releaseAt: 1)
        _ = try await LiveTriageEngine.resolveAndEnumerateConcurrently(
            albums: albums, workers: 1, enumerate: serial.enumerate
        )
        #expect(serial.peak == 1)
        #expect(!serial.timedOut)

        // Three workers over four albums, with a barrier that only opens once THREE
        // resolutions are inside it simultaneously. Reaching the barrier at all proves
        // the resolutions overlap; a serial implementation would time out.
        let concurrent = ResolutionBarrier(releaseAt: 3)
        let resolved = try await LiveTriageEngine.resolveAndEnumerateConcurrently(
            albums: albums, workers: 3, enumerate: concurrent.enumerate
        )
        #expect(!concurrent.timedOut)
        #expect(concurrent.peak == 3) // exactly the configured width, never more
        // Overlapping didn't cost ordering.
        #expect(resolved.map(\.name) == albums.map(\.lastPathComponent))
    }

    @Test("A failing album still throws out of the concurrent resolution")
    func concurrentResolutionPropagatesFailure() async throws {
        let good = try tempDir("resolve-good")
        try writePhotos(1, into: good)
        // A .zip that isn't a zip: `unzip` exits non-zero ⇒ zipExtractionFailed.
        let badZip = try tempDir("resolve-bad").appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: badZip)

        await #expect(throws: (any Error).self) {
            _ = try await LiveTriageEngine.resolveAndEnumerateConcurrently(
                albums: [good, badZip],
                workers: 4,
                enumerate: ScanPipeline.enumerateImages(in:)
            )
        }
    }
}
