#!/usr/bin/env bash
#
# Build, sign, (optionally) notarize, and zip agxntz.app for distribution.
#
# Local dev bundle (ad-hoc signed, no notarization):
#   ./scripts/package.sh
#
# Signed + notarized release (used by CI and for local release builds).
# Notarization uses an App Store Connect API key (.p8). Provide the key either
# as a file path (local) or base64-encoded (CI):
#   VERSION=0.1.0 \
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   AC_API_KEY_ID="KEYID" AC_API_ISSUER_ID="ISSUER-UUID" \
#   AC_API_KEY_PATH="$HOME/private_keys/AuthKey_KEYID.p8" \
#   ./scripts/package.sh
#
# In CI, pass AC_API_KEY_P8 (base64 of the .p8) instead of AC_API_KEY_PATH.
#
# Signing is skipped (ad-hoc) when SIGNING_IDENTITY is unset. Notarization runs
# only when SIGNING_IDENTITY is a real identity AND the API-key vars are set.
set -euo pipefail
cd "$(dirname "$0")/.."

CLEANUP=()
cleanup() { for f in "${CLEANUP[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done; }
trap cleanup EXIT

APP=agxntz
VERSION="${VERSION:-dev}"
VERSION="${VERSION#v}"                       # tolerate a leading v (git tag)
IDENTITY="${SIGNING_IDENTITY:--}"            # "-" = ad-hoc
BUNDLE="dist/$APP.app"
ZIP="dist/$APP-$VERSION.zip"

echo "==> Building $APP ($VERSION)"
swift build -c release

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE" "$ZIP"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Support/Info.plist "$BUNDLE/Contents/Info.plist"
cp ".build/release/$APP" "$BUNDLE/Contents/MacOS/$APP"

# Stamp the release version into the bundle (short version = marketing version).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true

echo "==> Signing (identity: $IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$BUNDLE"
else
    # Hardened runtime + secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
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

    echo "==> Notarizing (this waits for Apple, usually 1-5 min)"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    xcrun notarytool submit "$ZIP" \
        --key "$KEYFILE" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$BUNDLE"
    rm -f "$ZIP"
else
    echo "==> Skipping notarization (no Developer ID / API key)"
fi

echo "==> Zipping $ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> Done: $ZIP"
if notarize; then
    xcrun stapler validate "$BUNDLE" && echo "    notarization ticket stapled OK"
fi
