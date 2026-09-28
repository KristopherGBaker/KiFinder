# Contributing to KiFinder

Thanks for your interest in KiFinder, a privacy-first macOS app that finds photos of one
person in large albums, fully on-device. This guide covers how to build, test, and propose
changes.

By taking part, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- **macOS 15+** on Apple silicon. The app is built and tested on recent macOS.
- **Xcode 26 / Swift 6.2.** The package pins `swift-tools-version: 6.2`
  (`SWIFT_VERSION: "6.2"`, `SWIFT_STRICT_CONCURRENCY: complete`), so you need a
  toolchain that ships Swift 6.2.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen):** `brew install xcodegen`. The
  `.xcodeproj` is *generated* from `project.yml` and is never committed. Don't hand-edit
  the `.pbxproj`. Edit `project.yml` and re-run `xcodegen generate`.
- **SwiftLint (optional but recommended):** `brew install swiftlint`. The repo ships a
  `.swiftlint.yml`. CI does not gate on it yet, but new code should be lint-clean.

## First build (from a fresh clone)

Two large, non-redistributable artifacts and one derived fixture are **gitignored**. A fresh
clone must bootstrap them before it can build or test. Run these in order:

```sh
./Scripts/bootstrap-vendor.sh     # fetch the pinned, sha256-verified ONNX Runtime dylib
./Scripts/bootstrap-fixtures.sh   # build the test album zip + fetch both face models
xcodegen generate                 # produce KiFinder.xcodeproj from project.yml
swift test                        # run the platform-agnostic engine suite
xcodebuild -project KiFinder.xcodeproj -scheme KiFinder -destination platform=macOS build
xcodebuild -project KiFinder.xcodeproj -scheme KiFinder -destination platform=macOS test -only-testing:KiFinderTests
```

> **One engine test is opt-in.** `AdaFaceEmbedder built from the uncompiled .mlpackage warms up and embeds successfully` runs only when `KION_ADAFACE_PACKAGE_PATH` points at an uncompiled `AdaFace_IR18.mlpackage`. The bootstrap installs only the compiled `.mlmodelc`, so the test reports as *skipped* everywhere else. That includes CI, where `Scripts/ci-summary.sh` lists it as an expected skip and fails only on unexpected ones.

- `bootstrap-vendor.sh` downloads the pinned upstream ONNX Runtime release (macOS arm64),
  verifies its sha256, and stages the SwiftPM `.copy` resource dylib. It is idempotent.
  Use `--force` to refetch.
- `bootstrap-fixtures.sh` (default mode) rebuilds `Tests/Fixtures/sample_album.zip` from
  the committed `face_a.jpg`. It then downloads and sha256-verifies the ~249 MB ArcFace ONNX
  model and the ~42 MB AdaFace IR-18 CoreML model into
  `~/Library/Application Support/KiFinder/models`. `--skip-model` builds only the zip.
  `--skip-adaface` skips just the CoreML model.

## Running tests

There are **three** test targets, and they are not interchangeable:

| Suite | How to run | Count | Notes |
|-------|-----------|-------|-------|
| **Engine** (SwiftPM) | `swift test` | 129 tests / 15 suites | Platform-agnostic matching engine. |
| **App unit** | `xcodebuild … test -only-testing:KiFinderTests` | 519 tests / 77 suites | The SwiftUI app's logic. |
| **UI** | `xcodebuild … test -only-testing:KiFinderUITests` | 32 tests | XCUITest. See the caveats below. |

`xcodebuild … test` (no `-only-testing:`) runs the app unit **and** UI suites together.

### The engine suite needs the models

`swift test` is **not** model-free. A green run without the models is green for the
*wrong reason*:

- `EmbeddingBaselineTests.embeddingBaselineUnchangedOnGenuineDetection` deliberately
  **hard-fails** (it calls `Issue.record` and throws) when the ArcFace model is absent.
  This check must never skip.
- **28 other tests are `.enabled(if: isModelAvailable)`-gated** and **skip silently** when
  the model is missing. The suite still passes, but the embedding paths never run.

Always run `bootstrap-fixtures.sh` before trusting a green `swift test`. CI provisions both
models (and caches them) so these tests run instead of skipping. See
`.github/workflows/ci.yml` and the summary step (`Scripts/ci-summary.sh`), which fails the
job if any model-gated test skipped.

### UI test caveats (not runnable on hosted CI)

`KiFinderUITests` drive the real app through `XCUIApplication`. They require:

- an **unlocked, logged-in macOS session with an attached display**. Hosted CI runners
  are headless, so the UI suite can't run there. CI runs the engine suite and
  `KiFinderTests` only.
- the **default DerivedData** location. The runner and the app under test are sandboxed,
  and the UI harness encodes the exact container layout in
  [`KiFinderUITests/HarnessPaths.swift`](KiFinderUITests/HarnessPaths.swift). Read it
  before touching UI-test file I/O.

### The `KION_*` test harness (DEBUG-only)

The app honors a small set of `KION_*` launch environment hooks
(`KION_TEST_SCAN`, `KION_LIBRARY_PICK`, `KION_BACKEND`, `KION_MODEL_PATH`,
`KION_DEFAULTS_SUITE`, `KION_DYNAMIC_TYPE`). They let the UI tests inject sample data and
drive flows deterministically. These hooks are **compiled only in DEBUG**
(`KiFinder/KionEnvironment.swift`). A release build ignores them entirely. The UI-test side,
which defines where the harness may read and write inside the sandbox, lives in
[`KiFinderUITests/HarnessPaths.swift`](KiFinderUITests/HarnessPaths.swift).

## Signing

Builds are **ad-hoc signed by default**. With no `DEVELOPMENT_TEAM` set, `xcodebuild`
produces a runnable, ad-hoc-signed app, and the commands above work with no signing flags.
To run under your own Apple Developer team, use the local, env-enabled project include
described in **README › Distribution and signing**. Don't commit a team into `project.yml`.

## Code style

- **SwiftLint:** the repo's `.swiftlint.yml` is the authority. Keep new code warning-free.
- **Swift 6 strict concurrency:** `SWIFT_STRICT_CONCURRENCY: complete` is on. Keep it clean
  (zero concurrency warnings). Use `@Observable` + `@MainActor` for view and coordinator
  state, and `actor`s for long-lived services.
- **Swift Testing, not XCTest,** for the engine and app-logic suites (`import Testing`,
  `@Test`, `#expect`).
- **Conventional Commits:** `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, …
  (e.g. `fix(review): keep no-match photos visible under per-person filtering`).

## Proposing changes

1. Open an **issue** to discuss anything non-trivial before you start.
2. Fork, branch, and open a **pull request** against `main`. Keep PRs focused. Include a
   clear description and say how you tested the change.
3. Make sure `swift test` and `xcodebuild … test -only-testing:KiFinderTests` pass locally
   (with the models provisioned).
4. **Never let Xcode rewrite the string catalog.** `KiFinder/Localizable.xcstrings` is
   **hand-managed**. Xcode's build phase can silently re-extract and reformat it, adding
   untranslated "new" keys. If that happens, revert the catalog before you commit, unless
   your change is meant to touch copy.

## License

KiFinder is licensed under **GPL-3.0-or-later** (see `LICENSE`). By contributing, you agree
that your contributions are licensed under the same terms.
