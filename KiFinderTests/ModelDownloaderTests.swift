import CryptoKit
import Foundation
@testable import KiFinder
import Testing

@Suite("Model downloader state machine")
@MainActor
struct ModelDownloaderTests {
    /// A fake network seam. Each `download` consumes the next queued behavior and
    /// records EVERY temp file it actually wrote to disk, so tests can assert real
    /// files (not vacuous conditions) are cleaned up.
    final class FakeDownloadClient: ModelDownloadClient, @unchecked Sendable {
        enum Behavior {
            /// Succeed: write `Data` to a temp and return it.
            case yield(Data)
            /// Fail before writing anything (e.g. connection refused).
            case fail
            /// Write a REAL partial temp to disk, THEN fail (mid-download drop).
            case failAfterPartial(Data)
        }

        private let lock = NSLock()
        private var pending: [Behavior]
        private var temps: [URL] = []

        init(_ behaviors: [Behavior]) {
            pending = behaviors
        }

        convenience init(_ behavior: Behavior) {
            self.init([behavior])
        }

        /// Every temp the fake wrote to disk, in order.
        var createdTemps: [URL] {
            lock.lock(); defer { lock.unlock() }
            return temps
        }

        var lastTempURL: URL? {
            createdTemps.last
        }

        private func makeTemp(_ data: Data) throws -> URL {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("fake-download-\(UUID().uuidString)")
            try data.write(to: temp)
            lock.lock(); temps.append(temp); lock.unlock()
            return temp
        }

        func download(
            from _: URL,
            onProgress: @escaping @Sendable (Int64, Int64) -> Void
        ) async throws -> URL {
            let behavior = lock.withLock { pending.isEmpty ? Behavior.fail : pending.removeFirst() }
            switch behavior {
            case .fail:
                throw URLError(.notConnectedToInternet)
            case let .failAfterPartial(data):
                // The client owns its own temp; on a drop the downloader never
                // receives it, so the guarantee under test is that NOTHING lands in
                // the managed directory — not that the downloader deletes a temp it
                // never saw.
                _ = try makeTemp(data)
                throw URLError(.networkConnectionLost)
            case let .yield(data):
                onProgress(Int64(data.count), Int64(data.count))
                return try makeTemp(data)
            }
        }
    }

    /// Coordinates the injected verify seam with the test: signals when verify
    /// begins and blocks it until released, so the test can cancel mid-`verifying`.
    actor VerifyGate {
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var started = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var released = false

        /// Called by the verify seam: marks started, wakes any `waitUntilStarted`,
        /// then blocks until `release()`.
        func enterAndWait() async {
            started = true
            for waiter in startWaiters {
                waiter.resume()
            }
            startWaiters.removeAll()
            if released { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        /// Suspends until the verify seam has begun.
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        /// Lets the blocked verify seam return.
        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixtureDescriptor(for data: Data) -> ModelAssetDescriptor {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelAssetDescriptor(
            downloadURL: URL(string: "https://example.com/fixture.onnx")!,
            expectedByteCount: Int64(data.count),
            expectedSHA256: hash,
            fileName: "fixture.onnx"
        )
    }

    /// Polls until the downloader reaches a terminal (installed/failed) state.
    private func waitForTerminal(_ downloader: ModelDownloader) async {
        await waitUntil {
            switch downloader.state {
            case .installed, .failed: true
            default: false
            }
        }
    }

    /// Polls `condition` on the main actor until true or a timeout elapses.
    private func waitUntil(timeoutMs: Int = 6000, _ condition: @MainActor () -> Bool) async {
        var elapsed = 0
        while !condition(), elapsed < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            elapsed += 10
        }
    }

    @Test("Happy path installs the verified model at the managed location")
    func happyPathInstalls() async throws {
        let data = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let descriptor = fixtureDescriptor(for: data)
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        let client = FakeDownloadClient(.yield(data))
        let downloader = ModelDownloader(descriptor: descriptor, client: client, installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)

        #expect(downloader.state == .installed)
        #expect(FileManager.default.fileExists(atPath: installURL.path))
        let installed = try Data(contentsOf: installURL)
        #expect(installed == data)
        // The temp file was moved (not copied) — nothing left behind.
        let temp = try #require(client.lastTempURL)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("Wrong bytes → failed, no managed file, the downloaded temp is removed")
    func wrongBytesFails() async throws {
        let good = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let descriptor = fixtureDescriptor(for: good)
        // Yield SAME-size but tampered bytes → size matches, hash differs.
        var bad = good
        bad[42] = bad[42] &+ 1
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        let client = FakeDownloadClient(.yield(bad))
        let downloader = ModelDownloader(descriptor: descriptor, client: client, installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)

        if case .failed = downloader.state {} else {
            Issue.record("Expected .failed, got \(downloader.state)")
        }
        #expect(downloader.state != .installed)
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
        // A REAL temp was written by the client and verification rejected it — the
        // downloader removed that actual file (non-vacuous).
        let temp = try #require(client.lastTempURL)
        #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    }

    @Test("Network drop → failed, nothing contaminates the managed models directory")
    func networkDropLeavesManagedClean() async throws {
        let descriptor = fixtureDescriptor(for: Data((0 ..< 5000).map { UInt8($0 % 251) }))
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        // The fake writes a REAL partial temp to disk, then fails — so this exercises
        // an actually-created file, not a vacuous condition.
        let client = FakeDownloadClient(.failAfterPartial(Data(repeating: 7, count: 4096)))
        let downloader = ModelDownloader(descriptor: descriptor, client: client, installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)

        if case .failed = downloader.state {} else {
            Issue.record("Expected .failed, got \(downloader.state)")
        }
        // A real partial WAS created during the failed attempt…
        let partial = try #require(client.lastTempURL)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        // …yet nothing landed at the managed location or in its models/ directory.
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
        let modelsDir = installURL.deletingLastPathComponent()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        #expect(leftovers.isEmpty)
        try? FileManager.default.removeItem(at: partial)
    }

    @Test("installed is never reached without verification ok (wrong size)")
    func wrongSizeNeverInstalls() async throws {
        let descriptor = fixtureDescriptor(for: Data((0 ..< 5000).map { UInt8($0 % 251) }))
        // Yield a file whose size differs from the descriptor → wrongSize → failed.
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        let client = FakeDownloadClient(.yield(Data(repeating: 0, count: 10)))
        let downloader = ModelDownloader(descriptor: descriptor, client: client, installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)

        #expect(downloader.state != .installed)
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
        let temp = try #require(client.lastTempURL)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("Cancel during verification never installs and removes the temp")
    func cancelDuringVerify() async throws {
        let data = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let descriptor = fixtureDescriptor(for: data)
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        let client = FakeDownloadClient(.yield(data))
        let gate = VerifyGate()
        // The seam returns `.ok` AFTER release — so WITHOUT the post-verify
        // cancellation check, the install would (wrongly) proceed to `.installed`.
        let downloader = ModelDownloader(
            descriptor: descriptor,
            client: client,
            installURL: installURL,
            verify: { _, _ in
                await gate.enterAndWait()
                return .ok
            }
        )

        downloader.start()
        await gate.waitUntilStarted()
        #expect(downloader.state == .verifying)

        downloader.cancel()
        await gate.release()

        // Let run() resume and execute its CancellationError cleanup.
        let temp = try #require(client.lastTempURL)
        await waitUntil { !FileManager.default.fileExists(atPath: temp.path) }

        #expect(downloader.state != .installed)
        #expect(!FileManager.default.fileExists(atPath: installURL.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test("Retry after a failed attempt cleans up and a fresh attempt installs")
    func retryAfterFailureInstalls() async throws {
        let good = Data((0 ..< 5000).map { UInt8($0 % 251) })
        let descriptor = fixtureDescriptor(for: good)
        var bad = good
        bad[7] = bad[7] &+ 1
        let appSupport = try makeTempDir()
        let installURL = managedModelURL(appSupportRoot: appSupport, fileName: descriptor.fileName)
        // First attempt yields tampered bytes (fails); retry yields good bytes.
        let client = FakeDownloadClient([.yield(bad), .yield(good)])
        let downloader = ModelDownloader(descriptor: descriptor, client: client, installURL: installURL)

        downloader.start()
        await waitForTerminal(downloader)
        if case .failed = downloader.state {} else {
            Issue.record("Expected .failed on first attempt, got \(downloader.state)")
        }
        // The first attempt's real temp was removed at failure (no stray temp left).
        let firstTemp = try #require(client.createdTemps.first)
        #expect(!FileManager.default.fileExists(atPath: firstTemp.path))

        downloader.retry()
        await waitForTerminal(downloader)

        #expect(downloader.state == .installed)
        #expect(FileManager.default.fileExists(atPath: installURL.path))
        #expect(try Data(contentsOf: installURL) == good)
        // No stray temp survives anywhere: the failed one removed, the good one moved.
        #expect(client.createdTemps.count == 2)
        for temp in client.createdTemps {
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }
}
