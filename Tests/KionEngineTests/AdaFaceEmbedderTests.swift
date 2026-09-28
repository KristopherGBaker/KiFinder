import CoreGraphics
import Foundation
import KionCoreMLEmbedder
import KionEngine
import Testing

/// Item 74a — proves the THIRD `FaceEmbeddingProvider` backend, AdaFace IR-18
/// (CoreML), end-to-end at the engine layer: descriptor/registry resolution,
/// the provisioner's first REAL `downloadPlan`, init error paths, real embeds
/// via the shared core `FaceAligner`, a non-vacuous same-vs-different-person
/// discrimination margin, and the `.mlpackage` compile path
/// (`MLModel.compileModel(at:)`). Model-gated tests mirror the `FaceEmbedder`
/// (ONNX) and `VisionFeaturePrintEmbedder` patterns: `.enabled(if:)` on a
/// resolvable model so the suite stays green (by skipping) when the ~42 MB
/// CoreML model isn't provisioned, but genuinely EXECUTES when it is.
@Suite("AdaFaceEmbedder (item 74a)", .serialized)
struct AdaFaceEmbedderTests {
    /// Resolves the COMPILED `.mlmodelc`: prefer `KION_ADAFACE_MODEL_PATH` when it
    /// points at a real file/directory (so CI/dev can override it), but fall back to
    /// the well-known managed location `Scripts/bootstrap-fixtures.sh` compiles into,
    /// mirroring `kionResolvedModelURL()`'s ArcFace resolution.
    static func resolvedModelURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["KION_ADAFACE_MODEL_PATH"],
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let wellKnownPath = "\(NSHomeDirectory())/Library/Application Support/KiFinder/models/AdaFace_IR18.mlmodelc"
        return FileManager.default.fileExists(atPath: wellKnownPath) ? URL(fileURLWithPath: wellKnownPath) : nil
    }

    /// Resolves the UNCOMPILED `.mlpackage` from `KION_ADAFACE_PACKAGE_PATH` ONLY —
    /// deliberately NO managed fallback, so unsetting this one env var
    /// deterministically disables just the compile-path test without touching the
    /// `.mlmodelc`-gated tests above.
    static func resolvedPackageURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["KION_ADAFACE_PACKAGE_PATH"],
              FileManager.default.fileExists(atPath: path)
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    static var adafaceModelAvailable: Bool {
        resolvedModelURL() != nil
    }

    static var adafacePackageAvailable: Bool {
        resolvedPackageURL() != nil
    }

    // MARK: - Descriptor identity (no model needed)

    @Test("adaface descriptor is adaface-ir18/1, 512-d, cosine, calibration 0.40/0.08/0.0")
    func descriptorShape() {
        let descriptor = FaceModelDescriptor.adaface
        #expect(descriptor.id == "adaface-ir18")
        #expect(descriptor.version == "1")
        #expect(descriptor.embeddingDimension == 512)
        #expect(descriptor.similarityMetric == .cosine)
        #expect(descriptor.calibration == MatchCalibration(defaultThreshold: 0.40, maybeMargin: 0.08, negativeMargin: 0.0))
    }

    // MARK: - Registry (no model needed)

    @Test("standard registry resolves the adaface-ir18 stamp to .adaface")
    func registryResolvesAdaFaceStamp() {
        let resolved = FaceModelRegistry.standard.descriptor(for: "adaface-ir18", modelVersion: "1")
        #expect(resolved == .adaface)
        #expect(resolved?.similarityMetric == .cosine)
    }

    @Test("adding .adaface left ArcFace and Vision resolution unchanged")
    func registryResolutionUnaffectedForOtherModels() {
        let arcface = FaceModelRegistry.standard.descriptor(
            for: ModelIdentity.canonical.modelId,
            modelVersion: ModelIdentity.canonical.modelVersion
        )
        #expect(arcface == .arcface)

        let vision = FaceModelRegistry.standard.descriptor(for: "vision-featureprint", modelVersion: "1")
        #expect(vision == .visionFeaturePrint)
    }

    // MARK: - Provisioner (no model needed)

    @Test("AdaFaceProvisioner declares the exact pinned download plan")
    func provisionerDownloadPlan() throws {
        let provisioner = AdaFaceProvisioner(modelURLProvider: { URL(fileURLWithPath: "/nonexistent/AdaFace_IR18.mlmodelc") })
        #expect(provisioner.descriptor == .adaface)

        let plan = try #require(provisioner.downloadPlan)
        #expect(plan.url.absoluteString == "https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip")
        #expect(plan.expectedByteCount == 44_482_098)
        #expect(plan.expectedSHA256 == "c639ffc02233c72c10daf90f484e14bf570b7f70f55f0c0ee1ce3d284a04430b")
        #expect(plan.fileName == "AdaFace_IR18.mlpackage.zip")
    }

    @Test("AdaFaceProvisioner.isInstalled reflects an injected present-vs-absent path")
    func provisionerIsInstalledReflectsInjectedPath() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let presentPath = tempDirectory.appendingPathComponent("present.mlmodelc")
        try Data().write(to: presentPath)
        let absentPath = tempDirectory.appendingPathComponent("absent.mlmodelc")

        let installed = AdaFaceProvisioner(modelURLProvider: { presentPath })
        let notInstalled = AdaFaceProvisioner(modelURLProvider: { absentPath })
        #expect(installed.isInstalled == true)
        #expect(notInstalled.isInstalled == false)
    }

    @Test("AdaFaceProvisioner.makeProvider() with an injected existing path returns an .adaface provider")
    func provisionerMakeProviderReturnsAdaFaceDescriptor() throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let presentPath = tempDirectory.appendingPathComponent("present.mlmodelc")
        try Data().write(to: presentPath)

        // Construction is lazy (no CoreML touched), so this is model-independent —
        // an empty placeholder file is enough to prove the provisioner wires the
        // resolved path through to `AdaFaceEmbedder.init`.
        let provisioner = AdaFaceProvisioner(modelURLProvider: { presentPath })
        let provider = try provisioner.makeProvider()
        #expect(provider.descriptor == .adaface)
    }

    // MARK: - Init errors (no model needed)

    @Test("A nonexistent explicit model URL throws")
    func nonexistentModelURLThrows() {
        #expect(throws: (any Error).self) {
            _ = try AdaFaceEmbedder(modelURL: URL(fileURLWithPath: "/nonexistent/AdaFace_IR18.mlmodelc"))
        }
    }

    @Test("Injected nil env lookup throws modelNotFound")
    func nilEnvironmentLookupThrowsModelNotFound() {
        #expect(throws: FaceEmbedderError.modelNotFound) {
            _ = try AdaFaceEmbedder(modelURL: nil, envLookup: { _ in nil })
        }
    }

    // MARK: - Model-gated: full provider surface

    @Test(
        "embedFace/embedAllFaces/region-embed all succeed on a real face; warmUp does not throw",
        .enabled(if: AdaFaceEmbedderTests.adafaceModelAvailable)
    )
    func providerSurfaceEmbedsRealFace() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedModelURL())
        try await embedder.warmUp()

        let image = try fixtureImage("face_a", "jpg")

        let face = try #require(try await embedder.embedFace(image))
        #expect(face.embedding.count == 512)
        #expect(face.embedding.values.allSatisfy { $0.isFinite })
        #expect(face.embedding.values.contains { $0 != 0 })

        let allFaces = try await embedder.embedAllFaces(image)
        #expect(!allFaces.isEmpty)
        #expect(allFaces.allSatisfy { $0.embedding.count == 512 })

        let regionFace = try #require(
            try await embedder.embedFace(in: image, regionBoundingBox: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7))
        )
        #expect(regionFace.embedding.count == 512)
    }

    // MARK: - Model-gated: output is L2-normalized

    @Test("Output embedding is ~L2-normalized (model bakes in normalization)", .enabled(if: AdaFaceEmbedderTests.adafaceModelAvailable))
    func embeddingIsL2Normalized() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedModelURL())
        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))

        let sumOfSquares = face.embedding.values.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sumOfSquares.squareRoot()
        #expect(abs(norm - 1.0) <= 0.02)
    }

    // MARK: - Model-gated: blank image

    @Test("Blank image returns nil", .enabled(if: AdaFaceEmbedderTests.adafaceModelAvailable))
    func blankImageReturnsNil() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedModelURL())
        #expect(try await embedder.embedFace(fixtureImage("blank", "png")) == nil)
    }

    // MARK: - Model-gated: deterministic

    @Test("Same image embeds identically twice on one embedder", .enabled(if: AdaFaceEmbedderTests.adafaceModelAvailable))
    func embeddingIsDeterministic() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedModelURL())
        let image = try fixtureImage("face_a", "jpg")

        let first = try #require(try await embedder.embedFace(image))
        let second = try #require(try await embedder.embedFace(image))
        #expect(first.embedding.values == second.embedding.values)
    }

    // MARK: - Model-gated: discrimination margin (the WORKS proof)

    @Test(
        "same-person cosine beats different-person cosine by at least a 0.10 margin",
        .enabled(if: AdaFaceEmbedderTests.adafaceModelAvailable)
    )
    func discriminatesWithRealMargin() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedModelURL())

        // Precondition: all three fixtures decode AND each yields a detected face —
        // a missing/undetected fixture fails loudly here, never masquerading as a pass.
        let faceA = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        let faceA2 = try #require(try await embedder.embedFace(fixtureImage("face_a2", "jpg")))
        let faceB = try #require(try await embedder.embedFace(fixtureImage("face_b", "jpg")))
        #expect(faceA.embedding.count == 512)
        #expect(faceA2.embedding.count == 512)
        #expect(faceB.embedding.count == 512)

        let profile = ProfileBundle(
            subjectId: "subject-a",
            references: [faceA.embedding],
            threshold: FaceModelDescriptor.adaface.calibration.defaultThreshold,
            maybeMargin: FaceModelDescriptor.adaface.calibration.maybeMargin,
            negativeMargin: FaceModelDescriptor.adaface.calibration.negativeMargin,
            modelId: FaceModelDescriptor.adaface.id,
            modelVersion: FaceModelDescriptor.adaface.version
        )

        let sameScore = try FaceMatcher.score(embedding: faceA2.embedding, profile: profile, metric: .cosine)
        let differentScore = try FaceMatcher.score(embedding: faceB.embedding, profile: profile, metric: .cosine)

        #expect(sameScore - differentScore >= 0.10)
    }

    // MARK: - Model-gated: the .mlpackage compile path (separate gate)

    @Test(
        "AdaFaceEmbedder built from the uncompiled .mlpackage warms up and embeds successfully",
        .enabled(if: AdaFaceEmbedderTests.adafacePackageAvailable)
    )
    func compilePathFromUncompiledPackage() async throws {
        let embedder = try AdaFaceEmbedder(modelURL: Self.resolvedPackageURL())
        try await embedder.warmUp()

        let face = try #require(try await embedder.embedFace(fixtureImage("face_a", "jpg")))
        #expect(face.embedding.count == 512)
        #expect(face.embedding.values.allSatisfy { $0.isFinite })
    }
}

// MARK: - Local fixture helpers (this file's own, not shared with KionEngineTests.swift)

private enum AdaFaceFixtureError: Error {
    case imageLoadFailed(String)
}

private func fixtureImage(_ name: String, _ extensionName: String) throws -> CGImage {
    let url = fixtureURL(name, extensionName)
    guard let image = ScanPipeline.decodeImage(at: url) else {
        throw AdaFaceFixtureError.imageLoadFailed(url.path)
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
