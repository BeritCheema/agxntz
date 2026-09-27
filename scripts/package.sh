#!/usr/bin/env bash
#
# Build agxntz.app (with Sparkle embedded), sign it, and optionally notarize it,
# package it as agxntz.dmg (download) and agxntz.zip (Sparkle updates), and
# produce a Sparkle appcast for the release.
#
# Local dev bundle (ad-hoc signed, no zip, updater disabled):
#   ./scripts/package.sh            # or: make app
#
# Signed + notarized release (CI, or a local release build):
#   VERSION=0.1.0 \
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   AC_API_KEY_ID="KEYID" AC_API_ISSUER_ID="ISSUER-UUID" \
#   AC_API_KEY_PATH="$HOME/private_keys/AuthKey_KEYID.p8" \
#   ./scripts/package.sh
#
# In CI, pass AC_API_KEY_P8 (base64 of the .p8) instead of AC_API_KEY_PATH, and
# SPARKLE_ED_PRIVATE_KEY (the exported EdDSA key) to sign the update + appcast.
# Locally, SPARKLE_SIGN=1 signs with the key stored in the login keychain.
#
# Signing is skipped (ad-hoc) when SIGNING_IDENTITY is unset. Notarization runs
# only when SIGNING_IDENTITY is a real identity AND the API-key vars are set.
# NO_ZIP=1 stops after the signed bundle (used by `make app`).
set -euo pipefail
cd "$(dirname "$0")/.."

CLEANUP=()
# Must not change the exit status: with nothing to clean, a trailing failed
# test would make a successful build exit 1.
cleanup() { for f in "${CLEANUP[@]:-}"; do if [ -n "$f" ]; then rm -f "$f"; fi; done; return 0; }
trap cleanup EXIT

APP=agxntz
REPO=BeritCheema/agxntz
VERSION="${VERSION:-dev}"
VERSION="${VERSION#v}"                       # tolerate a leading v (git tag)
IDENTITY="${SIGNING_IDENTITY:--}"            # "-" = ad-hoc
BUNDLE="dist/$APP.app"
# Fixed asset name: releases/latest/download/agxntz.zip is a stable "latest"
# link, and the agxntz.com update Worker looks for exactly this asset name.
ZIP="dist/$APP.zip"          # what Sparkle updates from
DMG="dist/$APP.dmg"          # what people download
APPCAST="dist/appcast.xml"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"

echo "==> Building $APP ($VERSION)"
swift build -c release

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE" "$ZIP" "$DMG" "$APPCAST"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources"
cp Support/Info.plist "$BUNDLE/Contents/Info.plist"
cp Support/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp ".build/release/$APP" "$BUNDLE/Contents/MacOS/$APP"

# Stamp the release version into the bundle. Sparkle compares CFBundleVersion,
# so it must match <sparkle:version> in the appcast.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$BUNDLE/Contents/Info.plist"

# Embed Sparkle. The app isn't sandboxed, so its XPC services aren't needed
# (Sparkle docs: they may be removed); dropping them avoids shipping unused
# nested code that would otherwise need signing.
FW="$BUNDLE/Contents/Frameworks/Sparkle.framework"
ditto ".build/release/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
# The binary loads @rpath/Sparkle.framework; inside the bundle that's ../Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE/Contents/MacOS/$APP"

echo "==> Signing (identity: $IDENTITY)"
sign() {
    if [ "$IDENTITY" = "-" ]; then
        codesign --force --sign - "$1"
    else
        # Hardened runtime + secure timestamp are required for notarization.
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
    fi
}
# Inside-out, no --deep (per Sparkle's code-signing docs).
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign "$BUNDLE"
codesign --verify --strict "$BUNDLE"

if [ "${NO_ZIP:-}" = "1" ]; then
    echo "==> Done: $BUNDLE"
    exit 0
fi

notarize() {
    [ "$IDENTITY" != "-" ] || return 1
    [ -n "${AC_API_KEY_ID:-}" ] && [ -n "${AC_API_ISSUER_ID:-}" ] || return 1
    [ -n "${AC_API_KEY_PATH:-}" ] || [ -n "${AC_API_KEY_P8:-}" ]
}

if notarize; then
    # Resolve the API key to a file: either a given path, or a temp file
    # decoded from the base64 secret (CI). Temp files are cleaned up on exit.
    KEYFILE="${AC_API_KEY_PATH:-}"
    if [ -z "$KEYFILE" ]; then
        KEYFILE="$(mktemp -t agxntz-authkey).p8"
        CLEANUP+=("$KEYFILE")
        printf '%s' "$AC_API_KEY_P8" | base64 --decode > "$KEYFILE"
    fi

    submit() {
        xcrun notarytool submit "$1" \
            --key "$KEYFILE" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" --wait
    }

    echo "==> Notarizing (this waits for Apple, usually 1-5 min)"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    submit "$ZIP"
    echo "==> Stapling ticket"
    xcrun stapler staple "$BUNDLE"
    rm -f "$ZIP"
else
    echo "==> Skipping notarization (no Developer ID / API key)"
fi

echo "==> Zipping $ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

# The download for people: a disk image with the app and an Applications
# shortcut to drag it onto. Built from the already-stapled app, then the image
# itself is signed, notarized and stapled, so both the DMG and the app copied
# out of it verify offline.
echo "==> Building $DMG"
STAGE="$(mktemp -d -t agxntz-dmg)"
ditto "$BUNDLE" "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if notarize; then
    echo "==> Notarizing $DMG"
    submit "$DMG"
    xcrun stapler staple "$DMG"
fi

# Sparkle update signature + appcast. The appcast is published as a release
# asset; the app's SUFeedURL points at releases/latest/download/appcast.xml.
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || [ "${SPARKLE_SIGN:-}" = "1" ]; then
    echo "==> Signing update for Sparkle"
    if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
        EDKEY="$(mktemp -t agxntz-edkey)"
        CLEANUP+=("$EDKEY")
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$EDKEY"
        SIG_ATTRS="$("$SPARKLE_BIN/sign_update" --ed-key-file "$EDKEY" "$ZIP")"
    else
        SIG_ATTRS="$("$SPARKLE_BIN/sign_update" --account agxntz "$ZIP")"
    fi
    case "$SIG_ATTRS" in *edSignature=*length=*) ;; *) echo "sign_update failed: $SIG_ATTRS" >&2; exit 1;; esac

    MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUNDLE/Contents/Info.plist")"
    URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$ZIP")"
    cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" $SIG_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
    xmllint --noout "$APPCAST"
    echo "==> Wrote $APPCAST"
fi

echo "==> Done: $ZIP, $DMG"
if notarize; then
    xcrun stapler validate "$BUNDLE" && echo "    app notarization ticket stapled OK"
    xcrun stapler validate "$DMG" && echo "    dmg notarization ticket stapled OK"
fi
