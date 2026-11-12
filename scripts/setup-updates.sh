#!/usr/bin/env bash
# One-time setup for automatic updates (Sparkle).
#
#   scripts/setup-updates.sh                     feed on this repo's GitHub Releases
#   scripts/setup-updates.sh https://host/appcast.xml   or any other https address
#
# 1. Downloads Sparkle's tools (same version the app uses) into build/sparkle-tools.
# 2. Creates your update signing key in your login Keychain (or reuses it) and
#    prints the public half. Keep the Keychain item safe: every update must be
#    signed with it, and a lost key means users can't update automatically.
# 3. Writes scripts/updates.conf (feed address + public key). build-app.sh puts
#    both into the app; release.sh signs each release and writes appcast.xml.
#
# By default the feed is appcast.xml attached to the newest GitHub release
# (releases/latest/download/appcast.xml), so publishing a release is all it takes.
# Any other https static host works too: upload build/updates/ there.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(python3 -c 'import json; d=json.load(open("Package.resolved")); print(next(p["state"]["version"] for p in d["pins"] if p["identity"]=="sparkle"))')"
tools="build/sparkle-tools"

if [[ ! -x "$tools/bin/generate_appcast" ]]; then
  echo "Downloading Sparkle $version tools…"
  mkdir -p "$tools"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$tools/sparkle.tar.xz"
  tar -xJf "$tools/sparkle.tar.xz" -C "$tools"
  rm -f "$tools/sparkle.tar.xz"
fi
[[ "${1:-}" == "--tools-only" ]] && exit 0

feed="${1:-}"
if [[ -z "$feed" ]]; then
  # https://github.com/OWNER/REPO from the git remote (https or ssh form).
  repo="$(git remote get-url origin 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')"
  [[ "$repo" == https://github.com/*/* ]] && feed="$repo/releases/latest/download/appcast.xml"
fi
if [[ -z "$feed" || "$feed" != https://* ]]; then
  echo "Usage: scripts/setup-updates.sh [https://your.host/path/appcast.xml]" >&2
  exit 1
fi

# Creates the key the first time; afterwards just prints the existing public key.
"$tools/bin/generate_keys" >/dev/null
key="$("$tools/bin/generate_keys" -p)"
cat > scripts/updates.conf <<CONF
# Written by scripts/setup-updates.sh. The private key stays in your Keychain.
FEED_URL="$feed"
PUBLIC_KEY="$key"
CONF
echo "Updates set up."
echo "  Feed:       $feed"
echo "  Public key: $key"
echo "Back up the Keychain item \"Private key for signing Sparkle updates\": without it, updates can't be signed."
echo "Next: release with scripts/release.sh (see docs/RELEASING.md)."
