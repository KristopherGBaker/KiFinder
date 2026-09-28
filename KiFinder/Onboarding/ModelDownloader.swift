import CoreML
import Foundation
import Observation

/// First-run download state machine: downloads the model to a temp file, verifies
/// it (assertion-3 integrity), and ONLY on `ok` atomically moves it into the
/// managed location. The temp file is removed on EVERY non-success exit — network
/// error, wrong size/hash, cancel, and before a retry — so no partial ever leaks
/// and a partial never lands at the managed location.
@MainActor
@Observable
final class ModelDownloader {
    enum State: Equatable {
        case idle
        case downloading(fractionCompleted: Double, bytesWritten: Int64, totalBytes: Int64)
        case verifying
        case installed
        case failed(message: String)
    }

    private(set) var state: State = .idle

    private let descriptor: ModelAssetDescriptor
    /// The active descriptor's expected download size — item74b: the onboarding
    /// copy derives its byte-count text from THIS (not a hardcoded literal), so
    /// it reads correctly for whichever backend's asset this downloader owns.
    var expectedByteCount: Int64 { descriptor.expectedByteCount }
    private let client: any ModelDownloadClient
    /// The managed location the verified model is installed to. Internal (not
    /// `private`) so tests can pin it (e.g. "ends in `AdaFace_IR18.mlmodelc`").
    let installURL: URL
    /// Integrity-check seam. Defaults to the production streaming check run OFF the
    /// main actor; injectable so tests can make the verify window observable (e.g.
    /// to cancel mid-`verifying`). Production behavior is unchanged by the default.
    private let verifyFile: @Sendable (URL, ModelAssetDescriptor) async -> ModelIntegrityResult
    /// Install seam: turns the VERIFIED temp file into a loadable model at
    /// `installURL`, per `descriptor.installKind`. Defaults to the kind-appropriate
    /// production work (`.moveFile` = the original atomic move, byte-identical;
    /// `.unzipAndCompileMLModel` = unzip → `MLModel.compileModel` → move), run OFF
    /// the main actor; injectable so tests can make install failure/cancellation
    /// deterministic without a real zip.
    private let installFile: @Sendable (URL, ModelAssetDescriptor, URL) async -> Result<Void, Error>
    private var task: Task<Void, Never>?

    init(
        descriptor: ModelAssetDescriptor = .production,
        client: any ModelDownloadClient = URLSessionModelDownloadClient(),
        installURL: URL,
        verify: (@Sendable (URL, ModelAssetDescriptor) async -> ModelIntegrityResult)? = nil,
        install: (@Sendable (URL, ModelAssetDescriptor, URL) async -> Result<Void, Error>)? = nil
    ) {
        self.descriptor = descriptor
        self.client = client
        self.installURL = installURL
        verifyFile = verify ?? Self.defaultVerify
        installFile = install ?? Self.defaultInstall
    }

    /// Default verify seam: streams the SHA-256 OFF the main actor (a 261 MB hash
    /// must not block the UI).
    private static let defaultVerify: @Sendable (URL, ModelAssetDescriptor) async -> ModelIntegrityResult = { url, descriptor in
        await Task.detached(priority: .userInitiated) {
            verify(fileURL: url, against: descriptor)
        }.value
    }

    /// Default install seam: dispatches on `descriptor.installKind`, run OFF the
    /// main actor (a compile step must not block the UI any more than the hash
    /// does).
    private static let defaultInstall: @Sendable (URL, ModelAssetDescriptor, URL) async -> Result<Void, Error> = { temp, descriptor, installURL in
        await Task.detached(priority: .userInitiated) {
            switch descriptor.installKind {
            case .moveFile:
                Result { try ModelDownloader.moveInstall(from: temp, to: installURL) }
            case .unzipAndCompileMLModel:
                Result { try ModelDownloader.unzipAndCompileInstall(from: temp, to: installURL) }
            }
        }.value
    }

    /// Starts the download (no-op if one is already in flight).
    func start() {
        guard task == nil else { return }
        state = .downloading(fractionCompleted: 0, bytesWritten: 0, totalBytes: descriptor.expectedByteCount)
        task = Task { [weak self] in await self?.run() }
    }

    /// Cancels an in-flight download and returns to idle (temp cleaned up by `run`).
    func cancel() {
        task?.cancel()
        task = nil
        if case .installed = state { return }
        state = .idle
    }

    /// Clears any failed/idle state and starts a fresh attempt.
    func retry() {
        task?.cancel()
        task = nil
        state = .idle
        start()
    }

    private func run() async {
        var tempURL: URL?
        defer { task = nil }
        do {
            let temp = try await client.download(from: descriptor.downloadURL) { [weak self] written, total in
                _ = Task { @MainActor in self?.updateProgress(bytesWritten: written, totalBytes: total) }
            }
            tempURL = temp
            try Task.checkCancellation()

            state = .verifying
            let result = await verifyFile(temp, descriptor)
            guard result == .ok else {
                Self.remove(temp)
                state = .failed(message: Self.message(for: result))
                return
            }

            // A cancel() during `.verifying` must NOT leak through to an install:
            // re-check cancellation after verification and BEFORE calling install,
            // so a cancel mid-verify routes to the CancellationError cleanup below
            // (temp removed, state .idle) and the install never happens.
            try Task.checkCancellation()

            let installResult = await installFile(temp, descriptor, installURL)

            // A cancel() during install (e.g. mid-unzip/compile) must not land on
            // `.installed`: re-check AFTER the install seam returns, before
            // committing state, so a cancel routes to the CancellationError
            // cleanup below (temp + any installURL artifact removed, state .idle).
            try Task.checkCancellation()

            switch installResult {
            case .success:
                tempURL = nil
                state = .installed
            case let .failure(error):
                Self.remove(temp)
                Self.remove(installURL)
                state = .failed(message: error.localizedDescription)
            }
        } catch is CancellationError {
            if let tempURL { Self.remove(tempURL) }
            Self.remove(installURL)
            state = .idle
        } catch {
            if let tempURL { Self.remove(tempURL) }
            state = .failed(message: error.localizedDescription)
        }
    }

    private func updateProgress(bytesWritten: Int64, totalBytes: Int64) {
        guard case .downloading = state else { return }
        let total = totalBytes > 0 ? totalBytes : descriptor.expectedByteCount
        let fraction = total > 0 ? min(1, max(0, Double(bytesWritten) / Double(total))) : 0
        state = .downloading(fractionCompleted: fraction, bytesWritten: bytesWritten, totalBytes: total)
    }

    /// `.moveFile` install: the verified temp file IS the installed model, so it's
    /// atomically moved into the managed location — creating the `models/`
    /// directory and replacing any existing file. Byte-identical to the original
    /// (pre-item74b) ONNX-only behavior.
    private nonisolated static func moveInstall(from temp: URL, to installURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
        try fileManager.moveItem(at: temp, to: installURL)
    }

    /// `.unzipAndCompileMLModel` install (item74b, AdaFace): the verified temp is
    /// a zip of an `.mlpackage`. Unzips it into a private work dir (the same
    /// `/usr/bin/unzip` `Process` recipe `LiveTriageEngine.persistentAlbumRoot`
    /// uses — sandbox-proven), locates the `.mlpackage`, compiles it
    /// (`MLModel.compileModel(at:)` — CoreML writes the compiled `.mlmodelc` to
    /// its own temp location), then atomically moves THAT to `installURL`. The
    /// work dir is always removed, success or failure.
    private nonisolated static func unzipAndCompileInstall(from temp: URL, to installURL: URL) throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("kion-adaface-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", temp.path, "-d", work.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelInstallError.unzipFailed
        }

        guard let package = try fileManager
            .contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "mlpackage" })
        else {
            throw ModelInstallError.packageNotFound
        }

        let compiled = try MLModel.compileModel(at: package)
        try fileManager.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installURL.path) {
            try fileManager.removeItem(at: installURL)
        }
        try fileManager.moveItem(at: compiled, to: installURL)
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func message(for result: ModelIntegrityResult) -> String {
        switch result {
        case .ok: ""
        case .wrongSize: String(localized: "The downloaded model was the wrong size. Please try again.")
        case .wrongHash: String(localized: "The downloaded model failed its integrity check. Please try again.")
        case .unreadable: String(localized: "The downloaded model could not be read. Please try again.")
        }
    }
}

/// Diagnosable failures from `.unzipAndCompileMLModel` install (item74b): a
/// failed unzip/compile routes here, not a crash, surfacing a plain-language
/// message through `ModelDownloader.State.failed`.
enum ModelInstallError: LocalizedError {
    case unzipFailed
    case packageNotFound

    var errorDescription: String? {
        switch self {
        case .unzipFailed: String(localized: "The downloaded model archive could not be extracted. Please try again.")
        case .packageNotFound: String(localized: "The downloaded model archive did not contain a valid model. Please try again.")
        }
    }
}
