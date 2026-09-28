import Foundation
import KionEngine

/// The first `FaceModelProvisioner` conformer with a REAL `downloadPlan`
/// (item 74a) — Vision's `downloadPlan` is `nil` because it ships with the
/// OS; AdaFace ships as a `.mlpackage.zip` that must be downloaded, verified,
/// unzipped, and compiled. THIS unit only declares the plan + the
/// model-URL-resolution seam; the actual download→unzip→compile flow the app
/// drives is item74b's concern (mirrors how item71 shipped Vision's
/// provisioner before item72 wired app-side selection).
///
/// The asset constants below are pinned to the exact file that was
/// prototyped and verified end-to-end — kept identical to `Scripts/bootstrap-fixtures.sh`'s copy so the
/// two can never silently drift apart.
public struct AdaFaceProvisioner: FaceModelProvisioner {
    /// The exact asset the model was prototyped/verified against.
    static let downloadURL = URL(
        string: "https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip"
    )!
    static let expectedByteCount = 44_482_098
    static let expectedSHA256 = "c639ffc02233c72c10daf90f484e14bf570b7f70f55f0c0ee1ce3d284a04430b"
    static let fileName = "AdaFace_IR18.mlpackage.zip"

    /// Resolves the path AdaFace's COMPILED model would live at once
    /// installed. Injectable so tests can point it at an existing/absent
    /// temp path without touching `~/Library`; production points at the
    /// same managed location `Scripts/bootstrap-fixtures.sh` compiles into
    /// and `AdaFaceEmbedder`'s `KION_ADAFACE_MODEL_PATH` fallback resolves —
    /// the concrete managed-directory layout + compile-at-install flow is
    /// item74b's concern, so here `isInstalled`/`makeProvider()` just reflect
    /// whatever path this closure returns.
    private let modelURLProvider: @Sendable () -> URL

    public var descriptor: FaceModelDescriptor { .adaface }

    public var downloadPlan: ModelDownloadPlan? {
        ModelDownloadPlan(
            url: Self.downloadURL,
            expectedByteCount: Self.expectedByteCount,
            expectedSHA256: Self.expectedSHA256,
            fileName: Self.fileName
        )
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelURLProvider().path)
    }

    public init(modelURLProvider: @escaping @Sendable () -> URL = AdaFaceProvisioner.defaultModelURL) {
        self.modelURLProvider = modelURLProvider
    }

    public func makeProvider() throws -> any FaceEmbeddingProvider {
        try AdaFaceEmbedder(modelURL: modelURLProvider())
    }

    /// The production managed-install location — the same one
    /// `Scripts/bootstrap-fixtures.sh` compiles the model into.
    public static func defaultModelURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/KiFinder/models/AdaFace_IR18.mlmodelc")
    }
}
