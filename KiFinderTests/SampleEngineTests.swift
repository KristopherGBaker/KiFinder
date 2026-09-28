import CoreGraphics
import Foundation
import ImageIO
@testable import KiFinder
import Testing

@Suite("Sample triage engine")
@MainActor
struct SampleEngineTests {
    @Test("Sample data covers keep and maybe buckets")
    func sampleCandidatesCoverReviewBuckets() {
        let engine = SampleTriageEngine()

        #expect(engine.candidates.count >= 2)
        #expect(engine.candidates.contains { $0.bucket == .keep })
        #expect(engine.candidates.contains { $0.bucket == .maybe })
    }

    @Test("Sample export(fileURLs:) returns the input count, 0 for empty (item 28)")
    func sampleExportFileURLsCount() async throws {
        let engine = SampleTriageEngine()
        let urls = (0 ..< 3).map { URL(fileURLWithPath: "/tmp/lib/IMG_\($0).jpg") }

        let count = try await engine.export(fileURLs: urls, destination: .photos)
        #expect(count == 3)

        let empty = try await engine.export(fileURLs: [], destination: .photos)
        #expect(empty == 0)
    }

    @Test("Sample feedback records caller-supplied keys and labels")
    func sampleEngineRecordsLog() async throws {
        let engine = SampleTriageEngine()

        try await engine.recordFeedback(photoKey: "a", label: .confirm)
        try await engine.recordFeedback(photoKey: "b", label: .reject)

        #expect(engine.recordedFeedback.count == 2)
        #expect(engine.recordedFeedback[0].0 == "a")
        #expect(engine.recordedFeedback[1].0 == "b")
        #expect(engine.recordedFeedback[1].1 == .reject)
    }

    // MARK: - Manual face region (item 19, assertion 2)

    @Test("Sample addManualFace appends deterministically; a degenerate rect returns nil")
    func sampleAddManualFaceDeterministic() async throws {
        let engine = SampleTriageEngine()
        // The sample candidate "sample-keep-1" carries two detected faces, so a manual
        // face appends at index 2 with the deterministic keep score/bucket.
        let keep = try #require(engine.candidates.first { $0.id == "sample-keep-1" })
        let result = try #require(
            await engine.addManualFace(photoKey: keep.photoKey, normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        )
        #expect(result.faceIndex == keep.faceBoxes.count) // appended at the new last index
        #expect(result.bucket == .keep)
        #expect(abs(result.score - SampleTriageEngine.manualFaceScore) < 1e-9)

        // A degenerate rect returns nil (no result), mirroring the Live nil-guard.
        let degenerate = try await engine.addManualFace(
            photoKey: keep.photoKey, normalizedRect: CGRect(x: 0.4, y: 0.4, width: 0, height: 0)
        )
        #expect(degenerate == nil)
    }

    @Test("App model consumes sample scan stream")
    func appModelConsumesStream() async {
        // Reset an isolated store so no person is active: with the `nil`-active
        // fallback Review shows every candidate, so both people's sample candidates
        // are visible here (deterministic regardless of the host machine's roster).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-sample-stream")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: [
                "KION_PROFILE_STORE": dir.appendingPathComponent("store.json").path,
                "KION_RESET": "1",
            ]
        )

        await model.runScan(albums: [URL(fileURLWithPath: "/tmp", isDirectory: true)])

        #expect(model.keepCandidates == ["sample-keep-1", "sample-keep-2"])
        // Item 6 added the both-people group photo (a maybe for both), so the
        // nil-active "show all" maybe bucket now carries it too.
        #expect(model.maybeCandidates == ["sample-maybe-1", "sample-maybe-2", "sample-both-1"])
    }

    // MARK: - Multi-person attribution (assertion 7)

    @Test("Every sample candidate is attributed and carries per-person scores")
    func candidatesCarryAttributionAndScores() throws {
        let engine = SampleTriageEngine()

        for candidate in engine.candidates {
            // Attributed to a real person…
            let matched = try #require(candidate.matchedSubjectID)
            // …with a per-person score for that person…
            #expect(candidate.subjectScores[matched] != nil)
            // …and at least one more person scored (spanning both people).
            #expect(candidate.subjectScores.count >= 2)
            // The attributed person's score is the candidate's headline score.
            #expect(candidate.subjectScores[matched] == candidate.score)
        }
    }

    @Test("Sample candidates represent at least two distinct people")
    func candidatesSpanTwoPeople() {
        let engine = SampleTriageEngine()
        let people = Set(engine.candidates.compactMap(\.matchedSubjectID))
        #expect(people.count >= 2)
        #expect(people.contains(SampleTriageEngine.primarySubjectID))
        #expect(people.contains(SampleTriageEngine.secondarySubjectID))
    }

    @Test("enrollmentThumbnail returns non-nil decodable PNG data")
    func enrollmentThumbnailIsDecodablePNG() async throws {
        let engine = SampleTriageEngine()

        let data = try #require(await engine.enrollmentThumbnail(referenceURLs: []))
        #expect(!data.isEmpty)
        // Decodes as a PNG with sane pixel bounds (~256px max edge).
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source))
        #expect((type as String) == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 0)
        #expect(image.height > 0)
        #expect(max(image.width, image.height) <= 256)
    }

    // MARK: - Sample-mode seeding (assertion 6)

    @Test("Sample mode seeds BOTH people with Kris active")
    func sampleModeSeedsBothPeople() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-sample-seed")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("store.json")

        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_PROFILE_STORE": store.path, "KION_SAMPLE": "1"]
        )

        #expect(model.people.contains { $0.id == SampleTriageEngine.primarySubjectID })
        #expect(model.people.contains { $0.id == SampleTriageEngine.secondarySubjectID })
        #expect(model.people.count >= 2)
        // Default active person stays Kris. Item 4 added per-person filtering, so
        // Review now shows only the active person's (Kris's) candidates — one keep
        // and one maybe — not the full two-person set (which was the pre-filter
        // assertion). The other person's candidates surface when Ava is selected,
        // covered by AppModelReviewFilteringTests.
        #expect(model.activePersonID == SampleTriageEngine.primarySubjectID)
        #expect(model.keepCandidates == ["sample-keep-1"])
        // Item 6: the both-people group photo (a maybe for Kris AND Ava) now also
        // surfaces in Kris's "Worth a look" — a photo shows under every person it
        // matched, in that person's own bucket.
        #expect(model.maybeCandidates == ["sample-maybe-1", "sample-both-1"])
    }
}
