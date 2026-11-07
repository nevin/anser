#!/usr/bin/env bash
# One-time setup for automatic updates (Sparkle).
#
#   scripts/setup-updates.sh https://example.com/anser/appcast.xml
#
# 1. Downloads Sparkle's tools (same version the app uses) into build/sparkle-tools.
# 2. Creates your update signing key in your login Keychain (or reuses it) and
#    prints the public half. Keep the Keychain item safe: every update must be
#    signed with it, and a lost key means users can't update automatically.
# 3. Writes scripts/updates.conf (feed address + public key). build-app.sh puts
#    both into the app; release.sh signs each release and writes appcast.xml.
#
# The feed address is where you'll upload build/updates/ (any static web host:
# GitHub Pages, S3, your own site). It must be https.
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
if [[ -z "$feed" || "$feed" != https://* ]]; then
  echo "Usage: scripts/setup-updates.sh https://your.host/path/appcast.xml" >&2
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
echo "Next: bash scripts/release.sh (with SIGN_IDENTITY and NOTARY_PROFILE), then upload build/updates/*."
