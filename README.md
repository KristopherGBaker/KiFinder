# KiFinder

KiFinder is a privacy-first macOS app that finds photos of one person in large, messy albums.
Teach it a face from a few reference photos, drop in a folder or `.zip`, then keep or skip the
matches with the keyboard and export the keepers.

Everything runs on your Mac. Detection, matching, and export happen on-device, with no account
and no telemetry. The only network use is a one-time download of the face-model weights (see
[Models](#models)).

Use it before you import into Photos: filter a loose dump of photos (an SD card, a shared zip,
an AirDrop folder), then send the keepers to Photos.

## How it works

1. **Enroll.** Pick a few reference photos of the person. KiFinder detects, aligns, and embeds
   each face into a profile stored on your Mac.
2. **Scan.** Drop a folder or `.zip` of HEIC, JPEG, or PNG files. Nested folders are scanned
   too. Each photo is matched against the profile on-device.
3. **Review.** Photos are sorted into **Found matches**, **Worth a look**, and **The rest**.
   Use **←/→** to move, **Return** to keep, **Delete** to skip, and **Space** to preview. The
   preview outlines the detected face and shows the match confidence.
4. **Export.** Kept photos are copied byte for byte, with their original format and metadata,
   to a folder or to Photos. Your originals are never changed.

In sample mode, the people shown (Kris and Ava) are demo names.

## Requirements

- macOS 15 or later on Apple silicon (built for macOS 26; uses Liquid Glass where available)
- Xcode 26 and Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
  `.xcodeproj` is generated, not committed.
- Face-model weights, which are downloaded separately (see [Models](#models))

## Distribution and signing

KiFinder is source only. There are no prebuilt binaries and no App Store release. You build
and run it yourself.

No development team is pinned, so a fresh checkout builds ad-hoc signed with the app sandbox
intact. `codesign -dv` reports `Signature=adhoc` and `TeamIdentifier=not set`.

To sign with your own team, create a `project.local.yml` at the repo root (it's gitignored):

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: YOURTEAMID
```

Then generate the project with it enabled:

```sh
KIFINDER_LOCAL_SPEC=true xcodegen generate
```

Without `KIFINDER_LOCAL_SPEC`, the local file is ignored and the shared project stays
team-free.

## Build and run

```sh
./Scripts/bootstrap-vendor.sh     # download ONNX Runtime (once per checkout)
./Scripts/bootstrap-fixtures.sh   # build the test album and download the model weights
xcodegen generate                 # create KiFinder.xcodeproj from project.yml
open KiFinder.xcodeproj            # then Run (⌘R), or:
xcodebuild -scheme KiFinder -destination 'platform=macOS' build
```

> **Run `bootstrap-fixtures.sh` before you trust a passing test run.** A fresh clone is
> missing two gitignored files: `sample_album.zip` (rebuilt from `face_a.jpg`) and the ArcFace
> model. Without the model, model-dependent tests are skipped silently, so `swift test` can pass
> without testing any embeddings. The script is safe to rerun and checks each model's SHA-256.
> Use `--skip-model` to build only the zip.

> **ONNX Runtime:** `Vendor/OnnxRuntime.xcframework` and the `KionONNXEmbedder` dylib (about
> 114 MB) are gitignored. `Scripts/bootstrap-vendor.sh` downloads the pinned, SHA-256-verified
> release and sets up both.

## Command-line engine (`KionCLI`)

The matching logic lives in a platform-independent Swift package, `KionEngine`. A small CLI
lets you enroll, scan, and give feedback without the app:

```sh
export KION_MODEL_PATH="$HOME/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx"

swift run KionCLI enroll ref1.jpg ref2.jpg --subject person --store store.json
swift run KionCLI scan ./album --subject person --store store.json --manifest manifest.json
swift run KionCLI feedback confirm --photo <key> --store store.json --manifest manifest.json
```

## Models

KiFinder supports three face-matching backends, selectable during onboarding and in Settings.
**No model weights are stored in this repository.** ArcFace and AdaFace download their weights
into `"$HOME/Library/Application Support/KiFinder/models"` (or the app's sandbox container).
`Scripts/bootstrap-fixtures.sh` does the same for the tests. Apple Vision needs no download.
See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for full license details.

- **ArcFace `arcfaceresnet100-8`** (ONNX), Apache-2.0 tagged, from the ONNX Model Zoo mirror at
  https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8. Installed as
  `"$HOME/Library/Application Support/KiFinder/models/arcfaceresnet100-8.onnx"`.
  **Note:** it was trained on MS-Celeb-1M, a dataset that has been withdrawn. Personal use is
  fine; check the dataset's status before any other use.
- **AdaFace IR-18** (CoreML), MIT, from https://github.com/john-rocky/CoreML-Models (release
  `adaface-v1`), based on https://github.com/mk-minchul/AdaFace (MIT). Compiled and installed
  into the same folder.
- **Apple Vision FeaturePrint**, built into macOS. Nothing to download or install.

The models are for personal and research use. Check each model's license before any other use.

To install ArcFace by hand:

```sh
mkdir -p "$HOME/Library/Application Support/KiFinder/models"
cp arcfaceresnet100-8.onnx "$HOME/Library/Application Support/KiFinder/models/"
# or point KION_MODEL_PATH at any location
```

## Tests

```sh
swift test                                                       # engine tests
xcodebuild test -scheme KiFinder -destination 'platform=macOS'   # app unit and UI tests
```

## Repository layout

| Path | Contents |
|------|----------|
| `KiFinder/` | The SwiftUI macOS app (enrollment, scan, review, export) |
| `Sources/KionEngine/` | Platform-independent matching engine (detect, align, embed, match) |
| `Sources/KionONNXEmbedder/`, `Sources/KionVisionEmbedder/`, `Sources/KionCoreMLEmbedder/` | The three backends (ArcFace ONNX, Apple Vision, AdaFace CoreML) |
| `Sources/KionCLI/` | Command-line interface to the engine |
| `Tests/`, `KiFinderTests/`, `KiFinderUITests/` | Engine, app unit, and UI tests |
| `Vendor/`, `Sources/KionORTShim/` | ONNX Runtime xcframework and C shim |
| `project.yml` | XcodeGen project definition |

## Learn more

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the engine and app fit together
- [PRODUCT.md](PRODUCT.md): product goals and constraints
- [DESIGN.md](DESIGN.md): UI layout, design tokens, keyboard model, and accessibility
- [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md): third-party licenses and model sources

## Naming

The app is **KiFinder**. The engine package is **KionEngine**, and environment variables use
the `KION_` prefix. These prefixes are an internal code name kept for continuity.

## License

KiFinder is free software: you can redistribute it and/or modify it under the terms of the
**GNU General Public License** as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See
the [`LICENSE`](LICENSE) file (GPL-3.0-or-later) for the full text.

Copyright (C) 2026 Kristopher Baker

Third-party components and downloaded models have their own licenses. See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
