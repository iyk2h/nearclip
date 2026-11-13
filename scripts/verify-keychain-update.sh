#!/bin/bash
set -euo pipefail
old="${1:?Usage: verify-keychain-update.sh OLD_APP NEW_APP}"
new="${2:?Usage: verify-keychain-update.sh OLD_APP NEW_APP}"
bash "$(dirname "$0")/verify-update-identity.sh" "$old" "$new"
helper="Contents/Helpers/NearClipKeyStore"
if ! cmp -s "$old/$helper" "$new/$helper"; then
  echo "Keychain helper changed. Review and test its authorization migration." >&2
  exit 1
fi
"$old/Contents/MacOS/NearClip" --keychain-check
"$new/Contents/MacOS/NearClip" --keychain-check
echo "PASS: identical helper and prompt-free access across both app bundles."
