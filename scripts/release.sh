#!/usr/bin/env bash
# Builds a release Anser.app and a DMG in build/, with a new version every time:
#   scripts/release.sh            0.2.0 → 0.2.1 (and the build number + 1)
#   scripts/release.sh minor      0.2.0 → 0.3.0
#   scripts/release.sh major      0.2.0 → 1.0.0
#   scripts/release.sh 0.4.2      exactly that
#
# Optional, for sharing with other Macs:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   signs with hardened runtime
#   NOTARY_PROFILE=anser-notary                                     notarizes + staples the app and the DMG
#     (create once with: xcrun notarytool store-credentials anser-notary)
# Without them you get an ad-hoc signed build that runs on this Mac.
#
# Automatic updates: after scripts/setup-updates.sh has run once, this also
# writes build/updates/ (the DMG + a signed appcast.xml). Upload that folder's
# contents to the address you gave setup-updates.sh. See docs/RELEASING.md.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Every release gets a new version (see scripts/bump-version.sh).
bash scripts/bump-version.sh "${1:-patch}"

bash scripts/build-app.sh release
app="build/Anser.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

# Sends a file to Apple's notary service and waits; prints Apple's log if it's rejected.
notarize() {
  local file="$1" out id
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
  echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("notarization:", d.get("status"), d.get("id"))'
  if ! echo "$out" | grep -q '"status" *: *"Accepted"'; then
    id="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "Notarization failed for $file" >&2
    exit 1
  fi
}

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Sparkle's helpers first (inside out), then the app. No --deep: each part gets the hardened runtime.
  sp="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  [[ -d "$sp/XPCServices/Installer.xpc" ]] && sign "$sp/XPCServices/Installer.xpc"
  [[ -d "$sp/XPCServices/Downloader.xpc" ]] && sign --preserve-metadata=entitlements "$sp/XPCServices/Downloader.xpc"
  [[ -e "$sp/Autoupdate" ]] && sign "$sp/Autoupdate"
  [[ -d "$sp/Updater.app" ]] && sign "$sp/Updater.app"
  sign "$app/Contents/Frameworks/Sparkle.framework"
  sign "$app/Contents/MacOS/anser-session"
  sign "$app"
  codesign --verify --strict --deep --verbose=2 "$app"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # Notarize the app itself too, so it opens cleanly even outside the DMG (and offline).
    zip="build/Anser-notarize.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize "$zip"
    rm -f "$zip"
    xcrun stapler staple "$app"
  fi
fi

dmg="build/Anser-$version.dmg"
rw="build/Anser-rw.dmg"
volname="Anser $version"
rm -f "$dmg" "$rw"
staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
# Installer window art and the disk's own icon (made by scripts/make-brand.swift).
mkdir "$staging/.background"
cp branding/dmg/dmg-background.tiff "$staging/.background/background.tiff"
hdiutil create -volname "$volname" -srcfolder "$staging" -ov -format UDRW -fs HFS+ "$rw" >/dev/null
rm -rf "$staging"

# Lay out the window to match the background: app left of the arrow, Applications right of it.
mount="$(hdiutil attach "$rw" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}' | sed 's/[[:space:]]*$//')"
if ! osascript >/dev/null <<EOF
tell application "Finder"
  repeat 20 times
    if exists disk "$volname" then exit repeat
    delay 0.5
  end repeat
  tell disk "$volname"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Anser.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "warning: couldn't lay out the DMG window (allow your terminal to control Finder); the DMG still works" >&2
fi
# The disk's own icon: copy it in and set the volume's "has custom icon" flag.
cp Resources/AppIcon.icns "$mount/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mount"
sync
hdiutil detach "$mount" -quiet || hdiutil detach "$mount" -force -quiet
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
rm -f "$rw"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" || true
fi

# The update feed: the DMG plus appcast.xml, signed with your update key.
if [[ -f scripts/updates.conf ]]; then
  # shellcheck disable=SC1091
  source scripts/updates.conf
  tools="build/sparkle-tools/bin"
  [[ -x "$tools/generate_appcast" ]] || bash scripts/setup-updates.sh --tools-only
  mkdir -p build/updates
  cp "$dmg" build/updates/
  "$tools/generate_appcast" --download-url-prefix "${FEED_URL%/*}/" build/updates
  echo "Update feed ready in build/updates/: upload its files next to ${FEED_URL}"
fi
echo "Release ready: $dmg"
