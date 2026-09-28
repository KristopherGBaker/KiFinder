# KiFinder

A quiet, privacy-first macOS app for sorting photos of **one person you enroll** out of
large, messy albums — fully on-device. It's built for finding a specific person (your child,
a friend, yourself) across a loose dump of photos. Teach it a face once from a few reference
photos, drop in a folder or `.zip`, watch a local scan, then **cull with the keyboard**
(Keep / Skip) and export the keepers. Your photos and face data never leave your Mac: all
detection, matching, and export run on-device, with no account and no telemetry. The only
network use is a one-time download of the face-model weights from their documented upstream
sources (see [Models](#models)).

It's the *pre-Photos triage gate*: filter a loose dump (SD card, shared zip, AirDrop folder)
you haven't imported yet, then promote the keepers into Photos.

## How it works

1. **Enroll** — pick a few reference photos of the person. The engine detects, aligns,
   and embeds each face into a profile stored locally.
2. **Scan an album** — drop a folder or `.zip` (HEIC / JPEG / PNG, nested folders walked
   recursively). Each photo is embedded and matched against the profile on-device.
3. **Review** — candidates land in **Found matches**, **Worth a look**, and **The rest**. Cull
   keyboard-first: **←/→** to move, **Return** = Keep, **Delete** = Skip, **Space** = full-size
   preview. The lightbox draws an amber box over the actual detected face and shows the match
   confidence.
4. **Export** — a straight **byte-for-byte copy** of the originals (format + metadata
   preserved, no re-encode) to a chosen folder or the Photos app. **Originals are never
   modified.**

In sample mode the people shown (Kris and Ava) are demo names, not real users.

## Requirements

- macOS 15+ (built for macOS 26 "Tahoe"; Liquid Glass used on the control layer where
  available), Apple silicon
- Xcode 26 / Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the
  `.xcodeproj` is generated, not committed
- Face-embedding model weights are **not** in the repo (see [Models](#models))

## Distribution & signing

This is a **source-only** project. The author distributes **no binaries** — not on the App
Store, not as a downloadable build. You build and run it yourself from this source tree.

Because no team is pinned, a fresh checkout builds and runs **ad-hoc signed** by default
(`codesign -dv` reports `Signature=adhoc`, `TeamIdentifier=not set`), with the app sandbox
intact — every fork builds out of the box.

If you want a fully signed local build, supply your own team without touching the shared
`project.yml`. Create a gitignored `project.local.yml` at the repo root:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: YOURTEAMID
```

then regenerate with the include enabled:

```sh
KIFINDER_LOCAL_SPEC=true xcodegen generate
```

With `KIFINDER_LOCAL_SPEC` unset the local spec is ignored, so the shared project stays
team-free for everyone else.

## Build & run the app

```sh
./Scripts/bootstrap-vendor.sh     # fetch the gitignored ONNX Runtime (one-time per checkout)
./Scripts/bootstrap-fixtures.sh   # build the test album zip + fetch the model weights
xcodegen generate                 # produce KiFinder.xcodeproj from project.yml
open KiFinder.xcodeproj            # then Run (⌘R), or:
xcodebuild -scheme KiFinder -destination 'platform=macOS' build
```

> **Run `bootstrap-fixtures.sh` before trusting a green test run.** Two things a fresh clone
> lacks are gitignored and neither fails loudly: `sample_album.zip` (excluded by the `*.zip`
> rule that keeps real albums out of the repo — it's rebuilt from the committed `face_a.jpg`),
> and the ArcFace model. The model's absence is the dangerous one: every model-gated test
> **silently skips**, so `swift test` reports green while the embedding tests never run at all.
> The script is idempotent and sha256-verifies each model; `--skip-model` builds only the zip.

> **First-time setup:** the ONNX Runtime (`Vendor/OnnxRuntime.xcframework` + the `KionONNXEmbedder`
> resource dylib, ~114 MB) is gitignored, so a fresh clone runs `Scripts/bootstrap-vendor.sh`
> once — it downloads the pinned, sha256-verified upstream release and reconstructs both.

## The engine, headless (`KionCLI`)

The matching logic lives in a platform-agnostic Swift package (`KionEngine`) with a small
CLI for enroll / scan / feedback — handy for testing the pipeline without the UI:

```sh
export KION_MODEL_PATH="$HOME/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx"

swift run KionCLI enroll ref1.jpg ref2.jpg --subject person --store store.json
swift run KionCLI scan ./album --subject person --store store.json --manifest manifest.json
swift run KionCLI feedback confirm --photo <key> --store store.json --manifest manifest.json
```

## Models

KiFinder matches faces with a swappable embedding backend (selectable in onboarding and
Settings). **No model weights live in this repository.** The two downloadable backends
(ArcFace and AdaFace) fetch their weights from upstream into a local cache at
`"$HOME/Library/Application Support/KiFinder/models"` (or the app's sandbox container);
`Scripts/bootstrap-fixtures.sh` does this for the test suite. The third backend, Apple Vision
FeaturePrint, ships with macOS and downloads nothing.
Full license details are in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

- **ArcFace `arcfaceresnet100-8`** (ONNX) — downloaded from the ONNX Model Zoo mirror at
  https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8, Apache-2.0-tagged. Installed to
  `"$HOME/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx"`.
  **Caveat:** its weights are trained on the **withdrawn MS-Celeb-1M** dataset — fine for
  personal use, but review the dataset's status before any other use.
- **AdaFace IR-18** (CoreML) — downloaded from
  https://github.com/john-rocky/CoreML-Models (release `adaface-v1`), MIT, conforming to the
  original https://github.com/mk-minchul/AdaFace (MIT). Compiled and installed into the same
  models cache.
- **Apple Vision FeaturePrint** — Apple's **Vision** system framework. It ships with macOS:
  there is **no download and no weights** — nothing to install.

The models are provided for **personal / research use only**; check each model's license
before any other use.

To install ArcFace by hand instead of via the script:

```sh
mkdir -p "$HOME/Library/Application Support/KiFinder/models"
cp arcfaceresnet100-8.onnx "$HOME/Library/Application Support/KiFinder/models/"
# or set KION_MODEL_PATH to any location
```

## Tests

```sh
swift test                                                       # engine unit tests
xcodebuild test -scheme KiFinder -destination 'platform=macOS'   # app unit + UI tests
```

## Repository layout

| Path | What it is |
|------|------------|
| `KiFinder/` | The SwiftUI macOS app (enrollment, scan, review, export) |
| `Sources/KionEngine/` | Platform-agnostic matching engine (detect → align → embed → match) |
| `Sources/KionONNXEmbedder/`, `Sources/KionVisionEmbedder/`, `Sources/KionCoreMLEmbedder/` | The three face-embedding backends (ArcFace ONNX, Apple Vision, AdaFace CoreML) |
| `Sources/KionCLI/` | Headless harness for the engine |
| `Tests/`, `KiFinderTests/`, `KiFinderUITests/` | Engine, app unit, and UI tests |
| `Vendor/`, `Sources/KionORTShim/` | Bundled ONNX Runtime xcframework + C shim |
| `project.yml` | XcodeGen project definition |

## Learn more

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — the engine pipeline and how the pieces fit
- **[PRODUCT.md](PRODUCT.md)** — product vision and constraints
- **[DESIGN.md](DESIGN.md)** — UI design: layout, tokens, keyboard model, accessibility
- **[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)** — third-party licenses and model provenance

## Naming lineage

The app is **KiFinder**, the engine package is **KionEngine**, and environment
variables use the `KION_` prefix — those prefixes are an internal code name kept for
continuity.

## License

KiFinder is free software: you can redistribute it and/or modify it under the terms of the
**GNU General Public License** as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
the [`LICENSE`](LICENSE) file (GPL-3.0-or-later) for the full text.

Copyright (C) 2026 Kristopher Baker

Third-party components and downloaded models carry their own licenses — see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
