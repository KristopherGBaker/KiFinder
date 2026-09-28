# Multi-person enrollment: design

This feature lets the user enroll **multiple people**, give each a **name**, and see a **real
cropped-face thumbnail** for each. Scans find every enrolled person, and the sidebar, review,
scan, and export become person-aware. Everything stays on-device (no network). It builds on the
existing `KionEngine` package and the `TriageEngine` app seam.

## Confirmed decisions (locked with the user)
1. **Review model = per-person + switcher.** The sidebar lists every person. Selecting one makes
   them the *active person* and filters Review to their candidates. The toolbar reads
   "Review &lt;name&gt; candidates". Only one person is active at a time.
2. **Scan matches ALL enrolled people in one pass.** Each detected face is embedded **once** and
   scored against **every** enrolled person. Each candidate is attributed to its best-matching
   person, and per-person scores are kept.
3. **Name entry = inline in the enrollment sheet (required) + rename from the sidebar.**
4. **Bucket labels = person-agnostic.** "Found her" becomes **"Found matches"**. "Worth a look"
   and "The rest" stay. This removes the gendered assumption, and section headers don't
   interpolate a name.

## Architecture: where identity + thumbnails live

The engine's `ProfileStore` (`[subjectId: ProfileBundle]`) already stores **embeddings** for many
subjects, and it stays the engine's concern. **Do not** put names or thumbnails in the engine
package. A person's **name and thumbnail belong to the app layer**, owned by
`ProfileRepository`.

- **`Person`** (new, app-level): `{ id: String, displayName: String, thumbnailFileName: String?,
  createdAt: Date }`. `id` is the `subjectId` used everywhere in the engine. New people get a
  **UUID** `id`. A person migrated from a legacy single-subject store keeps that store's
  `subjectId` as their `id`, so its existing `ProfileStore` entry stays valid. `displayName` is
  **user data** and is never used as an accessibility identifier.
- **People roster** = a **versioned sidecar** `people-roster.json` next to the profile store
  (same directory as `storeURL`): `{ "schemaVersion": 2, "people": [Person...] }`. Thumbnails
  are cached as files in a `thumbnails/` subdir next to it (for example, `thumbnails/<id>.png`).
- **`ProfileStore` is untouched.** It is still the embedding store keyed by `subjectId`. The
  roster is the source of truth for *who exists*; `ProfileStore` is the source for *their
  embeddings*. A person is "enrolled" iff `ProfileStore` has a bundle for their `id`
  (references count > 0).

### Migration (safe, additive, versioned)
On the first `loadRoster()`:
- If `people-roster.json` exists and parses, return its people.
- Else, if the existing `ProfileStore` at `storeURL` has any profiles, synthesize a roster and
  write roster v2. Each existing `subjectId` becomes one
  `Person{ id: subjectId, displayName: subjectId, thumbnailFileName: nil }` (the legacy single
  subject becomes a person named after its id). **The existing enrollment is never dropped.**
- Else, return an empty roster.

The store JSON encoding stays `prettyPrinted + sortedKeys` (matching
`JSONEncoder.kionPersistence`).

## ProfileRepository API (expanded)
```swift
@MainActor protocol ProfileRepository: AnyObject {
    // roster (NEW)
    func loadRoster() -> [Person]              // migrates on first load
    func savePerson(_ person: Person) throws    // upsert name/thumbnail ref
    func deletePerson(id: String) throws        // remove roster entry + bundle + thumbnail
    // embeddings (existing)
    func loadProfile(subjectId: String) -> ProfileBundle?
    func saveProfile(_ bundle: ProfileBundle) throws
    func reset()
    // thumbnails (NEW; bytes written by the engine crop in item 2)
    func thumbnailURL(for id: String) -> URL?
    func saveThumbnail(_ pngData: Data, for id: String) throws -> URL
}
```

## AppModel (multi-person state)
- Remove the hard single-subject `static let activeSubjectID`. Add
  `private(set) var people: [Person]` and `var activePersonID: String?` (the selected person).
- `enrolledProfile`/`enrolledReferenceCount` derive from the **active** person.
- `addPerson(name:)`, `selectPerson(id:)`, `renamePerson(id:to:)`, `deletePerson(id:)`.
- **Backward-compat through item 1:** after migration, the only person is the migrated legacy
  subject, and it is the default active person, so the single-person UI still shows that name.
  UI strings don't change until items 3 and 4, and existing tests stay green at item 1.

## Engine multi-subject matching + thumbnails (item 2)
- **Scan all in one pass.** The scan path embeds each detected face once and scores it against
  **every** enrolled `ProfileBundle`. `BestFace.subjectResults` gets one entry **per person**.
  `LiveTriageEngine`/`ScanPipeline` take the **set** of enrolled profiles, not one.
- **Candidate attribution.** `Candidate` gains `matchedSubjectID: String?` (the best-matching
  person) and `subjectScores: [String: Double]` (per-person scores). `bucket` reflects the best
  match. `score` and `formattedScore` (`%.2f`) stay **unchanged**.
- **Face-crop thumbnail.** Reuse existing detection: take the best reference photo's
  `QualityMetrics.faceBoundingBox`, crop that rect from the original via ImageIO, downsample
  (~256px, adapting the `CandidateImage.downsample` logic to a `CGImage`/rect), and return **PNG
  `Data`**. `enroll(...)` returns embeddings **and** an optional thumbnail, and the app saves it
  via `repository.saveThumbnail`. On-device only.
- **SampleTriageEngine** grows to **≥2 deterministic people** (for example, "Kris" and "Ava",
  demo names for sample mode). Each has fixed embeddings and a bundled non-face placeholder image
  as its thumbnail (a real image, no network). Candidates are split across the two, so the
  sample/test path exercises multi-person. Determinism is preserved.

## UI (items 3 and 4)
- **Enrollment (item 3):** a required inline **name** `TextField` (a11y id `enroll-name-field`),
  real cropped-face thumbnails in the filmstrip and `ReferencePreview` (the placeholder icon is
  only a fallback before a crop exists), and person-agnostic copy. Users can add more people
  across sessions.
- **Sidebar (item 4):** a **List of people**. Each row shows a thumbnail (or an initials
  fallback), the name, and the reference count. Selecting a row makes that person active. Actions:
  **+ Add person**, **Re-enroll**, **Rename**, **Delete**. Stable a11y ids: `person-row-<id>`,
  `add-person`, `rename-person`, `delete-person` (NOT derived from the name).
- **Review/Scan/Export (item 4):** toolbar "Review &lt;name&gt; candidates", empty state
  "Scan an album to find &lt;name&gt;", person-agnostic buckets, and candidate sets filtered to
  the active person. ScanSheet and ExportSummary become person-aware.

## Accessibility identifiers (stable, name- & locale-independent)
Replace every name-derived id with a stable English literal or a person `id`:
- `accessibilityIdentifier("<name>")` (sidebar name) → `person-row-<id>` (or `person-name`).
- `accessibilityIdentifier("Enroll <name>")` (sheet) → `enroll-title`.
- `accessibilityIdentifier("Review <name> candidates")` (toolbar) → `review-title`.

UI tests query these stable ids. Visible text is asserted separately and updated in item 5.

## Localization (item 5)
- Parameterized name keys in **en + ja**, with the name **untranslated**: `Enroll %@`,
  `Review %@ candidates`, `Scan an album to find %@`, `Teach %@'s face to your Mac.`,
  the "Add 5 to 12 reference photos of %@" prompt, `Enrolling %@…`, `Ready to enroll %@.`,
  `%@ enrolled, %lld references` (plural), the scan "matched against %@" line, and de-gendered
  age-spread and crop copy. Drop the stale hard-coded single-name keys once nothing references
  them. ja uses `%1$@`/positional args as needed.
- Keep **en byte-identical** for any string a test still asserts. Keep `formattedScore` `%.2f`.

## Verification (per item)
Each item must pass:
- `xcodegen generate` (only if `project.yml` changed; it shouldn't need to),
- `xcodebuild build -scheme KiFinder -destination 'platform=macOS'` → succeeds,
- the **unit** test target (`swift test` for `KionEngine`; the `KiFinderTests` unit target) →
  green. **UI (XCUITest) runs are out of scope for now.** Item 5 updates the XCUITest text and
  adds multi-person coverage, but those tests are run manually.

Each item includes the unit-test updates it requires, so the unit suite stays green after every
item.
