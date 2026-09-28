#!/bin/bash
# Regenerate the macOS app icon into the asset catalog from the Swift renderer.
# Usage: Scripts/generate_app_icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$ROOT/KiFinder/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

swift "$ROOT/Scripts/generate_app_icon.swift" "$SET/AppIcon-1024.png"
for sz in 16 32 64 128 256 512; do
  cp "$SET/AppIcon-1024.png" "$SET/AppIcon-$sz.png"
  sips -z "$sz" "$sz" "$SET/AppIcon-$sz.png" >/dev/null
done
echo "Regenerated AppIcon for macOS. Rebuild to apply."
