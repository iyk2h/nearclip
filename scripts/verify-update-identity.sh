#!/bin/bash
set -euo pipefail
old="${1:?Usage: verify-update-identity.sh OLD_APP NEW_APP}"
new="${2:?Usage: verify-update-identity.sh OLD_APP NEW_APP}"
old_requirement="$(codesign -d -r- "$old" 2>&1 | sed -n 's/^designated => //p')"
new_requirement="$(codesign -d -r- "$new" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$old_requirement" || -z "$new_requirement" || "$old_requirement" == *cdhash* || "$new_requirement" == *cdhash* ]]; then
  echo "A version-specific or missing signing identity cannot pass the update check." >&2
  exit 1
fi
codesign --verify --deep --strict --test-requirement "=$old_requirement" "$new"
codesign --verify --deep --strict --test-requirement "=$new_requirement" "$old"
echo "PASS: both app versions satisfy the same signing identity requirements."
echo "This verifies code identity. A physical macOS permission check is still required."
