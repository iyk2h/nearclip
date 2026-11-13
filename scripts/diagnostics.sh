#!/bin/bash
set -euo pipefail
app="${1:-/Applications/NearClip.app}"
duration="${2:-10m}"
if [[ ! "$duration" =~ ^[0-9]+[smhd]$ ]]; then
  echo 'Usage: bash scripts/diagnostics.sh APP_PATH [10m]' >&2
  exit 2
fi
if [[ -f "$app/Contents/Info.plist" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"
fi
# Only fixed event names, reason codes, counts, and durations from NearClip.
# Do not collect system-wide logs, clipboard content, keys, paths, or addresses.
/usr/bin/log show --last "$duration" --style compact \
  --predicate 'subsystem == "dev.nearclip.mac" AND (category == "input" OR category == "transport")'
