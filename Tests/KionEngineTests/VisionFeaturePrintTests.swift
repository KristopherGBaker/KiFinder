import CoreGraphics
import Foundation
import KionEngine
import KionVisionEmbedder
import Testing

/// Item 71 — proves the SECOND `FaceEmbeddingProvider` backend, Apple Vision's
/// built-in feature print, end-to-end at the engine layer: descriptor/registry
/// resolution, real embeds via the shared core `FaceAligner`, a non-vacuous
/// same-vs-different-person discrimination margin, and the first real
/// `FaceModelProvisioner` conformer. None of these need the ONNX model — Vision
/// ships with the OS — so they run on any host, unlike the `.enabled(if:
/// isModelAvailable)`-gated ArcFace tests elsewhere in this target.
@Suite("VisionFeaturePrintEmbedder (item 71)")
struct VisionFeaturePrintTests {
    // MARK: - Descriptor + registry

    @Test("visionFeaturePrint descriptor has 768-d embeddings compared by cosine")
    func descriptorShape() {
        #expect(FaceModelDescriptor.visionFeaturePrint.embeddingDimension == 768)
        #expect(FaceModelDescriptor.visionFeaturePrint.similarityMetric == .cosine)
    }

    @Test("standard registry resolves the vision-featureprint stamp to .visionFeaturePrint")
    func registryResolvesVisionStamp() {
        let resolved = FaceModelRegistry.standard.descriptor(for: "vision-featureprint", modelVersion: "1")
        #expect(resolved == .visionFeaturePrint)
    }

    @Test("standard registry still resolves the canonical ArcFace stamp to .arcface")
    func registryStillResolvesArcface() {
        let resolved = FaceModelRegistry.standard.descriptor(
            for: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(resolved == .arcface)
    }

    // MARK: - Embeds

    @Test("embedFace on a real photo returns a DetectedFace with exactly 768 embedding values")
    func embedsFaceA() async throws {
        let embedder = VisionFeaturePrintEmbedder()
        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        #expect(face.embedding.values.count == 768)
    }

    @Test("descriptor property reports .visionFeaturePrint")
    func embedderDescriptor() {
        #expect(VisionFeaturePrintEmbedder().descriptor == .visionFeaturePrint)
    }

    // MARK: - Discrimination with a real margin (the key behavioral proof)

    /// All three fixtures embed to exactly 768 values, and enrolling a profile
    /// from `face_a` then scoring `face_a2` (same person) vs `face_b`
    /// (different person) shows the same-person score beats the
    /// different-person score by a real, non-negligible margin — not merely a
    /// numerically-distinguishable one. A prototype measurement gave
    /// ≈0.994 vs ≈0.961 (a ≈0.03 gap); this test only pins the much smaller,
    /// robust `>= 0.01` floor so it isn't brittle to minor Vision framework
    /// version drift.
    @Test("same-person score beats different-person score by at least a 0.01 margin")
    func discriminatesWithMargin() async throws {
        let embedder = VisionFeaturePrintEmbedder()

        let faceA = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        let faceA2 = try #require(try await embedder.embedFace(fixtureImage("face_a2", "jpg")))
        let faceB = try #require(try await embedder.embedFace(fixtureImage("face_b", "jpg")))

        #expect(faceA.embedding.values.count == 768)
        #expect(faceA2.embedding.values.count == 768)
        #expect(faceB.embedding.values.count == 768)

        let profile = ProfileBundle(
            subjectId: "subject-a",
            references: [faceA.embedding],
            threshold: FaceModelDescriptor.visionFeaturePrint.calibration.defaultThreshold,
            maybeMargin: FaceModelDescriptor.visionFeaturePrint.calibration.maybeMargin,
            negativeMargin: FaceModelDescriptor.visionFeaturePrint.calibration.negativeMargin,
            modelId: FaceModelDescriptor.visionFeaturePrint.id,
            modelVersion: FaceModelDescriptor.visionFeaturePrint.version
        )

        let sameScore = try FaceMatcher.score(embedding: faceA2.embedding, profile: profile, metric: .cosine)
        let differentScore = try FaceMatcher.score(embedding: faceB.embedding, profile: profile, metric: .cosine)

        #expect(sameScore - differentScore >= 0.01)
    }

    // MARK: - Provisioner (first real conformer)

    @Test("VisionFeaturePrintProvisioner is always installed, needs no download, and builds the right provider")
    func provisioner() throws {
        let provisioner = VisionFeaturePrintProvisioner()
        #expect(provisioner.isInstalled == true)
        #expect(provisioner.downloadPlan == nil)
        let provider = try provisioner.makeProvider()
        #expect(provider.descriptor == .visionFeaturePrint)
    }
}

// MARK: - Local fixture helpers (this file's own, not shared with KionEngineTests.swift)

private enum VisionFixtureError: Error {
    case imageLoadFailed(String)
}

private func fixtureImage(_ name: String, _ extensionName: String) throws -> CGImage {
    let url = fixtureURL(name, extensionName)
    guard let image = ScanPipeline.decodeImage(at: url) else {
        throw VisionFixtureError.imageLoadFailed(url.path)
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
