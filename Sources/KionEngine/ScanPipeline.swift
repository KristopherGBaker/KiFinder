import CoreGraphics
import Foundation
import ImageIO

public struct ScanResult: Sendable {
    public var manifest: Manifest
    public var keep: [String]
    public var maybe: [String]

    public init(manifest: Manifest, keep: [String], maybe: [String]) {
        self.manifest = manifest
        self.keep = keep
        self.maybe = maybe
    }
}

public enum ScanPipelineError: Error, Equatable, Sendable {
    case albumNotFound(String)
    case unsupportedAlbum(String)
    case zipExtractionFailed(String)
}

public struct ScanPipeline {
    private let embedAllFaces: (CGImage) async throws -> [DetectedFace]
    private let minDetectionScore: Float
    private let minBoundingBoxArea: Float
    /// Whether a face produced by `FaceEmbedder`'s blind heuristic fallback (no
    /// real detector found anything; `QualityMetrics.isFallback == true`) is
    /// eligible to be matched/ranked. Defaults to `false`: a "detection" that is
    /// really the whole photo embedded as a maximum-confidence guess must not
    /// silently land a face-less photo in `keep`/`maybe` (item 56) — the user
    /// story this item fixes is exactly that. A photo whose only detected face
    /// is a fallback still appears in the output manifest (bucketed `.no`,
    /// exactly like a photo that fails the existing detection-score/area
    /// quality gate); it's excluded from ranking, not silently dropped. Pass
    /// `true` to restore the pre-item-56 behavior of trusting a blind guess as a
    /// genuine detection.
    private let includeFallbackFaces: Bool

    public init(
        embedFace: @escaping (CGImage) async throws -> DetectedFace?,
        embedAllFaces: ((CGImage) async throws -> [DetectedFace])? = nil,
        minDetectionScore: Float,
        minBoundingBoxArea: Float,
        includeFallbackFaces: Bool = false
    ) {
        // Fall back to the single-face embedder (wrapped) when an all-faces
        // embedder isn't supplied, so existing callers keep working.
        self.embedAllFaces = embedAllFaces ?? { image in try await embedFace(image).map { [$0] } ?? [] }
        self.minDetectionScore = minDetectionScore
        self.minBoundingBoxArea = minBoundingBoxArea
        self.includeFallbackFaces = includeFallbackFaces
    }

    public func enumerateImages(in album: URL) throws -> [String] {
        try Self.enumerateImages(in: album)
    }

    /// Enumeration is pure — it reads the filesystem and touches no pipeline state —
    /// so it's also available statically. Callers that need to pass enumeration ACROSS
    /// a task boundary (the app's concurrent album resolution) reference this rather
    /// than a method bound to a non-`Sendable` pipeline instance.
    public static func enumerateImages(in album: URL) throws -> [String] {
        let resolved = try resolveAlbumRoot(album)
        defer { resolved.cleanup() }
        return try resolved.restrictKeys ?? imageKeys(in: resolved.root)
    }

    /// Single-profile scan. Implemented in terms of the multi-profile path with one
    /// profile so the two stay in lockstep; the result is byte-identical to scanning
    /// just this subject.
    public func scan(
        album: URL,
        profile: ProfileBundle,
        existingManifest: Manifest = .init()
    ) async throws -> ScanResult {
        try await scan(album: album, profiles: [profile], existingManifest: existingManifest)
    }

    /// One-pass scan over **multiple** profiles: each detected face is embedded
    /// **once** per photo, then scored against **every** supplied profile, recording
    /// a `SubjectResult` in `BestFace.subjectResults` under each profile's
    /// `subjectId`. A photo's representative `embedding`/`qualityMetrics` is the
    /// first profile's best-matching face (face 0 when nothing passes the gate); all
    /// detected faces are kept so the user can override the selection. The returned
    /// `keep`/`maybe` rankings reflect each photo's best bucket across the supplied
    /// profiles ("found by anyone"), which reduces exactly to the single-profile
    /// ranking when one profile is supplied.
    public func scan(
        album: URL,
        profiles: [ProfileBundle],
        existingManifest: Manifest = .init()
    ) async throws -> ScanResult {
        let resolved = try Self.resolveAlbumRoot(album)
        defer { resolved.cleanup() }
        let rootURL = resolved.root
        let keys = try resolved.restrictKeys ?? Self.imageKeys(in: rootURL)
        let stamp = profiles.first
        var manifest = Manifest(modelId: stamp?.modelId, modelVersion: stamp?.modelVersion)

        for key in keys {
            if let cached = cachedFace(
                for: key,
                in: existingManifest,
                profiles: profiles
            ) {
                manifest[key] = try rescore(cached, profiles: profiles)
                continue
            }

            let imageURL = rootURL.appendingPathComponent(key)
            guard let image = Self.decodeImage(at: imageURL) else {
                continue
            }
            let faces = try await embedAllFaces(image)
            guard !faces.isEmpty else {
                continue
            }

            manifest[key] = try bestFace(
                from: faces,
                profiles: profiles,
                existingFace: existingManifest[key]
            )
        }

        return ScanResult(
            manifest: manifest,
            keep: rankedKeys(in: manifest, profiles: profiles, bucket: .keep),
            maybe: rankedKeys(in: manifest, profiles: profiles, bucket: .maybe)
        )
    }
}

public extension ScanPipeline {
    /// The supported image file extensions (heic/heif/jpg/jpeg/png). Shared so the
    /// app layer resolves a loose image file the same way the pipeline does.
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    /// Whether `url` names a supported image file (by extension). The "is image file"
    /// check shared between the pipeline and `LiveTriageEngine`'s album resolution.
    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// The single, canonical image decode used everywhere a `CGImage` is loaded from
    /// disk (the scan loop, CLI enroll, and `LiveTriageEngine`'s enroll/scan/manual-face
    /// paths) — previously duplicated three times and free to drift. Decodes the first
    /// image at `url` with `ImageIO` using no options: no orientation correction, no
    /// downsampling, no color-management flags. That is deliberate — this function's
    /// output feeds face embedding, and changing decode flags changes the embeddings a
    /// given photo produces (stored references carry a model stamp that would still
    /// read as compatible against differently-preprocessed embeddings). `nil` when the
    /// file doesn't exist, isn't an image, or can't be decoded; never throws or crashes.
    static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private extension ScanPipeline {
    /// Resolves an album URL to a scan root and (optionally) a restricted set of keys.
    /// A `.zip` is extracted to a temp dir, a directory is scanned in place, and a
    /// regular **image file** resolves to its parent directory with just that file's
    /// name as the single key, so a loose image enumerates to only itself — never its
    /// siblings. Anything else throws `unsupportedAlbum`, unchanged.
    ///
    /// Returns a `cleanup` closure the caller MUST invoke (typically via `defer`,
    /// immediately after the call) once done with the root, even on an early return
    /// or a thrown error — it removes the temporary extraction directory for a `.zip`
    /// album, and is a no-op for a directory/loose-file album. This used to be a
    /// higher-order `withAlbumRoot(_:body:)` that ran the `defer` internally around
    /// an injected closure; item 64 split it into "resolve, then let the caller act"
    /// so the SAME resolution logic serves both a synchronous caller
    /// (`enumerateImages`) and an `async throws` one (`scan`) without forcing one
    /// generic function to pick a single sync/async shape for the closure it invokes.
    static func resolveAlbumRoot(_ album: URL) throws -> (root: URL, restrictKeys: [String]?, cleanup: () -> Void) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: album.path) else {
            throw ScanPipelineError.albumNotFound(album.path)
        }

        if album.pathExtension.lowercased() == "zip" {
            let extractionRoot = fileManager.temporaryDirectory
                .appendingPathComponent("KionScan-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
            let cleanup: () -> Void = { try? fileManager.removeItem(at: extractionRoot) }

            do {
                try unzip(album, to: extractionRoot)
            } catch {
                cleanup()
                throw error
            }
            return (extractionRoot, nil, cleanup)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: album.path, isDirectory: &isDirectory) else {
            throw ScanPipelineError.unsupportedAlbum(album.path)
        }

        if isDirectory.boolValue {
            return (album, nil, {})
        }

        // A regular file that is a supported image scans as just that one file: root
        // is its PARENT and the only key is its name (siblings are NOT enumerated).
        guard Self.isImageFile(album) else {
            throw ScanPipelineError.unsupportedAlbum(album.path)
        }
        return (album.deletingLastPathComponent(), [album.lastPathComponent], {})
    }

    static func unzip(_ zipURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", destinationURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ScanPipelineError.zipExtractionFailed(zipURL.path)
        }
    }

    static func imageKeys(in rootURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var keys: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            guard Self.imageExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            keys.append(Self.relativeKey(for: fileURL, rootURL: rootURL))
        }
        return keys.sorted()
    }

    func cachedFace(
        for key: String,
        in manifest: Manifest,
        profiles: [ProfileBundle]
    ) -> BestFace? {
        // All supplied profiles come from one store and share a model stamp, so the
        // first profile's stamp gates the cache for the whole set. A legacy-alias
        // manifest stamp (item 58) is treated as compatible with a canonical
        // profile, exactly like `FaceMatcher.checkManifestStamp` — never a cache
        // miss just because an old label differs from today's truthful one.
        guard let profile = profiles.first else {
            return manifest[key]
        }
        guard FaceMatcher.manifestStampCompatible(
            manifest,
            modelId: profile.modelId,
            modelVersion: profile.modelVersion
        ) else {
            return nil
        }
        return manifest[key]
    }

    /// Records, per photo, one `SubjectResult` for **every** supplied profile —
    /// each scored against that profile's own best-matching detected face — while
    /// keeping all detected faces so the user can override the choice. The photo's
    /// representative `embedding`/`qualityMetrics` is the first profile's best face
    /// (face 0 when nothing passes the gate), which keeps the single-profile path
    /// identical.
    func bestFace(
        from faces: [DetectedFace],
        profiles: [ProfileBundle],
        existingFace: BestFace?
    ) throws -> BestFace {
        let representativeIndex = try profiles.first.flatMap { profile in
            try FaceMatcher.bestMatchingFace(
                among: faces,
                profile: profile,
                minDetectionScore: minDetectionScore,
                minBoundingBoxArea: minBoundingBoxArea,
                includeFallbackFaces: includeFallbackFaces
            )?.index
        } ?? 0
        let representative = faces[representativeIndex]

        var subjectResults: [String: SubjectResult] = [:]
        for profile in profiles {
            let selectedIndex = try FaceMatcher.bestMatchingFace(
                among: faces,
                profile: profile,
                minDetectionScore: minDetectionScore,
                minBoundingBoxArea: minBoundingBoxArea,
                includeFallbackFaces: includeFallbackFaces
            )?.index ?? 0
            let selected = faces[selectedIndex]
            let feedback = existingFace?.subjectResults[profile.subjectId]?.feedback
            subjectResults[profile.subjectId] = try subjectResult(
                embedding: selected.embedding,
                qualityMetrics: selected.qualityMetrics,
                profile: profile,
                feedback: feedback
            )
        }

        return BestFace(
            embedding: representative.embedding,
            qualityMetrics: representative.qualityMetrics,
            subjectResults: subjectResults,
            faces: faces
        )
    }

    /// Re-scores a cached photo against the supplied profiles. When every detected
    /// face is cached (`BestFace.faces`), each profile is re-attributed to **its
    /// own** best-matching face — exactly as the fresh path does — so a group photo
    /// on a re-scan never mis-attributes a person to another person's face. Falls
    /// back to scoring the single representative `embedding` only for a **legacy**
    /// manifest written before `faces` existed (the per-face information is gone, so
    /// the representative is all we have).
    func rescore(_ bestFace: BestFace, profiles: [ProfileBundle]) throws -> BestFace {
        guard let faces = bestFace.faces, !faces.isEmpty else {
            var rescored = bestFace
            for profile in profiles {
                let feedback = bestFace.subjectResults[profile.subjectId]?.feedback
                rescored.subjectResults[profile.subjectId] = try subjectResult(
                    embedding: bestFace.embedding,
                    qualityMetrics: bestFace.qualityMetrics,
                    profile: profile,
                    feedback: feedback
                )
            }
            return rescored
        }

        var rescored = bestFace
        for profile in profiles {
            let selectedIndex = try FaceMatcher.bestMatchingFace(
                among: faces,
                profile: profile,
                minDetectionScore: minDetectionScore,
                minBoundingBoxArea: minBoundingBoxArea,
                includeFallbackFaces: includeFallbackFaces
            )?.index ?? 0
            let selected = faces[selectedIndex]
            let feedback = bestFace.subjectResults[profile.subjectId]?.feedback
            rescored.subjectResults[profile.subjectId] = try subjectResult(
                embedding: selected.embedding,
                qualityMetrics: selected.qualityMetrics,
                profile: profile,
                feedback: feedback
            )
        }
        return rescored
    }

    func subjectResult(
        embedding: FaceEmbedding,
        qualityMetrics: QualityMetrics,
        profile: ProfileBundle,
        feedback: FeedbackLabel?
    ) throws -> SubjectResult {
        guard FaceMatcher.passesQualityGate(
            metrics: qualityMetrics,
            minDetectionScore: minDetectionScore,
            minBoundingBoxArea: minBoundingBoxArea,
            includeFallbackFaces: includeFallbackFaces
        ) else {
            return SubjectResult(score: 0.0, bucket: .no, feedback: feedback)
        }

        let metric = FaceModelRegistry.standard.metric(for: profile)
        let raw = try FaceMatcher.score(embedding: embedding, profile: profile, metric: metric)
        let adjusted = try FaceMatcher.adjustedScore(
            raw: raw,
            embedding: embedding,
            negatives: profile.negatives,
            negativeMargin: profile.negativeMargin,
            metric: metric
        )
        return SubjectResult(
            score: adjusted,
            bucket: FaceMatcher.bucket(
                score: adjusted,
                threshold: profile.threshold,
                maybeMargin: profile.maybeMargin
            ),
            feedback: feedback
        )
    }

    /// Ranks the photos whose **best** bucket across the supplied profiles equals
    /// `bucket`. A photo's representative result is the highest-ranked bucket among
    /// its subjects (keep > maybe > no), tie-broken by score — i.e. "found by
    /// anyone". With one profile this reduces exactly to per-subject ranking.
    func rankedKeys(in manifest: Manifest, profiles: [ProfileBundle], bucket: Bucket) -> [String] {
        let subjectIds = profiles.map(\.subjectId)
        return manifest.bestFacesByPhotoPath
            .compactMap { key, face -> (String, Float)? in
                let results = subjectIds.compactMap { face.subjectResults[$0] }
                guard let best = results.max(by: { lhs, rhs in
                    if Self.bucketRank(lhs.bucket) == Self.bucketRank(rhs.bucket) {
                        return lhs.score < rhs.score
                    }
                    return Self.bucketRank(lhs.bucket) < Self.bucketRank(rhs.bucket)
                }), best.bucket == bucket
                else {
                    return nil
                }
                return (key, best.score)
            }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0 < $1.0
                }
                return $0.1 > $1.1
            }
            .map(\.0)
    }

    /// Bucket precedence for picking a photo's representative match across people.
    static func bucketRank(_ bucket: Bucket) -> Int {
        switch bucket {
        case .keep: 2
        case .maybe: 1
        case .no: 0
        }
    }

    static func relativeKey(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}
