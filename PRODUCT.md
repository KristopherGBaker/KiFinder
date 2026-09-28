# KiFinder — Product vision

> The whole-product picture: what KiFinder is for, what it promises, and what it deliberately
> doesn't do. `docs/ARCHITECTURE.md` describes the current structure; `DESIGN.md` is the UI
> source of truth.

## Intent

Make sorting "which of these 312 photos have this person in them" fast, calm, and fully private.
The user enrolls a person once from a few reference photos, drops an album (a folder or a zip),
watches a local scan, then **culls candidates with the keyboard** — Keep / Skip — improving the
match as they go, and exports the kept photos. Several people can be enrolled; review is always
scoped to the active person. Nothing about your photos or faces leaves the Mac.

## Constraints

- **Native & private.** All detection, matching, review, and export run on-device; no cloud
  account, no sync, no telemetry. "Everything stays on your Mac" is a product promise. The only
  network use is a one-time download of face-model weights from their documented upstream
  sources (see the README and `THIRD-PARTY-NOTICES.md`).
- **Native Mac structure** per `DESIGN.md`: `NavigationSplitView` + a trailing `.inspector`
  lightbox, real `List`/`LazyVGrid`/toolbar, **keyboard-first culling** (arrows to move, Return =
  Keep, Delete = Skip, Space = full-size preview). SwiftUI, Apple silicon, Liquid Glass on the
  floating control layer where available; respect Reduce Transparency/Motion.
- **Album input = folder OR .zip ONLY** (zips may contain nested folders → traversed recursively;
  dropped folders walk subdirectories; HEIC/JPEG/PNG). **Reading *from* the Photos library is a
  deliberate non-goal** — KiFinder is the **pre-Photos triage gatekeeper**: filter a loose dump
  (SD card, shared zip, AirDrop folder) you haven't imported, then **promote keepers into Photos**
  via export. Photos has its own People recognition; users who live entirely in Photos aren't the
  target.
- **Originals are never modified.** Export is a **straight byte-for-byte copy** (original format +
  metadata, no re-encode) to a **chosen folder** or the **Photos app** (add-only — an asset
  creation request from the original file). No format conversion. The enrolled reference set stays
  the stable core; feedback only appends.

## Matching & feedback

- **Detect & align**: find the face and its landmarks, then warp it to a canonical **112×112**
  chip with a 5-point affine transform. Alignment fidelity matters — a wrong warp quietly degrades
  matching.
- **Embed** the aligned chip with the selected backend and **match** against the person's
  profile: score = **max cosine similarity over references ∪ confirmed positives** (exemplars
  spanning ages and looks, not one centroid), with an optional margin against negatives, a
  **quality gate** (detection score + minimum box) before a face is folded in, and
  keep / maybe / no bucketing that surfaces as **Found matches**, **Worth a look**, and
  **The rest**.
- **Feedback teaches.** Keep appends a confirmed positive, Skip a negative; both are idempotent
  and never touch the references. The **manifest** stores each photo's subject-agnostic face
  embeddings once, so feedback and re-scoring are cheap math — no re-embedding — and re-scoring
  against another enrolled person needs no re-scan.
- **Profiles are keyed per person** and stamped with the model id/version; embeddings are
  model-specific, so a model mismatch forces re-embedding rather than mixing vectors.
- When the detector misses a face, the user can **draw the face region by hand** so it can still
  be matched and taught.

## Models

The embedding backend is **swappable and version-stamped**, selectable in onboarding and Settings:

- **ArcFace `arcfaceresnet100-8`** (ONNX, via ONNX Runtime) — 512-d, downloaded on first use.
- **AdaFace IR-18** (CoreML) — 512-d, downloaded on first use.
- **Apple Vision FeaturePrint** — built into macOS; nothing to download.

**License & provenance caveat.** The weights are not in this repository and are fetched from
upstream by each user. ArcFace's weights are trained on **MS-Celeb-1M, a withdrawn dataset** — a
concern its Apache-2.0 tag doesn't cover. The models are intended for personal / research use;
anyone building KiFinder should review each model's license and training-data provenance before
any other use. `THIRD-PARTY-NOTICES.md` has the details. Because the model is swappable and
stamped, moving to a model with cleaner provenance is cheap.

## Recognition reality

When the person is a young child, **adult-trained face-recognition models degrade** — both on
young children generally and across large age gaps. A bigger model raises the floor but doesn't
remove the domain mismatch. KiFinder works best on a **time-bounded album** where the person is
roughly one age, and it improves as confirmed positives spanning ages accumulate through feedback.
Match thresholds are model-specific; the Vision FeaturePrint and AdaFace calibrations are
untuned starting points (see `docs/future-work.md`).

## Non-goals

- **iOS app UI** — the engine is a platform-agnostic Swift package, but only macOS ships.
- **Cloud / accounts / sync** — local only.
- **Reading from the Photos library as a scan source** — input is folders/zips; export *to* Photos
  is supported.
- **Re-training / fine-tuning** a face model — stock models plus a decision rule on top.
- **Format conversion on export** — straight copy only.
