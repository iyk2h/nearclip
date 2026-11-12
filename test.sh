#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-build}"
mkdir -p "$out/module-cache"
xcrun swiftc -swift-version 5 -Onone -parse-as-library -module-cache-path "$out/module-cache" \
  Sources/MouseGeometry.swift Sources/SharingProtocol.swift Sources/FileTransfer.swift Sources/MouseSharing.swift Sources/Preferences.swift Sources/Core.swift Sources/Clipboard.swift Sources/Transport.swift Sources/Pairing.swift Tests/*.swift -o "$out/NearClipTests"
"$out/NearClipTests"
