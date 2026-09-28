import Foundation

/// The filesystem root the model resolver consults. Defaults to the real
/// Application Support directory in production, but is injectable so resolver tests
/// pass a temp dir and NEVER read/write the real `~/Library`.
struct ModelLocations {
    /// Root under which the managed model lives at `KiFinder/models/<fileName>`.
    /// In production this is `~/Library/Application Support`.
    var appSupportRoot: URL

    /// The real production root: Application Support for the managed model.
    static var production: ModelLocations {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return ModelLocations(appSupportRoot: appSupport)
    }
}

/// The managed install URL: `<appSupportRoot>/KiFinder/models/<installedName>`.
/// The model goes under `KiFinder/` (Application Support — never Caches, which
/// the OS may purge); the existing profile store stays under `KiFinder/`. Takes
/// the INSTALLED name (`ModelAssetDescriptor.installedName`), not the downloaded
/// `fileName` — identical for `.moveFile` descriptors (ONNX), distinct for
/// `.unzipAndCompileMLModel` ones (AdaFace's `.mlmodelc`).
func managedModelURL(appSupportRoot: URL, fileName: String = ModelAssetDescriptor.production.installedName) -> URL {
    appSupportRoot
        .appendingPathComponent("KiFinder", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent(fileName)
}

/// Resolves the model to use, checking sources in this explicit order and
/// returning the first match (else `nil`). This is the SAME function the readiness
/// gate and `LiveTriageEngine` resolve through. `installKind`-aware (item74b): a
/// `.moveFile` descriptor (ONNX) checks a FILE's exact size; a
/// `.unzipAndCompileMLModel` descriptor (AdaFace) checks a DIRECTORY's existence
/// (a `.mlmodelc` is a bundle directory — no single meaningful byte count).
///
/// 1. `KION_MODEL_PATH` — used iff set and that file **exists** (no size check; an
///    explicit override is trusted as-is).
/// 2. Managed location — used iff it's installed per `descriptor.installKind`:
///    `.moveFile` = file exists **and its size == `expectedByteCount`** (a
///    wrong-size/partial file there is treated as NOT installed);
///    `.unzipAndCompileMLModel` = the `installedName` DIRECTORY exists.
func resolveModelURL(
    env: [String: String],
    locations: ModelLocations,
    descriptor: ModelAssetDescriptor = .production
) -> URL? {
    let fileManager = FileManager.default

    if let path = env["KION_MODEL_PATH"], fileManager.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }

    let managed = managedModelURL(appSupportRoot: locations.appSupportRoot, fileName: descriptor.installedName)

    switch descriptor.installKind {
    case .moveFile:
        if let size = fileSize(of: managed), size == descriptor.expectedByteCount {
            return managed
        }
    case .unzipAndCompileMLModel:
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: managed.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return managed
        }
    }

    return nil
}

/// File size in bytes, or `nil` when the file is missing/unreadable.
private func fileSize(of url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = (attributes[.size] as? NSNumber)?.int64Value
    else { return nil }
    return size
}
