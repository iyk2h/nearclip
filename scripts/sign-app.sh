#!/bin/bash
set -euo pipefail
app="${1:?Usage: sign-app.sh APP}"
identity="${SIGNING_IDENTITY:-}"
profile="${NEARCLIP_SIGNING_IDENTITY_FILE:-$HOME/Library/Application Support/NearClip Signing/identity.txt}"
if [[ -z "$identity" && -f "$profile" ]]; then
  identity="$(cat "$profile")"
fi
if [[ -n "$identity" && "$identity" != "-" ]]; then
  # Never fall back to ad-hoc if an expected identity is missing or locked.
  if [[ -n "${NOTARY_PROFILE:-}" || "$identity" == "Developer ID Application:"* ]]; then
    codesign --force --options runtime --timestamp --sign "$identity" --identifier dev.nearclip.mac "$app"
  else
    codesign --force --options runtime --timestamp=none --sign "$identity" --identifier dev.nearclip.mac "$app"
  fi
elif [[ "${NEARCLIP_REQUIRE_STABLE_SIGNING:-0}" == 1 ]]; then
  echo "No stable signing identity. Run scripts/setup-local-signing.py or set SIGNING_IDENTITY." >&2
  exit 1
else
  echo "Development-only ad-hoc signature: macOS permissions can expire after a rebuild." >&2
  codesign --force --sign - --identifier dev.nearclip.mac "$app"
fi
codesign --verify --deep --strict "$app"
