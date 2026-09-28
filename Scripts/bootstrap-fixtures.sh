#!/usr/bin/env bash
#
# bootstrap-fixtures.sh — make a fresh clone able to run the test suite.
#
# `Scripts/bootstrap-vendor.sh` fetches the gitignored ONNX Runtime binaries. This script
# covers the other things a fresh clone lacks, without which `swift test` is green for the
# WRONG REASON:
#
#   1. Tests/Fixtures/sample_album.zip — gitignored by the `*.zip` rule (which exists to keep
#      real photo albums out of the repo). Its absence fails the ScanPipeline zip test.
#   2. The ArcFace ONNX model (~249 MB, not redistributable here). Its absence does NOT fail
#      the suite — every model-gated test SILENTLY SKIPS, so the suite passes while the
#      embedding tests never run. That is the dangerous one.
#   3. The AdaFace IR-18 CoreML model (~42 MB .mlpackage.zip, item 74a) — same silent-skip
#      trap as #2, compiled to a `.mlmodelc` so `AdaFaceEmbedderTests` can load it directly.
#
# All three are idempotent: existing, valid artifacts are left alone.
#
#   ./Scripts/bootstrap-fixtures.sh                  # album zip + both models
#   ./Scripts/bootstrap-fixtures.sh --skip-model     # album zip only (no large downloads)
#   ./Scripts/bootstrap-fixtures.sh --skip-adaface   # album zip + ArcFace only
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/Tests/Fixtures"

# Keep these in sync with KiFinder/Onboarding/ModelAsset.swift (ModelAssetDescriptor.production);
# ModelAssetTests pins those constants, so a drift here is a deliberate edit, not an accident.
MODEL_DIR="${KION_MODEL_DIR:-$HOME/Library/Application Support/KiFinder/models}"
MODEL_NAME="arcfaceresnet100-8.onnx"
MODEL_URL="${KION_MODEL_URL:-https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8/resolve/main/arcfaceresnet100-8.onnx?download=true}"
MODEL_SHA256="f3a6bc281e72f88862f5748b53be3d76b3b48f8f1ab1f4a537941bdc4e1b01da"
MODEL_BYTES=261036388

# Keep these identical to Sources/KionCoreMLEmbedder/AdaFaceProvisioner.swift's copy — the
# two must never silently drift apart (see that file's doc comment).
ADAFACE_ZIP_NAME="AdaFace_IR18.mlpackage.zip"
ADAFACE_PACKAGE_NAME="AdaFace_IR18.mlpackage"
ADAFACE_MODELC_NAME="AdaFace_IR18.mlmodelc"
ADAFACE_URL="${KION_ADAFACE_URL:-https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip}"
ADAFACE_SHA256="c639ffc02233c72c10daf90f484e14bf570b7f70f55f0c0ee1ce3d284a04430b"
ADAFACE_BYTES=44482098

SKIP_MODEL=0
SKIP_ADAFACE=0
for arg in "$@"; do
  case "$arg" in
    --skip-model) SKIP_MODEL=1 ;;
    --skip-adaface) SKIP_ADAFACE=1 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg (try --help)" >&2; exit 64 ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. sample_album.zip
# ---------------------------------------------------------------------------
# ScanPipeline's zip test asserts the manifest contains "face_a.jpg", so the archive must
# hold that file at its root. Built from the committed fixture rather than committed itself:
# the `*.zip` ignore is a privacy guard (no real albums in git), and a derived artifact does
# not belong in source control when a five-line recipe reproduces it exactly.
ZIP="$FIXTURES/sample_album.zip"
if [ -f "$ZIP" ] && unzip -l "$ZIP" 2>/dev/null | grep -q 'face_a\.jpg'; then
  echo "✔ sample_album.zip already present"
else
  [ -f "$FIXTURES/face_a.jpg" ] || { echo "✘ missing $FIXTURES/face_a.jpg — is this a full checkout?" >&2; exit 1; }
  rm -f "$ZIP"
  ( cd "$FIXTURES" && zip -X -q sample_album.zip face_a.jpg )
  echo "✔ built sample_album.zip from face_a.jpg"
fi

# ---------------------------------------------------------------------------
# 2. ArcFace model
# ---------------------------------------------------------------------------
if [ "$SKIP_MODEL" -eq 1 ]; then
  echo "• skipping ArcFace model (--skip-model): model-gated tests will SKIP, not fail"
else
  MODEL_PATH="$MODEL_DIR/$MODEL_NAME"
  if [ -f "$MODEL_PATH" ] && [ "$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')" = "$MODEL_SHA256" ]; then
    echo "✔ ArcFace model already installed and verified: $MODEL_PATH"
  else
    # The weights are trained on the withdrawn MS-Celeb-1M dataset and are research-oriented;
    # this repo contains no weights and only fetches them to the app's own managed location.
    # See the Model section of the README before using them for anything but personal use.
    echo "• downloading ArcFace model (~249 MB) -> $MODEL_PATH"
    mkdir -p "$MODEL_DIR"
    TMP="$MODEL_DIR/.$MODEL_NAME.download"
    trap 'rm -f "$TMP"' EXIT
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$TMP" "$MODEL_URL"

    ACTUAL_BYTES=$(stat -f%z "$TMP")
    ACTUAL_SHA=$(shasum -a 256 "$TMP" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$MODEL_SHA256" ] || [ "$ACTUAL_BYTES" != "$MODEL_BYTES" ]; then
      echo "✘ verification FAILED — refusing to install." >&2
      echo "    expected sha256 $MODEL_SHA256 ($MODEL_BYTES bytes)" >&2
      echo "    actual   sha256 $ACTUAL_SHA ($ACTUAL_BYTES bytes)" >&2
      exit 1
    fi

    mv "$TMP" "$MODEL_PATH"
    trap - EXIT
    echo "✔ ArcFace model installed and sha256-verified: $MODEL_PATH"
  fi
fi

# ---------------------------------------------------------------------------
# 3. AdaFace IR-18 model (item 74a)
# ---------------------------------------------------------------------------
# AdaFace IR-18 is redistributed as a CoreML conversion by john-rocky/CoreML-Models; this
# repo contains no weights and only fetches them to the app's own managed location. See the
# Model section of the README before using them for anything but personal use.
if [ "$SKIP_MODEL" -eq 1 ] || [ "$SKIP_ADAFACE" -eq 1 ]; then
  echo "• skipping AdaFace model (--skip-model/--skip-adaface): model-gated tests will SKIP, not fail"
else
  ADAFACE_MODELC_PATH="$MODEL_DIR/$ADAFACE_MODELC_NAME"
  if [ -e "$ADAFACE_MODELC_PATH" ]; then
    echo "✔ AdaFace model already installed: $ADAFACE_MODELC_PATH"
  else
    echo "• downloading AdaFace IR-18 CoreML model (~42 MB) -> $ADAFACE_MODELC_PATH"
    mkdir -p "$MODEL_DIR"
    ADAFACE_TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$ADAFACE_TMPDIR"' EXIT
    ZIP_TMP="$ADAFACE_TMPDIR/$ADAFACE_ZIP_NAME"
    curl -fL --retry 3 --retry-delay 2 --progress-bar -o "$ZIP_TMP" "$ADAFACE_URL"

    ACTUAL_BYTES=$(stat -f%z "$ZIP_TMP")
    ACTUAL_SHA=$(shasum -a 256 "$ZIP_TMP" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$ADAFACE_SHA256" ] || [ "$ACTUAL_BYTES" != "$ADAFACE_BYTES" ]; then
      echo "✘ verification FAILED — refusing to install." >&2
      echo "    expected sha256 $ADAFACE_SHA256 ($ADAFACE_BYTES bytes)" >&2
      echo "    actual   sha256 $ACTUAL_SHA ($ACTUAL_BYTES bytes)" >&2
      exit 1
    fi

    unzip -q "$ZIP_TMP" -d "$ADAFACE_TMPDIR"
    PACKAGE_PATH="$ADAFACE_TMPDIR/$ADAFACE_PACKAGE_NAME"
    [ -d "$PACKAGE_PATH" ] || { echo "✘ expected $ADAFACE_PACKAGE_NAME inside the zip" >&2; exit 1; }

    echo "• compiling $ADAFACE_PACKAGE_NAME (xcrun coremlc)"
    COMPILE_OUT="$ADAFACE_TMPDIR/compiled"
    xcrun coremlc compile "$PACKAGE_PATH" "$COMPILE_OUT"
    COMPILED_RESULT="$COMPILE_OUT/$ADAFACE_MODELC_NAME"
    [ -d "$COMPILED_RESULT" ] || { echo "✘ coremlc did not produce $ADAFACE_MODELC_NAME" >&2; exit 1; }

    rm -rf "$ADAFACE_MODELC_PATH"
    mv "$COMPILED_RESULT" "$ADAFACE_MODELC_PATH"
    trap - EXIT
    rm -rf "$ADAFACE_TMPDIR"
    echo "✔ AdaFace model compiled and installed: $ADAFACE_MODELC_PATH"
  fi
fi

echo
echo "Now: swift test   (model-gated tests will EXECUTE rather than skip)"
