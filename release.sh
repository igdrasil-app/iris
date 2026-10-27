#!/bin/bash
# Publish the version in Info.plist: universal build, notarize, tar, GitHub release, cask bump.
# Bump CFBundleShortVersionString in a PR first, then run this on a clean checkout of origin/main.
# One-time setup: xcrun notarytool store-credentials iris --key AuthKey.p8 --key-id KEY --issuer ISSUER
set -euo pipefail
cd "$(dirname "$0")"

# iris is private and brew downloads anonymously, so the tarball lives on the public tap.
RELEASE_REPO=igdrasil-app/homebrew-tap
TAP="$(brew --repository igdrasil-app/tap)"
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
TAR="build/Iris-$VERSION.tar.gz"

[ -d "$TAP" ] || brew tap igdrasil-app/tap
git -C "$TAP" pull -q --ff-only
[ -z "$(git status --porcelain)" ] || { echo "release: the tree is dirty" >&2; exit 1; }
git fetch -q --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release: HEAD is not origin/main" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "release: v$VERSION is already tagged" >&2; exit 1; }

make app
ditto -c -k --keepParent build/Iris.app build/Iris.zip
xcrun notarytool submit build/Iris.zip --keychain-profile iris --wait
xcrun stapler staple build/Iris.app
COPYFILE_DISABLE=1 tar -czf "$TAR" -C build Iris.app
SHA="$(shasum -a 256 "$TAR" | cut -d' ' -f1)"

mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/iris.rb" <<CASK
cask "iris" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$RELEASE_REPO/releases/download/v#{version}/Iris-#{version}.tar.gz"
  name "Iris"
  desc "Apple Calendar for the coding agents you run"
  homepage "https://github.com/igdrasil-app/iris"

  depends_on macos: :sonoma

  app "Iris.app"
  binary "#{appdir}/Iris.app/Contents/MacOS/iris"

  caveats <<~EOS
    Next:
      iris calendar calendars                        # macOS asks once for Calendar access
      claude mcp add --scope user iris -- iris mcp   # Claude Code; other hosts: iris help mcp
  EOS
end
CASK
git -C "$TAP" add Casks/iris.rb
git -C "$TAP" commit -q -m "iris $VERSION"

# Public from here on. A failure below is cleaned up by hand, not by a rerun.
gh release create "v$VERSION" "$TAR" --repo "$RELEASE_REPO" --title "Iris $VERSION" --notes "iris@$(git rev-parse --short HEAD)"
git -C "$TAP" push -q
git tag "v$VERSION"
git push -q origin "v$VERSION"
echo "released $VERSION: brew upgrade --cask igdrasil-app/tap/iris"
