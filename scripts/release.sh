#!/usr/bin/env bash
# Builds a Developer ID signed, notarized DarkRoom DMG and publishes it, with a signed Sparkle
# appcast entry, as a GitHub release of this repo.
#
# Needs (see Docs/Releasing.md):
#   DEVELOPER_ID      "Developer ID Application: … (TEAMID)" signing identity in the keychain
#   NOTARY_PROFILE    notarytool keychain profile (xcrun notarytool store-credentials)
#   SPARKLE_KEY_FILE  optional: EdDSA private key file (default: the key in the login keychain)
#   gh                signed in with access to pingpongshow/darkroom
# Usage: scripts/release.sh 0.2.0 [--dry-run]
set -euo pipefail
version="${1:?usage: release.sh <version> [--dry-run]}"
dry_run="${2:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
releases_repo="pingpongshow/darkroom"
work="$(mktemp -d "${TMPDIR:-/tmp}/darkroom-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
: "${DEVELOPER_ID:?set DEVELOPER_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

cd "$root"
scripts/check-secrets.sh
build_number="$(git rev-list --count HEAD)"
xcodegen generate -q

echo "› Archiving $version ($build_number)"
xcodebuild -project DarkRoom.xcodeproj -scheme DarkRoom -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$work/DarkRoom.xcarchive" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  archive | tail -3

app="$work/DarkRoom.xcarchive/Products/Applications/DarkRoom.app"
# Xcode leaves Sparkle's helpers with Sparkle's own signatures; notarization needs every executable
# signed with the Developer ID, hardened runtime and a secure timestamp. Sign inside-out, then the app.
# (The bundled ExifTool is Perl, not Mach-O, so it needs no signature.)
sign() { codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle" ]; then
  sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  sign "$sparkle/Versions/B/Autoupdate"
  sign "$sparkle/Versions/B/Updater.app"
  sign "$sparkle"
fi
sign --preserve-metadata=entitlements,requirements,flags "$app"
codesign --verify --deep --strict --verbose=2 "$app"

echo "› Building DMG"
dmg="$work/DarkRoom-$version.dmg"
mkdir "$work/dmg" && cp -R "$app" "$work/dmg/" && ln -s /Applications "$work/dmg/Applications"
hdiutil create -volname "DarkRoom $version" -srcfolder "$work/dmg" -fs APFS -format ULFO "$dmg" >/dev/null
codesign --sign "$DEVELOPER_ID" --timestamp "$dmg"

echo "› Notarizing"
result="$(xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
submission="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
if [ "$status" != "Accepted" ]; then
  echo "Notarization $status. Apple's log:"
  xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE"
  exit 1
fi
echo "Notarization accepted ($submission)"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"

echo "› Signing the update"
sign_update="$( { find "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Caches/DarkRoom/DerivedData" \
  -path '*Sparkle*/bin/sign_update' -type f 2>/dev/null || true; } | head -1)"
[ -n "$sign_update" ] || { echo "sign_update not found (build once so SwiftPM fetches Sparkle)"; exit 1; }
signature="$("$sign_update" ${SPARKLE_KEY_FILE:+--ed-key-file "$SPARKLE_KEY_FILE"} "$dmg")"
notes="$root/docs/ReleaseNotes/$version.md"
[ -f "$notes" ] || notes=/dev/null

item="    <item>
      <title>DarkRoom $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$releases_repo/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url=\"https://github.com/$releases_repo/releases/download/v$version/DarkRoom-$version.dmg\" $signature type=\"application/octet-stream\"/>
    </item>"

# The appcast is a release asset of the newest release (feed URL: …/releases/latest/download/appcast.xml),
# so it accumulates items from the previous appcast.
previous="$work/previous.xml"
if gh release download --repo "$releases_repo" --pattern appcast.xml --output "$previous" 2>/dev/null; then
  old_items="$(sed -n '/<item>/,/<\/item>/p' "$previous")"
else
  old_items=""
fi
cat > "$work/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DarkRoom</title>
$item
$old_items
  </channel>
</rss>
XML

if [ "$dry_run" = "--dry-run" ]; then
  cp "$dmg" "$work/appcast.xml" "$root/build/" 2>/dev/null || { mkdir -p "$root/build"; cp "$dmg" "$work/appcast.xml" "$root/build/"; }
  echo "Dry run: DMG and appcast are in build/"
  exit 0
fi

echo "› Publishing to $releases_repo"
gh release create "v$version" --repo "$releases_repo" --title "DarkRoom $version" --notes-file "$notes" \
  "$dmg" "$work/appcast.xml"
echo "Released DarkRoom $version"
