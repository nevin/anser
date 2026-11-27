#!/usr/bin/env bash
# Runs the live end-to-end self-test against build/Anser.app.
# Usage: scripts/selftest.sh [output-dir]   (UI snapshots land there too)
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="${1:-$root/build/selftest}"
mkdir -p "$dir"; rm -f "$dir"/*.png "$dir/results.txt"
# A throwaway config folder, so the test never touches your settings.
cfg="$(mktemp -d)"
# Optional starting settings, e.g. CONFIG='{"keepShellsRunning":false}'
if [[ -n "${CONFIG:-}" ]]; then mkdir -p "$cfg/anser"; printf '%s' "$CONFIG" > "$cfg/anser/config.json"; fi
XDG_CONFIG_HOME="$cfg" ANSER_SELFTEST_ONLY="${ANSER_SELFTEST_ONLY:-}" ANSER_SELFTEST="$dir/results.txt" "$root/build/Anser.app/Contents/MacOS/Anser" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 "${SELFTEST_TIMEOUT:-300}"); do [[ -f "$dir/results.txt" ]] && break; sleep 1; done
sleep 1; kill "$pid" 2>/dev/null
rm -rf "$cfg"
# The session helper on its own: closing a busy tab mustn't freeze the app.
[[ -f "$dir/results.txt" ]] && bash "$root/scripts/test-session-helper.sh" >> "$dir/results.txt" 2>&1
# Full runs: kill -9 and relaunch, and the fallback for a helper that won't hand terminals over.
[[ -f "$dir/results.txt" && -z "${ANSER_SELFTEST_ONLY:-}" ]] && bash "$root/scripts/test-crash-relaunch.sh" "$dir/crash" >> "$dir/results.txt" 2>&1
cat "$dir/results.txt" 2>/dev/null || { echo "no results (timed out)"; exit 1; }
! grep -q '^FAIL' "$dir/results.txt"
