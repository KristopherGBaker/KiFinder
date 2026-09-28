import Foundation
import KionCoreMLEmbedder
import KionEngine
import KionONNXEmbedder
import KionVisionEmbedder

// The single canonical model identity (item 58) — the SAME value the app's
// `FileProfileRepository` resolves to, so a store written by either side loads
// under the other without a mismatch.
private let activeModelId = ModelIdentity.canonical.modelId
private let activeModelVersion = ModelIdentity.canonical.modelVersion
private let defaultMinDetectionScore: Float = 0.0
private let defaultMinBoundingBoxArea: Float = 0.0
// `scan` (via `ScanPipeline`, whose own default is `false`) already excludes a
// blind-guess fallback face from keep/maybe by default (item 56). `rescore`
// must agree: without this, teaching a new exemplar and re-scoring could
// resurrect a face-less photo that a fresh scan correctly excluded, which
// would be a confusing, order-dependent inconsistency between the two
// commands acting on the SAME manifest.
private let defaultIncludeFallbackFaces = false

@main
struct KionCLI {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("\(describe(error))\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw CLIError.usage("missing command")
        }

        switch command {
        case "enroll":
            try await runEnroll(Array(arguments.dropFirst()))
        case "scan":
            try await runScan(Array(arguments.dropFirst()))
        case "feedback":
            try runFeedback(Array(arguments.dropFirst()))
        case "rescore":
            try runRescore(Array(arguments.dropFirst()))
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func runEnroll(_ arguments: [String]) async throws {
        let options = try Options(arguments, allowPositionals: true)
        guard !options.positionals.isEmpty else {
            throw CLIError.usage("enroll requires at least one image")
        }

        let subjectId = try options.required("subject")
        let storeURL = try options.requiredURL("store")
        let threshold = try options.optionalFloat("threshold")
        let (embedder, descriptor) = try resolveBackend(options)

        var detectedFaces: [DetectedFace] = []
        for path in options.positionals {
            guard let image = ScanPipeline.decodeImage(at: URL(fileURLWithPath: path)) else {
                continue
            }
            if let face = try await embedder.embedFace(image) {
                detectedFaces.append(face)
            }
        }

        guard !detectedFaces.isEmpty else {
            throw CLIError.usage("no face detected in any image")
        }

        var store = try loadOrCreateStore(at: storeURL, modelId: descriptor.id, modelVersion: descriptor.version)
        let calibration = FaceModelRegistry.standard.calibration(for: descriptor.id, modelVersion: descriptor.version)
        var profile = store[subjectId] ?? ProfileBundle(
            subjectId: subjectId,
            references: [],
            threshold: threshold ?? calibration.defaultThreshold,
            maybeMargin: calibration.maybeMargin,
            negativeMargin: calibration.negativeMargin,
            modelId: descriptor.id,
            modelVersion: descriptor.version
        )

        profile.references.append(contentsOf: detectedFaces.map(\.embedding))
        if let threshold {
            profile.threshold = threshold
        }
        profile.modelId = descriptor.id
        profile.modelVersion = descriptor.version

        store[subjectId] = profile
        try store.encode(to: storeURL)
    }

    private static func runScan(_ arguments: [String]) async throws {
        let options = try Options(arguments, allowPositionals: true)
        guard options.positionals.count == 1 else {
            throw CLIError.usage("scan requires exactly one album path")
        }

        let albumURL = URL(fileURLWithPath: options.positionals[0])
        let subjectId = try options.required("subject")
        let storeURL = try options.requiredURL("store")
        let manifestURL = try options.requiredURL("manifest")
        let (embedder, descriptor) = try resolveBackend(options)

        let store = try ProfileStore.load(
            from: storeURL,
            expectingModelId: descriptor.id,
            expectingModelVersion: descriptor.version
        )
        guard let profile = store[subjectId] else {
            throw FaceMatcherError.unknownSubject(subjectId)
        }

        let existingManifest: Manifest
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            existingManifest = try ManifestStore.load(from: manifestURL)
        } else {
            existingManifest = Manifest()
        }

        let pipeline = ScanPipeline(
            embedFace: embedder.embedFace,
            embedAllFaces: embedder.embedAllFaces,
            minDetectionScore: defaultMinDetectionScore,
            minBoundingBoxArea: defaultMinBoundingBoxArea
        )
        let result = try await pipeline.scan(
            album: albumURL,
            profile: profile,
            existingManifest: existingManifest
        )

        try ManifestStore.encode(result.manifest, to: manifestURL)
        let outputData = try JSONEncoder.kionCLIOutput.encode(ScanBuckets(keep: result.keep, maybe: result.maybe))
        FileHandle.standardOutput.write(outputData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func runFeedback(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.usage("missing feedback action")
        }
        let options = try Options(Array(arguments.dropFirst()))
        let storeURL = try options.requiredURL("store")
        let manifestURL = try options.requiredURL("manifest")
        let photoKey = try options.required("photo")
        let subjectId = try options.required("subject")

        var store = try ProfileStore.load(
            from: storeURL,
            expectingModelId: activeModelId,
            expectingModelVersion: activeModelVersion
        )
        var manifest = try ManifestStore.load(from: manifestURL)

        switch action {
        case "confirm":
            try FaceMatcher.confirm(
                photoKey: photoKey,
                subjectId: subjectId,
                manifest: &manifest,
                store: &store
            )
        case "reject":
            try FaceMatcher.reject(
                photoKey: photoKey,
                subjectId: subjectId,
                manifest: &manifest,
                store: &store
            )
        default:
            throw CLIError.usage("unknown feedback action: \(action)")
        }

        try writeBoth(store: store, to: storeURL, manifest: manifest, to: manifestURL)
    }

    private static func runRescore(_ arguments: [String]) throws {
        let options = try Options(arguments)
        let storeURL = try options.requiredURL("store")
        let manifestURL = try options.requiredURL("manifest")
        let subjectId = try options.required("subject")

        let store = try ProfileStore.load(
            from: storeURL,
            expectingModelId: activeModelId,
            expectingModelVersion: activeModelVersion
        )
        guard let profile = store[subjectId] else {
            throw FaceMatcherError.unknownSubject(subjectId)
        }

        let manifest = try ManifestStore.load(from: manifestURL)
        let rescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: profile,
            subjectId: subjectId,
            minDetectionScore: defaultMinDetectionScore,
            minBoundingBoxArea: defaultMinBoundingBoxArea,
            includeFallbackFaces: defaultIncludeFallbackFaces
        )
        let outputData = try JSONEncoder.kionCLIOutput.encode(rescored)

        if let outputPath = options.optional("output") {
            try outputData.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
        } else {
            FileHandle.standardOutput.write(outputData)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// Resolves the `--backend onnx|vision|coreml` option (default `onnx`) to
    /// a provider + the descriptor whose `id`/`version` the caller should
    /// stamp stores/manifests with (item 71, item 74a). `vision` needs no
    /// model file at all — it never consults `--model`/`KION_MODEL_PATH`.
    /// `coreml` resolves its AdaFace model from `--model` else
    /// `KION_ADAFACE_MODEL_PATH` — a DISTINCT resolver from `onnx`'s (they
    /// name different files; `KION_MODEL_PATH` stays the ArcFace path). An
    /// unrecognized value throws a usage error mentioning "backend" so both
    /// `enroll` and `scan` fail the same, diagnosable way rather than
    /// crashing.
    private static func resolveBackend(
        _ options: Options
    ) throws -> (provider: any FaceEmbeddingProvider, descriptor: FaceModelDescriptor) {
        let backend = options.optional("backend") ?? "onnx"
        switch backend {
        case "onnx":
            let modelURL = try resolveModelURL(options)
            let embedder = try FaceEmbedder(modelURL: modelURL)
            return (embedder, .arcface)
        case "vision":
            return (VisionFeaturePrintEmbedder(), .visionFeaturePrint)
        case "coreml":
            let modelURL = try resolveAdaFaceModelURL(options)
            let embedder = try AdaFaceEmbedder(modelURL: modelURL)
            return (embedder, .adaface)
        default:
            throw CLIError.usage("unknown --backend: \(backend) (expected \"onnx\", \"vision\", or \"coreml\")")
        }
    }

    private static func resolveModelURL(_ options: Options) throws -> URL {
        if let modelPath = options.optional("model") {
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw CLIError.usage("model not found: \(modelPath)")
            }
            return URL(fileURLWithPath: modelPath)
        }

        if let modelPath = ProcessInfo.processInfo.environment["KION_MODEL_PATH"],
           FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath)
        }

        throw CLIError.usage("model not found; pass --model or set KION_MODEL_PATH")
    }

    /// Resolves the AdaFace model path from `--model` else
    /// `KION_ADAFACE_MODEL_PATH` — intentionally distinct from
    /// `resolveModelURL`'s `KION_MODEL_PATH`, which names the ONNX ArcFace
    /// file, not this one.
    private static func resolveAdaFaceModelURL(_ options: Options) throws -> URL {
        if let modelPath = options.optional("model") {
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw CLIError.usage("model not found: \(modelPath)")
            }
            return URL(fileURLWithPath: modelPath)
        }

        if let modelPath = ProcessInfo.processInfo.environment["KION_ADAFACE_MODEL_PATH"],
           FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath)
        }

        throw CLIError.usage("model not found; pass --model or set KION_ADAFACE_MODEL_PATH")
    }

    private static func loadOrCreateStore(at url: URL, modelId: String, modelVersion: String) throws -> ProfileStore {
        if FileManager.default.fileExists(atPath: url.path) {
            return try ProfileStore.load(
                from: url,
                expectingModelId: modelId,
                expectingModelVersion: modelVersion
            )
        }

        return ProfileStore(modelId: modelId, modelVersion: modelVersion)
    }

    private static func writeBoth(
        store: ProfileStore,
        to storeURL: URL,
        manifest: Manifest,
        to manifestURL: URL
    ) throws {
        let encoder = JSONEncoder.kionCLIOutput
        let storeData = try encoder.encode(store)
        let manifestData = try encoder.encode(manifest)
        let originalStoreData = try Data(contentsOf: storeURL)
        let originalManifestData = try Data(contentsOf: manifestURL)

        do {
            try storeData.write(to: storeURL, options: [.atomic])
            try manifestData.write(to: manifestURL, options: [.atomic])
        } catch {
            try? originalStoreData.write(to: storeURL, options: [.atomic])
            try? originalManifestData.write(to: manifestURL, options: [.atomic])
            throw error
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private struct Options {
    private var values: [String: String] = [:]
    var positionals: [String] = []

    init(_ arguments: [String], allowPositionals: Bool = false) throws {
        var index = 0
        while index < arguments.count {
            let rawKey = arguments[index]
            guard rawKey.hasPrefix("--") else {
                guard allowPositionals else {
                    throw CLIError.usage("unexpected argument: \(rawKey)")
                }
                positionals.append(rawKey)
                index += 1
                continue
            }

            guard rawKey.count > 2 else {
                throw CLIError.usage("unexpected argument: \(rawKey)")
            }
            let key = String(rawKey.dropFirst(2))
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].hasPrefix("--") else {
                throw CLIError.usage("missing value for --\(key)")
            }
            values[key] = arguments[valueIndex]
            index += 2
        }
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else {
            throw CLIError.usage("missing --\(key)")
        }
        return value
    }

    func optional(_ key: String) -> String? {
        values[key]
    }

    func optionalFloat(_ key: String) throws -> Float? {
        guard let value = values[key] else {
            return nil
        }
        guard let parsed = Float(value) else {
            throw CLIError.usage("invalid --\(key): \(value)")
        }
        return parsed
    }

    func requiredURL(_ key: String) throws -> URL {
        URL(fileURLWithPath: try required(key))
    }
}

private struct ScanBuckets: Codable {
    var keep: [String]
    var maybe: [String]
}

private enum CLIError: Error, Equatable {
    case usage(String)
}

extension CLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

private extension JSONEncoder {
    static var kionCLIOutput: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
