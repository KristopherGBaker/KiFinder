import Foundation
@testable import KiFinder
import KionEngine
import Testing

/// Pure-logic coverage for enrollment: image validation, the 5/12 reference
/// bounds, the empty/too-few/ready/enrolling states, the single ordered
/// `enroll(referenceURLs:)` call, and the persisted `ProfileBundle`. Each test
/// uses its own unique temp store path, so the suite passes in any order.
@Suite("Enrollment model")
@MainActor
struct EnrollmentModelTests {
    // MARK: - Fixtures (located via #filePath like the engine tests)

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KiFinderTests
            .deletingLastPathComponent() // repo root
    }

    private static func fixture(_ name: String) -> URL {
        repoRoot().appendingPathComponent("Tests").appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    private static var validImageURL: URL {
        fixture("face_a.jpg")
    }

    private static var nonImageURL: URL {
        fixture("not-an-image.txt")
    }

    // MARK: - Per-test isolation

    private func uniqueDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-enroll-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRepository() -> FileProfileRepository {
        FileProfileRepository(storeURL: uniqueDir().appendingPathComponent("store.json"))
    }

    /// `count` distinct, decodable image URLs (copies of the fixture), so the
    /// dedupe and ordering invariants are exercised against unique paths.
    private func makeValidReferences(_ count: Int) throws -> [URL] {
        let dir = uniqueDir()
        return try (0 ..< count).map { index in
            let dest = dir.appendingPathComponent("ref-\(index).jpg")
            try FileManager.default.copyItem(at: Self.validImageURL, to: dest)
            return dest
        }
    }

    private func makeModel(
        engine: any TriageEngine = SampleTriageEngine(),
        repository: FileProfileRepository? = nil,
        subjectId: String = "Kris",
        initialName: String = "Kris",
        onComplete: @escaping (ProfileBundle) -> Void = { _ in }
    ) -> EnrollmentModel {
        EnrollmentModel(
            engine: engine,
            repository: repository ?? makeRepository(),
            subjectId: subjectId,
            initialName: initialName,
            onComplete: onComplete
        )
    }

    // MARK: - Validation

    @Test("Validation precondition: valid image decodes, non-image fails")
    func validationFixturePreconditions() {
        #expect(FileManager.default.fileExists(atPath: Self.validImageURL.path))
        #expect(FileManager.default.fileExists(atPath: Self.nonImageURL.path))
        #expect(ReferenceImageValidator.isReferenceImage(at: Self.validImageURL))
        #expect(!ReferenceImageValidator.isReferenceImage(at: Self.nonImageURL))
    }

    @Test("Add accepts the image fixture, rejects the non-image fixture")
    func addAcceptsImageRejectsNonImage() {
        let model = makeModel()

        let added = model.add([Self.validImageURL, Self.nonImageURL])

        #expect(added == 1)
        #expect(model.acceptedURLs == [Self.validImageURL])
    }

    @Test("Missing/invalid URL rejected without changing the accepted count")
    func missingURLRejected() throws {
        let model = makeModel()
        try model.add(makeValidReferences(3))
        #expect(model.referenceCount == 3)

        let missing = URL(fileURLWithPath: "/tmp/kion-missing-\(UUID().uuidString).jpg")
        let added = model.add([missing, Self.nonImageURL])

        #expect(added == 0)
        #expect(model.referenceCount == 3)
    }

    @Test("Duplicate URL collapses to one reference (one preview per URL)")
    func duplicateURLCollapses() {
        let model = makeModel()

        model.add([Self.validImageURL])
        model.add([Self.validImageURL])

        #expect(model.referenceCount == 1)
    }

    // MARK: - States & bounds

    @Test("Empty / too-few / ready states")
    func readinessStates() throws {
        let model = makeModel()
        #expect(model.readiness == .empty)
        #expect(!model.canEnroll)

        try model.add(makeValidReferences(4))
        #expect(model.referenceCount == 4)
        #expect(model.readiness == .tooFew)
        #expect(!model.canEnroll)

        try model.add(makeValidReferences(1))
        #expect(model.referenceCount == 5)
        #expect(model.readiness == .ready)
        #expect(model.canEnroll)
    }

    @Test("Adding 13 references caps at 12 and flags the limit")
    func capsAtTwelve() throws {
        let model = makeModel()

        try model.add(makeValidReferences(13))

        #expect(model.referenceCount == 12)
        #expect(model.didHitLimit)
        #expect(model.canEnroll)
    }

    // MARK: - Enrolling

    @Test("In-progress enroll disables drop + enroll until completion")
    func enrollingStateDisables() async throws {
        let engine = SampleTriageEngine(enrollDelay: .milliseconds(300))
        let model = makeModel(engine: engine)
        try model.add(makeValidReferences(5))
        #expect(model.canEnroll)

        let task = Task { await model.enroll() }
        try? await Task.sleep(for: .milliseconds(60))

        #expect(model.readiness == .enrolling)
        #expect(model.isEnrolling)
        #expect(!model.canEnroll)
        #expect(!model.isDropEnabled)

        await task.value
        #expect(!model.isEnrolling)
    }

    @Test("Enroll records exactly one call with the same ordered URLs and persists the bundle + named Person")
    func enrollRecordsCallAndPersists() async throws {
        let engine = SampleTriageEngine()
        let repository = makeRepository()
        var completed: ProfileBundle?
        // A name with surrounding whitespace exercises the trim on persistence.
        let model = makeModel(
            engine: engine,
            repository: repository,
            initialName: "  Ada  "
        ) { completed = $0 }

        let references = try makeValidReferences(6)
        model.add(references)
        await model.enroll()

        // Spy: exactly one enroll call, with the same ordered URLs.
        #expect(engine.recordedEnrollments.count == 1)
        #expect(engine.recordedEnrollments.first == references)

        // Persisted bundle for the active subject "Kris".
        let persisted = try #require(repository.loadProfile(subjectId: "Kris"))
        #expect(persisted.subjectId == "Kris")
        #expect(persisted.references.count == 6)

        // The roster gained a Person under the same subjectId with the trimmed name.
        let person = try #require(repository.loadRoster().first { $0.id == "Kris" })
        #expect(person.displayName == "Ada")

        // Completion exposes the enrolled bundle (dismiss-to-Review hook).
        #expect(completed?.subjectId == "Kris")
        #expect(completed?.references.count == 6)
    }

    @Test("A non-empty name is required to enroll")
    func nameRequiredToEnroll() async throws {
        let engine = SampleTriageEngine()
        let repository = makeRepository()
        let model = makeModel(engine: engine, repository: repository, initialName: "   ")

        try model.add(makeValidReferences(6))
        // Photos are in range but the (whitespace-only) name is empty → blocked.
        #expect(model.readiness == .ready)
        #expect(!model.canEnroll)

        await model.enroll()
        #expect(engine.recordedEnrollments.isEmpty)
        #expect(repository.loadProfile(subjectId: "Kris") == nil)
        #expect(repository.loadRoster().isEmpty)

        // Supplying a name unblocks enrollment.
        model.displayName = "Mara"
        #expect(model.canEnroll)
        await model.enroll()
        #expect(engine.recordedEnrollments.count == 1)
        #expect(repository.loadRoster().first { $0.id == "Kris" }?.displayName == "Mara")
    }

    @Test("Enroll persists a thumbnail when the engine returns one")
    func enrollPersistsThumbnail() async throws {
        let engine = ThumbnailStubEngine(thumbnail: Self.tinyPNG())
        let repository = makeRepository()
        let model = makeModel(engine: engine, repository: repository, initialName: "Nora")

        try model.add(makeValidReferences(5))
        await model.enroll()

        // The engine was asked for a thumbnail and the bytes were cached on disk…
        #expect(engine.thumbnailRequests == 1)
        let cached = try #require(repository.thumbnailURL(for: "Kris"))
        #expect(FileManager.default.fileExists(atPath: cached.path))
        // …and the resulting file name is recorded on the saved Person.
        let person = try #require(repository.loadRoster().first { $0.id == "Kris" })
        #expect(person.thumbnailFileName == cached.lastPathComponent)
    }

    @Test("A nil thumbnail still enrolls the Person without one")
    func enrollHandlesNilThumbnail() async throws {
        let engine = ThumbnailStubEngine(thumbnail: nil)
        let repository = makeRepository()
        let model = makeModel(engine: engine, repository: repository, initialName: "Iris")

        try model.add(makeValidReferences(5))
        await model.enroll()

        #expect(engine.thumbnailRequests == 1)
        #expect(repository.thumbnailURL(for: "Kris") == nil)
        let person = try #require(repository.loadRoster().first { $0.id == "Kris" })
        #expect(person.displayName == "Iris")
        #expect(person.thumbnailFileName == nil)
    }

    /// A minimal valid PNG (1×1) used as deterministic thumbnail bytes.
    private static func tinyPNG() -> Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
    }

    @Test("Enroll is a no-op below the minimum (no engine call, no persistence)")
    func enrollNoOpBelowMinimum() async throws {
        let engine = SampleTriageEngine()
        let repository = makeRepository()
        let model = makeModel(engine: engine, repository: repository)

        try model.add(makeValidReferences(3))
        await model.enroll()

        #expect(engine.recordedEnrollments.isEmpty)
        #expect(repository.loadProfile(subjectId: "Kris") == nil)
    }
}

/// A minimal `TriageEngine` stub that lets a test control the exact thumbnail
/// bytes returned from `enrollmentThumbnail` (the sample engine reads a bundled
/// asset that isn't present in the unit-test host). Everything else is a no-op.
@MainActor
private final class ThumbnailStubEngine: TriageEngine {
    private let thumbnail: Data?
    private(set) var thumbnailRequests = 0
    private(set) var recordedEnrollments: [[URL]] = []

    init(thumbnail: Data?) {
        self.thumbnail = thumbnail
    }

    func enroll(referenceURLs: [URL]) async throws -> [FaceEmbedding] {
        recordedEnrollments.append(referenceURLs)
        return referenceURLs.enumerated().map { index, _ in FaceEmbedding([Float(index + 1)]) }
    }

    func enrollmentThumbnail(referenceURLs _: [URL]) async -> Data? {
        thumbnailRequests += 1
        return thumbnail
    }

    func scan(albums _: [URL]) -> AsyncStream<ScanProgress> {
        AsyncStream { $0.finish() }
    }

    func recordFeedback(photoKey _: String, label _: KiFinder.FeedbackLabel) async throws {}

    func selectFace(photoKey _: String, faceIndex _: Int) async throws -> FaceSelectionResult {
        FaceSelectionResult(score: 0, bucket: .other)
    }

    func rescoreAll(onlyPhotoKeys _: Set<String>?) async throws -> [String: RescoredPhoto] {
        [:]
    }

    func export(photoKeys: [String], destination _: ExportDestination) async throws -> Int {
        photoKeys.count
    }

    func export(fileURLs: [URL], destination _: ExportDestination) async throws -> Int {
        fileURLs.count
    }
}
