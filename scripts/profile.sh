#!/usr/bin/env bash
# Measures the live app's memory, CPU, GPU and wakeups (idle, many tabs,
# after output, minimized), plus its shell helpers. Uses build/Anser.app.
#   scripts/profile.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/build/profile"; mkdir -p "$dir"; rm -f "$dir/results.txt"
cfg="$(mktemp -d)"
XDG_CONFIG_HOME="$cfg" ANSER_SELFTEST_ONLY=profile ANSER_SELFTEST_HOLD=1 ANSER_SELFTEST="$dir/results.txt" \
    "$root/build/Anser.app/Contents/MacOS/Anser" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 400); do [[ -f "$dir/results.txt" ]] && break; sleep 1; done
{
    echo "--- footprint breakdown (1 tab, app still open)"
    footprint "$pid" 2>/dev/null | grep -E "phys_footprint|^ +[0-9.]+ [KMG]B" | head -14
    echo "--- heap zones"; heap "$pid" 2>/dev/null | grep -E "^(Zone|All zones|Process)" | head -12; vmmap --summary "$pid" 2>/dev/null | grep -E "^(DefaultMallocZone|MallocHelperZone|QuartzCore|TOTAL|Physical footprint)|MALLOC_(SMALL|TINY|LARGE|MEDIUM) " | head -14
    echo "--- shell helpers (this test's)"
    ps -axo pid,ppid,rss,command | awk -v p="$pid" '$2==p && /anser-session/ {s+=$3; n++} END {printf "%d attach helpers, %.0f MB total\n", n, s/1024}'
} >> "$dir/results.txt"
kill "$pid" 2>/dev/null; sleep 1
rm -rf "$cfg"
cat "$dir/results.txt"
