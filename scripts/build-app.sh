#!/usr/bin/env bash
# Builds build/Anser.app. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
config="${1:-release}"

[[ -d vendor/GhosttyKit.xcframework ]] || bash scripts/build-ghostty.sh

swift build -c "$config" --product Anser
swift build -c "$config" --product anser-session
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Anser.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/licenses"
cp "$bin/Anser" "$app/Contents/MacOS/Anser"
# Keeps shells running across restarts and updates.
cp "$bin/anser-session" "$app/Contents/MacOS/anser-session"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Ghostty looks for terminfo next to its resources folder.
cp -R vendor/ghostty-share/ghostty "$app/Contents/Resources/ghostty"
cp -R vendor/ghostty-share/terminfo "$app/Contents/Resources/terminfo"
cp -R Resources/shell "$app/Contents/Resources/shell"
cp -R Sources/AnserCore/Specs "$app/Contents/Resources/Specs"
cp vendor/ghostty-share/GHOSTTY-LICENSE "$app/Contents/Resources/licenses/Ghostty-MIT.txt"

# Sparkle (automatic updates) ships inside the app.
mkdir -p "$app/Contents/Frameworks"
ditto "$bin/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Anser" 2>/dev/null || true
cp .build/checkouts/Sparkle/LICENSE "$app/Contents/Resources/licenses/Sparkle-MIT.txt" 2>/dev/null || true

# Update feed and signing key, written once by scripts/setup-updates.sh.
# Without them the app still works; it just can't update itself.
if [[ -f scripts/updates.conf ]]; then
  # shellcheck disable=SC1091
  source scripts/updates.conf
  plist="$app/Contents/Info.plist"
  plutil -replace SUFeedURL -string "$FEED_URL" "$plist"
  plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$plist"
  plutil -replace SUEnableAutomaticChecks -bool YES "$plist"
fi

codesign --force --deep --sign - "$app" >/dev/null
echo "Built $app"
