import Foundation

public struct Subject: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct FaceEmbedding: Codable, Equatable, Sendable {
    public var values: [Float]
    public var count: Int {
        values.count
    }

    public init(_ values: [Float]) {
        self.values = values
    }

    public init(values: [Float]) {
        self.values = values
    }
}

/// A face rectangle in normalized image coordinates (each component 0…1) with a
/// top-left origin, expressed in the image's *raw* (un-oriented) pixel space —
/// the same space the detector and embedder work in. Being normalized makes it
/// resolution-independent, so it maps onto any displayed size of the same image;
/// consumers that show an EXIF-oriented image must apply the orientation.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct QualityMetrics: Codable, Equatable, Sendable {
    public var detectionScore: Float
    public var boundingBoxArea: Float
    /// The matched face's rectangle, when a detector (not the blind heuristic
    /// fallback) located one. `nil` when no real box is known. Optional so that
    /// manifests written before this field decode unchanged.
    public var faceBoundingBox: NormalizedRect?
    /// Whether this face came from `FaceEmbedder`'s blind heuristic fallback — the
    /// last resort when BOTH Vision and Core Image detection fail, which embeds a
    /// heuristic center-ish crop with no real localization. A fallback face's
    /// `detectionScore`/`faceBoundingBox` carry no detector confidence, so a
    /// consumer that wants only genuine detections must gate on THIS flag rather
    /// than on `detectionScore` (a numeric threshold is guessable/overloadable;
    /// this isn't). See item 56. `decodeIfPresent`-backed so manifests/stores
    /// written before this field decode unchanged, defaulting to `false` — which
    /// preserves exactly how existing persisted data reads today: nothing already
    /// on disk retroactively becomes "fallback" and gets newly excluded by a
    /// fallback gate.
    public var isFallback: Bool

    public init(
        detectionScore: Float,
        boundingBoxArea: Float,
        faceBoundingBox: NormalizedRect? = nil,
        isFallback: Bool = false
    ) {
        self.detectionScore = detectionScore
        self.boundingBoxArea = boundingBoxArea
        self.faceBoundingBox = faceBoundingBox
        self.isFallback = isFallback
    }

    private enum CodingKeys: String, CodingKey {
        case detectionScore
        case boundingBoxArea
        case faceBoundingBox
        case isFallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectionScore = try container.decode(Float.self, forKey: .detectionScore)
        boundingBoxArea = try container.decode(Float.self, forKey: .boundingBoxArea)
        faceBoundingBox = try container.decodeIfPresent(NormalizedRect.self, forKey: .faceBoundingBox)
        isFallback = try container.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
    }
}

public struct DetectedFace: Codable, Equatable, Sendable {
    public var embedding: FaceEmbedding
    public var qualityMetrics: QualityMetrics

    public init(embedding: FaceEmbedding, qualityMetrics: QualityMetrics) {
        self.embedding = embedding
        self.qualityMetrics = qualityMetrics
    }
}

public struct ProfileBundle: Codable, Equatable, Sendable {
    public var subjectId: String
    public var references: [FaceEmbedding]
    public var confirmedPositives: [FaceEmbedding]
    public var negatives: [FaceEmbedding]
    public var threshold: Float
    public var maybeMargin: Float
    public var negativeMargin: Float
    public var modelId: String
    public var modelVersion: String

    public init(
        subjectId: String,
        references: [FaceEmbedding],
        confirmedPositives: [FaceEmbedding] = [],
        negatives: [FaceEmbedding] = [],
        threshold: Float,
        maybeMargin: Float = 0.1,
        negativeMargin: Float = 0.0,
        modelId: String,
        modelVersion: String
    ) {
        self.subjectId = subjectId
        self.references = references
        self.confirmedPositives = confirmedPositives
        self.negatives = negatives
        self.threshold = threshold
        self.maybeMargin = maybeMargin
        self.negativeMargin = negativeMargin
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    private enum CodingKeys: String, CodingKey {
        case subjectId
        case references
        case confirmedPositives
        case negatives
        case threshold
        case maybeMargin
        case negativeMargin
        case modelId
        case modelVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjectId = try container.decode(String.self, forKey: .subjectId)
        references = try container.decode([FaceEmbedding].self, forKey: .references)
        confirmedPositives = try container.decodeIfPresent([FaceEmbedding].self, forKey: .confirmedPositives) ?? []
        negatives = try container.decodeIfPresent([FaceEmbedding].self, forKey: .negatives) ?? []
        threshold = try container.decode(Float.self, forKey: .threshold)
        maybeMargin = try container.decodeIfPresent(Float.self, forKey: .maybeMargin) ?? 0.1
        negativeMargin = try container.decodeIfPresent(Float.self, forKey: .negativeMargin) ?? 0.0
        modelId = try container.decode(String.self, forKey: .modelId)
        modelVersion = try container.decode(String.self, forKey: .modelVersion)
    }
}

public enum Bucket: String, Codable, Equatable, Sendable {
    case keep
    case maybe
    case no
}

public struct MatchResult: Codable, Equatable, Sendable {
    public var subjectId: String
    public var score: Float
    public var bucket: Bucket

    public init(subjectId: String, score: Float, bucket: Bucket) {
        self.subjectId = subjectId
        self.score = score
        self.bucket = bucket
    }
}

public enum FeedbackLabel: String, Codable, Equatable, Sendable {
    case confirm
    case reject
}

public struct SubjectResult: Codable, Equatable, Sendable {
    public var score: Float
    public var bucket: Bucket
    public var feedback: FeedbackLabel?

    public init(score: Float, bucket: Bucket, feedback: FeedbackLabel? = nil) {
        self.score = score
        self.bucket = bucket
        self.feedback = feedback
    }
}

public struct BestFace: Codable, Equatable, Sendable {
    /// The currently-selected face's embedding (the one scoring/feedback act on).
    public var embedding: FaceEmbedding
    /// The currently-selected face's quality metrics, including its bounding box.
    public var qualityMetrics: QualityMetrics
    public var subjectResults: [String: SubjectResult]
    /// Every face detected in the photo, in detection order, so the user can
    /// override the auto-selected one. Optional so manifests written before this
    /// field decode unchanged; when present it includes the selected face.
    public var faces: [DetectedFace]?

    public init(
        embedding: FaceEmbedding,
        qualityMetrics: QualityMetrics,
        subjectResults: [String: SubjectResult],
        faces: [DetectedFace]? = nil
    ) {
        self.embedding = embedding
        self.qualityMetrics = qualityMetrics
        self.subjectResults = subjectResults
        self.faces = faces
    }
}

public struct Manifest: Codable, Equatable, Sendable {
    public var bestFacesByPhotoPath: [String: BestFace]
    public var modelId: String?
    public var modelVersion: String?

    public init(
        _ bestFacesByPhotoPath: [String: BestFace] = [:],
        modelId: String? = nil,
        modelVersion: String? = nil
    ) {
        self.bestFacesByPhotoPath = bestFacesByPhotoPath
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    public init(
        bestFacesByPhotoPath: [String: BestFace],
        modelId: String? = nil,
        modelVersion: String? = nil
    ) {
        self.bestFacesByPhotoPath = bestFacesByPhotoPath
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    public init(
        photoFaces: [String: BestFace],
        modelId: String? = nil,
        modelVersion: String? = nil
    ) {
        self.bestFacesByPhotoPath = photoFaces
        self.modelId = modelId
        self.modelVersion = modelVersion
    }

    public subscript(photoPath: String) -> BestFace? {
        get { bestFacesByPhotoPath[photoPath] }
        set { bestFacesByPhotoPath[photoPath] = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case bestFacesByPhotoPath
        case modelId
        case modelVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bestFacesByPhotoPath = try container.decode([String: BestFace].self, forKey: .bestFacesByPhotoPath)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        modelVersion = try container.decodeIfPresent(String.self, forKey: .modelVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bestFacesByPhotoPath, forKey: .bestFacesByPhotoPath)
        try container.encodeIfPresent(modelId, forKey: .modelId)
        try container.encodeIfPresent(modelVersion, forKey: .modelVersion)
    }
}

public struct ModelVersionMismatchError: Error, Equatable, Sendable {
    public let persistedModelId: String
    public let persistedModelVersion: String
    public let expectedModelId: String
    public let expectedModelVersion: String

    public init(
        persistedModelId: String,
        persistedModelVersion: String,
        expectedModelId: String,
        expectedModelVersion: String
    ) {
        self.persistedModelId = persistedModelId
        self.persistedModelVersion = persistedModelVersion
        self.expectedModelId = expectedModelId
        self.expectedModelVersion = expectedModelVersion
    }
}

public struct ProfileStore: Codable, Equatable, Sendable {
    public var modelId: String
    public var modelVersion: String
    public var profiles: [String: ProfileBundle]

    public init(
        modelId: String,
        modelVersion: String,
        profiles: [String: ProfileBundle] = [:]
    ) {
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.profiles = profiles
    }

    public var bundles: [String: ProfileBundle] {
        get { profiles }
        set { profiles = newValue }
    }

    public subscript(subjectId: String) -> ProfileBundle? {
        get { profiles[subjectId] }
        set { profiles[subjectId] = newValue }
    }

    @discardableResult
    public mutating func updateValue(_ profile: ProfileBundle, forKey subjectId: String) -> ProfileBundle? {
        profiles.updateValue(profile, forKey: subjectId)
    }

    public func encode(to url: URL) throws {
        let data = try JSONEncoder.kionPersistence.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    public static func load(
        from url: URL,
        expectingModelId expectedModelId: String,
        expectingModelVersion expectedModelVersion: String
    ) throws -> ProfileStore {
        let data = try Data(contentsOf: url)
        let store = try JSONDecoder.kionPersistence.decode(ProfileStore.self, from: data)
        guard store.modelId == expectedModelId, store.modelVersion == expectedModelVersion else {
            // Not an exact match. When the caller expects the canonical identity and
            // the persisted stamp is a recognized legacy alias of it (item 58: the
            // app's old "kion-local-enroll" and the CLI's "arcfaceresnet100-8" are
            // the SAME model), this is NOT a mismatch — self-heal in place: re-stamp
            // the store AND every bundle to canonical, preserving all other data
            // exactly, then persist the rewrite atomically before returning it. A
            // genuine mismatch (foreign model id, or a version outside the closed
            // alias set) still throws below, unchanged.
            let expected = ModelIdentity(modelId: expectedModelId, modelVersion: expectedModelVersion)
            let persisted = ModelIdentity(modelId: store.modelId, modelVersion: store.modelVersion)
            guard expected == ModelIdentity.canonical, persisted.isCanonicalOrLegacyAlias else {
                throw ModelVersionMismatchError(
                    persistedModelId: store.modelId,
                    persistedModelVersion: store.modelVersion,
                    expectedModelId: expectedModelId,
                    expectedModelVersion: expectedModelVersion
                )
            }

            var migrated = store
            migrated.modelId = ModelIdentity.canonical.modelId
            migrated.modelVersion = ModelIdentity.canonical.modelVersion
            migrated.profiles = migrated.profiles.mapValues { bundle in
                var restamped = bundle
                restamped.modelId = ModelIdentity.canonical.modelId
                restamped.modelVersion = ModelIdentity.canonical.modelVersion
                return restamped
            }

            do {
                let migratedData = try JSONEncoder.kionPersistence.encode(migrated)
                try migratedData.write(to: url, options: [.atomic])
            } catch {
                // The atomic write failed — because it's atomic (temp file + rename),
                // the ORIGINAL legacy file on disk is untouched. Throw a DISTINCT
                // error so a caller never confuses this with a genuine mismatch (and
                // never treats it as "load succeeded with an empty store").
                throw ProfileStoreMigrationPersistError(url: url, underlyingDescription: String(describing: error))
            }
            return migrated
        }
        return store
    }
}

public enum ManifestStore {
    public static func encode(_ manifest: Manifest, to url: URL) throws {
        let data = try JSONEncoder.kionPersistence.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    public static func load(from url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.kionPersistence.decode(Manifest.self, from: data)
    }
}

private extension JSONEncoder {
    static var kionPersistence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var kionPersistence: JSONDecoder {
        JSONDecoder()
    }
}
