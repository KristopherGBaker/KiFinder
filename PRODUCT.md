# KiFinder: Product vision

> What KiFinder is for, what it promises, and what it deliberately doesn't do.
> `docs/ARCHITECTURE.md` describes the current structure. `DESIGN.md` is the UI source of truth.

## Intent

Make it fast, calm, and fully private to answer "which of these 312 photos have this person in
them?" You enroll a person once from a few reference photos, then drop an album (a folder or a
zip) and watch a local scan. Then you **cull candidates with the keyboard** (Keep or Skip), which
improves the match as you go, and export the kept photos. You can enroll several people. Review is
always scoped to the active person. Nothing about your photos or faces leaves the Mac.

## Constraints

- **Native and private.** Detection, matching, review, and export all run on-device. There is no
  cloud account, no sync, and no telemetry. "Everything stays on your Mac" is a product promise.
  The only network use is a one-time download of face-model weights from their documented
  upstream sources (see the README and `THIRD-PARTY-NOTICES.md`).
- **Native Mac structure**, per `DESIGN.md`: `NavigationSplitView` with a trailing `.inspector`
  lightbox, and a real `List`, `LazyVGrid`, and toolbar. Culling is **keyboard-first**: arrows
  move, Return = Keep, Delete = Skip, Space = full-size preview. Built with SwiftUI for Apple
  silicon, with Liquid Glass on the floating control layer where available. Reduce Transparency
  and Reduce Motion are respected.
- **Album input is a folder OR a .zip ONLY.** Zips may contain nested folders, which are traversed
  recursively. Dropped folders walk their subdirectories. Supported formats are HEIC, JPEG, and
  PNG. **Reading *from* the Photos library is a deliberate non-goal.** KiFinder is the
  **pre-Photos triage gatekeeper**: filter a loose dump you haven't imported yet (an SD card, a
  shared zip, an AirDrop folder), then **promote the keepers into Photos** via export. Photos has
  its own People recognition, so users who live entirely in Photos aren't the target.
- **Originals are never modified.** Export is a **straight byte-for-byte copy** (original format
  and metadata, no re-encode) to a **chosen folder** or the **Photos app**. Photos export is
  add-only: an asset creation request from the original file. There is no format conversion. The
  enrolled reference set stays the stable core; feedback only appends to it.

## Matching and feedback

- **Detect and align.** Find the face and its landmarks, then warp it to a canonical **112×112**
  chip with a 5-point affine transform. Alignment fidelity matters: a wrong warp quietly degrades
  matching.
- **Embed and match.** Embed the aligned chip with the selected backend and match it against the
  person's profile. The score is the **max cosine similarity over references ∪ confirmed
  positives** (exemplars spanning ages and looks, not one centroid). There is an optional margin
  against negatives. A **quality gate** (detection score plus minimum box size) runs before a face
  is folded in. Keep / maybe / no bucketing surfaces as **Found matches**, **Worth a look**, and
  **The rest**.
- **Feedback teaches.** Keep appends a confirmed positive; Skip appends a negative. Both are
  idempotent and never touch the references. The **manifest** stores each photo's
  subject-agnostic face embeddings once. That makes feedback and re-scoring cheap math with no
  re-embedding, and re-scoring against another enrolled person needs no re-scan.
- **Profiles are keyed per person** and stamped with the model id and version. Embeddings are
  model-specific, so a model mismatch forces re-embedding instead of mixing vectors.
- When the detector misses a face, the user can **draw the face region by hand** so it can still
  be matched and taught.

## Models

The embedding backend is **swappable and version-stamped**. You pick it in onboarding and
Settings:

- **ArcFace `arcfaceresnet100-8`** (ONNX, via ONNX Runtime): 512-d, downloaded on first use.
- **AdaFace IR-18** (CoreML): 512-d, downloaded on first use.
- **Apple Vision FeaturePrint**: built into macOS, nothing to download.

**License and provenance caveat.** The weights are not in this repository. Each user fetches them
from upstream. ArcFace's weights are trained on **MS-Celeb-1M, a withdrawn dataset**, a concern
its Apache-2.0 tag doesn't cover. The models are intended for personal or research use. Anyone
building KiFinder should review each model's license and training-data provenance before any
other use. `THIRD-PARTY-NOTICES.md` has the details. Because the model is swappable and stamped,
moving to a model with cleaner provenance is cheap.

## Recognition reality

When the person is a young child, **adult-trained face-recognition models degrade**, both on
young children in general and across large age gaps. A bigger model raises the floor but doesn't
remove the domain mismatch. KiFinder works best on a **time-bounded album** where the person is
roughly one age. It improves as feedback adds confirmed positives that span ages. Match
thresholds are model-specific. The Vision FeaturePrint and AdaFace calibrations are untuned
starting points (see `docs/future-work.md`).

## Non-goals

- **iOS app UI.** The engine is a platform-agnostic Swift package, but only macOS ships.
- **Cloud, accounts, or sync.** Local only.
- **Reading from the Photos library as a scan source.** Input is folders and zips. Export *to*
  Photos is supported.
- **Re-training or fine-tuning** a face model. KiFinder uses stock models plus a decision rule on
  top.
- **Format conversion on export.** Straight copy only.
