#!/usr/bin/env bash
# Gives Anser a new version. Run by release.sh on every release; also usable alone.
#
#   scripts/bump-version.sh          0.2.0 → 0.2.1   (the default: a patch release)
#   scripts/bump-version.sh minor    0.2.0 → 0.3.0
#   scripts/bump-version.sh major    0.2.0 → 1.0.0
#   scripts/bump-version.sh 0.4.2    exactly that (must be higher than now)
#
# The build number (CFBundleVersion) always goes up by one: Sparkle compares
# it to decide whether an update is newer. PLIST=… points it at another file.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
plist="${PLIST:-$root/Resources/Info.plist}"
pb=/usr/libexec/PlistBuddy

old_v="$("$pb" -c "Print CFBundleShortVersionString" "$plist")"
old_b="$("$pb" -c "Print CFBundleVersion" "$plist")"
IFS=. read -r major minor patch <<< "$old_v"
major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}

case "${1:-patch}" in
  patch) new_v="$major.$minor.$((patch + 1))" ;;
  minor) new_v="$major.$((minor + 1)).0" ;;
  major) new_v="$((major + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*)
    new_v="$1"
    # Must go up, or Sparkle and people would see it as older.
    if [[ "$(printf '%s\n%s\n' "$old_v" "$new_v" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$new_v" || "$new_v" == "$old_v" ]]; then
      echo "Version $new_v isn't higher than $old_v" >&2; exit 1
    fi ;;
  *) echo "Usage: $0 [patch|minor|major|X.Y.Z]" >&2; exit 1 ;;
esac

[[ "$old_b" =~ ^[0-9]+$ ]] || { echo "Build number '$old_b' isn't a whole number" >&2; exit 1; }
new_b=$((old_b + 1))

plutil -replace CFBundleShortVersionString -string "$new_v" "$plist"
plutil -replace CFBundleVersion -string "$new_b" "$plist"
echo "Version $old_v ($old_b) → $new_v ($new_b)"
