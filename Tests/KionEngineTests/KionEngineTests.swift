import CoreGraphics
import Foundation
import ImageIO
@testable import KionEngine
@testable import KionONNXEmbedder
import Testing
import UniformTypeIdentifiers

@Suite("KionEngine persistence")
struct KionEngineTests {
    @Test("ProfileStore loads matching model stamps and preserves two subjects")
    func profileStorePositiveLoadPath() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let store = ProfileStore(
            modelId: "arcfaceresnet100-8",
            modelVersion: "1",
            profiles: [
                "subject-alice": ProfileBundle(
                    subjectId: "subject-alice",
                    references: [FaceEmbedding([0.1, 0.2, 0.3])],
                    threshold: 0.6,
                    modelId: "arcfaceresnet100-8",
                    modelVersion: "1"
                ),
                "subject-bob": ProfileBundle(
                    subjectId: "subject-bob",
                    references: [FaceEmbedding([0.4, 0.5, 0.6])],
                    threshold: 0.5,
                    modelId: "arcfaceresnet100-8",
                    modelVersion: "1"
                ),
            ]
        )

        try store.encode(to: url)
        let loaded = try ProfileStore.load(
            from: url,
            expectingModelId: "arcfaceresnet100-8",
            expectingModelVersion: "1"
        )

        #expect(loaded["subject-alice"] != nil)
        #expect(loaded["subject-bob"] != nil)
        #expect(loaded["subject-alice"]?.references.first?.values == [0.1, 0.2, 0.3])
        #expect(loaded["subject-bob"]?.references.first?.values == [0.4, 0.5, 0.6])
        #expect(loaded["subject-alice"]?.threshold == 0.6)
        #expect(loaded["subject-bob"]?.threshold == 0.5)
    }

    @Test("ProfileStore rejects mismatched model version")
    func profileStoreModelVersionMismatch() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let store = singleSubjectStore(modelId: "arcfaceresnet100-8", modelVersion: "1")
        try store.encode(to: url)

        do {
            _ = try ProfileStore.load(
                from: url,
                expectingModelId: "arcfaceresnet100-8",
                expectingModelVersion: "2"
            )
            Issue.record("Expected ModelVersionMismatchError")
        } catch let error as ModelVersionMismatchError {
            #expect(error.persistedModelVersion == "1")
            #expect(error.expectedModelVersion == "2")
        }
    }

    @Test("ProfileStore rejects mismatched model id")
    func profileStoreModelIdMismatch() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let store = singleSubjectStore(modelId: "arcfaceresnet100-8", modelVersion: "1")
        try store.encode(to: url)

        do {
            _ = try ProfileStore.load(
                from: url,
                expectingModelId: "mobilefacenet",
                expectingModelVersion: "1"
            )
            Issue.record("Expected ModelVersionMismatchError")
        } catch let error as ModelVersionMismatchError {
            #expect(error.persistedModelId == "arcfaceresnet100-8")
            #expect(error.expectedModelId == "mobilefacenet")
        }
    }

    // MARK: - Item 58: canonical model identity + legacy-alias migration

    @Test("A legacy app store (\"kion-local-enroll\"/\"1\") migrates losslessly to canonical, at both store and bundle level")
    func migrationRestampsLegacyAppStoreLosslessly() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let legacyId = "kion-local-enroll"
        let legacyVersion = "1"
        let alice = ProfileBundle(
            subjectId: "subject-alice",
            references: [FaceEmbedding([0.1, 0.2, 0.3])],
            confirmedPositives: [FaceEmbedding([0.11, 0.21, 0.31])],
            negatives: [FaceEmbedding([0.9, 0.8, 0.7])],
            threshold: 0.62,
            maybeMargin: 0.17,
            negativeMargin: 0.05,
            modelId: legacyId,
            modelVersion: legacyVersion
        )
        let bob = ProfileBundle(
            subjectId: "subject-bob",
            references: [FaceEmbedding([0.4, 0.5, 0.6])],
            confirmedPositives: [FaceEmbedding([0.41, 0.51, 0.61])],
            negatives: [FaceEmbedding([0.2, 0.1, 0.05])],
            threshold: 0.55,
            maybeMargin: 0.22,
            negativeMargin: 0.08,
            modelId: legacyId,
            modelVersion: legacyVersion
        )
        let legacyStore = ProfileStore(
            modelId: legacyId,
            modelVersion: legacyVersion,
            profiles: ["subject-alice": alice, "subject-bob": bob]
        )
        try legacyStore.encode(to: url)

        let loaded = try ProfileStore.load(
            from: url,
            expectingModelId: ModelIdentity.canonical.modelId,
            expectingModelVersion: ModelIdentity.canonical.modelVersion
        )

        #expect(loaded.modelId == ModelIdentity.canonical.modelId)
        #expect(loaded.modelVersion == ModelIdentity.canonical.modelVersion)
        #expect(Set(loaded.profiles.keys) == Set(["subject-alice", "subject-bob"]))

        for (subjectId, original) in [("subject-alice", alice), ("subject-bob", bob)] {
            let restamped = try #require(loaded[subjectId])
            #expect(restamped.modelId == ModelIdentity.canonical.modelId)
            #expect(restamped.modelVersion == ModelIdentity.canonical.modelVersion)
            #expect(restamped.subjectId == original.subjectId)
            #expect(restamped.references == original.references)
            #expect(restamped.confirmedPositives == original.confirmedPositives)
            #expect(restamped.negatives == original.negatives)
            #expect(restamped.threshold == original.threshold)
            #expect(restamped.maybeMargin == original.maybeMargin)
            #expect(restamped.negativeMargin == original.negativeMargin)
        }

        // A SECOND load is a no-op re-read: the file already converged, so nothing
        // rewrites again and the (already-canonical) data is unchanged.
        let reloaded = try ProfileStore.load(
            from: url,
            expectingModelId: ModelIdentity.canonical.modelId,
            expectingModelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(reloaded == loaded)
    }

    @Test("A foreign model id, or an incompatible version, still throws ModelVersionMismatchError against canonical")
    func foreignStampStillRejected() throws {
        let foreignURL = temporaryFileURL()
        defer { cleanup(foreignURL) }
        try singleSubjectStore(modelId: "mobilefacenet", modelVersion: "1").encode(to: foreignURL)
        #expect(throws: ModelVersionMismatchError.self) {
            _ = try ProfileStore.load(
                from: foreignURL,
                expectingModelId: ModelIdentity.canonical.modelId,
                expectingModelVersion: ModelIdentity.canonical.modelVersion
            )
        }

        let incompatibleURL = temporaryFileURL()
        defer { cleanup(incompatibleURL) }
        try singleSubjectStore(modelId: "arcfaceresnet100-8", modelVersion: "2").encode(to: incompatibleURL)
        #expect(throws: ModelVersionMismatchError.self) {
            _ = try ProfileStore.load(
                from: incompatibleURL,
                expectingModelId: ModelIdentity.canonical.modelId,
                expectingModelVersion: ModelIdentity.canonical.modelVersion
            )
        }
    }

    @Test("A legacy-alias-stamped manifest reuses the scan cache against a canonical profile and converges on persist; a nil-stamped manifest is accepted and untouched")
    func legacyAliasManifestReusesCacheAndConverges() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        FileManager.default.createFile(atPath: album.appendingPathComponent("photo_a.jpg").path, contents: Data())

        let legacyManifest = Manifest(
            [
                "photo_a.jpg": BestFace(
                    embedding: unitEmbedding(),
                    qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
                    subjectResults: ["subject-a": SubjectResult(score: 1, bucket: .keep)]
                ),
            ],
            modelId: "kion-local-enroll",
            modelVersion: "1"
        )
        let manifestURL = temporaryFileURL()
        defer { cleanup(manifestURL) }
        try ManifestStore.encode(legacyManifest, to: manifestURL)

        #expect(FaceMatcher.manifestStampCompatible(legacyManifest, modelId: "arcfaceresnet100-8", modelVersion: "1"))

        var embedCallCount = 0
        let onDiskManifest = try ManifestStore.load(from: manifestURL)
        let result = try await ScanPipeline(
            embedFace: { _ in
                embedCallCount += 1
                return nil
            },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(
            album: album,
            profile: profile(references: [unitEmbedding()]),
            existingManifest: onDiskManifest
        )

        // Cache hit: the legacy-alias-stamped manifest was never re-embedded.
        #expect(embedCallCount == 0)
        #expect(result.manifest["photo_a.jpg"] != nil)

        // Convergence: persisting the scan's fresh output manifest through the
        // normal write path leaves it canonically stamped, not legacy.
        try ManifestStore.encode(result.manifest, to: manifestURL)
        let reconverged = try ManifestStore.load(from: manifestURL)
        #expect(reconverged.modelId == "arcfaceresnet100-8")
        #expect(reconverged.modelVersion == "1")

        // A fully unstamped (nil) manifest is accepted (never throws) and left
        // completely alone by the compatibility check — no bytes touched.
        let unstampedURL = temporaryFileURL()
        defer { cleanup(unstampedURL) }
        let unstamped = Manifest(legacyManifest.bestFacesByPhotoPath)
        try ManifestStore.encode(unstamped, to: unstampedURL)
        let beforeBytes = try Data(contentsOf: unstampedURL)
        #expect(FaceMatcher.manifestStampCompatible(unstamped, modelId: "arcfaceresnet100-8", modelVersion: "1"))
        let afterBytes = try Data(contentsOf: unstampedURL)
        #expect(beforeBytes == afterBytes)
        #expect(unstamped.modelId == nil)
        #expect(unstamped.modelVersion == nil)
    }

    @Test("A canonical-stamped store encode->load round-trips, usable as either consumer's expectation")
    func canonicalStoreRoundTripsAcrossConsumers() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let store = ProfileStore(
            modelId: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion,
            profiles: ["subject-a": profile(references: [FaceEmbedding([1, 0, 0])])]
        )
        try store.encode(to: url)

        let loaded = try ProfileStore.load(
            from: url,
            expectingModelId: ModelIdentity.canonical.modelId,
            expectingModelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(loaded.modelId == ModelIdentity.canonical.modelId)
        #expect(loaded.modelVersion == ModelIdentity.canonical.modelVersion)
        #expect(loaded["subject-a"] != nil)
    }

    @Test("A legacy-alias store whose atomic migration rewrite fails throws a distinct persist error and leaves the original file byte-intact")
    func migrationPersistFailureThrowsAndPreservesFile() throws {
        let dir = try temporaryDirectoryURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            cleanup(dir)
        }
        let url = dir.appendingPathComponent("store.json")

        let legacyStore = singleSubjectStore(modelId: "kion-local-enroll", modelVersion: "1")
        try legacyStore.encode(to: url)
        let originalBytes = try Data(contentsOf: url)

        // A read-only directory: the existing file can still be READ, but the
        // atomic rewrite (temp file alongside it, then rename) cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)

        do {
            _ = try ProfileStore.load(
                from: url,
                expectingModelId: ModelIdentity.canonical.modelId,
                expectingModelVersion: ModelIdentity.canonical.modelVersion
            )
            Issue.record("Expected ProfileStoreMigrationPersistError")
        } catch let error as ProfileStoreMigrationPersistError {
            #expect(error.url == url)
        } catch {
            Issue.record("Expected ProfileStoreMigrationPersistError, got \(error)")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let afterBytes = try Data(contentsOf: url)
        #expect(afterBytes == originalBytes)
    }

    @Test("Manifest round-trips subject results including nil feedback")
    func manifestRoundTripWithNilFeedback() throws {
        let url = temporaryFileURL()
        defer { cleanup(url) }

        let subjectResults = [
            "subject-alice": SubjectResult(score: 0.92, bucket: .keep, feedback: .confirm),
            "subject-bob": SubjectResult(score: 0.31, bucket: .no, feedback: .reject),
            "subject-carol": SubjectResult(score: 0.55, bucket: .maybe, feedback: nil),
        ]
        let manifest = Manifest([
            "album/photo_a.jpg": BestFace(
                embedding: FaceEmbedding([0.7, 0.8, 0.9]),
                qualityMetrics: QualityMetrics(detectionScore: 0.98, boundingBoxArea: 14000),
                subjectResults: subjectResults
            ),
            "album/photo_b.jpg": BestFace(
                embedding: FaceEmbedding([0.2, 0.3, 0.4]),
                qualityMetrics: QualityMetrics(detectionScore: 0.93, boundingBoxArea: 9000),
                subjectResults: subjectResults
            ),
        ])

        try ManifestStore.encode(manifest, to: url)
        let loaded = try ManifestStore.load(from: url)

        for photoPath in ["album/photo_a.jpg", "album/photo_b.jpg"] {
            let face = try #require(loaded[photoPath])
            #expect(face.subjectResults["subject-alice"]?.bucket == .keep)
            #expect(face.subjectResults["subject-alice"]?.feedback == .confirm)
            #expect(face.subjectResults["subject-bob"]?.bucket == .no)
            #expect(face.subjectResults["subject-bob"]?.feedback == .reject)
            #expect(face.subjectResults["subject-carol"]?.bucket == .maybe)
            #expect(face.subjectResults["subject-carol"]?.feedback == nil)
        }
    }

    @Test("Manifest preserves optional model stamps and decodes legacy nil stamps")
    func manifestModelStampJSON() throws {
        let stamped = Manifest(
            [
                "photo": BestFace(
                    embedding: FaceEmbedding([1, 0, 0]),
                    qualityMetrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 100),
                    subjectResults: [:]
                ),
            ],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let data = try JSONEncoder().encode(stamped)
        let decoded = try JSONDecoder().decode(Manifest.self, from: data)
        #expect(decoded.modelId == "arcfaceresnet100-8")
        #expect(decoded.modelVersion == "1")

        let legacyData = Data(#"{"bestFacesByPhotoPath":{}}"#.utf8)
        let legacy = try JSONDecoder().decode(Manifest.self, from: legacyData)
        #expect(legacy.modelId == nil)
        #expect(legacy.modelVersion == nil)
    }

    /// Item 56, required behavior 3: a manifest written before `isFallback`
    /// existed has NO `isFallback` key at all in its `qualityMetrics` JSON. It
    /// must still decode, and the new field must default to `false` — which is
    /// the value that PRESERVES today's reading of old data (nothing already on
    /// disk retroactively becomes "fallback" and gets newly excluded by the
    /// item-56 gate). No stamp bump: the manifest's `modelId`/`modelVersion`
    /// round-trip unchanged.
    @Test("Legacy manifest JSON without isFallback decodes with isFallback defaulting to false")
    func legacyManifestDecodesWithoutIsFallback() throws {
        let legacyData = Data("""
        {
          "bestFacesByPhotoPath": {
            "photo.jpg": {
              "embedding": {"values": [1.0, 0.0, 0.0]},
              "qualityMetrics": {"detectionScore": 1.0, "boundingBoxArea": 10000},
              "subjectResults": {}
            }
          },
          "modelId": "arcfaceresnet100-8",
          "modelVersion": "1"
        }
        """.utf8)

        let legacy = try JSONDecoder().decode(Manifest.self, from: legacyData)
        let face = try #require(legacy["photo.jpg"])
        #expect(face.qualityMetrics.isFallback == false)
        #expect(face.qualityMetrics.detectionScore == 1.0)
        #expect(face.qualityMetrics.boundingBoxArea == 10000)
        // No stamp bump: the model stamp round-trips exactly as written.
        #expect(legacy.modelId == "arcfaceresnet100-8")
        #expect(legacy.modelVersion == "1")

        // Round-tripping through OUR encoder now writes `isFallback` explicitly,
        // and decoding that back still reads `false` — additive, not lossy.
        let reEncoded = try JSONEncoder().encode(legacy)
        let reDecoded = try JSONDecoder().decode(Manifest.self, from: reEncoded)
        #expect(reDecoded["photo.jpg"]?.qualityMetrics.isFallback == false)
    }

    @Test("ProfileBundle decodes missing matcher margins with defaults")
    func profileBundleMarginDefaults() throws {
        let data = Data("""
        {
          "subjectId": "subject-a",
          "references": [{"values": [1.0, 0.0, 0.0]}],
          "confirmedPositives": [],
          "negatives": [],
          "threshold": 0.5,
          "modelId": "arcfaceresnet100-8",
          "modelVersion": "1"
        }
        """.utf8)

        let profile = try JSONDecoder().decode(ProfileBundle.self, from: data)
        #expect(profile.maybeMargin == 0.1)
        #expect(profile.negativeMargin == 0.0)
    }

    @Test("Bucket encodes and decodes all three raw-value cases")
    func bucketThreeCaseRoundTrip() throws {
        for bucket in [Bucket.keep, .maybe, .no] {
            let data = try JSONEncoder().encode(bucket)
            let decoded = try JSONDecoder().decode(Bucket.self, from: data)
            #expect(decoded == bucket)
        }
    }

    @Test("ProfileStore can add a second subject without migration")
    func secondSubjectNoMigration() throws {
        let firstURL = temporaryFileURL()
        let secondURL = temporaryFileURL()
        defer {
            cleanup(firstURL)
            cleanup(secondURL)
        }

        let originalStore = singleSubjectStore(modelId: "arcfaceresnet100-8", modelVersion: "1")
        try originalStore.encode(to: firstURL)
        var loaded = try ProfileStore.load(
            from: firstURL,
            expectingModelId: "arcfaceresnet100-8",
            expectingModelVersion: "1"
        )

        loaded["subject-bob"] = ProfileBundle(
            subjectId: "subject-bob",
            references: [FaceEmbedding([0.4, 0.5, 0.6])],
            threshold: 0.5,
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        try loaded.encode(to: secondURL)
        let reloaded = try ProfileStore.load(
            from: secondURL,
            expectingModelId: "arcfaceresnet100-8",
            expectingModelVersion: "1"
        )

        #expect(reloaded["subject-alice"] != nil)
        #expect(reloaded["subject-bob"] != nil)
    }
}

@Suite("FaceMatcher")
struct FaceMatcherTests {
    @Test("Cosine score uses references and confirmed positives")
    func scoreUsesReferencesAndConfirmedPositives() throws {
        let same = profile(references: [FaceEmbedding([1, 0, 0])])
        let sameScore = try FaceMatcher.score(embedding: FaceEmbedding([1, 0, 0]), profile: same)
        #expect(abs(sameScore - 1.0) < 0.0001)

        let orthogonal = profile(references: [FaceEmbedding([0, 1, 0])])
        let orthogonalScore = try FaceMatcher.score(embedding: FaceEmbedding([1, 0, 0]), profile: orthogonal)
        #expect(abs(orthogonalScore) < 0.0001)

        let confirmedPositive = profile(
            references: [FaceEmbedding([0, 1, 0])],
            confirmedPositives: [FaceEmbedding([1, 0, 0])]
        )
        let confirmedScore = try FaceMatcher.score(embedding: FaceEmbedding([1, 0, 0]), profile: confirmedPositive)
        #expect(abs(confirmedScore - 1.0) < 0.0001)
    }

    @Test("Quality gate checks detection score and bounding box area")
    func qualityGate() {
        #expect(!FaceMatcher.passesQualityGate(
            metrics: QualityMetrics(detectionScore: 0.4, boundingBoxArea: 100),
            minDetectionScore: 0.5,
            minBoundingBoxArea: 50
        ))
        #expect(!FaceMatcher.passesQualityGate(
            metrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 40),
            minDetectionScore: 0.5,
            minBoundingBoxArea: 50
        ))
        #expect(FaceMatcher.passesQualityGate(
            metrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 100),
            minDetectionScore: 0.5,
            minBoundingBoxArea: 50
        ))
    }

    @Test("Bucket uses keep maybe and no bands")
    func bucketBands() {
        #expect(FaceMatcher.bucket(score: 0.6, threshold: 0.5, maybeMargin: 0.1) == .keep)
        #expect(FaceMatcher.bucket(score: 0.45, threshold: 0.5, maybeMargin: 0.1) == .maybe)
        #expect(FaceMatcher.bucket(score: 0.35, threshold: 0.5, maybeMargin: 0.1) == .no)
    }

    @Test("Negative adjustment penalizes only close negatives beyond margin")
    func adjustedScore() throws {
        #expect(try FaceMatcher.adjustedScore(
            raw: 0.7,
            embedding: FaceEmbedding([1, 0, 0]),
            negatives: [],
            negativeMargin: 0
        ) == 0.7)
        #expect(try FaceMatcher.adjustedScore(
            raw: 0.7,
            embedding: FaceEmbedding([1, 0, 0]),
            negatives: [FaceEmbedding([0, 1, 0])],
            negativeMargin: 0
        ) == 0.7)
        #expect(try FaceMatcher.adjustedScore(
            raw: 0.7,
            embedding: FaceEmbedding([1, 0, 0]),
            negatives: [FaceEmbedding([1, 0, 0])],
            negativeMargin: 0
        ) < 0.7)
    }

    /// Item 60: a dimension mismatch reaching the comparison is a "should be
    /// impossible" invariant violation (item 58's model-stamp gating is
    /// supposed to keep a manifest/profile pair on one model) — it must THROW
    /// `FaceMatchDimensionError`, never launder into the innocent-looking
    /// `0.0` the pre-item-60 code returned. Checked for BOTH a genuine length
    /// mismatch and two same-length EMPTY embeddings, and under BOTH metrics —
    /// `.dotProduct` must not silently truncate-zip past a length mismatch
    /// either; the guard runs before either metric's math.
    @Test("Dimension mismatch throws instead of silently returning 0.0")
    func dimensionMismatchThrowsInsteadOfSilentZero() throws {
        let threeDimensional = profile(references: [FaceEmbedding([1, 0, 0])])
        let twoDimensional = FaceEmbedding([1, 0])

        for metric in [SimilarityMetric.cosine, .dotProduct] {
            #expect(throws: FaceMatchDimensionError(lhsCount: 2, rhsCount: 3)) {
                _ = try FaceMatcher.score(embedding: twoDimensional, profile: threeDimensional, metric: metric)
            }
        }

        // Two same-length EMPTY embeddings: `!lhs.isEmpty` in the guard means
        // this is a mismatch-shaped case too, not a legitimate 0-length compare.
        let emptyProfile = profile(references: [FaceEmbedding([])])
        let emptyEmbedding = FaceEmbedding([])
        for metric in [SimilarityMetric.cosine, .dotProduct] {
            #expect(throws: FaceMatchDimensionError(lhsCount: 0, rhsCount: 0)) {
                _ = try FaceMatcher.score(embedding: emptyEmbedding, profile: emptyProfile, metric: metric)
            }
        }
    }

    /// The SEPARATE zero-norm guard (same-length, non-empty, but one or both
    /// vectors are all-zero, so cosine's division is undefined) is a
    /// legitimate "no similarity" result and must stay `0.0` — item 60 only
    /// changes the DIMENSION guard to throw, not this one.
    @Test("A zero-norm same-length pair still returns 0.0 without throwing")
    func zeroNormStillReturnsZero() throws {
        let zeroProfile = profile(references: [FaceEmbedding([0, 0, 0])])
        let zeroScore = try FaceMatcher.score(embedding: FaceEmbedding([0, 0, 0]), profile: zeroProfile)
        #expect(zeroScore == 0.0)

        let nonZeroProfile = profile(references: [FaceEmbedding([1, 0, 0])])
        let mixedScore = try FaceMatcher.score(embedding: FaceEmbedding([0, 0, 0]), profile: nonZeroProfile)
        #expect(mixedScore == 0.0)
    }

    @Test("FaceModelDescriptor.arcface wraps ModelIdentity.canonical without drift")
    func arcfaceDescriptorMatchesCanonicalIdentity() {
        #expect(FaceModelDescriptor.arcface.id == ModelIdentity.canonical.modelId)
        #expect(FaceModelDescriptor.arcface.version == ModelIdentity.canonical.modelVersion)
        #expect(FaceModelDescriptor.arcface.embeddingDimension == 512)
        #expect(FaceModelDescriptor.arcface.similarityMetric == .cosine)
        #expect(FaceModelDescriptor.arcface.calibration == MatchCalibration(
            defaultThreshold: 0.45,
            maybeMargin: 0.20,
            negativeMargin: 0.0
        ))
    }

    /// Hand-checkable: `[1,2,3]·[4,5,6] = 4+10+18 = 32`, distinct from the
    /// cosine similarity of the same (non-normalized) pair (~0.975).
    @Test("dotProduct metric scores by the raw dot product, distinct from cosine")
    func dotProductMetricScoresByDotProduct() throws {
        let embedding = FaceEmbedding([1, 2, 3])
        let bundle = profile(references: [FaceEmbedding([4, 5, 6])])

        let dotScore = try FaceMatcher.score(embedding: embedding, profile: bundle, metric: .dotProduct)
        #expect(abs(dotScore - 32.0) < 0.0001)

        let cosineScore = try FaceMatcher.score(embedding: embedding, profile: bundle, metric: .cosine)
        #expect(abs(cosineScore - 0.9746) < 0.001)
        #expect(abs(dotScore - cosineScore) > 1.0) // clearly distinct, not coincidentally equal
    }

    @Test("Negative margin changes end-to-end bucket")
    func negativeMarginEndToEnd() throws {
        let manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: [:],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )
        let withoutNegative = profile(
            references: [FaceEmbedding([0.6, 0.8, 0])],
            threshold: 0.5,
            maybeMargin: 0.1,
            negativeMargin: 0.0
        )
        let rescoredKeep = try FaceMatcher.rescore(
            manifest: manifest,
            profile: withoutNegative,
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        #expect(rescoredKeep["photo-001"]?.subjectResults["subject-a"]?.bucket == .keep)

        let withNegative = profile(
            references: [FaceEmbedding([0.6, 0.8, 0])],
            negatives: [FaceEmbedding([1, 0, 0])],
            threshold: 0.5,
            maybeMargin: 0.1,
            negativeMargin: 0.0
        )
        let rescoredNo = try FaceMatcher.rescore(
            manifest: manifest,
            profile: withNegative,
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let result = try #require(rescoredNo["photo-001"]?.subjectResults["subject-a"])
        #expect(abs(result.score - -0.4) < 0.0001)
        #expect(result.bucket == .no)
    }

    @Test("Confirm appends once and records feedback")
    func confirmIsIdempotent() throws {
        var store = storeWithSubject()
        var manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: ["subject-a": SubjectResult(score: 0.2, bucket: .no)],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )
        let references = try #require(store["subject-a"]?.references)

        try FaceMatcher.confirm(photoKey: "photo-001", subjectId: "subject-a", manifest: &manifest, store: &store)
        try FaceMatcher.confirm(photoKey: "photo-001", subjectId: "subject-a", manifest: &manifest, store: &store)

        let profile = try #require(store["subject-a"])
        #expect(profile.confirmedPositives.count == 1)
        #expect(profile.references == references)
        #expect(manifest["photo-001"]?.subjectResults["subject-a"]?.feedback == .confirm)
    }

    @Test("Reject appends once and records feedback")
    func rejectIsIdempotent() throws {
        var store = storeWithSubject()
        var manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: ["subject-a": SubjectResult(score: 0.2, bucket: .no)],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )
        let references = try #require(store["subject-a"]?.references)

        try FaceMatcher.reject(photoKey: "photo-001", subjectId: "subject-a", manifest: &manifest, store: &store)
        try FaceMatcher.reject(photoKey: "photo-001", subjectId: "subject-a", manifest: &manifest, store: &store)

        let profile = try #require(store["subject-a"])
        #expect(profile.negatives.count == 1)
        #expect(profile.references == references)
        #expect(manifest["photo-001"]?.subjectResults["subject-a"]?.feedback == .reject)
    }

    @Test("Confirm rejects mismatched manifest stamp and accepts nil stamp")
    func confirmStampGuard() throws {
        var store = storeWithSubject()
        var mismatch = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: ["subject-a": SubjectResult(score: 0.2, bucket: .no)],
            modelId: "other",
            modelVersion: "1"
        )

        #expect(throws: ModelVersionMismatchError.self) {
            try FaceMatcher.confirm(photoKey: "photo-001", subjectId: "subject-a", manifest: &mismatch, store: &store)
        }
        #expect(store["subject-a"]?.confirmedPositives.isEmpty == true)

        var nilStamp = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: ["subject-a": SubjectResult(score: 0.2, bucket: .no)]
        )
        try FaceMatcher.confirm(photoKey: "photo-001", subjectId: "subject-a", manifest: &nilStamp, store: &store)
        #expect(store["subject-a"]?.confirmedPositives.count == 1)
    }

    @Test("Rescore overwrites stale result and preserves feedback")
    func rescoreOverwritesStaleAndPreservesFeedback() throws {
        let manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: ["subject-a": SubjectResult(score: 0.0, bucket: .no, feedback: .confirm)],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let rescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: profile(references: [FaceEmbedding([1, 0, 0])]),
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let result = try #require(rescored["photo-001"]?.subjectResults["subject-a"])
        #expect(result.score >= 0.99)
        #expect(result.bucket == .keep)
        #expect(result.feedback == .confirm)
    }

    @Test("Rescore quality gate forces no bucket")
    func rescoreQualityGate() throws {
        var manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: [:],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )
        manifest["photo-001"]?.qualityMetrics = QualityMetrics(detectionScore: 0.01, boundingBoxArea: 100)

        let rescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: profile(references: [FaceEmbedding([1, 0, 0])]),
            subjectId: "subject-a",
            minDetectionScore: 0.5,
            minBoundingBoxArea: 0
        )
        let result = try #require(rescored["photo-001"]?.subjectResults["subject-a"])
        #expect(result.score == 0.0)
        #expect(result.bucket == .no)
    }

    @Test("Rescore rejects mismatched manifest stamp without changing input")
    func rescoreManifestStampMismatch() throws {
        let manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: [:],
            modelId: "other",
            modelVersion: "1"
        )

        #expect(throws: ModelVersionMismatchError.self) {
            _ = try FaceMatcher.rescore(
                manifest: manifest,
                profile: profile(references: [FaceEmbedding([1, 0, 0])]),
                subjectId: "subject-a",
                minDetectionScore: 0,
                minBoundingBoxArea: 0
            )
        }
        #expect(manifest.modelId == "other")
        #expect(manifest["photo-001"]?.subjectResults.isEmpty == true)
    }

    @Test("Rescore accepts nil manifest stamp and writes profile stamp")
    func rescoreNilStampBackCompat() throws {
        let manifest = singleFaceManifest(
            embedding: FaceEmbedding([1, 0, 0]),
            subjectResults: [:]
        )

        let rescored = try FaceMatcher.rescore(
            manifest: manifest,
            profile: profile(references: [FaceEmbedding([1, 0, 0])]),
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        #expect(rescored.modelId == "arcfaceresnet100-8")
        #expect(rescored.modelVersion == "1")
        #expect(rescored["photo-001"]?.subjectResults["subject-a"]?.bucket == .keep)
    }

    /// Assertions 3/10: a manifest entry written BEFORE item 56 — its
    /// `qualityMetrics` JSON has no `isFallback` key, so it decodes to
    /// `isFallback == false` — must bucket EXACTLY as it did before this item,
    /// including landing in `.keep` when its embedding matches. The absence of
    /// the field must never be misread as "this was a fallback" (that would be
    /// the wrong default — see `QualityMetrics.isFallback`'s doc comment). No
    /// stamp bump: the manifest's model stamp is untouched by decoding.
    @Test("A legacy manifest entry (no isFallback key) still buckets exactly as before item 56")
    func legacyManifestBucketingUnchanged() throws {
        let legacyData = Data("""
        {
          "bestFacesByPhotoPath": {
            "photo-001": {
              "embedding": {"values": [1.0, 0.0, 0.0]},
              "qualityMetrics": {"detectionScore": 1.0, "boundingBoxArea": 10000},
              "subjectResults": {}
            }
          },
          "modelId": "arcfaceresnet100-8",
          "modelVersion": "1"
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(Manifest.self, from: legacyData)
        #expect(legacy["photo-001"]?.qualityMetrics.isFallback == false)

        let rescored = try FaceMatcher.rescore(
            manifest: legacy,
            profile: profile(references: [FaceEmbedding([1, 0, 0])]),
            subjectId: "subject-a",
            minDetectionScore: 0,
            minBoundingBoxArea: 0,
            includeFallbackFaces: false // the new, safer default
        )
        let result = try #require(rescored["photo-001"]?.subjectResults["subject-a"])
        // Not excluded: decoding an absent `isFallback` as `false` means old
        // data is NOT retroactively caught by the new gate.
        #expect(result.bucket == .keep)
        #expect(result.score >= 0.99)
        #expect(rescored.modelId == "arcfaceresnet100-8")
        #expect(rescored.modelVersion == "1")
    }
}

/// Regression pin for item 36: `LiveTriageEngine.rescoreAll` moved its per-photo
/// scoring loop OFF the main actor into the `nonisolated` `computeRescore`, which
/// composes the SAME pure `FaceMatcher` pieces — `bestMatchingFace` (the re-pick),
/// `score`/`adjustedScore`, and `bucket`. These tests pin those pieces over a
/// fixture manifest (≥2 photos, ≥1 multi-face) so the off-actor refactor can't
/// silently change which face is selected or its score/bucket.
@Suite("FaceMatcher rescore re-pick")
struct FaceMatcherRescoreRepickTests {
    /// The same per-photo computation `LiveTriageEngine.computeRescore` performs:
    /// re-pick the best-matching face, fall back to face 0, and derive the adjusted
    /// score + bucket. Returned so a test can assert the trio (index/score/bucket).
    private func rescore(
        faces: [DetectedFace],
        profile bundle: ProfileBundle
    ) throws -> (index: Int, score: Float, bucket: Bucket) {
        let best = try FaceMatcher.bestMatchingFace(
            among: faces,
            profile: bundle,
            minDetectionScore: 0.0,
            minBoundingBoxArea: 0.0
        )
        let index = best?.index ?? 0
        let selected = faces[index]
        let adjusted: Float
        if let best {
            adjusted = best.score
        } else {
            let raw = try FaceMatcher.score(embedding: selected.embedding, profile: bundle)
            adjusted = try FaceMatcher.adjustedScore(
                raw: raw,
                embedding: selected.embedding,
                negatives: bundle.negatives,
                negativeMargin: bundle.negativeMargin
            )
        }
        let bucket = FaceMatcher.bucket(
            score: adjusted,
            threshold: bundle.threshold,
            maybeMargin: bundle.maybeMargin
        )
        return (index, adjusted, bucket)
    }

    @Test("Re-pick selects the better face in a multi-face photo and a single face elsewhere")
    func rescoreRepicksAcrossPhotos() throws {
        let bundle = profile(references: [FaceEmbedding([1, 0, 0])], threshold: 0.5, maybeMargin: 0.1)

        // A two-face photo where the AUTO-selected face 0 doesn't match but face 1
        // does — the re-pick must move the selection to face 1 (keep), not face 0.
        let multiFace = [
            face(embedding: FaceEmbedding([0, 1, 0])),
            face(embedding: FaceEmbedding([1, 0, 0])),
        ]
        let multi = try rescore(faces: multiFace, profile: bundle)
        #expect(multi.index == 1)
        #expect(abs(multi.score - 1.0) < 0.0001)
        #expect(multi.bucket == .keep)

        // A single-face photo in the "maybe" band stays on face 0.
        let single = [face(embedding: FaceEmbedding([0.45, 0.893025, 0]))]
        let one = try rescore(faces: single, profile: bundle)
        #expect(one.index == 0)
        #expect(abs(one.score - 0.45) < 0.001)
        #expect(one.bucket == .maybe)
    }

    @Test("A newly-taught positive flips the re-picked face from no to keep")
    func taughtPositiveChangesRepick() throws {
        let faces = [
            face(embedding: FaceEmbedding([0, 1, 0])),
            face(embedding: FaceEmbedding([0, 0, 1])),
        ]
        let untaught = profile(references: [FaceEmbedding([1, 0, 0])], threshold: 0.5, maybeMargin: 0.1)
        let before = try rescore(faces: faces, profile: untaught)
        #expect(before.bucket == .no)

        // Teaching face 1's embedding as a confirmed positive makes it the match.
        let taught = profile(
            references: [FaceEmbedding([1, 0, 0])],
            confirmedPositives: [FaceEmbedding([0, 0, 1])],
            threshold: 0.5,
            maybeMargin: 0.1
        )
        let after = try rescore(faces: faces, profile: taught)
        #expect(after.index == 1)
        #expect(abs(after.score - 1.0) < 0.0001)
        #expect(after.bucket == .keep)
    }

    private func face(embedding: FaceEmbedding) -> DetectedFace {
        DetectedFace(
            embedding: embedding,
            qualityMetrics: QualityMetrics(detectionScore: 0.95, boundingBoxArea: 10000)
        )
    }
}

/// Item 55: `ScanPipeline.decodeImage` is now the SINGLE decode implementation used
/// by the scan loop, the CLI, and `LiveTriageEngine` (previously duplicated three
/// times). These tests close the previously-untested corrupt-file path and pin the
/// decode's dimensions per fixture (hard-coded, not just `> 0`).
@Suite("ScanPipeline.decodeImage")
struct DecodeImageTests {
    @Test("Decodes face_a.jpg to its actual pixel dimensions")
    func decodesFaceAToExpectedDimensions() throws {
        let image = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_a", "jpg")))
        #expect(image.width == 1254)
        #expect(image.height == 1254)
    }

    @Test("Decodes face_a2.jpg to its actual pixel dimensions")
    func decodesFaceA2ToExpectedDimensions() throws {
        let image = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_a2", "jpg")))
        #expect(image.width == 1254)
        #expect(image.height == 1254)
    }

    @Test("Decodes face_b.jpg to its actual pixel dimensions")
    func decodesFaceBToExpectedDimensions() throws {
        let image = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_b", "jpg")))
        #expect(image.width == 1254)
        #expect(image.height == 1254)
    }

    @Test("Corrupt file decodes to nil without crashing or throwing")
    func corruptFileReturnsNil() throws {
        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kion-decode-corrupt-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try Data("this is not a jpeg, just garbage bytes".utf8).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        #expect(ScanPipeline.decodeImage(at: corruptURL) == nil)
    }

    @Test("Nonexistent file decodes to nil without crashing or throwing")
    func nonexistentFileReturnsNil() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kion-decode-missing-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        #expect(ScanPipeline.decodeImage(at: missingURL) == nil)
    }
}

@Suite("FaceEmbedder", .serialized)
struct FaceEmbedderTests {
    static var isModelAvailable: Bool {
        kionResolvedModelURL() != nil
    }

    @Test("Missing explicit model URL throws")
    func missingExplicitModelThrows() {
        #expect(throws: (any Error).self) {
            _ = try FaceEmbedder(modelURL: URL(fileURLWithPath: "/nonexistent/model.onnx"))
        }
    }

    @Test("Injected nil env lookup throws modelNotFound")
    func nilEnvironmentLookupThrowsModelNotFound() {
        #expect(throws: FaceEmbedderError.modelNotFound) {
            _ = try FaceEmbedder(modelURL: nil, envLookup: { _ in nil })
        }
    }

    @Test("RGB input tensor uses raw planar RGB pixel values")
    func rgbInputTensorIsRawPixels() throws {
        let image = try solidImage(width: 112, height: 112, red: 200, green: 100, blue: 50)
        let tensor = try FaceAligner().rgbInputTensor(from112x112: image)
        let planeSize = 112 * 112

        #expect(tensor[0] == 200)
        #expect(tensor[planeSize] == 100)
        #expect(tensor[2 * planeSize] == 50)
    }

    @Test("Alignment warp returns non-degenerate 112x112 pixels")
    func alignmentWarpSanity() throws {
        let aligned = try #require(try FaceAligner().alignedFace(in: fixtureImage("face_a", "jpg")))
        let pixels = try rgbaPixels(from: aligned.image)

        #expect(aligned.image.width == 112)
        #expect(aligned.image.height == 112)

        var sum = 0
        var firstPixel: (UInt8, UInt8, UInt8)?
        var allIdentical = true
        var index = 0
        while index < pixels.count {
            let pixel = (pixels[index], pixels[index + 1], pixels[index + 2])
            if firstPixel == nil {
                firstPixel = pixel
            } else if let firstPixel, pixel != firstPixel {
                allIdentical = false
            }
            sum += Int(pixel.0) + Int(pixel.1) + Int(pixel.2)
            index += 4
        }

        let mean = Double(sum) / Double(112 * 112 * 3)
        #expect(mean >= 20)
        #expect(mean <= 235)
        #expect(!allIdentical)
    }

    @Test("Face image embeds to non-degenerate 512 values", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func embedsFaceImage() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))

        #expect(face.embedding.count == 512)
        #expect(face.embedding.values.allSatisfy { $0.isFinite })
        #expect(face.embedding.values.contains { $0 != 0 })
    }

    @Test("Blank image returns nil", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func blankImageReturnsNil() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        #expect(try await embedder.embedFace(fixtureImage("blank", "png")) == nil)
    }

    @Test("Embedding is deterministic on a single embedder", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func embeddingIsDeterministic() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")
        let first = try #require(try await embedder.embedFace(image))
        let second = try #require(try await embedder.embedFace(image))

        #expect(first.embedding.values.count == second.embedding.values.count)
        for index in first.embedding.values.indices {
            #expect(abs(first.embedding.values[index] - second.embedding.values[index]) <= 1e-5)
        }
    }

    /// Item 52 decisive regression: the shim's release calls must not change WHAT is
    /// embedded, only whether the tensors are freed afterward. `face_a_embedding_baseline.json`
    /// was captured on unmodified main (commit d3583ea, before any item-52 edit) via the
    /// exact same CLI enrollment path this test exercises through `FaceEmbedder` directly.
    /// A byte-level mismatch here means the lifetime fix corrupted the computation (e.g. a
    /// use-after-free reading freed tensor memory) — a green test suite alone would NOT catch
    /// that, since corrupted-but-plausible floats still pass cosine/ordering checks.
    @Test("Genuine embedding of face_a.jpg is bit-reproducible and stays close to the pre-change baseline", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func embeddingMatchesPreChangeBaseline() async throws {
        let baselineData = try Data(contentsOf: fixtureURL("face_a_embedding_baseline", "json"))
        let baseline = try JSONDecoder().decode(EmbeddingBaselineFixture.self, from: baselineData)
        #expect(baseline.values.count == 512)

        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        #expect(face.embedding.values.count == baseline.values.count)

        // Primary claim — bit-exact reproducibility within this run: a SECOND,
        // independent embedder over the same image must produce identical floats.
        // A use-after-free reading freed tensor memory yields non-deterministic
        // garbage, which this catches regardless of OS version.
        let reference = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let again = try #require(try await reference.embedFace(fixtureImage("face_a", "jpg")))
        #expect(face.embedding.values == again.embedding.values)

        // Cross-OS drift guard against the checked-in fixture. The fixture was captured
        // on macOS 26; macOS 27's Vision returns a slightly different face box/landmarks,
        // so the aligned crop — and every float — shifts (measured cosine 0.974, max abs
        // delta 0.34). Bit-exactness against a fixture is therefore an OS-version claim,
        // not a correctness one; a corrupted or wrong embedding is near-orthogonal
        // (cosine ≈ 0), far below this bound.
        let cosine = Self.cosineToFixture(face.embedding.values, baseline.values)
        #expect(cosine >= 0.95, "cosine to baseline \(cosine)")
    }

    private static func cosineToFixture(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let norms = sqrt(lhs.reduce(Float(0)) { $0 + $1 * $1 }) * sqrt(rhs.reduce(Float(0)) { $0 + $1 * $1 })
        return norms > 0 ? dot / norms : 0
    }

    /// Item 52 regression: `KionORTRun` releases both OrtValues on every exit path,
    /// copying the output tensor's data out BEFORE releasing it. Embedding the same
    /// fixture 50+ times through ONE embedder (one long-lived ORT session) exercises
    /// those release paths under repetition — a use-after-free from releasing the
    /// output value before the `memcpy` would corrupt or crash, not merely leak.
    @Test("Repeated embeds through one embedder stay identical across 50+ runs", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func repeatedEmbedsStayIdentical() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")
        let first = try #require(try await embedder.embedFace(image))

        for _ in 0 ..< 50 {
            let next = try #require(try await embedder.embedFace(image))
            #expect(next.embedding.values == first.embedding.values)
        }
    }

    /// Item 52 regression: a model file ONNX Runtime cannot parse must produce a
    /// diagnosable `FaceEmbedderError.runtime`, not a crash — exercising
    /// `kion_check_status`'s status-release path and `KionORTDestroy` tearing down
    /// a partially-created session (env created, session creation failed) without
    /// touching the dylib's parked worker threads unsafely. `init` stays lazy: it
    /// succeeds even though the "model" is garbage, because no ORT call happens
    /// until `warmUp()`.
    @Test("Corrupt model file: init succeeds, warmUp throws a non-empty runtime error, no crash")
    func corruptModelFileWarmUpThrows() async throws {
        let directory = try temporaryDirectoryURL()
        defer { cleanup(directory) }
        let corruptModelURL = directory.appendingPathComponent("corrupt.onnx")
        try Data("this is not an onnx model".utf8).write(to: corruptModelURL)

        let embedder = try FaceEmbedder(modelURL: corruptModelURL)

        do {
            try await embedder.warmUp()
            Issue.record("Expected FaceEmbedderError.runtime")
        } catch let error as FaceEmbedderError {
            guard case .runtime(let message) = error else {
                Issue.record("Expected .runtime, got \(error)")
                return
            }
            #expect(!message.isEmpty)
        }
    }

    @Test("Same-person cosine is higher than different-person cosine", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func cosineOrdering() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let faceA = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        let faceA2 = try #require(try await embedder.embedFace(fixtureImage("face_a2", "jpg")))
        let faceB = try #require(try await embedder.embedFace(fixtureImage("face_b", "jpg")))

        #expect(cosine(faceA.embedding.values, faceA2.embedding.values) > cosine(faceA.embedding.values, faceB.embedding.values))
    }

    @Test("Same-person cosine is above the acceptance floor", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func samePersonCosineAboveThreshold() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let faceA = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        let faceA2 = try #require(try await embedder.embedFace(fixtureImage("face_a2", "jpg")))

        #expect(cosine(faceA.embedding.values, faceA2.embedding.values) >= 0.25)
    }

    @Test("Different-person cosine stays below keep threshold", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func differentPersonCosineBelowThreshold() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let faceA = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        let faceB = try #require(try await embedder.embedFace(fixtureImage("face_b", "jpg")))

        #expect(cosine(faceA.embedding.values, faceB.embedding.values) < 0.45)
    }

    @Test("Batch collects detected faces only", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func mixedBatch() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let results = try await embedder.embedFaces([
            fixtureImage("face_a", "jpg"),
            fixtureImage("blank", "png"),
            fixtureImage("face_b", "jpg"),
        ])

        #expect(results.count == 2)
    }

    @Test("Quality metrics include confidence and pixel area", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func qualityMetrics() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))

        #expect(face.qualityMetrics.detectionScore > 0)
        #expect(face.qualityMetrics.detectionScore <= 1)
        #expect(face.qualityMetrics.boundingBoxArea > 0)
    }

    /// Item 55's central guard: the unified decode path (`ScanPipeline.decodeImage`,
    /// via `fixtureImage`) feeding the embedder is deterministic and produces the
    /// same match ordering as before the `rgbaPixels` UB fix. Two independent decodes
    /// of the same file must embed to element-wise identical vectors — if the old
    /// `&pixels`-into-`CGContext` UB had ever actually manifested (a moved/reallocated
    /// buffer written to after the fact), this is exactly the kind of run-to-run
    /// divergence it would surface. Also re-confirms `cosineOrdering`'s same-vs-
    /// different-person ordering through the identical decode path.
    @Test(
        "Unified decode: repeat decode+embed is identical, and same-person cosine beats different-person",
        .enabled(if: FaceEmbedderTests.isModelAvailable)
    )
    func unifiedDecodeEmbeddingStability() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())

        let firstImage = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_a", "jpg")))
        let secondImage = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_a", "jpg")))
        let firstEmbed = try #require(try await embedder.embedFace(firstImage))
        let secondEmbed = try #require(try await embedder.embedFace(secondImage))

        #expect(firstEmbed.embedding.values.count == secondEmbed.embedding.values.count)
        #expect(firstEmbed.embedding.values == secondEmbed.embedding.values)

        let imageA2 = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_a2", "jpg")))
        let imageB = try #require(ScanPipeline.decodeImage(at: fixtureURL("face_b", "jpg")))
        let faceA2 = try #require(try await embedder.embedFace(imageA2))
        let faceB = try #require(try await embedder.embedFace(imageB))

        #expect(
            cosine(firstEmbed.embedding.values, faceA2.embedding.values)
                > cosine(firstEmbed.embedding.values, faceB.embedding.values)
        )
    }

    // MARK: - Item 64: actor + FaceEmbeddingProvider conformance

    /// Required behavior (i): `FaceEmbedder` used purely through `any
    /// FaceEmbeddingProvider` — never naming the concrete type past this point —
    /// reports the ArcFace descriptor and embeds BYTE-IDENTICALLY to calling the
    /// concrete type directly, proving the protocol-conformance path runs the
    /// exact same math, not a parallel/different implementation.
    @Test(
        "FaceEmbedder used as any FaceEmbeddingProvider reports .arcface and embeds identically to the direct call",
        .enabled(if: FaceEmbedderTests.isModelAvailable)
    )
    func faceEmbedderConformsToProviderAndEmbedsIdentically() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let provider: any FaceEmbeddingProvider = embedder
        #expect(provider.descriptor == .arcface)

        let image = try fixtureImage("face_a", "jpg")
        let direct = try #require(try await embedder.embedFace(image))
        let viaProvider = try #require(try await provider.embedFace(image))

        #expect(viaProvider.embedding.values.count == direct.embedding.values.count)
        #expect(viaProvider.embedding.values == direct.embedding.values)
    }

    /// Required behavior (ii): a `warmUp` issued CONCURRENTLY with multiple
    /// `embedFace` calls on ONE embedder — exercising exactly the race the
    /// pre-item-64 hand-rolled `sessionLock` used to guard in `ensureSession()` —
    /// all complete without crashing, and EVERY result matches a serial
    /// reference embedding exactly. `warmUp` is deliberately included in the
    /// concurrent group (not run-then-await-serially first): actor isolation,
    /// not a lock, is what must serialize the race here.
    @Test(
        "A warmUp concurrent with multiple embedFace calls on one embedder all complete and match a serial reference exactly",
        .enabled(if: FaceEmbedderTests.isModelAvailable)
    )
    func concurrentEmbedsAreActorSerializedAndIdentical() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")
        // Bit-exact reference computed serially on a SEPARATE embedder in this run (not
        // the checked-in fixture, whose floats are OS-version-dependent — see
        // embeddingMatchesPreChangeBaseline). Concurrency must not change a single bit.
        let reference = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let baseline = try #require(try await reference.embedFace(image)).embedding

        let embedResults: [[Float]] = try await withThrowingTaskGroup(of: [Float]?.self) { group in
            // `warmUp` races the SAME lazy `ensureSession()` every `embedFace`
            // call below also reaches — this is the concurrent group, not a
            // priming step run to completion first.
            group.addTask {
                try await embedder.warmUp()
                return nil
            }
            for _ in 0 ..< 8 {
                group.addTask {
                    try await embedder.embedFace(image)?.embedding.values
                }
            }

            var collected: [[Float]] = []
            for try await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        // 8 embeds issued (the warmUp task contributes no embedding of its own).
        #expect(embedResults.count == 8)
        for values in embedResults {
            #expect(values == baseline.values)
        }
    }
}

private struct EmbeddingBaseline: Decodable {
    let embeddingDimension: Int
    let values: [Float]
}

/// Item 62: `FaceAligner` is a pure-geometry extraction out of `FaceEmbedder`,
/// driven entirely by its `AlignmentSpec` rather than hardcoded ArcFace
/// constants. These tests are model-free (no ONNX involved) and prove the
/// spec, not just the (unchanged) numbers it happens to carry today.
struct FaceAlignerSpecTests {
    // No custom display string: the bare function name is the test's identity here.
    @Test
    func alignerIsSpecDrivenAndProduces112Chip() throws {
        #expect(AlignmentSpec.arcface.chipSize == 112)
        #expect(AlignmentSpec.arcface.pixelNormalization == .raw)
        #expect(AlignmentSpec.arcface.canonicalLandmarks == [
            CGPoint(x: 38.2946, y: 51.6963),
            CGPoint(x: 73.5318, y: 51.5014),
            CGPoint(x: 56.0252, y: 71.7366),
            CGPoint(x: 41.5493, y: 92.3655),
            CGPoint(x: 70.7299, y: 92.2041),
        ])

        // The align entry (via the real Vision/CoreImage/heuristic cascade,
        // exercised model-free over a real face fixture) yields a chip sized
        // exactly `spec.chipSize` x `spec.chipSize` — not a hardcoded 112.
        let aligner = FaceAligner(spec: .arcface)
        let aligned = try #require(try aligner.alignedFace(in: fixtureImage("face_a", "jpg")))
        #expect(aligned.image.width == AlignmentSpec.arcface.chipSize)
        #expect(aligned.image.height == AlignmentSpec.arcface.chipSize)
    }

    @Test
    func rawPixelNormalizationProducesExactCHWValues() throws {
        // A tiny (spec-sized) chip-shaped spec, independent of ArcFace's own
        // 112 — proves the tensor packing reads `spec.chipSize` and
        // `spec.pixelNormalization`, not a hardcoded literal.
        let spec = AlignmentSpec(
            chipSize: 112,
            canonicalLandmarks: AlignmentSpec.arcface.canonicalLandmarks,
            pixelNormalization: .raw
        )
        let aligner = FaceAligner(spec: spec)
        let image = try solidImage(width: 112, height: 112, red: 200, green: 100, blue: 50)
        let tensor = try aligner.rgbInputTensor(from112x112: image)
        let planeSize = 112 * 112

        #expect(tensor[0] == 200)
        #expect(tensor[planeSize] == 100)
        #expect(tensor[2 * planeSize] == 50)
    }
}

struct FaceAlignmentFallbackTests {
    // VNFaceObservation.boundingBox is normalized, bottom-left origin.
    // A tall box near the top-left and a wide box near the bottom-right,
    // each with a distinct origin, size, and aspect ratio.
    static let tallBox = CGRect(x: 0.10, y: 0.55, width: 0.20, height: 0.35)
    static let wideBox = CGRect(x: 0.45, y: 0.05, width: 0.40, height: 0.15)
    static let imageWidth = 1000
    static let imageHeight = 800

    private func normalizedOffsets(_ points: [CGPoint], in box: CGRect) -> [CGPoint] {
        // Express each point as a fraction inside the top-left pixel rect of the box.
        let width = CGFloat(Self.imageWidth)
        let height = CGFloat(Self.imageHeight)
        let originX = box.minX * width
        let originY = (1 - box.maxY) * height
        let boxWidth = box.width * width
        let boxHeight = box.height * height
        return points.map {
            CGPoint(x: ($0.x - originX) / boxWidth, y: ($0.y - originY) / boxHeight)
        }
    }

    private func pixelRect(for box: CGRect) -> CGRect {
        let width = CGFloat(Self.imageWidth)
        let height = CGFloat(Self.imageHeight)
        return CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
    }

    private func assertWellFormed(_ points: [CGPoint], box: CGRect) {
        #expect(points.count == 5)
        let leftEye = points[0]
        let rightEye = points[1]
        let nose = points[2]
        let mouthLeft = points[3]
        let mouthRight = points[4]

        // Order: left eye is left of right eye.
        #expect(leftEye.x < rightEye.x)
        // Both eyes above both mouth corners (top-left coords: smaller y is higher).
        #expect(leftEye.y < mouthLeft.y)
        #expect(leftEye.y < mouthRight.y)
        #expect(rightEye.y < mouthLeft.y)
        #expect(rightEye.y < mouthRight.y)
        // Nose between the eye line and the mouth.
        let eyeLineY = (leftEye.y + rightEye.y) / 2
        let mouthLineY = (mouthLeft.y + mouthRight.y) / 2
        #expect(nose.y > eyeLineY)
        #expect(nose.y < mouthLineY)

        // All strictly within the box.
        let rect = pixelRect(for: box)
        for point in points {
            #expect(point.x > rect.minX)
            #expect(point.x < rect.maxX)
            #expect(point.y > rect.minY)
            #expect(point.y < rect.maxY)
        }

        // Non-collinear: the eye line and the nose are not on one line.
        let area = abs(
            (rightEye.x - leftEye.x) * (nose.y - leftEye.y)
                - (nose.x - leftEye.x) * (rightEye.y - leftEye.y)
        )
        #expect(area > 0)
    }

    @Test("Bounding-box landmarks are well-formed for a tall and a wide box")
    func boundingBoxLandmarksWellFormed() throws {
        let tall = try #require(FaceAligner.boundingBoxLandmarks(
            for: Self.tallBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ))
        let wide = try #require(FaceAligner.boundingBoxLandmarks(
            for: Self.wideBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ))
        assertWellFormed(tall, box: Self.tallBox)
        assertWellFormed(wide, box: Self.wideBox)
    }

    @Test("Bounding-box landmarks track the box proportionally, not by constant")
    func boundingBoxLandmarksAreProportional() throws {
        let tall = try #require(FaceAligner.boundingBoxLandmarks(
            for: Self.tallBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ))
        let wide = try #require(FaceAligner.boundingBoxLandmarks(
            for: Self.wideBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ))

        // The absolute pixel points must differ (so a constant set would fail).
        #expect(tall[0] != wide[0])
        #expect(tall[2] != wide[2])

        // But the normalized in-box offsets are identical: the points scale and
        // translate with the box rather than being hardcoded pixel constants.
        let tallOffsets = normalizedOffsets(tall, in: Self.tallBox)
        let wideOffsets = normalizedOffsets(wide, in: Self.wideBox)
        for index in tallOffsets.indices {
            #expect(abs(tallOffsets[index].x - wideOffsets[index].x) < 1e-9)
            #expect(abs(tallOffsets[index].y - wideOffsets[index].y) < 1e-9)
        }
    }

    @Test("Bounding-box landmarks return nil for degenerate boxes")
    func boundingBoxLandmarksRejectDegenerate() {
        #expect(FaceAligner.boundingBoxLandmarks(
            for: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.3),
            imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ) == nil)
        #expect(FaceAligner.boundingBoxLandmarks(
            for: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0),
            imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ) == nil)
        #expect(FaceAligner.boundingBoxLandmarks(
            for: CGRect(x: 0.2, y: 0.2, width: -0.3, height: 0.3),
            imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ) == nil)
        #expect(FaceAligner.boundingBoxLandmarks(
            for: CGRect(x: 0.2, y: 0.2, width: 0.3, height: -0.3),
            imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ) == nil)
    }

    @Test("Selector returns the supplied complete landmarks unchanged")
    func selectorPrefersCompleteLandmarks() throws {
        let landmarks = [
            CGPoint(x: 11, y: 12),
            CGPoint(x: 33, y: 12),
            CGPoint(x: 22, y: 25),
            CGPoint(x: 14, y: 40),
            CGPoint(x: 30, y: 40),
        ]
        let selected = try #require(FaceAligner.alignmentPoints(
            landmarks: landmarks,
            boundingBox: Self.tallBox,
            imageWidth: Self.imageWidth,
            imageHeight: Self.imageHeight
        ))
        // Identity: bbox fallback NOT used.
        #expect(selected == landmarks)
        let fallback = FaceAligner.boundingBoxLandmarks(
            for: Self.tallBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        )
        #expect(selected != fallback)
    }

    @Test("Selector falls back to bbox landmarks when landmarks are nil or incomplete")
    func selectorFallsBackForIncompleteLandmarks() throws {
        let expected = try #require(FaceAligner.boundingBoxLandmarks(
            for: Self.wideBox, imageWidth: Self.imageWidth, imageHeight: Self.imageHeight
        ))

        let fromNil = try #require(FaceAligner.alignmentPoints(
            landmarks: nil,
            boundingBox: Self.wideBox,
            imageWidth: Self.imageWidth,
            imageHeight: Self.imageHeight
        ))
        #expect(fromNil == expected)
        assertWellFormed(fromNil, box: Self.wideBox)

        // An incomplete (e.g. 2-point) set is treated as missing.
        let fromIncomplete = try #require(FaceAligner.alignmentPoints(
            landmarks: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)],
            boundingBox: Self.wideBox,
            imageWidth: Self.imageWidth,
            imageHeight: Self.imageHeight
        ))
        #expect(fromIncomplete == expected)
    }

    @Test("Selector returns nil only when landmarks missing and box degenerate")
    func selectorNilForDegenerateBox() {
        #expect(FaceAligner.alignmentPoints(
            landmarks: nil,
            boundingBox: CGRect(x: 0.2, y: 0.2, width: 0, height: 0),
            imageWidth: Self.imageWidth,
            imageHeight: Self.imageHeight
        ) == nil)
    }

    // MARK: - Item 56: fallback labelling, driven through the REAL cascade

    /// End-to-end, model-free: drives `FaceAligner.alignedFaces(in:)` — the REAL
    /// Vision → Core Image → heuristic cascade, NOT `heuristicAlignedFace` called
    /// directly — over a deterministic noise image that contains no real face.
    /// Asserts the PRECONDITIONS (the real detectors genuinely find nothing) and
    /// then that the cascade still yields a face (the fallback is preserved, not
    /// deleted), marked `isFallback == true` and reporting `detectionScore < 1`
    /// (never a maximum-confidence lie).
    @Test("A no-face noise image cascades through real Vision/CoreImage misses to a fallback-marked face")
    func noiseFallbackCascadeMarksFace() throws {
        let noise = try noiseImage(width: 240, height: 240, seed: 0x5A17_C0DE)

        // Preconditions: the REAL detectors find nothing in this image — this is
        // what makes it a genuine test of the FALLBACK path, not a detour around it.
        let visionFaces = try FaceAligner().visionAlignedFaces(in: noise)
        #expect(visionFaces.isEmpty)
        let coreImageFace = try FaceAligner().coreImageAlignedFace(in: noise)
        #expect(coreImageFace == nil)

        // The end-to-end cascade — item 56 does not delete the fallback, it
        // labels it.
        let faces = try FaceAligner().alignedFaces(in: noise)
        #expect(faces.count == 1)
        let face = try #require(faces.first)
        #expect(face.qualityMetrics.isFallback == true)
        #expect(face.qualityMetrics.detectionScore < 1)
    }

    /// Model-free: a REAL face photo run through Vision directly must NOT be
    /// marked fallback, and must keep VISION'S OWN reported confidence (not
    /// forced to a sentinel `1`) — required behavior 5 (no change to the
    /// genuine-detection path).
    @Test("A Vision-detected face is never marked fallback and keeps Vision's own confidence")
    func visionFacesNotFallbackKeepConfidence() throws {
        let image = try fixtureImage("face_a", "jpg")
        let faces = try FaceAligner().visionAlignedFaces(in: image)
        let face = try #require(faces.first)
        #expect(face.qualityMetrics.isFallback == false)
        #expect(face.qualityMetrics.detectionScore > 0)
        #expect(face.qualityMetrics.detectionScore <= 1)
    }

    /// A11/A12 support: measures, BY FILENAME, which bundled fixtures (loose
    /// files and everything inside `sample_album.zip`) actually reach the blind
    /// fallback under the real cascade. Model-free (only detection, not
    /// embedding, is exercised). This is a regression guard AND the source of
    /// the "measured result" the item-56 report is required to enumerate: if a
    /// future fixture change makes a bundled photo start hitting the fallback,
    /// this test fails loudly instead of the fact going unnoticed in prose.
    @Test("Measured: which bundled fixtures reach the fallback path (by filename)")
    func measureFixtureFallbackHits() throws {
        var fallbackHits: [String] = []
        var noFaceAtAll: [String] = []
        var genuineHits: [String] = []

        func classify(_ name: String, _ image: CGImage) throws {
            let faces = try FaceAligner().alignedFaces(in: image)
            if faces.isEmpty {
                noFaceAtAll.append(name)
            } else if faces.contains(where: { $0.qualityMetrics.isFallback }) {
                fallbackHits.append(name)
            } else {
                genuineHits.append(name)
            }
        }

        for fixture in [("face_a", "jpg"), ("face_a2", "jpg"), ("face_b", "jpg"), ("blank", "png")] {
            try classify("\(fixture.0).\(fixture.1)", try fixtureImage(fixture.0, fixture.1))
        }

        // sample_album.zip: extracted the SAME way `ScanPipeline` extracts it
        // (a subprocess `unzip`, run by the TEST BINARY itself — not by me via a
        // shell tool — so this is reproducible by anyone running `swift test`).
        let zipURL = fixtureURL("sample_album", "zip")
        let extractionRoot = try temporaryDirectoryURL()
        defer { cleanup(extractionRoot) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", extractionRoot.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let keys = try pipeline().enumerateImages(in: extractionRoot)
        for key in keys {
            guard let source = CGImageSourceCreateWithURL(
                extractionRoot.appendingPathComponent(key) as CFURL, nil
            ), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            try classify(key, image)
        }

        // MEASURED RESULT (recorded in the item-56 report): no bundled fixture —
        // loose or inside sample_album.zip — reaches the blind fallback; every
        // real photo is a genuine Vision/Core-Image detection. `blank.png` is
        // the one fixture that yields NO face at all (rejected by the
        // pre-existing `isLikelyNonBlank` guard before the fallback would even
        // fire) — it was never a "fallback" case, it's a "nothing detected at
        // all" case, unaffected by item 56.
        #expect(fallbackHits.isEmpty)
        #expect(noFaceAtAll == ["blank.png"])
        #expect(!genuineHits.isEmpty)
    }
}

@Suite("Manual face region (item 19)")
struct ManualFaceRegionTests {
    /// Embedding a drawn region needs the ArcFace model; gate like the other embed
    /// tests. Proves the bbox→landmark→warp→embed path yields a real 512-d embedding
    /// and a top-left (Y-flipped) box for an arbitrary region.
    @Test("Embeds an arbitrary region via the bounding-box path", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func embedsRegion() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")
        // A box in Vision's bottom-left normalized convention, covering the frame.
        let face = try #require(
            try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7))
        )
        #expect(face.embedding.count == 512)
        #expect(face.embedding.values.allSatisfy { $0.isFinite })
        #expect(face.embedding.values.contains { $0 != 0 })

        // The returned box is top-left: y = 1 - maxY = 1 - 0.85 = 0.15; x unchanged.
        let box = try #require(face.qualityMetrics.faceBoundingBox)
        #expect(abs(box.x - 0.15) < 1e-5)
        #expect(abs(box.y - 0.15) < 1e-5)
        #expect(abs(box.width - 0.7) < 1e-5)
        #expect(abs(box.height - 0.7) < 1e-5)
    }

    /// A degenerate box short-circuits to nil in the bounding-box-landmark guard
    /// before any embed — no append, no throw.
    @Test("A degenerate region returns nil", .enabled(if: FaceEmbedderTests.isModelAvailable))
    func degenerateRegionReturnsNil() async throws {
        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")
        #expect(try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 0.2, y: 0.2, width: 0, height: 0.3)) == nil)
        #expect(try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0)) == nil)
        #expect(try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: -0.2)) == nil)
        // Fully outside the unit square (no overlap with the image rect).
        #expect(try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 2, y: 2, width: 0.3, height: 0.3)) == nil)
    }

    /// Assertion 5: an appended manual face is NOT pinned or excluded — it competes
    /// in the SAME `bestMatchingFace` selection `rescoreAll` uses, and a removed one
    /// no longer participates. Model-independent (cosine over fixed embeddings).
    @Test("An appended manual face competes in rescore; a removed one drops out")
    func manualFaceCompetesInRescore() throws {
        let prof = profile(references: [axisEmbedding(0)], threshold: 0.5)
        let quality = QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        // A weak auto face (orthogonal to the profile) and a strong manual face
        // (aligned with the profile reference).
        let auto = DetectedFace(embedding: axisEmbedding(1), qualityMetrics: quality)
        let manual = DetectedFace(
            embedding: axisEmbedding(0),
            qualityMetrics: QualityMetrics(
                detectionScore: 1,
                boundingBoxArea: 10000,
                faceBoundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
            )
        )

        // With the manual face appended, it wins (it competes, not pinned/excluded).
        let withManual = try FaceMatcher.bestMatchingFace(
            among: [auto, manual], profile: prof, minDetectionScore: 0, minBoundingBoxArea: 0
        )
        #expect(withManual?.index == 1)
        #expect((withManual?.score ?? 0) > 0.99)

        // Removed: only the weak auto face remains and is the (low-scoring) pick.
        let withoutManual = try FaceMatcher.bestMatchingFace(
            among: [auto], profile: prof, minDetectionScore: 0, minBoundingBoxArea: 0
        )
        #expect(withoutManual?.index == 0)
        #expect((withoutManual?.score ?? 1) < 0.01)
    }
}

@Suite("ScanPipeline", .serialized)
struct ScanPipelineTests {
    static var isModelAvailable: Bool {
        kionResolvedModelURL() != nil
    }

    @Test("Enumerates supported extensions only")
    func extensionFilter() throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        for name in ["a.jpg", "b.jpeg", "c.heic", "d.heif", "e.png", "f.pdf", "g.txt"] {
            FileManager.default.createFile(atPath: album.appendingPathComponent(name).path, contents: Data())
        }

        let keys = try Set(pipeline().enumerateImages(in: album))
        #expect(keys == ["a.jpg", "b.jpeg", "c.heic", "d.heif", "e.png"])
    }

    @Test("Enumerates extensions case-insensitively")
    func caseInsensitiveExtensions() throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        for name in ["h.HEIC", "i.JPG", "j.PNG"] {
            FileManager.default.createFile(atPath: album.appendingPathComponent(name).path, contents: Data())
        }

        let keys = try Set(pipeline().enumerateImages(in: album))
        #expect(keys == ["h.HEIC", "i.JPG", "j.PNG"])
    }

    @Test("Enumerates nested images recursively")
    func recursiveWalk() throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        let nested = album.appendingPathComponent("nested/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nested.appendingPathComponent("photo.jpg").path, contents: Data())

        let keys = try pipeline().enumerateImages(in: album)
        #expect(keys.contains("nested/sub/photo.jpg"))
    }

    @Test("A single image file enumerates as just that file, not its siblings")
    func singleImageFileEnumeratesItselfOnly() throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        // Target image AND a sibling valid image in the same directory.
        let target = album.appendingPathComponent("target.jpg")
        try copyFixture("face_a", "jpg", to: target)
        try copyFixture("face_b", "jpg", to: album.appendingPathComponent("sibling.jpg"))

        // The album URL is the regular IMAGE FILE itself → exactly its own key, and
        // the sibling must NOT be enumerated (an impl that scans the parent fails).
        let keys = try pipeline().enumerateImages(in: target)
        #expect(keys == ["target.jpg"])
        #expect(!keys.contains("sibling.jpg"))
    }

    @Test("Scanning a single image file yields exactly one result for that file")
    func scanSingleImageFileYieldsOneResult() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        let target = album.appendingPathComponent("target.jpg")
        try copyFixture("face_a", "jpg", to: target)
        try copyFixture("face_b", "jpg", to: album.appendingPathComponent("sibling.jpg"))

        // Deterministic embedder (a fixed detectable face) — as the other ScanPipeline
        // tests use — so the scan is model-independent.
        let result = try await pipeline(
            detectedFace: DetectedFace(
                embedding: unitEmbedding(),
                qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
            )
        ).scan(album: target, profiles: [profile(references: [unitEmbedding()], threshold: 0.5)])

        #expect(result.manifest.bestFacesByPhotoPath.count == 1)
        #expect(result.manifest["target.jpg"] != nil)
        #expect(result.manifest["sibling.jpg"] == nil)
        #expect(result.keep == ["target.jpg"])
    }

    @Test("A non-image file throws unsupportedAlbum and never enumerates its siblings")
    func nonImageFileThrowsAndIgnoresSiblings() throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        // A non-image file with a sibling valid image: if the parent were wrongly
        // enumerated, the sibling key would surface — but the call must throw instead.
        let nonImage = album.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: nonImage)
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("sibling.jpg"))

        #expect(throws: ScanPipelineError.unsupportedAlbum(nonImage.path)) {
            _ = try pipeline().enumerateImages(in: nonImage)
        }
    }

    @Test("Empty album scans to an empty stamped manifest")
    func emptyAlbum() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        let result = try await pipeline().scan(album: album, profile: profile(references: [unitEmbedding()]))

        #expect(result.keep.isEmpty)
        #expect(result.maybe.isEmpty)
        #expect(result.manifest.bestFacesByPhotoPath.isEmpty)
    }

    @Test("Nil embed result skips manifest and ranking")
    func nilEmbedSkipsPhoto() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("x.jpg"))

        let result = try await ScanPipeline(
            embedFace: { _ in nil },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(album: album, profile: profile(references: [unitEmbedding()]))

        #expect(result.manifest["x.jpg"] == nil)
        #expect(!result.keep.contains("x.jpg"))
        #expect(!result.maybe.contains("x.jpg"))
    }

    @Test("Zip fixture extracts scans and cleans temporary directory")
    func zipExtractionAndCleanup() async throws {
        let zipURL = fixtureURL("sample_album", "zip")
        #expect(FileManager.default.fileExists(atPath: zipURL.path))
        let before = kionScanTemporaryEntries()

        let result = try await pipeline(
            detectedFace: DetectedFace(
                embedding: unitEmbedding(),
                qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
            )
        ).scan(album: zipURL, profile: profile(references: [unitEmbedding()], threshold: 0.5))

        let after = kionScanTemporaryEntries()
        #expect(result.manifest["face_a.jpg"] != nil)
        #expect(result.keep.contains("face_a.jpg"))
        #expect(before == after)
    }

    @Test("Nonexistent album throws")
    func nonexistentPathThrows() async {
        let missingURL = URL(fileURLWithPath: "/nonexistent/path_\(UUID().uuidString)")

        do {
            _ = try await pipeline().scan(album: missingURL, profile: profile(references: [unitEmbedding()]))
            Issue.record("Expected an error")
        } catch {
            // Any error is acceptable — matches the pre-item-64 `(any Error).self` check.
        }
    }

    @Test("Orphans are excluded from output manifest")
    func orphanExclusion() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        let existing = Manifest(
            [
                "orphan.jpg": BestFace(
                    embedding: unitEmbedding(),
                    qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
                    subjectResults: ["subject-a": SubjectResult(score: 1, bucket: .keep)]
                ),
            ],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let result = try await pipeline().scan(
            album: album,
            profile: profile(references: [unitEmbedding()]),
            existingManifest: existing
        )

        #expect(result.manifest["orphan.jpg"] == nil)
    }

    @Test("Cache hit reuses embedding and preserves other subject result")
    func incrementalCacheHitAndSubjectIsolation() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        FileManager.default.createFile(atPath: album.appendingPathComponent("photo_a.jpg").path, contents: Data())

        let existing = Manifest(
            [
                "photo_a.jpg": BestFace(
                    embedding: unitEmbedding(),
                    qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
                    subjectResults: ["subject-b": SubjectResult(score: 0.9, bucket: .keep)]
                ),
            ],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let result = try await pipeline(
            detectedFace: DetectedFace(
                embedding: axisEmbedding(1),
                qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
            )
        ).scan(
            album: album,
            profile: profile(references: [unitEmbedding()], threshold: 0.7),
            existingManifest: existing
        )

        let face = try #require(result.manifest["photo_a.jpg"])
        #expect(face.embedding.values[0] == 1.0)
        #expect(face.subjectResults["subject-b"]?.score == 0.9)
        #expect(face.subjectResults["subject-a"]?.bucket == .keep)
    }

    // MARK: - Item 56: fallback labelling + gating

    /// Assertion 2: adding `QualityMetrics.isFallback` must not disturb the
    /// existing model-stamp cache-reuse mechanism. A legacy-stamped manifest
    /// (its JSON has NO `isFallback` key at all) is still a cache HIT — the
    /// injected `embedFace` is never called — proving the new field is purely
    /// additive to the cache-gating logic in `cachedFace`/`ScanPipeline.scan`.
    @Test("A legacy-stamped manifest (no isFallback in its JSON) is still cache-reused, never re-embedded")
    func legacyStampedManifestStillCacheReused() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        FileManager.default.createFile(atPath: album.appendingPathComponent("photo_a.jpg").path, contents: Data())

        let legacyData = Data("""
        {
          "bestFacesByPhotoPath": {
            "photo_a.jpg": {
              "embedding": {"values": [1.0, 0.0, 0.0]},
              "qualityMetrics": {"detectionScore": 1.0, "boundingBoxArea": 10000},
              "subjectResults": {"subject-a": {"score": 1.0, "bucket": "keep"}}
            }
          },
          "modelId": "arcfaceresnet100-8",
          "modelVersion": "1"
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(Manifest.self, from: legacyData)

        var embedCallCount = 0
        let result = try await ScanPipeline(
            embedFace: { _ in
                embedCallCount += 1
                return nil
            },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(
            album: album,
            // The legacy cached embedding above is written 3-dim for JSON brevity; the profile
            // reference must share that dimension (a single model stamp implies a single embedding
            // dimension — item 60 now throws on a mismatch rather than silently scoring 0.0).
            profile: profile(references: [FaceEmbedding([1.0, 0.0, 0.0])]),
            existingManifest: legacy
        )

        #expect(embedCallCount == 0)
        #expect(result.manifest["photo_a.jpg"] != nil)
    }

    /// Assertions 5/6/7: `ScanPipeline`'s default (`includeFallbackFaces`
    /// unspecified) excludes a fallback-only face from `keep`/`maybe` — even
    /// though its embedding is a PERFECT match for the profile — while the
    /// photo still appears in the output manifest bucketed `.no`, exactly like
    /// a photo that fails the pre-existing detection-score/area quality gate.
    /// It is excluded from ranking, never silently dropped.
    @Test("Default ScanPipeline excludes a fallback-only face from ranking but keeps the photo in the manifest at .no")
    func fallbackExcludedFromRankingByDefault() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("blind.jpg"))

        let matchingEmbedding = unitEmbedding()
        let fallbackFace = DetectedFace(
            embedding: matchingEmbedding,
            qualityMetrics: QualityMetrics(detectionScore: 0, boundingBoxArea: 10000, isFallback: true)
        )

        // `includeFallbackFaces` is NOT passed here — this pins the DEFAULT.
        let result = try await ScanPipeline(
            embedFace: { _ in fallbackFace },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(album: album, profile: profile(references: [matchingEmbedding], threshold: 0.5))

        #expect(!result.keep.contains("blind.jpg"))
        #expect(!result.maybe.contains("blind.jpg"))
        let face = try #require(result.manifest["blind.jpg"])
        #expect(face.subjectResults["subject-a"]?.bucket == .no)
        #expect(face.subjectResults["subject-a"]?.score == 0.0)
    }

    /// Assertions 5/8: the gate is keyed on `isFallback` — NOT overloaded onto
    /// `detectionScore` — so a fallback face is excluded regardless of how high
    /// its score is, and a genuine (non-fallback) low-scoring face is unaffected.
    /// `includeFallbackFaces: true` restores the pre-item-56 behavior end-to-end.
    @Test("Fallback gating keys on the isFallback flag, not the detection score; include-mode restores the old behavior")
    func fallbackGateKeysOnFlag() async throws {
        let fallbackHighScore = QualityMetrics(detectionScore: 1, boundingBoxArea: 10000, isFallback: true)
        let genuineLowScore = QualityMetrics(detectionScore: 0.01, boundingBoxArea: 10000, isFallback: false)

        #expect(FaceMatcher.passesQualityGate(
            metrics: fallbackHighScore, minDetectionScore: 0, minBoundingBoxArea: 0, includeFallbackFaces: false
        ) == false)
        #expect(FaceMatcher.passesQualityGate(
            metrics: genuineLowScore, minDetectionScore: 0, minBoundingBoxArea: 0, includeFallbackFaces: false
        ) == true)
        #expect(FaceMatcher.passesQualityGate(
            metrics: fallbackHighScore, minDetectionScore: 0, minBoundingBoxArea: 0, includeFallbackFaces: true
        ) == true)

        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("photo.jpg"))

        let matchingEmbedding = unitEmbedding()
        let fallbackFace = DetectedFace(embedding: matchingEmbedding, qualityMetrics: fallbackHighScore)
        let genuineFace = DetectedFace(
            embedding: matchingEmbedding,
            qualityMetrics: QualityMetrics(detectionScore: 0.9, boundingBoxArea: 10000, isFallback: false)
        )

        // Include-mode: the SAME fallback face now DOES land in keep — the
        // pre-item-56 behavior, opted back into explicitly.
        let includeResult = try await ScanPipeline(
            embedFace: { _ in fallbackFace },
            minDetectionScore: 0,
            minBoundingBoxArea: 0,
            includeFallbackFaces: true
        ).scan(album: album, profile: profile(references: [matchingEmbedding], threshold: 0.5))
        #expect(includeResult.keep.contains("photo.jpg"))

        // Contrast: a genuine face surfaces under the DEFAULT (exclude) mode
        // too — the exclusion targets fallback faces specifically, not every
        // maximum-confidence face.
        let genuineResult = try await ScanPipeline(
            embedFace: { _ in genuineFace },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(album: album, profile: profile(references: [matchingEmbedding], threshold: 0.5))
        #expect(genuineResult.keep.contains("photo.jpg"))
    }

    /// Assertion 9: `ScanPipeline.rescore` (the cache-hit re-attribution path)
    /// gates on `isFallback` on BOTH of its branches — the per-face `faces`
    /// array branch (a group-photo-shaped cache entry) AND the legacy
    /// single-representative branch (a pre-`faces` manifest entry) — so a
    /// cached fallback face can't slip back into `keep`/`maybe` on a re-scan
    /// via either shape.
    @Test("Rescore excludes a fallback face on BOTH cache branches: the faces array and the legacy representative")
    func rescoreGatesFallbackBothCacheBranches() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        FileManager.default.createFile(atPath: album.appendingPathComponent("multi.jpg").path, contents: Data())
        FileManager.default.createFile(atPath: album.appendingPathComponent("legacy.jpg").path, contents: Data())

        let matchingEmbedding = unitEmbedding()
        let fallbackFace = DetectedFace(
            embedding: matchingEmbedding,
            qualityMetrics: QualityMetrics(detectionScore: 0, boundingBoxArea: 10000, isFallback: true)
        )

        // Branch A: a cached photo whose ONLY detected face (in `faces`) is fallback.
        let multiEntry = BestFace(
            embedding: fallbackFace.embedding,
            qualityMetrics: fallbackFace.qualityMetrics,
            subjectResults: [:],
            faces: [fallbackFace]
        )
        // Branch B: a LEGACY entry (`faces == nil`) whose single representative
        // face is itself fallback-marked — the pre-`faces` manifest shape.
        let legacyEntry = BestFace(
            embedding: fallbackFace.embedding,
            qualityMetrics: fallbackFace.qualityMetrics,
            subjectResults: [:],
            faces: nil
        )

        let existing = Manifest(
            ["multi.jpg": multiEntry, "legacy.jpg": legacyEntry],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let result = try await pipeline().scan(
            album: album,
            profile: profile(references: [matchingEmbedding], threshold: 0.5),
            existingManifest: existing
        )

        let multiResult = try #require(result.manifest["multi.jpg"]?.subjectResults["subject-a"])
        #expect(multiResult.bucket == .no)
        #expect(multiResult.score == 0.0)
        #expect(!result.keep.contains("multi.jpg"))
        #expect(!result.maybe.contains("multi.jpg"))

        let legacyResult = try #require(result.manifest["legacy.jpg"]?.subjectResults["subject-a"])
        #expect(legacyResult.bucket == .no)
        #expect(legacyResult.score == 0.0)
        #expect(!result.keep.contains("legacy.jpg"))
        #expect(!result.maybe.contains("legacy.jpg"))
    }

    @Test("Stamp mismatch re-embeds decodable image")
    func stampMismatchReEmbeds() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("photo_x.jpg"))

        let existing = Manifest(
            [
                "photo_x.jpg": BestFace(
                    embedding: axisEmbedding(1),
                    qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
                    subjectResults: [:]
                ),
            ],
            modelId: "arcfaceresnet100-8",
            modelVersion: "OLD"
        )

        let result = try await pipeline(
            detectedFace: DetectedFace(
                embedding: unitEmbedding(),
                qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
            )
        ).scan(
            album: album,
            profile: profile(references: [unitEmbedding()]),
            existingManifest: existing
        )

        #expect(result.manifest["photo_x.jpg"]?.embedding.values[0] == 1.0)
    }

    @Test("Quality gate stores no bucket and excludes rankings")
    func qualityGateDiscrimination() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("gated.jpg"))

        let result = try await pipeline(
            detectedFace: DetectedFace(
                embedding: unitEmbedding(),
                qualityMetrics: QualityMetrics(detectionScore: 0.1, boundingBoxArea: 10000)
            ),
            minDetectionScore: 0.5
        ).scan(album: album, profile: profile(references: [unitEmbedding()], threshold: 0.5))

        #expect(result.manifest["gated.jpg"]?.subjectResults["subject-a"]?.bucket == .no)
        #expect(!result.keep.contains("gated.jpg"))
        #expect(!result.maybe.contains("gated.jpg"))
    }

    @Test("Buckets and rankings are score ordered")
    func bucketDiscriminationAndOrdering() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        for name in ["keep_a.jpg", "keep_b.jpg", "maybe.jpg", "no.jpg"] {
            FileManager.default.createFile(atPath: album.appendingPathComponent(name).path, contents: Data())
        }

        let existing = Manifest(
            [
                "keep_a.jpg": cachedFace(embedding: FaceEmbedding([1, 0] + zeros(510))),
                "keep_b.jpg": cachedFace(embedding: FaceEmbedding([0.8, 0.6] + zeros(510))),
                "maybe.jpg": cachedFace(embedding: FaceEmbedding([0.6, 0.8] + zeros(510))),
                "no.jpg": cachedFace(embedding: FaceEmbedding([0, 1] + zeros(510))),
            ],
            modelId: "arcfaceresnet100-8",
            modelVersion: "1"
        )

        let result = try await pipeline().scan(
            album: album,
            profile: profile(
                references: [unitEmbedding()],
                threshold: 0.7,
                maybeMargin: 0.2
            ),
            existingManifest: existing
        )

        #expect(result.keep == ["keep_a.jpg", "keep_b.jpg"])
        #expect(result.maybe == ["maybe.jpg"])
        #expect(result.manifest["no.jpg"] != nil)
        #expect(!result.keep.contains("no.jpg"))
        #expect(!result.maybe.contains("no.jpg"))
    }

    @Test("Scan stamps fresh output manifest")
    func manifestStampedOnScan() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }

        let result = try await pipeline().scan(album: album, profile: profile(references: [unitEmbedding()]))

        #expect(result.manifest.modelId == "arcfaceresnet100-8")
        #expect(result.manifest.modelVersion == "1")
    }

    @Test("Real folder scan detects face and skips blank", .enabled(if: ScanPipelineTests.isModelAvailable))
    func realFolderScan() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("face_a.jpg"))
        try copyFixture("blank", "png", to: album.appendingPathComponent("blank.png"))

        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let reference = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg"))?.embedding)
        let result = try await ScanPipeline(
            embedFace: embedder.embedFace,
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        ).scan(album: album, profile: profile(references: [reference], threshold: 0.5))

        #expect(result.manifest["face_a.jpg"] != nil)
        #expect(result.keep.contains("face_a.jpg") || result.maybe.contains("face_a.jpg"))
        #expect(result.manifest["blank.png"] == nil)
        #expect(!result.keep.contains("blank.png"))
        #expect(!result.maybe.contains("blank.png"))
    }

    @Test("Cache hit supports two subjects", .enabled(if: ScanPipelineTests.isModelAvailable))
    func twoSubjectParameterization() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("face_a.jpg"))
        try copyFixture("blank", "png", to: album.appendingPathComponent("blank.png"))

        let embedder = try FaceEmbedder(modelURL: kionResolvedModelURL())
        let reference = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg"))?.embedding)
        let firstPipeline = ScanPipeline(
            embedFace: embedder.embedFace,
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let result1 = try await firstPipeline.scan(
            album: album,
            profile: profile(subjectId: "subject-a", references: [reference], threshold: 0.5)
        )
        let result2 = try await firstPipeline.scan(
            album: album,
            profile: profile(subjectId: "subject-b", references: [reference], threshold: 0.5),
            existingManifest: result1.manifest
        )

        let subjectResults = result2.manifest["face_a.jpg"]?.subjectResults
        #expect(subjectResults?["subject-a"] != nil)
        #expect(subjectResults?["subject-b"] != nil)
    }
}

@Suite("Multi-profile scan")
struct MultiProfileScanTests {
    /// Two people in one group photo (faceA + faceB). A single one-pass scan over
    /// both profiles must record a `SubjectResult` for each, with each subject
    /// scored against *its own* best-matching face — i.e. exactly what running each
    /// subject's single-profile scan alone produces, merged.
    @Test("Two-profile scan records both subjects and equals merged single scans")
    func twoProfileEqualsMergedSingles() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        // A real decodable image so the pipeline reaches the (injected) embedder;
        // the injected faces — not the file's pixels — drive the scoring.
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("group.jpg"))

        let faceA = DetectedFace(
            embedding: FaceEmbedding([1, 0] + zeros(510)),
            qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        )
        let faceB = DetectedFace(
            embedding: FaceEmbedding([0, 1] + zeros(510)),
            qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        )
        let faces = [faceA, faceB]
        let pipeline = ScanPipeline(
            embedFace: { _ in faces.first },
            embedAllFaces: { _ in faces },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )

        let profileA = profile(subjectId: "subject-a", references: [faceA.embedding], threshold: 0.5)
        let profileB = profile(subjectId: "subject-b", references: [faceB.embedding], threshold: 0.5)

        let multi = try await pipeline.scan(album: album, profiles: [profileA, profileB])
        let face = try #require(multi.manifest["group.jpg"])

        // Both people are recorded under their own subjectId.
        #expect(Set(face.subjectResults.keys) == ["subject-a", "subject-b"])

        // Multi == merge of two independent single-profile scans, per subject.
        let singleA = try await pipeline.scan(album: album, profile: profileA)
        let singleB = try await pipeline.scan(album: album, profile: profileB)
        #expect(face.subjectResults["subject-a"] == singleA.manifest["group.jpg"]?.subjectResults["subject-a"])
        #expect(face.subjectResults["subject-b"] == singleB.manifest["group.jpg"]?.subjectResults["subject-b"])

        // Each subject matched its own face → both keep.
        #expect(face.subjectResults["subject-a"]?.bucket == .keep)
        #expect(face.subjectResults["subject-b"]?.bucket == .keep)
        #expect(abs((face.subjectResults["subject-a"]?.score ?? 0) - 1.0) < 0.0001)
        #expect(abs((face.subjectResults["subject-b"]?.score ?? 0) - 1.0) < 0.0001)
        #expect(multi.keep.contains("group.jpg"))
    }

    /// Regression: a CACHED re-scan (model stamp matches `existingManifest`) of a
    /// two-face group photo with two profiles must re-attribute each person to
    /// *their own* best-matching face — not score every profile against the single
    /// cached representative embedding (which would mis-attribute one person to the
    /// other's face on a re-scan).
    @Test("Cached re-scan attributes each profile to its own face")
    func cachedRescanUsesPerProfileBestFace() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("group.jpg"))

        // faceA matches subject-a only; faceB matches subject-b only.
        let faceA = DetectedFace(
            embedding: FaceEmbedding([1, 0] + zeros(510)),
            qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        )
        let faceB = DetectedFace(
            embedding: FaceEmbedding([0, 1] + zeros(510)),
            qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        )
        let faces = [faceA, faceB]
        let pipeline = ScanPipeline(
            embedFace: { _ in faces.first },
            embedAllFaces: { _ in faces },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )

        let profileA = profile(subjectId: "subject-a", references: [faceA.embedding], threshold: 0.5)
        let profileB = profile(subjectId: "subject-b", references: [faceB.embedding], threshold: 0.5)

        // Fresh scan caches all faces + the model stamp in the manifest.
        let fresh = try await pipeline.scan(album: album, profiles: [profileA, profileB])
        #expect(fresh.manifest["group.jpg"]?.faces?.count == 2)

        // Re-scan with the cached manifest → cache hit (stamp matches). The
        // representative embedding is faceA (subject-a's best), so the old bug
        // would score subject-b against faceA and bucket it `.no`.
        let cached = try await pipeline.scan(album: album, profiles: [profileA, profileB], existingManifest: fresh.manifest)
        let face = try #require(cached.manifest["group.jpg"])

        #expect(Set(face.subjectResults.keys) == ["subject-a", "subject-b"])
        // Each subject is attributed to its OWN face → both keep, score ≈ 1.
        #expect(face.subjectResults["subject-a"]?.bucket == .keep)
        #expect(face.subjectResults["subject-b"]?.bucket == .keep)
        #expect(abs((face.subjectResults["subject-a"]?.score ?? 0) - 1.0) < 0.0001)
        #expect(abs((face.subjectResults["subject-b"]?.score ?? 0) - 1.0) < 0.0001)
        // Cached re-scan == fresh scan for the same inputs.
        #expect(face.subjectResults == fresh.manifest["group.jpg"]?.subjectResults)
    }

    /// Legacy manifest (no cached `faces`) falls back to scoring the single
    /// representative embedding for every profile — the only thing available.
    @Test("Cached re-scan of a legacy manifest falls back to the representative")
    func cachedRescanLegacyManifestFallsBack() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("group.jpg"))

        let representative = FaceEmbedding([1, 0] + zeros(510))
        let profileA = profile(subjectId: "subject-a", references: [representative], threshold: 0.5)
        let profileB = profile(subjectId: "subject-b", references: [representative], threshold: 0.5)

        // A pre-`faces` manifest: only the representative embedding is known.
        let legacy = Manifest(
            [
                "group.jpg": BestFace(
                    embedding: representative,
                    qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
                    subjectResults: [:],
                    faces: nil
                ),
            ],
            modelId: profileA.modelId,
            modelVersion: profileA.modelVersion
        )

        let pipeline = ScanPipeline(
            embedFace: { _ in nil },
            embedAllFaces: { _ in [] },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let cached = try await pipeline.scan(album: album, profiles: [profileA, profileB], existingManifest: legacy)
        let face = try #require(cached.manifest["group.jpg"])
        #expect(face.faces == nil)
        // Both profiles scored against the representative → both keep ≈ 1.
        #expect(face.subjectResults["subject-a"]?.bucket == .keep)
        #expect(face.subjectResults["subject-b"]?.bucket == .keep)
    }

    /// The single-profile scan stays a thin wrapper over the multi path: scanning
    /// one profile is byte-identical to supplying it in a one-element array.
    @Test("Single-profile scan equals one-element multi scan")
    func singleEqualsOneElementMulti() async throws {
        let album = try temporaryDirectoryURL()
        defer { cleanup(album) }
        try copyFixture("face_a", "jpg", to: album.appendingPathComponent("solo.jpg"))

        let face = DetectedFace(
            embedding: FaceEmbedding([1] + zeros(511)),
            qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000)
        )
        let pipeline = ScanPipeline(
            embedFace: { _ in face },
            embedAllFaces: { _ in [face] },
            minDetectionScore: 0,
            minBoundingBoxArea: 0
        )
        let only = profile(subjectId: "subject-a", references: [face.embedding], threshold: 0.5)

        let single = try await pipeline.scan(album: album, profile: only)
        let multi = try await pipeline.scan(album: album, profiles: [only])
        #expect(single.manifest == multi.manifest)
        #expect(single.keep == multi.keep)
        #expect(single.maybe == multi.maybe)
    }
}

/// Item 52 model resolution for model-gated tests: prefer `KION_MODEL_PATH` when it
/// points at a real file (so CI/dev can override it), but fall back to the
/// well-known installed location so model-gated tests actually EXECUTE under a bare
/// `swift test` without requiring an env var to be injected into the test process.
private func kionResolvedModelURL() -> URL? {
    if let path = ProcessInfo.processInfo.environment["KION_MODEL_PATH"], FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    let wellKnownPath = "\(NSHomeDirectory())/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx"
    return FileManager.default.fileExists(atPath: wellKnownPath) ? URL(fileURLWithPath: wellKnownPath) : nil
}

private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func temporaryDirectoryURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func singleSubjectStore(modelId: String, modelVersion: String) -> ProfileStore {
    ProfileStore(
        modelId: modelId,
        modelVersion: modelVersion,
        profiles: [
            "subject-alice": ProfileBundle(
                subjectId: "subject-alice",
                references: [FaceEmbedding([0.1, 0.2, 0.3])],
                threshold: 0.6,
                modelId: modelId,
                modelVersion: modelVersion
            ),
        ]
    )
}

private func profile(
    subjectId: String = "subject-a",
    references: [FaceEmbedding],
    confirmedPositives: [FaceEmbedding] = [],
    negatives: [FaceEmbedding] = [],
    threshold: Float = 0.5,
    maybeMargin: Float = 0.1,
    negativeMargin: Float = 0.0
) -> ProfileBundle {
    ProfileBundle(
        subjectId: subjectId,
        references: references,
        confirmedPositives: confirmedPositives,
        negatives: negatives,
        threshold: threshold,
        maybeMargin: maybeMargin,
        negativeMargin: negativeMargin,
        modelId: "arcfaceresnet100-8",
        modelVersion: "1"
    )
}

private func storeWithSubject() -> ProfileStore {
    ProfileStore(
        modelId: "arcfaceresnet100-8",
        modelVersion: "1",
        profiles: [
            "subject-a": profile(references: [FaceEmbedding([1, 0, 0])]),
        ]
    )
}

private func singleFaceManifest(
    embedding: FaceEmbedding,
    subjectResults: [String: SubjectResult],
    modelId: String? = nil,
    modelVersion: String? = nil
) -> Manifest {
    Manifest(
        [
            "photo-001": BestFace(
                embedding: embedding,
                qualityMetrics: QualityMetrics(detectionScore: 0.95, boundingBoxArea: 10000),
                subjectResults: subjectResults
            ),
        ],
        modelId: modelId,
        modelVersion: modelVersion
    )
}

/// Loads a fixture through the SAME unified decode path production code uses (item
/// 55: previously this duplicated its own `CGImageSourceCreateWithURL`/`...AtIndex`
/// call, a fourth copy alongside the three unified in `ScanPipeline.decodeImage`).
/// Every test that calls this — most of `FaceEmbedderTests`, `ScanPipelineTests`,
/// etc. — now transitively exercises `ScanPipeline.decodeImage` too.
private func fixtureImage(_ name: String, _ extensionName: String) throws -> CGImage {
    let fixturesURL = fixtureURL(name, extensionName)
    guard let image = ScanPipeline.decodeImage(at: fixturesURL) else {
        throw FixtureError.imageLoadFailed(fixturesURL.path)
    }
    return image
}

private func fixtureURL(_ name: String, _ extensionName: String) -> URL {
    let currentFile = URL(fileURLWithPath: #filePath)
    return currentFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
        .appendingPathExtension(extensionName)
}


private func rgbaPixels(from image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw FixtureError.imageCreationFailed
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return pixels
}

private func copyFixture(_ name: String, _ extensionName: String, to destinationURL: URL) throws {
    try FileManager.default.copyItem(at: fixtureURL(name, extensionName), to: destinationURL)
}

private func pipeline(
    detectedFace: DetectedFace? = nil,
    minDetectionScore: Float = 0,
    minBoundingBoxArea: Float = 0
) -> ScanPipeline {
    ScanPipeline(
        embedFace: { _ in detectedFace },
        minDetectionScore: minDetectionScore,
        minBoundingBoxArea: minBoundingBoxArea
    )
}

private func unitEmbedding() -> FaceEmbedding {
    FaceEmbedding([1] + zeros(511))
}

private func axisEmbedding(_ index: Int) -> FaceEmbedding {
    var values = zeros(512)
    values[index] = 1
    return FaceEmbedding(values)
}

private func zeros(_ count: Int) -> [Float] {
    [Float](repeating: 0, count: count)
}

private func cachedFace(embedding: FaceEmbedding) -> BestFace {
    BestFace(
        embedding: embedding,
        qualityMetrics: QualityMetrics(detectionScore: 1, boundingBoxArea: 10000),
        subjectResults: [:]
    )
}

private func kionScanTemporaryEntries() -> Set<String> {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)) ?? []
    return Set(entries.filter { $0.hasPrefix("KionScan-") })
}

private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 4)
    for _ in 0 ..< (width * height) {
        pixels.append(red)
        pixels.append(green)
        pixels.append(blue)
        pixels.append(255)
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        throw FixtureError.imageCreationFailed
    }
    return image
}

/// A deterministic (seeded) pseudo-random noise image: every pixel is
/// independently "random" (a simple seeded PRNG, not real entropy), so it has
/// no facial structure for Vision/Core Image to find, yet is emphatically
/// non-blank (passes `FaceEmbedder`'s `isLikelyNonBlank` guard by a wide
/// margin) — the shape of image the item-56 fallback test needs: something the
/// real detectors genuinely miss but the heuristic fallback still accepts.
/// Seeded (not `SystemRandomNumberGenerator`) so the test is reproducible.
private func noiseImage(width: Int, height: Int, seed: UInt64) throws -> CGImage {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func nextByte() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8((state >> 33) & 0xFF)
    }

    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 4)
    for _ in 0 ..< (width * height) {
        pixels.append(nextByte())
        pixels.append(nextByte())
        pixels.append(nextByte())
        pixels.append(255)
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else {
        throw FixtureError.imageCreationFailed
    }
    return image
}

private func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
    var dot: Float = 0
    var lhsNorm: Float = 0
    var rhsNorm: Float = 0
    for index in lhs.indices {
        dot += lhs[index] * rhs[index]
        lhsNorm += lhs[index] * lhs[index]
        rhsNorm += rhs[index] * rhs[index]
    }
    return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
}

private enum FixtureError: Error {
    case imageCreationFailed
    case imageLoadFailed(String)
}

/// Decodes `Tests/Fixtures/face_a_embedding_baseline.json` (checked-in baseline, captured
/// on unmodified main before any item-52 edit). Only the fields this suite reads.
private struct EmbeddingBaselineFixture: Decodable {
    let embeddingDimension: Int
    let values: [Float]
}

/// Regression guard: the ONNX Runtime CoreML execution provider compiles the model into
/// `TMPDIR`. That scratch dir MUST be inside the process temp dir (the app's sandbox
/// container tmp under App Sandbox), never a hardcoded `/private/tmp/...` — which the
/// sandbox blocks, making CoreML session creation fail so every embed returns nil (no
/// faces detected, no photos scored). See item 44 (App Sandbox) + the item-50 follow-up.
@Suite("FaceEmbedder CoreML temp dir (sandbox-safe)")
struct FaceEmbedderCoreMLTempDirTests {
    @Test("CoreML scratch dir lives under the process temp dir, not /private/tmp")
    func coreMLTempDirIsInsideProcessTempDir() {
        let path = FaceEmbedder.coreMLTemporaryDirectoryURL.path
        #expect(path.hasPrefix(NSTemporaryDirectory()))
        #expect(!path.hasPrefix("/private/tmp/kifinder"))
        #expect(path.hasSuffix("kifinder-coreml"))
    }
}

/// Item 56, assertion 12: proves the genuine-detection embedding path is
/// UNCHANGED by this item — this item only relabels the FALLBACK path and adds
/// engine-internal synchronization; it must not perturb a real embedding by
/// even a little. Deliberately NOT `.enabled(if:)`-gated: unlike the other
/// model-optional tests in this file, a missing model here must HARD-FAIL the
/// suite, not silently skip past the one check that would catch a regression
/// in the vector itself.
@Suite("Embedding baseline (item 56 no-regression check)")
struct EmbeddingBaselineTests {
    /// Mirrors `Tests/Fixtures/face_a_embedding_baseline.json`'s shape exactly:
    /// `{ "_provenance": {...}, "embeddingDimension": 512, "values": [...] }`.
    /// `_provenance` is intentionally NOT decoded (unused, purely documentation
    /// in the fixture) — Swift's keyed decoding only reads the keys the target
    /// type declares, so its presence is harmless.
    private struct EmbeddingBaseline: Decodable {
        var embeddingDimension: Int
        var values: [Float]
    }

    @Test("embedFace on face_a.jpg matches the checked-in pre-item-56 baseline (cosine >= 0.95)")
    func embeddingBaselineUnchangedOnGenuineDetection() async throws {
        guard let modelURL = kionResolvedModelURL() else {
            Issue.record(
                """
                Model not found via KION_MODEL_PATH or the managed install location \
                (~/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx) — \
                this check must HARD-FAIL, never skip.
                """
            )
            throw ModelFixtureError.modelUnavailable
        }

        let embedder = try FaceEmbedder(modelURL: modelURL)
        let image = try fixtureImage("face_a", "jpg")
        let detected = try #require(try await embedder.embedFace(image))

        // Non-fallback property check ONLY (no score-vs-baseline comparison,
        // per the assertion): `face_a.jpg` is a real photo, so this must be a
        // genuine Vision/Core-Image detection, never the blind fallback.
        #expect(detected.qualityMetrics.isFallback == false)
        #expect(detected.qualityMetrics.detectionScore < 1)

        // The baseline fixture is checked in and READ-ONLY: this test
        // must never create, modify, regenerate, or delete it (assertion 13).
        let baselineURL = fixtureURL("face_a_embedding_baseline", "json")
        let baselineData = try Data(contentsOf: baselineURL)
        let baseline = try JSONDecoder().decode(EmbeddingBaseline.self, from: baselineData)
        #expect(baseline.embeddingDimension == 512)
        #expect(baseline.values.count == 512)

        // Was >= 0.9999 when the fixture and the run shared an OS. macOS 27's Vision
        // shifts the detected box/landmarks slightly, so the aligned crop — and the
        // embedding — drift (measured 0.974). Same identity, still far above any match
        // threshold; a broken pipeline lands near 0. See embeddingMatchesPreChangeBaseline.
        let similarity = cosine(detected.embedding.values, baseline.values)
        #expect(similarity >= 0.95, "cosine to baseline \(similarity)")
    }
}

/// Thrown by the model-gated baseline check when the ArcFace model cannot be resolved.
/// A12 must HARD-FAIL rather than skip, so this is an error, not a skip condition.
private enum ModelFixtureError: Error {
    case modelUnavailable
}
