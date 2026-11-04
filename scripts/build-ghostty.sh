#!/usr/bin/env bash
# Builds GhosttyKit.xcframework (libghostty) from pristine upstream Ghostty (MIT).
# Output: vendor/GhosttyKit.xcframework and vendor/ghostty-share (terminfo, shell integration).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

GHOSTTY_REV=554ea65867ffe34bb3e51e09bd016e154a1f9d7a
ZIG_VERSION=0.16.0
ZIG_SHA=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489  # aarch64-macos

mkdir -p .tools .build vendor
zig_dir="$root/.tools/zig-aarch64-macos-$ZIG_VERSION"
if [[ ! -x "$zig_dir/zig" ]]; then
  archive="$root/.tools/zig-$ZIG_VERSION.tar.xz"
  curl --fail --location "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" -o "$archive"
  echo "$ZIG_SHA  $archive" | shasum -a 256 -c -
  tar -xJf "$archive" -C "$root/.tools"
fi

src="$root/.build/ghostty"
if [[ ! -d "$src/.git" ]]; then
  git init -q "$src"
  git -C "$src" remote add origin https://github.com/ghostty-org/ghostty.git
fi
if [[ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$GHOSTTY_REV" ]]; then
  git -C "$src" fetch --depth 1 origin "$GHOSTTY_REV"
  git -C "$src" checkout -q --detach FETCH_HEAD
fi

# Apply Anser's small patches (each is skipped if already applied).
for p in "$root"/patches/*.patch; do
  if git -C "$src" apply --check "$p" 2>/dev/null; then
    git -C "$src" apply "$p"
  elif ! git -C "$src" apply --reverse --check "$p" 2>/dev/null; then
    echo "Patch does not apply: $p" >&2; exit 1
  fi
done

(cd "$src" && "$zig_dir/zig" build -Doptimize=ReleaseFast -Demit-xcframework=true \
  -Demit-macos-app=false -Dxcframework-target=native -Dsentry=false)

rm -rf vendor/GhosttyKit.xcframework vendor/ghostty-share
cp -R "$src/macos/GhosttyKit.xcframework" vendor/
mkdir -p vendor/ghostty-share
cp -R "$src/zig-out/share/ghostty" "$src/zig-out/share/terminfo" vendor/ghostty-share/
cp "$src/LICENSE" vendor/ghostty-share/GHOSTTY-LICENSE
echo "libghostty ready in vendor/"
