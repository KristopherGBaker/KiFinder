#!/usr/bin/env bash
# ci-summary.sh <swift-test.log> — the loud end of the CI job.
#
# Counts the tests Swift Testing reported as `skipped` in the engine-test log and prints
#   Skipped model-gated tests: <unexpected> (expected opt-in skips: <n>)
# to stdout and to $GITHUB_STEP_SUMMARY (when set). Any UNEXPECTED skip fails the job: CI
# provisions both models (Scripts/bootstrap-fixtures.sh), so a model-gated test skipping means
# the provisioning broke — never a silently green run.
#
# EXPECTED skips are tests that are opt-in by design and only run when an extra environment
# variable points at an artifact the bootstrap does not keep; they are listed by their exact
# test title and reported, not failed.
set -euo pipefail

LOG="${1:-}"
if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
  echo "usage: $(basename "$0") <swift-test.log>" >&2
  exit 2
fi

EXPECTED_SKIPS=(
  # Needs KION_ADAFACE_PACKAGE_PATH → an UNCOMPILED AdaFace .mlpackage; the bootstrap installs
  # only the compiled .mlmodelc (see Tests/KionEngineTests/AdaFaceEmbedderTests.swift).
  'AdaFaceEmbedder built from the uncompiled .mlpackage warms up and embeds successfully'
)

skipped_lines="$(grep -E '^[^A-Za-z0-9]*Test "[^"]*" skipped' "$LOG" || true)"
total=0; expected=0; unexpected=0; unexpected_names=""
if [ -n "$skipped_lines" ]; then
  while IFS= read -r line; do
    total=$((total + 1))
    name="$(printf '%s' "$line" | sed -E 's/^[^"]*"([^"]*)".*$/\1/')"
    is_expected=0
    for e in "${EXPECTED_SKIPS[@]}"; do [ "$name" = "$e" ] && is_expected=1; done
    if [ "$is_expected" -eq 1 ]; then expected=$((expected + 1)); else unexpected=$((unexpected + 1)); unexpected_names="$unexpected_names"$'\n'"  - $name"; fi
  done <<< "$skipped_lines"
fi

line="Skipped model-gated tests: $unexpected (expected opt-in skips: $expected)"
echo "$line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Engine tests"; echo; echo "$line"; [ -n "$unexpected_names" ] && printf '%s\n' "$unexpected_names"; } >> "$GITHUB_STEP_SUMMARY"
fi
if [ "$unexpected" -gt 0 ]; then
  echo "error: $unexpected model-gated test(s) skipped unexpectedly — the models were not provisioned." >&2
  printf '%s\n' "$unexpected_names" >&2
  echo "       A skip here is a broken bootstrap, not a green run. Failing the job." >&2
  exit 1
fi
