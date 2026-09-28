# Multi-person enrollment — design (feature cycle)

Lets the user enroll **multiple people**, give each a **name**, and see a **real cropped-face
thumbnail** per person. Scans find each enrolled person; sidebar/review/scan/export become
person-aware. Everything stays on-device (no network). Built on the existing `KionEngine`
package and the `TriageEngine` app seam.

## Confirmed decisions (locked with the user)
1. **Review model = per-person + switcher.** The sidebar lists every person; selecting one
   makes them the *active person* and filters Review to that person's candidates. Toolbar reads
   "Review &lt;name&gt; candidates". One active person at a time.
2. **Scan matches ALL enrolled people in one pass.** Each detected face is embedded **once** and
   scored against **every** enrolled person; each candidate is attributed to its best-matching
   person (with per-person scores retained).
3. **Name entry = inline in the enrollment sheet (required) + rename from the sidebar.**
4. **Bucket labels = person-agnostic.** "Found her" → **"Found matches"**; "Worth a look" and
   "The rest" stay. Removes the gendered assumption; no name interpolation in section headers.

## Architecture: where identity + thumbnails live

The engine's `ProfileStore` (`[subjectId: ProfileBundle]`) already stores **embeddings** for many
subjects and stays the engine's concern — **do not** put names/thumbnails in the engine package.
A person's **name and thumbnail are an app-layer concern**, owned by `ProfileRepository`.

- **`Person`** (new, app-level): `{ id: String, displayName: String, thumbnailFileName: String?,
  createdAt: Date }`. `id` is the `subjectId` used everywhere in the engine. New people get a
  **UUID** `id`; a person migrated from a legacy single-subject store keeps that store's
  `subjectId` as their `id` so its existing `ProfileStore` entry stays valid. `displayName` is **user data** — never used as an accessibility identifier.
- **People roster** = a **versioned sidecar** `people-roster.json` next to the profile store
  (same directory as `storeURL`), `{ "schemaVersion": 2, "people": [Person...] }`. Thumbnails are
  cached as files in a `thumbnails/` subdir next to it (e.g. `thumbnails/<id>.png`).
- **`ProfileStore` is untouched** — it remains the embedding store keyed by `subjectId`. The
  roster is the source of truth for *who exists*; `ProfileStore` for *their embeddings*. A person
  is "enrolled" iff `ProfileStore` has a bundle for their `id` (references count > 0).

### Migration (safe, additive, versioned)
On first `loadRoster()`:
- If `people-roster.json` exists & parses → return its people.
- Else if the existing `ProfileStore` at `storeURL` has any profiles → synthesize a roster: one
  `Person{ id: subjectId, displayName: subjectId, thumbnailFileName: nil }` per existing
  `subjectId` (the legacy single subject becomes a person named after its id), write roster v2.
  **Never drops the existing enrollment.**
- Else → empty roster.
The store JSON encoding stays `prettyPrinted + sortedKeys` (matches `JSONEncoder.kionPersistence`).

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
- Remove the hard `static let activeSubjectID` single-subject coupling. Introduce
  `private(set) var people: [Person]` and `var activePersonID: String?` (the selected person).
- `enrolledProfile`/`enrolledReferenceCount` derive from the **active** person.
- `addPerson(name:)`, `selectPerson(id:)`, `renamePerson(id:to:)`, `deletePerson(id:)`.
- **Backward-compat through item 1:** after migration the only person is the migrated legacy
  subject and is the default active person, so the single-person UI still renders that name.
  UI strings don't change until items 3–4; existing tests stay green at item 1.

## Engine multi-subject matching + thumbnails (item 2)
- **Scan all in one pass.** The scan path embeds each detected face once and scores it against
  **every** enrolled `ProfileBundle`; populate `BestFace.subjectResults` with an entry **per
  person**. `LiveTriageEngine`/`ScanPipeline` take the **set** of enrolled profiles, not one.
- **Candidate attribution.** `Candidate` gains `matchedSubjectID: String?` (best-matching person)
  and `subjectScores: [String: Double]` (per-person score). `bucket` reflects the best match.
  Keep `score`, `formattedScore` (`%.2f`) **unchanged**.
- **Face-crop thumbnail.** Reuse existing detection: take the best reference photo's
  `QualityMetrics.faceBoundingBox`, crop that rect from the original via ImageIO, downsample
  (~256px, reuse `CandidateImage.downsample` logic adapted to a `CGImage`/rect), return **PNG
  `Data`**. `enroll(...)` returns embeddings **and** an optional thumbnail; the app saves it via
  `repository.saveThumbnail`. On-device only.
- **SampleTriageEngine** is extended to **≥2 deterministic people** (e.g. "Kris" + "Ava" — demo
  names for sample mode) with
  fixed embeddings, a bundled non-face placeholder image as each person's thumbnail (real image,
  no network), and candidates attributed across the two so the sample/test path exercises
  multi-person. Determinism preserved.

## UI (items 3–4)
- **Enrollment (item 3):** required inline **name** `TextField` (a11y id `enroll-name-field`),
  real cropped-face thumbnails in the filmstrip + `ReferencePreview` (placeholder icon only as a
  fallback before a crop exists), person-agnostic copy. Can add multiple people across sessions.
- **Sidebar (item 4):** a **List of people** — each row: thumbnail (or initials fallback) +
  name + reference count; select to make active; **+ Add person**, **Re-enroll**, **Rename**,
  **Delete**. Stable a11y ids: `person-row-<id>`, `add-person`, `rename-person`, `delete-person`
  (NOT derived from the name).
- **Review/Scan/Export (item 4):** toolbar "Review &lt;name&gt; candidates", empty state
  "Scan an album to find &lt;name&gt;", buckets person-agnostic, candidate sets filtered to the
  active person; ScanSheet + ExportSummary person-aware.

## Accessibility identifiers (stable, name- & locale-independent)
Replace every name-derived id with a stable English literal or a person `id`:
- `accessibilityIdentifier("<name>")` (sidebar name) → `person-row-<id>` (or `person-name`).
- `accessibilityIdentifier("Enroll <name>")` (sheet) → `enroll-title`.
- `accessibilityIdentifier("Review <name> candidates")` (toolbar) → `review-title`.
UI tests query these stable ids; visible text is asserted separately and updated in item 5.

## Localization (item 5)
- Parameterized name keys, **en + ja**, name **untranslated**: `Enroll %@`, `Review %@ candidates`,
  `Scan an album to find %@`, `Teach %@'s face to your Mac.`, `Add 5–12 reference photos of %@`,
  `Enrolling %@…`, `Ready to enroll %@.`, `%@ enrolled, %lld references` (plural), the scan
  "matched against %@" line, and de-gendered age-spread + crop copy. Drop the stale
  hard-coded-single-name keys once nothing references them. ja uses `%1$@`/positional args as needed.
- Keep **en byte-identical** for any string a test still asserts; keep `formattedScore` `%.2f`.

## Verification (per item)
Each item must pass:
- `xcodegen generate` (only if `project.yml` changed — it should not need to),
- `xcodebuild build -scheme KiFinder -destination 'platform=macOS'` → succeeds,
- the **unit** test target (`swift test` for `KionEngine`; the `KiFinderTests` unit target) →
  green. **UI (XCUITest) runs are out of scope for now** — item 5 updates the XCUITest text and
  adds multi-person coverage, but those are run manually.
Each item co-locates the unit-test updates it necessitates so the unit suite stays green per item.
