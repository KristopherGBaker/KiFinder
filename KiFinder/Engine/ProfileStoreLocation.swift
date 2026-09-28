import Foundation
import KionEngine

/// Resolves the production profile-store path for a given backend/descriptor
/// (item 72). Before backend selection there was ONE store file,
/// `<appSupportRoot>/KiFinder/profile-store.json`, always ArcFace. Now each
/// backend gets its OWN file, keyed by its descriptor's model id
/// (`profile-store-<id>.json`), so an ArcFace-enrolled (512-d) profile and a
/// Vision-enrolled (768-d) profile never collide on disk — the item 58
/// model-stamp gating enforces this at READ time too; keeping them in separate
/// files means the two are never even asked to coexist in one.
///
/// Pure except for the ONE side effect below: when resolving the ARCFACE path and
/// a pre-item-72 legacy `profile-store.json` exists while the arcface-suffixed
/// file does NOT, this moves (not copies) the legacy file to the suffixed path —
/// preserving whatever was enrolled under the old name exactly once, the first
/// time the new suffixed path is resolved. A Vision resolution NEVER touches the
/// legacy file (there is nothing of Vision's to migrate from an ArcFace store),
/// and a suffixed file that already exists is never overwritten (no data loss).
///
/// `appSupportRoot` is injectable (mirrors `ModelLocations.appSupportRoot`) so
/// `AppModelBackendSelectionTests` can prove path-separation + migration against a
/// temp directory — never the real `~/Library/Application Support`.
func resolveProfileStoreURL(
    descriptor: FaceModelDescriptor,
    appSupportRoot: URL,
    fileManager: FileManager = .default
) -> URL {
    let directory = appSupportRoot.appendingPathComponent("KiFinder", isDirectory: true)
    let suffixed = directory.appendingPathComponent("profile-store-\(descriptor.id).json")

    if descriptor.id == FaceModelDescriptor.arcface.id {
        let legacy = directory.appendingPathComponent("profile-store.json")
        if fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: suffixed.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fileManager.moveItem(at: legacy, to: suffixed)
        }
    }
    return suffixed
}
