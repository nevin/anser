#!/usr/bin/env bash
# Captures the real Anser window (Metal terminal included) after a few short
# commands, to check the layout by eye. Uses build/Anser.app and a throwaway
# config; needs Screen Recording permission for the app running this script.
#   scripts/window-shot.sh [output.png]
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/build/window-shot"; mkdir -p "$dir"; rm -f "$dir/results.txt"
out="${1:-$dir/window.png}"
cfg="$(mktemp -d)"
XDG_CONFIG_HOME="$cfg" ANSER_SELFTEST_ONLY=window ANSER_SELFTEST_HOLD=1 ANSER_SELFTEST="$dir/results.txt" \
    "$root/build/Anser.app/Contents/MacOS/Anser" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 60); do [[ -f "$dir/results.txt" ]] && break; sleep 1; done
wid="$(swift -e "import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let w = list.filter { (\$0[kCGWindowOwnerPID as String] as? Int) == $pid && (\$0[kCGWindowLayer as String] as? Int) == 0 }
    .max { ((\$0[kCGWindowBounds as String] as? [String: Double])?[\"Height\"] ?? 0) < ((\$1[kCGWindowBounds as String] as? [String: Double])?[\"Height\"] ?? 0) }
print(w?[kCGWindowNumber as String] as? Int ?? 0)" 2>/dev/null)"
if [[ -n "$wid" && "$wid" != 0 ]]; then screencapture -x -o -l "$wid" "$out" && echo "saved $out"; else echo "no window found"; fi
kill "$pid" 2>/dev/null; sleep 1
rm -rf "$cfg"
cat "$dir/results.txt" 2>/dev/null
