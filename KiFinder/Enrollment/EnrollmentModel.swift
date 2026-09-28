import Foundation
import KionEngine
import Observation

/// Drives the enrollment sheet: collects 5–12 validated local reference photos,
/// reports the empty/too-few/ready/enrolling state the UI renders, then enrolls
/// through `TriageEngine.enroll(referenceURLs:)` and persists a local
/// `ProfileBundle`. Pure-ish coordinator (no SwiftUI), so `EnrollmentModelTests`
/// drives every transition without the view.
@MainActor
@Observable
final class EnrollmentModel {
    static let minReferences = 5
    static let maxReferences = 12

    /// Coarse state the sheet maps onto copy + enable/disable. `.enrolling`
    /// supersedes the count-based states so the drop zone and button lock down.
    enum Readiness: Equatable {
        case empty
        case tooFew
        case ready
        case enrolling
    }

    private(set) var acceptedURLs: [URL] = []
    /// The person's display name, bound to the sheet's name field. Stored raw (so
    /// the user can type interior spaces); the trimmed form gates enrollment and is
    /// what gets persisted onto the `Person`. Seeded from `initialName` so
    /// re-enrolling an existing person prefills their current name.
    var displayName: String
    /// True once an `add` had to drop at least one URL because the 12-reference
    /// cap was already reached — drives the visible limit feedback.
    private(set) var didHitLimit = false
    private(set) var isEnrolling = false
    private(set) var errorMessage: String?

    /// Test-only references injected via `KION_TEST_REFERENCE_PATHS`. The sheet
    /// surfaces an "add" affordance only when this is non-empty, so UI tests can
    /// populate the drop zone deterministically without synthesizing a drag.
    let testReferencePaths: [URL]

    private let engine: any TriageEngine
    private let repository: any ProfileRepository
    /// The engine `subjectId` this enrollment targets — a fresh UUID for a new
    /// person, or an existing person's id when re-enrolling. Exposed (read-only) so
    /// `AppModel` callers and tests can confirm the new-vs-re-enroll target.
    let subjectId: String
    /// The model this enrollment stamps/calibrates against — INJECTED by
    /// `AppModel` as its `activeFaceBackend`'s descriptor (item 72), rather than
    /// this type reading `FileProfileRepository`'s arcface-default statics
    /// directly. Defaults to `.arcface` so every pre-item-72 caller/test is
    /// unaffected.
    private let descriptor: FaceModelDescriptor
    private let onComplete: (ProfileBundle) -> Void

    init(
        engine: any TriageEngine,
        repository: any ProfileRepository,
        subjectId: String,
        initialName: String = "",
        testReferencePaths: [URL] = [],
        descriptor: FaceModelDescriptor = .arcface,
        onComplete: @escaping (ProfileBundle) -> Void
    ) {
        self.engine = engine
        self.repository = repository
        self.subjectId = subjectId
        displayName = initialName
        self.testReferencePaths = testReferencePaths
        self.descriptor = descriptor
        self.onComplete = onComplete
    }

    // MARK: - Derived state

    var referenceCount: Int {
        acceptedURLs.count
    }

    var readiness: Readiness {
        if isEnrolling { return .enrolling }
        if acceptedURLs.isEmpty { return .empty }
        if acceptedURLs.count < Self.minReferences { return .tooFew }
        return .ready
    }

    /// The display name with surrounding whitespace removed — the form persisted
    /// onto the `Person` and the value enrollment gates on.
    var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canEnroll: Bool {
        readiness == .ready && !trimmedName.isEmpty
    }

    /// The drop zone (and the test add affordance) only accept input while we are
    /// still collecting — never mid-enroll.
    var isDropEnabled: Bool {
        !isEnrolling
    }

    // MARK: - Collecting references

    /// Adds the decodable, not-yet-present image URLs, preserving selection order
    /// and capping at `maxReferences`. Missing/non-image/duplicate URLs are
    /// dropped without disturbing the accepted count. Returns the number added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        guard isDropEnabled else { return 0 }
        didHitLimit = false
        var added = 0
        for url in urls {
            if acceptedURLs.count >= Self.maxReferences {
                didHitLimit = true
                continue
            }
            guard ReferenceImageValidator.isReferenceImage(at: url) else { continue }
            guard !acceptedURLs.contains(url) else { continue }
            acceptedURLs.append(url)
            added += 1
        }
        return added
    }

    func addTestReferences() {
        add(testReferencePaths)
    }

    func remove(_ url: URL) {
        guard isDropEnabled else { return }
        acceptedURLs.removeAll { $0 == url }
        didHitLimit = false
    }

    // MARK: - Enrolling

    func enroll() async {
        guard canEnroll else { return }
        isEnrolling = true
        errorMessage = nil
        defer { isEnrolling = false }
        do {
            let references = try await engine.enroll(referenceURLs: acceptedURLs)
            let bundle = makeBundle(references: references)
            // Item 53: capture + cancel any pending coalesced write BEFORE the
            // repository's load-modify-write of the store (so a stale snapshot
            // can't fire after and clobber this bundle), then re-arm a copy of it
            // updated to this bundle once the write lands — preserving any OTHER
            // person's pending feedback the cancellation swept up. Replaces a
            // plain `flush()`, which would have written (rather than preserved via
            // reschedule) the pending snapshot ahead of the repository's read.
            try engine.writingThroughRepository(merging: { store in store.profiles[subjectId] = bundle }) {
                try repository.saveProfile(bundle)
            }

            // Produce + cache a real cropped-face thumbnail on-device. A nil result
            // (or a cache write failure) is non-fatal: the person is still enrolled,
            // just without a thumbnail, so a sidebar/initials fallback renders.
            var thumbnailFileName: String?
            if let data = await engine.enrollmentThumbnail(referenceURLs: acceptedURLs) {
                thumbnailFileName = (try? repository.saveThumbnail(data, for: subjectId))?.lastPathComponent
            }

            // Record who this subject is (name + thumbnail ref) in the roster —
            // roster-only write, but run through the same transaction for
            // uniformity (item 53) so nothing pending gets dropped along the way.
            try engine.writingThroughRepository {
                try repository.savePerson(
                    Person(id: subjectId, displayName: trimmedName, thumbnailFileName: thumbnailFileName)
                )
            }
            onComplete(bundle)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persists the embeddings the engine produced for the accepted photos. In the
    /// live engine these are real ArcFace embeddings; in sample mode they are
    /// placeholders (one per photo). Calibration is resolved through
    /// `FaceModelRegistry.standard` keyed on the model this profile is stamped with
    /// (item 69), so it matches the engine/CLI seed and a later scan buckets
    /// candidates consistently.
    private func makeBundle(references: [FaceEmbedding]) -> ProfileBundle {
        let calibration = FaceModelRegistry.standard.calibration(for: descriptor.id, modelVersion: descriptor.version)
        return ProfileBundle(
            subjectId: subjectId,
            references: references,
            threshold: calibration.defaultThreshold,
            maybeMargin: calibration.maybeMargin,
            negativeMargin: calibration.negativeMargin,
            modelId: descriptor.id,
            modelVersion: descriptor.version
        )
    }
}
