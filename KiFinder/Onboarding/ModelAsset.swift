import Foundation

/// Single source of truth for the models the app downloads on first run. The
/// downloader and integrity check both take a descriptor (defaulting to
/// `.production`) so tests can substitute a SMALL-fixture descriptor — that's what
/// lets the fake/network path be exercised without masking a wrong production
/// constant.
struct ModelAssetDescriptor: Equatable {
    /// How the verified download is turned into the installed, loadable model —
    /// item74b. `.moveFile` is the original ONNX behavior: the verified temp file
    /// IS the installed model, so it's simply moved into place. `.unzipAndCompileMLModel`
    /// is AdaFace's: the verified temp is a zip of an `.mlpackage`, which must be
    /// unzipped and compiled (`MLModel.compileModel(at:)`) into a `.mlmodelc`
    /// before it's a loadable model.
    enum InstallKind: Equatable {
        case moveFile
        case unzipAndCompileMLModel
    }

    /// Where the model is fetched from.
    let downloadURL: URL
    /// Exact byte count of the DOWNLOADED asset; a size mismatch is a failed download.
    let expectedByteCount: Int64
    /// Lowercase hex SHA-256 of the downloaded asset, verified after download.
    let expectedSHA256: String
    /// On-disk file name of the downloaded asset (what the verify step checks).
    let fileName: String
    /// On-disk name of the INSTALLED model under the managed `models/` directory —
    /// same as `fileName` for `.moveFile` (the verified file IS the installed
    /// file); a distinct name (e.g. a `.mlmodelc`) for `.unzipAndCompileMLModel`.
    let installedName: String
    /// How the verified download becomes the installed model. Defaults to
    /// `.moveFile` so every existing descriptor/call site (which never mentions
    /// this) keeps today's exact behavior.
    let installKind: InstallKind

    init(
        downloadURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String,
        fileName: String,
        installedName: String? = nil,
        installKind: InstallKind = .moveFile
    ) {
        self.downloadURL = downloadURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.fileName = fileName
        self.installedName = installedName ?? fileName
        self.installKind = installKind
    }

    /// The real ArcFace asset (`arcfaceresnet100-8.onnx`, ~249 MB). These values
    /// are fixed inputs — a unit test pins them so a typo can't slip through.
    static let production = ModelAssetDescriptor(
        downloadURL: URL(string: "https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8/resolve/main/arcfaceresnet100-8.onnx?download=true")!,
        expectedByteCount: 261_036_388,
        expectedSHA256: "f3a6bc281e72f88862f5748b53be3d76b3b48f8f1ab1f4a537941bdc4e1b01da",
        fileName: "arcfaceresnet100-8.onnx"
    )

    /// The real AdaFace IR-18 asset (item74b): a ~44 MB zip of an `.mlpackage`
    /// that must be unzipped + compiled into a `.mlmodelc` before it's loadable.
    /// These values are fixed inputs, pinned identically to
    /// `AdaFaceProvisioner`'s copy (`Sources/KionCoreMLEmbedder`) — a unit test
    /// pins them so the two can never silently drift apart.
    static let adaface = ModelAssetDescriptor(
        downloadURL: URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip")!,
        expectedByteCount: 44_482_098,
        expectedSHA256: "c639ffc02233c72c10daf90f484e14bf570b7f70f55f0c0ee1ce3d284a04430b",
        fileName: "AdaFace_IR18.mlpackage.zip",
        installedName: "AdaFace_IR18.mlmodelc",
        installKind: .unzipAndCompileMLModel
    )
}
