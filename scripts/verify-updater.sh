#!/bin/bash
set -euo pipefail
app="${1:?Usage: verify-updater.sh APP}"
"$app/Contents/MacOS/NearClip" --update-component-check
"$app/Contents/Helpers/NearClipUpdater.app/Contents/MacOS/NearClipUpdater" --configuration-check
"$app/Contents/Helpers/NearClipUpdater.app/Contents/MacOS/NearClipUpdater" --error-policy-check
fixture=$(mktemp -d "${TMPDIR:-/tmp}/nearclip-updater-check.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
ditto "$app" "$fixture/NearClip.app"
printf '\nsynthetic tamper\n' >> "$fixture/NearClip.app/Contents/Helpers/NearClipUpdater.app/Contents/Resources/Sparkle-LICENSE.txt"
if "$fixture/NearClip.app/Contents/MacOS/NearClip" --update-component-check; then
  echo 'FAIL: modified updater component was accepted' >&2; exit 1
fi
echo 'PASS: main app rejects a modified updater component.'
if "$fixture/NearClip.app/Contents/Helpers/NearClipUpdater.app/Contents/MacOS/NearClipUpdater" --configuration-check; then
  echo 'FAIL: updater accepted a modified host bundle' >&2; exit 1
fi
echo 'PASS: updater rejects a modified host bundle.'
