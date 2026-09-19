#!/usr/bin/env bash
#
# Build, sign, (optionally) notarize, and zip agxntz.app for distribution.
#
# Local dev bundle (ad-hoc signed, no notarization):
#   ./scripts/package.sh
#
# Signed + notarized release (used by CI and for local release builds):
#   VERSION=0.1.0 \
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   AC_APPLE_ID="you@example.com" AC_PASSWORD="app-specific-pw" AC_TEAM_ID="TEAMID" \
#   ./scripts/package.sh
#
# Signing is skipped (ad-hoc) when SIGNING_IDENTITY is unset. Notarization runs
# only when SIGNING_IDENTITY is a real identity AND Apple credentials are set.
set -euo pipefail
cd "$(dirname "$0")/.."

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
    [ -n "${AC_APPLE_ID:-}" ] && [ -n "${AC_PASSWORD:-}" ] && [ -n "${AC_TEAM_ID:-}" ]
}

if notarize; then
    echo "==> Notarizing (this waits for Apple, usually 1-5 min)"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP"
    xcrun notarytool submit "$ZIP" \
        --apple-id "$AC_APPLE_ID" --password "$AC_PASSWORD" --team-id "$AC_TEAM_ID" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$BUNDLE"
    rm -f "$ZIP"
else
    echo "==> Skipping notarization (no Developer ID / Apple credentials)"
fi

echo "==> Zipping $ZIP"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> Done: $ZIP"
if notarize; then
    xcrun stapler validate "$BUNDLE" && echo "    notarization ticket stapled OK"
fi
