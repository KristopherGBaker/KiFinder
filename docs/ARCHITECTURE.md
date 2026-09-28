# Architecture

KiFinder is two layers: a platform-agnostic **engine** that does the face matching, and a
**macOS app** that wraps it in a calm, keyboard-first review UI. A small CLI exposes the
engine headlessly. Everything runs on-device; there is no network code.

```
┌─────────────────────────────────────────────┐
│ KiFinder (SwiftUI macOS app)              │  Enroll · Scan · Review · Export
│   LiveTriageEngine  ──┐                      │
│   SampleTriageEngine  │ (previews / UI tests)│
└───────────────────────┼──────────────────────┘
                        │ depends on
┌───────────────────────▼──────────────────────┐
│ KionEngine (Swift package, no UI)            │  detect → align → embed → match
│   FaceEmbedder · ScanPipeline · FaceMatcher  │
│   ProfileStore · Manifest · Models           │
│   KionORTShim → ONNX Runtime (ArcFace)       │
└──────────────────────────────────────────────┘
        ▲
        │ also driven headlessly by
   KionCLI (enroll / scan / feedback / rescore)
```

## The matching pipeline

For each photo, the engine runs the same sequence (`Sources/KionEngine/`):

1. **Decode** the image (`ScanPipeline`, ImageIO). Albums are a folder or a `.zip`;
   `.zip`s are extracted to a temp/cache dir and walked recursively. HEIC / JPEG / PNG.
2. **Detect & align** the face (`FaceEmbedder.alignedFace`), with graceful fallback:
   - **Vision** — `VNDetectFaceRectangles` + `VNDetectFaceLandmarks` (primary).
   - **Core Image** — `CIDetector` with eye/mouth positions (fallback).
   - **Heuristic** — fixed canonical landmarks on a non-blank image (last resort; this
     path yields no real bounding box).
3. **Warp** to a 112×112 chip using a 5-point affine transform (eyes, nose, mouth corners)
   onto ArcFace's canonical landmark positions.
4. **Embed** the chip through the **ArcFace ResNet-100 ONNX** model via ONNX Runtime,
   producing a **512-dimension** face embedding. (The model is fed raw planar RGB in
   `[0,255]` — see the note in `FaceEmbedder.rgbInputTensor`.)
5. **Match** against the enrolled profile (`FaceMatcher`): cosine similarity to the
   reference embeddings (max-similarity), adjusted by a margin against any **negatives**,
   then bucketed by the profile's `threshold` / `maybeMargin` into **keep / maybe / no**.

A **quality gate** (min detection score / bounding-box area) drops low-confidence faces
before scoring.

## Detection geometry

The detector reports each matched face's rectangle, normalized (`0…1`, top-left origin) in
the image's **raw, un-oriented** pixel space. It rides along on `QualityMetrics`
(`faceBoundingBox`) → the manifest → `Candidate`, and the lightbox maps it onto the
displayed (EXIF-oriented) photo to draw the amber overlay. No detected face → no overlay.

## Profiles & feedback

- A **`ProfileBundle`** holds a subject's reference embeddings, confirmed positives,
  negatives, and thresholds. Enrollment embeds the reference photos and appends them; the
  reference set is the stable core.
- **Feedback** (`confirm` / `reject`) appends to positives/negatives and **rescores from the
  stored embeddings** — no re-embedding. This mirrors the semantics of the project's
  original Python prototype: feedback only ever changes the *decision boundary*, never
  the vectors already on disk.
- **`ProfileStore`** persists all subjects' bundles as JSON.

## Persistence & model versioning

- The **`Manifest`** caches one `BestFace` (embedding + quality metrics + per-subject
  results) per photo path, so re-scanning an album reuses embeddings.
- Both the store and manifest are **stamped with the model id/version**; a mismatch forces
  re-embedding (and surfaces as `ModelVersionMismatchError`), so embeddings are never mixed
  across models.

## ONNX Runtime integration

`KionEngine` links a vendored ONNX Runtime: the **`OnnxRuntime.xcframework`** (`Vendor/`)
plus a bundled `libonnxruntime…dylib` resource, bridged through the C shim **`KionORTShim`**
(`KionORTCreate` / `KionORTRun` / `KionORTDestroy`). The shim keeps the Swift side free of
ORT headers. CoreML execution is enabled via a prepared temp dir.

The model file itself is **not** in the repo; it's resolved from `KION_MODEL_PATH` or
`~/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx` (see the README).

## App layer

- **`LiveTriageEngine`** (`KiFinder/Engine/`) is the real, on-device `TriageEngine`: it
  wraps `KionEngine`, streams live per-photo scan progress, records feedback, and copies
  kept files on export (folder or Photos add-only, originals untouched).
- **`SampleTriageEngine`** provides deterministic fixture data so SwiftUI previews and UI
  tests run without a model or real photos.
- The UI follows `DESIGN.md`: `NavigationSplitView` + a trailing `.inspector` lightbox, real
  `LazyVGrid` tiles, and keyboard-first culling (Space = Keep, Delete = Skip, ←/→). The
  buckets surface as **Found matches** / **Worth a look** / **The rest**.

## Where to look in the code

| Concern | Start here |
|---------|-----------|
| Detect / align / embed | `Sources/KionEngine/FaceEmbedder.swift` |
| Album scan & manifest | `Sources/KionEngine/ScanPipeline.swift` |
| Scoring, buckets, feedback | `Sources/KionEngine/FaceMatcher.swift` |
| Data model & JSON persistence | `Sources/KionEngine/Models.swift` |
| App ↔ engine boundary | `KiFinder/Engine/TriageEngine.swift`, `LiveTriageEngine.swift` |
| Review UI & lightbox | `KiFinder/Review/` |
| Headless harness | `Sources/KionCLI/main.swift` |
