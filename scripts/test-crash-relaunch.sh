#!/usr/bin/env bash
# Kept shells against crashes: kill -9 the app, relaunch, and check the shell is still running
# and its history comes back. Then a helper that won't hand terminals over (as one left from an
# older Anser would): tabs fall back to `attach`. Uses the self-test's own helper and settings.
#
#   scripts/test-crash-relaunch.sh [results-dir]
#
# Prints PASS or FAIL lines like the self-test; exits 1 on a failure.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Anser.app/Contents/MacOS/Anser"
out="${1:-$root/build/selftest-crash}"
mkdir -p "$out"; rm -f "$out"/*.txt
cfg="$(mktemp -d)"
fb="$(mktemp -d "${TMPDIR:-/tmp}/anser-fb.XXXXXX")"; chmod 700 "$fb"
pid=""
cleanup() {
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
    for p in $(pgrep -f "anser-session daemon"); do lsof -p "$p" 2>/dev/null | grep -q "$fb" && kill "$p"; done
    rm -rf "$cfg" "$fb"
}
trap cleanup EXIT
run() {   # run <subset> <results> [VAR=value…]: launch the app like scripts/selftest.sh does
    local only="$1" results="$2"; shift 2
    env "$@" XDG_CONFIG_HOME="$cfg" ANSER_SELFTEST_ONLY="$only" ANSER_SELFTEST="$results" "$app" >/dev/null 2>&1 &
    pid=$!
}
wait_for() { for _ in $(seq 1 "$2"); do [[ -s "$1" ]] && return 0; sleep 1; done; return 1; }
failed=0

# 1. Crash: output and a snapshot, then kill -9.
run crash1 "$out/crash1.txt" ANSER_CRASH_FILE="$out/crash-id.txt"
if ! wait_for "$out/crash-id.txt" 90; then echo "FAIL  after kill -9: the first launch didn't get ready"; exit 1; fi
read -r id state < "$out/crash-id.txt"
kill -9 "$pid"; wait "$pid" 2>/dev/null; pid=""
[[ "$state" == ok ]] || { echo "FAIL  after kill -9: no snapshot reached the helper before the kill ($state)"; failed=1; }
# 2. Relaunch, back to that shell.
run crash2 "$out/crash2.txt" ANSER_SELFTEST_KEEP="$id"
wait_for "$out/crash2.txt" 120 || echo "FAIL  after kill -9: the relaunch timed out" >> "$out/crash2.txt"
sleep 1; kill "$pid" 2>/dev/null; pid=""
cat "$out/crash2.txt"

# 3. A helper that won't hand terminals over, in its own folder.
run fallback "$out/fallback.txt" ANSER_SELFTEST_SESSIONS="$fb" ANSER_SESSION_IGNORE_DIRECT=1
wait_for "$out/fallback.txt" 120 || echo "FAIL  fallback: timed out" >> "$out/fallback.txt"
sleep 1; kill "$pid" 2>/dev/null; pid=""
cat "$out/fallback.txt"

grep -q '^FAIL' "$out/crash2.txt" "$out/fallback.txt" && failed=1
grep -q '^PASS' "$out/crash2.txt" || failed=1
exit $failed
