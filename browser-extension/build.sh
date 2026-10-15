#!/usr/bin/env bash
# Build the Lucero Sync browser extension packages.
#   dist/lucero-sync-chrome.zip   (load unpacked / Chrome Web Store)
#   dist/lucero-sync-firefox.zip  (about:debugging / AMO)
# Requires: bash, zip. Works on macOS and Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
DIST="$ROOT/dist"

command -v zip >/dev/null 2>&1 || { echo "error: 'zip' is required" >&2; exit 1; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t lucero-ext)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$DIST"

build() {
  local target="$1"
  local stage="$WORK/$target"
  local out="$DIST/lucero-sync-$target.zip"

  mkdir -p "$stage"
  # Copy everything except the per-browser manifests and OS junk.
  (cd "$SRC" && tar cf - --exclude='manifest.*.json' --exclude='.DS_Store' .) | (cd "$stage" && tar xf -)
  cp "$SRC/manifest.$target.json" "$stage/manifest.json"

  rm -f "$out"
  (cd "$stage" && zip -q -r -X "$out" .)
  echo "built $out"
}

build chrome
build firefox
