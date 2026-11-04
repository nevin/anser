#!/usr/bin/env bash
# Builds build/Anser.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
config="${1:-release}"

[[ -d vendor/GhosttyKit.xcframework ]] || bash scripts/build-ghostty.sh

swift build -c "$config" --product Anser
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Anser.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/licenses"
cp "$bin/Anser" "$app/Contents/MacOS/Anser"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Ghostty looks for terminfo next to its resources folder.
cp -R vendor/ghostty-share/ghostty "$app/Contents/Resources/ghostty"
cp -R vendor/ghostty-share/terminfo "$app/Contents/Resources/terminfo"
cp -R Resources/shell "$app/Contents/Resources/shell"
cp -R Sources/AnserCore/Specs "$app/Contents/Resources/Specs"
cp vendor/ghostty-share/GHOSTTY-LICENSE "$app/Contents/Resources/licenses/Ghostty-MIT.txt"

codesign --force --sign - "$app" >/dev/null
echo "Built $app"
