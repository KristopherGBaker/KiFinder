import Foundation

/// Network seam: downloads the asset to a temporary file and reports byte
/// progress. Injected into `ModelDownloader` so tests can substitute a FAKE that
/// yields a fixture file (and a deterministic failure) without any real network.
protocol ModelDownloadClient: Sendable {
    /// Downloads `url` to a freshly created temp file and returns its URL. Calls
    /// `onProgress` with cumulative bytes written and the total (which may be
    /// `expectedContentLength` or `-1` when unknown). Throws on network failure;
    /// honors task cancellation.
    func download(
        from url: URL,
        onProgress: @escaping @Sendable (_ bytesWritten: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> URL
}

/// Production client: a `URLSession` download task whose delegate reports progress
/// and yields the downloaded temp file. The temp file's lifetime is owned by the
/// caller (`ModelDownloader`), which moves or removes it.
final class URLSessionModelDownloadClient: NSObject, ModelDownloadClient, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?

    func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                self.continuation = continuation
                self.onProgress = onProgress
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let onProgress = self.onProgress
        lock.unlock()
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The session deletes `location` once this returns, so move it to a temp
        // file we own before resuming the continuation.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kifinder-model-\(UUID().uuidString)")
        let result = Result<URL, Error> {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return destination
        }
        resume(with: result)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is delivered by didFinishDownloadingTo; only surface a real error.
        guard let error else { return }
        resume(with: .failure(error))
    }

    private func resume(with result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        onProgress = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
