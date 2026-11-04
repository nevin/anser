#!/usr/bin/env bash
# Runs the live end-to-end self-test against build/Anser.app.
# Usage: scripts/selftest.sh [output-dir]   (UI snapshots land there too)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$root/build/selftest}"
mkdir -p "$dir"; rm -f "$dir"/*.png "$dir/results.txt"
# A throwaway config folder, so the test never touches your settings.
cfg="$(mktemp -d)"
XDG_CONFIG_HOME="$cfg" ANSER_SELFTEST="$dir/results.txt" "$root/build/Anser.app/Contents/MacOS/Anser" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 150); do [[ -f "$dir/results.txt" ]] && break; sleep 1; done
sleep 1; kill "$pid" 2>/dev/null
rm -rf "$cfg"
cat "$dir/results.txt" 2>/dev/null || { echo "no results (timed out)"; exit 1; }
! grep -q '^FAIL' "$dir/results.txt"
