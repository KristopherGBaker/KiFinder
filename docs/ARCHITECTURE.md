# Architecture

KiFinder has two layers: a platform-agnostic **engine** that does the face matching, and a
**macOS app** that wraps it in a calm, keyboard-first review UI. A small CLI runs the engine
without the app. Everything runs on-device. The only network code is the one-time model
download during onboarding (`KiFinder/Onboarding/ModelDownloader.swift`).

```
KiFinder (SwiftUI macOS app)          Enroll · Scan · Review · Export
  LiveTriageEngine
  SampleTriageEngine (previews, UI tests)
        │ depends on
        ▼
KionEngine (Swift package, no UI)     detect → align → embed → match
  FaceAligner · ScanPipeline · FaceMatcher
  ProfileStore · Manifest · Models
  FaceEmbeddingProvider (protocol)
        ▲ implemented by
        │
  KionONNXEmbedder    ArcFace via ONNX Runtime (KionORTShim)
  KionCoreMLEmbedder  AdaFace IR-18 via CoreML
  KionVisionEmbedder  Apple Vision FeaturePrint

KionCLI (enroll / scan / feedback / rescore) drives the engine headlessly.
```

## The matching pipeline

The engine runs the same steps for each photo (`Sources/KionEngine/`):

1. **Decode** the image (`ScanPipeline`, ImageIO). An album is a folder or a `.zip`. A `.zip`
   is extracted to a temp/cache dir and walked recursively. Formats: HEIC, JPEG, PNG.
2. **Detect and align** the face (`FaceAligner.alignedFace`). Each method falls back to the
   next:
   - **Vision** (primary): `VNDetectFaceRectangles` + `VNDetectFaceLandmarks`.
   - **Core Image** (fallback): `CIDetector` with eye and mouth positions.
   - **Heuristic** (last resort): fixed canonical landmarks on a non-blank image. This path
     gives no real bounding box.
3. **Warp** to a 112×112 chip with a 5-point affine transform (eyes, nose, mouth corners)
   onto ArcFace's canonical landmark positions.
4. **Embed** the chip with the selected backend, any `FaceEmbeddingProvider`: ArcFace
   ResNet-100 (ONNX Runtime, 512 dimensions), AdaFace IR-18 (CoreML, 512 dimensions), or Apple
   Vision FeaturePrint. ArcFace takes raw planar RGB in `[0,255]` (see
   `FaceAligner.rgbInputTensor`).
5. **Match** against the enrolled profile (`FaceMatcher`). The score is the max cosine
   similarity to the reference embeddings, adjusted by a margin against any **negatives**. The
   profile's `threshold` and `maybeMargin` then sort it into **keep / maybe / no**.

A **quality gate** (minimum detection score and bounding-box area) drops low-confidence faces
before scoring.

## Detection geometry

The detector reports each matched face's rectangle, normalized (`0…1`, top-left origin) in the
image's **raw, un-oriented** pixel space. It travels on `QualityMetrics` (`faceBoundingBox`) →
the manifest → `Candidate`. The lightbox maps it onto the displayed (EXIF-oriented) photo to
draw the amber overlay. If no face is detected, there is no overlay.

## Profiles & feedback

- A **`ProfileBundle`** holds a subject's reference embeddings, confirmed positives,
  negatives, and thresholds. Enrollment embeds the reference photos and appends them. The
  reference set is the stable core.
- **Feedback** (`confirm` / `reject`) appends to positives or negatives and **rescores from
  the stored embeddings**, with no re-embedding. This matches the project's original Python
  prototype: feedback only changes the *decision boundary*, never the vectors on disk.
- **`ProfileStore`** saves every subject's bundle as JSON.

## Persistence & model versioning

- The **`Manifest`** caches one `BestFace` (embedding, quality metrics, and per-subject
  results) per photo path, so re-scanning an album reuses embeddings.
- The store and manifest are both **stamped with the model id and version**. A mismatch
  forces re-embedding (and surfaces as `ModelVersionMismatchError`), so embeddings from
  different models are never mixed.

## ONNX Runtime integration

`KionONNXEmbedder` (the ArcFace backend) links a vendored ONNX Runtime: **`OnnxRuntime.xcframework`** (`Vendor/`) plus a
bundled `libonnxruntime…dylib` resource. The C shim **`KionORTShim`** (`KionORTCreate` /
`KionORTRun` / `KionORTDestroy`) bridges to it and keeps ORT headers out of the Swift code. `KionEngine` itself has no ONNX dependency.
CoreML execution is enabled through a prepared temp dir.

The ArcFace model file is **not** in the repo. It is loaded from `KION_MODEL_PATH` or
`~/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx` (see the README).

## App layer

- **`LiveTriageEngine`** (`KiFinder/Engine/`) is the real, on-device `TriageEngine`. It wraps
  `KionEngine`, streams per-photo scan progress, records feedback, and copies kept files on
  export (to a folder, or add-only to Photos; originals are untouched).
- **`SampleTriageEngine`** supplies deterministic fixture data, so SwiftUI previews and UI
  tests run without a model or real photos.
- The UI follows `DESIGN.md`: `NavigationSplitView` with a trailing `.inspector` lightbox, real
  `LazyVGrid` tiles, and keyboard-first culling (←/→ to move, Return = Keep, Delete = Skip, Space = preview). The
  buckets appear as **Found matches** / **Worth a look** / **The rest**.

## Where to look in the code

| Concern | Start here |
|---------|-----------|
| Detect / align | `Sources/KionEngine/FaceAligner.swift` |
| Embedding backends | `Sources/KionONNXEmbedder/`, `Sources/KionCoreMLEmbedder/`, `Sources/KionVisionEmbedder/` |
| Album scan & manifest | `Sources/KionEngine/ScanPipeline.swift` |
| Scoring, buckets, feedback | `Sources/KionEngine/FaceMatcher.swift` |
| Data model & JSON persistence | `Sources/KionEngine/Models.swift` |
| App ↔ engine boundary | `KiFinder/Engine/TriageEngine.swift`, `LiveTriageEngine.swift` |
| Review UI & lightbox | `KiFinder/Review/` |
| Command-line tool | `Sources/KionCLI/main.swift` |
