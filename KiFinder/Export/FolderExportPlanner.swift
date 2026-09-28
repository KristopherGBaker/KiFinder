import Foundation

/// One planned file copy for a folder export: a source paired with the exact
/// destination it should land at. `Sendable` value type so planning (cheap, can run
/// on either actor) and the actual byte copies (item 54: off the `@MainActor`) can
/// cross the actor boundary through `Task.detached` — the same snapshot shape
/// `LiveTriageEngine.computeRescore` uses for its manifest/profile inputs.
struct FolderExportPlan: Sendable, Equatable {
    let source: URL
    let destination: URL
}

/// Plans destinations for a batch of folder-export sources, de-colliding filenames
/// that collide WITHIN this batch (item 54: two kept photos both named
/// `IMG_0001.jpg` from different source albums must both survive under distinct
/// names) while preserving the existing, deliberate behavior for a name that only
/// collides with a STALE file already on disk: the first source in the batch to
/// claim a name still lands at that exact path and overwrites whatever's there.
/// De-collision (`-2`, `-3`, …) applies only to the SECOND-and-later source in this
/// same batch that wants the same name.
enum FolderExportPlanner {
    static func plan(sources: [URL], directory: URL, fileManager: FileManager = .default) -> [FolderExportPlan] {
        var claimedThisBatch: Set<String> = []
        var plans: [FolderExportPlan] = []
        plans.reserveCapacity(sources.count)

        for source in sources {
            let fileName = source.lastPathComponent
            let name: String
            if claimedThisBatch.contains(fileName) {
                // Intra-batch collision: find the next name not already claimed by an
                // earlier source THIS batch (which may not be written to disk yet) and
                // not genuinely on disk either, reusing the exact same `-N` numbering
                // `KeptLibrary` uses for its own save-time de-collision.
                name = KeptLibrary.firstAvailableName(fileName) { candidate in
                    claimedThisBatch.contains(candidate)
                        || fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                }
            } else {
                // First source this batch to want this name: use it as-is. A stale
                // file already on disk at that path is deliberately overwritten by
                // the copy step, not de-collided away from.
                name = fileName
            }
            claimedThisBatch.insert(name)
            plans.append(FolderExportPlan(source: source, destination: directory.appendingPathComponent(name)))
        }
        return plans
    }
}
