# Releasing

Each release publishes three assets: `agxntz.dmg` (the download people install from),
`agxntz.zip` (what Sparkle updates from) and `appcast.xml` (the Sparkle feed). The DMG
and the app inside it are each notarized and stapled.

Releases are produced by GitHub Actions (`.github/workflows/release.yml`): push
a version tag and CI builds on macOS, signs with your Developer ID, notarizes
with Apple, and publishes a GitHub Release with the zipped app attached.

```sh
git tag v0.1.0
git push origin v0.1.0
```

This requires an [Apple Developer Program](https://developer.apple.com/programs/)
membership and these repository secrets
(**Settings → Secrets and variables → Actions**):

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Base64 of the **Developer ID Application** certificate exported as `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PWD` | Password of that `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string (unlocks a throwaway CI keychain) |
| `SIGNING_IDENTITY` | The identity name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `AC_API_KEY_P8` | Base64 of your App Store Connect API key `.p8` (`base64 -i AuthKey_XXXX.p8 \| pbcopy`) |
| `AC_API_KEY_ID` | The API key ID (the `XXXX` in `AuthKey_XXXX.p8`) |
| `AC_API_ISSUER_ID` | The App Store Connect issuer ID (a UUID) |
| `SPARKLE_ED_PRIVATE_KEY` | The Sparkle EdDSA update key (`generate_keys --account agxntz -x file`); signs `agxntz.zip` and `appcast.xml` |

Notarization uses an [App Store Connect API key](https://appstoreconnect.apple.com/access/integrations/api)
(Keys tab → generate a key with the *Developer* role → download the `.p8`; the
issuer ID is shown on that page). Export the signing certificate from
**Keychain Access** → your *Developer ID Application* cert → right-click →
**Export** as `.p12`.

You can build a signed, notarized zip locally the same way CI does — point at
the `.p8` on disk instead of base64:

```sh
VERSION=0.1.0 \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
AC_API_KEY_ID="XXXX" AC_API_ISSUER_ID="issuer-uuid" \
AC_API_KEY_PATH="$HOME/private_keys/AuthKey_XXXX.p8" \
make release
```

With no signing env vars, `make release` just produces an ad-hoc-signed zip for
local testing.
