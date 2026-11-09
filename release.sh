#!/bin/bash
# Publish the version in Info.plist: universal build, notarize, tar, GitHub release, cask bump, appcast.
# Bump CFBundleShortVersionString and CFBundleVersion in a PR first, then run this on a clean checkout of origin/main.
# One-time setup: xcrun notarytool store-credentials iris --key AuthKey.p8 --key-id KEY --issuer ISSUER
# Where the keychain cannot prompt (over SSH, from an agent session) the profile is unreachable;
# set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER to sign in with the key file instead.
# Sparkle signs the update with the EdDSA key generate_keys put in the keychain; SPARKLE_KEY=<file>
# (its generate_keys -x export) does the same where the keychain cannot prompt.
set -euo pipefail
cd "$(dirname "$0")"

# Releases live on the tap, next to the cask and the appcast.
RELEASE_REPO=igdrasil-app/homebrew-tap
NOTARY=(--keychain-profile iris)
[ -z "${NOTARY_KEY:-}" ] || NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
SPARKLE=(--account ed25519)
[ -z "${SPARKLE_KEY:-}" ] || SPARKLE=(--ed-key-file "$SPARKLE_KEY")
TAP="$(brew --repository igdrasil-app/tap)"
APPCAST="$TAP/Appcasts/iris.xml"
VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw Info.plist)"
TAR="build/Iris-$VERSION.tar.gz"

[ -d "$TAP" ] || brew tap igdrasil-app/tap
git -C "$TAP" pull -q --ff-only
# Sparkle compares CFBundleVersion only: a release that keeps it reaches no one, silently.
# Read from the pushed tap, not the checkout, which a failed run may have left edited.
PUBLISHED="$(git -C "$TAP" show origin/main:Appcasts/iris.xml 2>/dev/null | sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' || true)"
[ "$BUILD" -gt "${PUBLISHED:-0}" ] || { echo "release: CFBundleVersion $BUILD is not above the published $PUBLISHED" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "release: the tree is dirty" >&2; exit 1; }
git fetch -q --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "release: HEAD is not origin/main" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "release: v$VERSION is already tagged" >&2; exit 1; }

make app
ditto -c -k --keepParent build/Iris.app build/Iris.zip
xcrun notarytool submit build/Iris.zip "${NOTARY[@]}" --wait
xcrun stapler staple build/Iris.app
COPYFILE_DISABLE=1 tar -czf "$TAR" -C build Iris.app
SHA="$(shasum -a 256 "$TAR" | cut -d' ' -f1)"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update "${SPARKLE[@]}" "$TAR")"

mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/iris.rb" <<CASK
cask "iris" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$RELEASE_REPO/releases/download/v#{version}/Iris-#{version}.tar.gz"
  name "Iris"
  desc "Apple Calendar for the coding agents you run"
  homepage "https://github.com/igdrasil-app/iris"

  # The menu bar app updates itself with Sparkle; a plain brew upgrade skips a bundle that is already current.
  auto_updates true
  depends_on macos: :sonoma

  app "Iris.app"
  binary "#{appdir}/Iris.app/Contents/MacOS/iris"

  # Upgrades quit the menu bar app and brew reopens the new one; iris mcp processes are not apps and keep running.
  uninstall quit: "app.igdrasil.iris"

  caveats <<~EOS
    Open Iris once to put it in the menu bar; macOS may ask you to confirm the download:
      open #{appdir.to_s.shellescape}/Iris.app
    macOS asks once for Calendar access, on the first calendar command:
      iris calendar calendars
    Add iris to Claude Code (other hosts: iris help mcp):
      claude mcp add --scope user iris -- iris mcp
  EOS
end
CASK

# The feed SUFeedURL in Info.plist reads; Sparkle downloads the same tarball as brew.
mkdir -p "$TAP/Appcasts"
cat > "$APPCAST" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Iris</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(plutil -extract LSMinimumSystemVersion raw Info.plist)</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$RELEASE_REPO/releases/download/v$VERSION/Iris-$VERSION.tar.gz" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST
git -C "$TAP" add Casks/iris.rb Appcasts/iris.xml
git -C "$TAP" commit -q -m "iris $VERSION"

# Public from here on. A failure below is cleaned up by hand, not by a rerun.
gh release create "v$VERSION" "$TAR" --repo "$RELEASE_REPO" --title "Iris $VERSION" --notes "iris@$(git rev-parse --short HEAD)"
git -C "$TAP" push -q
git tag "v$VERSION"
git push -q origin "v$VERSION"
echo "released $VERSION: brew upgrade --cask igdrasil-app/tap/iris"
