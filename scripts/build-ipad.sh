#!/bin/bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$repo/dist/ipad-checks"
xcrun swiftc -module-cache-path "$repo/dist/ipad-checks/modules" \
  "$repo/ipad/Shoebox/ServerAddress.swift" "$repo/ipad/Shoebox/ServerDiscovery.swift" "$repo/ipad/checks/main.swift" \
  -o "$repo/dist/ipad-checks/check-address"
"$repo/dist/ipad-checks/check-address"
# Physical iPads need signing in Xcode; this build needs no Apple account.
xcodebuild -project "$repo/ipad/Shoebox.xcodeproj" -scheme Shoebox \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$repo/dist/ipad" CODE_SIGNING_ALLOWED=NO build
echo "Simulator app: $repo/dist/ipad/Build/Products/Debug-iphonesimulator/Shoebox.app"
echo "For your iPad, open ipad/Shoebox.xcodeproj, select your signing team and iPad, then Run."
