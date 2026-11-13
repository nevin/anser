#!/usr/bin/env bash
# Points the Homebrew cask (github.com/nevin/homebrew-tap, Casks/anser.rb) at a
# released version, so `brew install --cask nevin/tap/anser` gets it.
#
#   scripts/update-cask.sh 6.2.2
#
# Run after the GitHub release exists: the checksum comes from the published DMG.
# publish-update.sh runs this for you when PUBLISH=1.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: update-cask.sh VERSION}
tap_repo=${TAP_REPO:-nevin/homebrew-tap}
app_repo=${APP_REPO:-nevin/anser}
dir=build/homebrew-tap

sha=$(gh release view "v$version" -R "$app_repo" --json assets \
  -q ".assets[] | select(.name == \"Anser-$version.dmg\") | .digest" | sed 's/^sha256://')
[[ ${#sha} -eq 64 ]] || { echo "No Anser-$version.dmg on release v$version" >&2; exit 1; }
# The published file should be the one built here.
if [[ -f build/Anser-$version.dmg ]]; then
  local_sha=$(shasum -a 256 "build/Anser-$version.dmg" | cut -d' ' -f1)
  [[ $local_sha == "$sha" ]] || { echo "build/Anser-$version.dmg differs from the released DMG" >&2; exit 1; }
fi

rm -rf "$dir"
gh repo clone "$tap_repo" "$dir" -- --quiet
mkdir -p "$dir/Casks"
cat > "$dir/Casks/anser.rb" <<EOF
cask "anser" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$app_repo/releases/download/v#{version}/Anser-#{version}.dmg"
  name "Anser"
  desc "Terminal with a real command editor, built on Ghostty"
  homepage "https://nevin.github.io/anser/"

  livecheck do
    url "https://github.com/$app_repo/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Anser.app"

  uninstall quit: "app.anser.terminal"

  zap trash: [
    "~/.config/anser",
    "~/Library/Application Support/Anser",
    "~/Library/Caches/Anser",
    "~/Library/Caches/app.anser.terminal",
    "~/Library/HTTPStorages/app.anser.terminal",
    "~/Library/Logs/Anser",
    "~/Library/Preferences/app.anser.terminal.plist",
    "~/Library/Saved Application State/app.anser.terminal.savedState",
  ]
end
EOF

cd "$dir"
git add Casks/anser.rb
if git diff --cached --quiet; then
  echo "Cask already at $version"; exit 0
fi
git -c user.name="Nevin Paul" -c user.email="nevinpaul@gmail.com" commit -q -m "anser $version"
git push -q
echo "Cask updated to $version: brew install --cask ${tap_repo%%/*}/${tap_repo#*/homebrew-}/anser"
