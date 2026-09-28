#!/usr/bin/env bash
#
# bootstrap-vendor.sh — materialize the gitignored ONNX Runtime dylib so a FRESH
# clone (or CI) can build KiFinder. SwiftPM pins the artifact to a package-relative
# path, so it MUST live in the tree (can't be referenced out-of-repo like the model):
#
#   • Sources/KionONNXEmbedder/Resources/<dylib>  — Package.swift `.copy` resource
#
# It's in .gitignore (~36.5MB, never committed). This fetches the pinned upstream
# ONNX Runtime macOS-arm64 release and verifies its sha256 before staging it.
#
# Idempotent: a no-op when the artifact already exists (pass --force to refetch).
#
# Note: the committed copy was additionally `strip`ped + ad-hoc-signed for size
# (~29.6MB vs the ~38.3MB upstream); this script installs the upstream Microsoft-signed
# dylib as-is — larger but identical API/install-name (`@rpath/libonnxruntime.1.dylib`)
# and guaranteed to link/load. The bytes differ from the committed copy by design; the
# artifact is gitignored, so sha drift never reaches git.
set -euo pipefail

ORT_VERSION="1.27.0"
DYLIB_NAME="libonnxruntime.${ORT_VERSION}.dylib"
# Override ORT_TGZ_URL to point at a mirror/cache; the sha gate still applies.
ORT_TGZ_URL="${ORT_TGZ_URL:-https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/onnxruntime-osx-arm64-${ORT_VERSION}.tgz}"
# sha256 of lib/<DYLIB_NAME> INSIDE the upstream osx-arm64 tarball (download integrity).
EXPECTED_DYLIB_SHA256="299e5a2c6ea00531ecd6bf3217e23798c1fcba1698bb386d313c8e16d7317d60"

# Repo root (overridable for testing). Defaults to the parent of this script's dir.
REPO_ROOT="${REPO_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
RES="${REPO_ROOT}/Sources/KionONNXEmbedder/Resources/${DYLIB_NAME}"

force=0
[[ "${1:-}" == "--force" ]] && force=1

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "warning: this project targets macOS arm64; '$(uname -m)' is unsupported by this bootstrap." >&2
fi

if [[ $force -eq 0 && -f "$RES" ]]; then
  echo "✓ ONNX Runtime already present (Resources dylib). Use --force to refetch."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "↓ Downloading ONNX Runtime ${ORT_VERSION} (osx-arm64) …"
echo "  $ORT_TGZ_URL"
curl -fSL --retry 3 -o "$tmp/ort.tgz" "$ORT_TGZ_URL"
tar xzf "$tmp/ort.tgz" -C "$tmp"

dylib="$(find "$tmp" -path "*/lib/${DYLIB_NAME}" ! -path "*dSYM*" -type f | head -1)"
[[ -n "$dylib" ]] || { echo "error: ${DYLIB_NAME} not found inside the archive" >&2; exit 1; }

got="$(shasum -a 256 "$dylib" | awk '{print $1}')"
if [[ "$got" != "$EXPECTED_DYLIB_SHA256" ]]; then
  echo "error: sha256 mismatch for ${DYLIB_NAME}" >&2
  echo "  expected $EXPECTED_DYLIB_SHA256" >&2
  echo "  got      $got" >&2
  echo "  (refusing to install an unverified binary; check ORT_VERSION/ORT_TGZ_URL)" >&2
  exit 1
fi
echo "✓ sha256 verified ($got)"

# --- Stage the SwiftPM `.copy` resource dylib ---
mkdir -p "$(dirname "$RES")"
cp "$dylib" "$RES"

echo "✓ ONNX Runtime bootstrapped:"
echo "    $RES"
