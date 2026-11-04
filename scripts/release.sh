#!/usr/bin/env bash
# Builds a release Anser.app and a DMG in build/.
#
# Optional, for sharing with other Macs:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"   signs with hardened runtime
#   NOTARY_PROFILE=anser-notary                                     notarizes + staples
#     (create once with: xcrun notarytool store-credentials anser-notary)
# Without them you get an ad-hoc signed build that runs on this Mac.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

bash scripts/build-app.sh release
app="build/Anser.app"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
  codesign --verify --strict --verbose=2 "$app"
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
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi
echo "Release ready: $dmg"
