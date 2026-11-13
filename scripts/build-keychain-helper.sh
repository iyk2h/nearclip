#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Usage: build-keychain-helper.sh APP}"
identity="${SIGNING_IDENTITY:-}"
profile="${NEARCLIP_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/NearClip Signing/identity.txt}"
if [[ -z "$identity" && -f "$profile" ]]; then identity="$(cat "$profile")"; fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  if [[ "${NEARCLIP_REQUIRE_STABLE_SIGNING:-0}" == 1 ]]; then
    echo "A certificate signing identity is required for the restricted Keychain helper." >&2
    exit 1
  fi
  identity="-"
  echo "Ad-hoc helper: synthetic diagnostics only; real pairing requires certificate signing." >&2
fi
# Cache this small binary independently of app builds. Its partition ID must not
# change when only UI/transport code, app version, or build tools are updated.
source_hash="$(shasum -a 256 Helpers/NearClipKeyStore.m | cut -d ' ' -f 1)"
identity_hash="$(printf '%s' "$identity" | shasum -a 256 | cut -d ' ' -f 1)"
cache="${NEARCLIP_HELPER_CACHE:-build/keystore-cache}/$source_hash-$identity_hash"
mkdir -p "$cache" "$app/Contents/Helpers"
helper="$cache/NearClipKeyStore"
if [[ ! -f "$helper" || ! -f "$cache/SHA256SUMS" ]]; then
  for arch in arm64 x86_64; do
    xcrun clang -arch "$arch" -mmacosx-version-min=13.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
      -framework Foundation -framework Security -framework LocalAuthentication \
      -Wl,-no_uuid Helpers/NearClipKeyStore.m -o "$cache/helper-$arch"
  done
  xcrun lipo -create "$cache/helper-arm64" "$cache/helper-x86_64" -output "$helper"
  timestamp="--timestamp=none"
  if [[ -n "${NOTARY_PROFILE:-}" || "$identity" == "Developer ID Application:"* ]]; then timestamp="--timestamp"; fi
  codesign --force --options runtime "$timestamp" --sign "$identity" --identifier dev.nearclip.keystore "$helper"
  shasum -a 256 "$helper" > "$cache/SHA256SUMS"
fi
shasum -a 256 -c "$cache/SHA256SUMS"
codesign --verify --strict "$helper"
cp "$helper" "$app/Contents/Helpers/NearClipKeyStore"
