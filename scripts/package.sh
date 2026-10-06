#!/usr/bin/env bash
# Packages build/OpenSpell.app (made by scripts/build.sh) into a drag-to-Applications
# disk image: build/OpenSpell-<version>.dmg plus a .sha256 checksum.
#
#   ./scripts/build.sh && ./scripts/package.sh
#
# Optional, for distribution outside the App Store:
#   CODESIGN_IDENTITY="Developer ID Application: …"            sign the disk image
#   NOTARY_PROFILE=<profile>                                     notarize with `xcrun notarytool store-credentials` credentials
#   NOTARY_KEY=<AuthKey.p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<id>   …or with an App Store Connect API key
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OpenSpell.app"
[ -d "$APP" ] || { echo "Missing $APP — run scripts/build.sh first."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/OpenSpell-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "› Creating disk image…"
ditto "$APP" "$STAGING/OpenSpell.app"
ln -s /Applications "$STAGING/Applications"
# hdiutil sometimes fails with "Resource busy" on CI runners; retrying helps.
for attempt in 1 2 3 4 5; do
    hdiutil create -volname OpenSpell -srcfolder "$STAGING" -format UDZO -ov -quiet "$DMG" && break
    [ "$attempt" -lt 5 ] || exit 1
    echo "  hdiutil failed, retrying ($attempt)…"
    sleep 5
done

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    echo "› Signing disk image…"
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
    AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
if [ -n "${AUTH+x}" ]; then
    echo "› Notarizing (usually takes a few minutes)…"
    RESULT="$ROOT/build/notarization.json"
    xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --output-format json > "$RESULT"
    # notarytool can exit 0 even when Apple rejects the submission.
    if [ "$(plutil -extract status raw -o - "$RESULT")" != "Accepted" ]; then
        xcrun notarytool log "$(plutil -extract id raw -o - "$RESULT")" "${AUTH[@]}" || true
        echo "Notarization failed — see the log above."
        exit 1
    fi
    xcrun stapler staple "$DMG"
fi

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "✓ Packaged $DMG"
