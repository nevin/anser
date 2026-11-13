#!/usr/bin/env bash
# Makes the update feed for a release that release.sh has built, and with
# PUBLISH=1 creates the GitHub release. release.sh runs it; run it alone to
# finish a release whose last step failed, without building again:
#
#   NOTES=notes.md PUBLISH=1 scripts/publish-update.sh 6.2.2
#
#   NOTES=file.md   release notes (Markdown) for the update window and GitHub
#   PUBLISH=1       also create the GitHub release (needs gh signed in)
#
# Writes build/updates/: the DMG and appcast.xml, signed with the update key
# in your Keychain (ED_KEY_FILE=… uses a key file instead, for testing).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="${1:?usage: scripts/publish-update.sh VERSION}"
dmg="build/Anser-$version.dmg"
[[ -f "$dmg" ]] || { echo "$dmg not found: build it with scripts/release.sh" >&2; exit 1; }
[[ -f scripts/updates.conf ]] || { echo "Updates aren't set up: run scripts/setup-updates.sh" >&2; exit 1; }
if [[ -n "${NOTES:-}" && ! -f "$NOTES" ]]; then echo "NOTES file not found: $NOTES" >&2; exit 1; fi
# The DMG must hold the version it's named after.
mnt="$(mktemp -d)"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" -quiet
inside="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$mnt/Anser.app/Contents/Info.plist" 2>/dev/null || true)"
feedkey="$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$mnt/Anser.app/Contents/Info.plist" 2>/dev/null || true)"
hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet
rmdir "$mnt" 2>/dev/null || true
[[ "$inside" == "$version" ]] || { echo "$dmg holds Anser $inside, not $version" >&2; exit 1; }

# shellcheck disable=SC1091
source scripts/updates.conf
# Built with this update key, or Sparkle in that copy couldn't check later updates.
[[ "$feedkey" == "$PUBLIC_KEY" ]] || { echo "$dmg wasn't built with the update key in scripts/updates.conf" >&2; exit 1; }
tools="build/sparkle-tools/bin"
[[ -x "$tools/generate_appcast" ]] || bash scripts/setup-updates.sh --tools-only
# A fresh folder each time: the feed only needs the newest version.
rm -rf build/updates
mkdir -p build/updates
cp "$dmg" build/updates/
if [[ -n "${NOTES:-}" ]]; then
  cp "$NOTES" "build/updates/Anser-$version.md"
fi
# On GitHub Releases each DMG lives under its own tag; elsewhere, next to appcast.xml.
if [[ "$FEED_URL" =~ ^(https://github\.com/[^/]+/[^/]+)/releases/latest/download/ ]]; then
  gh_repo="${BASH_REMATCH[1]}"
  prefix="$gh_repo/releases/download/v$version/"
  link="$gh_repo/releases"
else
  gh_repo=""
  prefix="${FEED_URL%/*}/"
  link="${FEED_URL%/*}/"
fi
key_args=()
[[ -n "${ED_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$ED_KEY_FILE")
"$tools/generate_appcast" ${key_args[@]+"${key_args[@]}"} --embed-release-notes \
  --download-url-prefix "$prefix" --link "$link" build/updates
rm -f "build/updates/Anser-$version.md"
# Sparkle rejects an update without a signature, so never ship one.
grep -q "Anser-$version.dmg\".*sparkle:edSignature=" build/updates/appcast.xml ||
  { echo "appcast.xml has no signed entry for Anser-$version.dmg (is the update key in your Keychain?)" >&2; exit 1; }

if [[ "${PUBLISH:-}" == 1 && -n "$gh_repo" ]]; then
  # Creates the GitHub release with the DMG and appcast.xml. Once it's the
  # latest release, every copy of Anser with updates on will find it.
  notes_args=(--generate-notes)
  [[ -n "${NOTES:-}" ]] && notes_args=(--notes-file "$NOTES")
  gh release create "v$version" "build/updates/Anser-$version.dmg" build/updates/appcast.xml \
    -R "${gh_repo#https://github.com/}" --title "Anser $version" "${notes_args[@]}"
  # Homebrew: point the cask at this release.
  bash scripts/update-cask.sh "$version"
elif [[ -n "$gh_repo" ]]; then
  echo "Update feed ready in build/updates/. To publish it:"
  echo "  ${NOTES:+NOTES=$NOTES }PUBLISH=1 bash scripts/publish-update.sh $version"
else
  echo "Update feed ready in build/updates/: upload its files next to ${FEED_URL}"
fi
