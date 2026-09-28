import Foundation
@testable import KiFinder
import KionEngine
import Observation
import Testing

/// Item 59 seam coverage: `AppModel` COMPOSES a separate `ReviewSession` — not an
/// `AppModel` extension, and not a duplicated copy of state. This suite proves:
///
/// 1. `model.review` is a genuine `ReviewSession` instance the app model owns.
/// 2. A review decision routed through the `AppModel` FACADE (`model.keep(_:)`, never
///    `model.review.keep(_:)` directly) is reflected in `ReviewSession`'s OWN state —
///    proving composition, not a second copy of the decision living on `AppModel`.
/// 3. Observing a forwarded computed property on the `@Observable` `AppModel`
///    (`model.keepCandidates`) still fires when the composed (also `@Observable`)
///    `ReviewSession` mutates its OWN storage — proving no `@ObservationIgnored`
///    severs the composed observation graph.
///
/// Uses `withObservationTracking`'s single-shot `onChange` — no `Task.yield()`
/// spin-polling: the mutation is a synchronous, same-actor call, so the change
/// notification fires deterministically before the confirmation block returns.
@Suite("ReviewSession composition (item 59)")
@MainActor
struct ReviewSessionCompositionTests {
    private func uniqueStore() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kion-reviewsession-composition-tests")
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    @Test("model.review is a distinct ReviewSession; a facade decision reflects in it, and observation propagates through the composed graph")
    func compositionAndObservationPropagation() async throws {
        let model = AppModel(
            engine: SampleTriageEngine(),
            environment: ["KION_SAMPLE": "1", "KION_PROFILE_STORE": uniqueStore().path]
        )

        // 1. Composed, not an extension: `review` is a genuine, separate `ReviewSession`
        // the app model owns — its own decision/focus/selection state is private to it,
        // not widened onto `AppModel` the way the cross-file library extensions were.
        let session: ReviewSession = model.review
        #expect(model.activePersonID == SampleTriageEngine.primarySubjectID)

        // Kris's own "Worth a look" candidate (per `AppModelMultiPersonTests`), still
        // undecided.
        let candidateID = "sample-maybe-1"
        #expect(model.state(for: candidateID) == .maybe)
        #expect(session.state(for: candidateID) == .maybe)
        #expect(!model.keepCandidates.contains(candidateID))

        // 3. Register observation on a forwarded computed property via the AppModel
        // facade, then route the decision through that SAME facade (2).
        try await confirmation { observedChange in
            withObservationTracking {
                _ = model.keepCandidates
            } onChange: {
                observedChange()
            }

            // Routed through AppModel, never `session.keep(_:)` directly.
            model.keep(try #require(model.candidate(for: candidateID)))
        }

        // 2. `ReviewSession`'s OWN state reflects the change — the decision landed on
        // the composed sub-model, not a second copy on `AppModel`.
        #expect(session.state(for: candidateID) == .keep)
        #expect(session.keepCandidates.contains(candidateID))
        // The AppModel facade reflects the SAME (single) source of truth.
        #expect(model.state(for: candidateID) == .keep)
        #expect(model.keepCandidates.contains(candidateID))
    }
}
