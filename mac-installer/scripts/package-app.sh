#!/bin/sh
# Sign, notarize, and package the Clrc app into a distributable .dmg.
#
# Usage: sh mac-installer/scripts/package-app.sh /path/to/Clrc.app [OUT_DMG]
#
# Prerequisites (one-time, on the signing Mac):
#   1. A "Developer ID Application" certificate in the login keychain
#      (team 3ZZ5K4QUDG). Verify: security find-identity -v -p codesigning
#   2. A notarytool keychain profile named "clrc-notary":
#        xcrun notarytool store-credentials clrc-notary \
#          --apple-id YOUR_APPLE_ID --team-id 3ZZ5K4QUDG \
#          --password APP_SPECIFIC_PASSWORD
#
# Override the signing identity or notary profile via env if needed:
#   CODESIGN_IDENTITY (default: "Developer ID Application")
#   NOTARY_PROFILE    (default: "clrc-notary")
set -e

APP="$1"
[ -n "$APP" ] || { echo "usage: package-app.sh /path/to/Clrc.app [OUT_DMG]" >&2; exit 2; }
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

OUT_DMG="${2:-Clrc.dmg}"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-clrc-notary}"

echo "==> code signing $APP (hardened runtime)"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> building $OUT_DMG"
rm -f "$OUT_DMG"
hdiutil create -volname "clrc" -srcfolder "$APP" -ov -format UDZO "$OUT_DMG"

echo "==> notarizing (this can take a few minutes)"
xcrun notarytool submit "$OUT_DMG" --keychain-profile "$PROFILE" --wait

echo "==> stapling ticket"
xcrun stapler staple "$OUT_DMG"
xcrun stapler validate "$OUT_DMG"

echo "==> done: signed + notarized $OUT_DMG"
