#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.10.1
sha=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
archive="build/vendor/Sparkle-$version.tar.xz"
root="build/vendor/sparkle-$version"
mkdir -p build/vendor
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive.part"
  mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c - >&2
# Always extract verified bytes, not a mutable cached framework.
mkdir -p "$root"
tar -xJf "$archive" -C "$root"
printf '%s\n' "$root"
