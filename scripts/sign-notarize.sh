#!/usr/bin/env bash
# Sign, notarize, staple, and wrap Parrot.app in a distributable DMG.
#
#   scripts/sign-notarize.sh <path-to-Parrot.app> <version> <outdir>
#
# Requires a "Developer ID Application" certificate. An "Apple Distribution"
# or "Apple Development" cert will not do — those are for the App Store and for
# local development, and Gatekeeper rejects them for direct distribution.
#
# Identity (optional, auto-discovered from the keychain otherwise):
#   SIGN_IDENTITY   e.g. "Developer ID Application: Your Name (TEAMID)"
#
# Notarization credentials, either an App Store Connect API key (preferred —
# does not put a password in the process table):
#   NOTARY_KEY_P8      base64 of the AuthKey_XXXX.p8
#   NOTARY_KEY_ID      the key's ID
#   NOTARY_ISSUER_ID   the issuer UUID
# or an Apple ID with an app-specific password:
#   NOTARY_APPLE_ID / NOTARY_PASSWORD / NOTARY_TEAM_ID
#
# SKIP_NOTARIZE=1 signs and builds the DMG without submitting, for local
# smoke tests. The result will not pass Gatekeeper on another Mac.

set -euo pipefail

APP="${1:?usage: sign-notarize.sh <Parrot.app> <version> <outdir>}"
VERSION="${2:?usage: sign-notarize.sh <Parrot.app> <version> <outdir>}"
OUTDIR="${3:?usage: sign-notarize.sh <Parrot.app> <version> <outdir>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/packaging/parrot.entitlements"

dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH" || true; }
trap cleanup EXIT

SCRATCH="$(mktemp -d)"

[ -d "$APP" ] || { red "no app bundle at $APP"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { red "no entitlements at $ENTITLEMENTS"; exit 1; }

# ---------------------------------------------------------------- identity

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning \
        | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' \
        | head -1)
fi

if [ -z "$SIGN_IDENTITY" ]; then
    red "no 'Developer ID Application' certificate found in the keychain"
    red "available codesigning identities:"
    security find-identity -v -p codesigning | sed -nE 's/.*"([^"]+)".*/  \1/p' >&2
    red "create one at https://developer.apple.com/account/resources/certificates"
    red "(Xcode: Settings -> Accounts -> Manage Certificates -> + -> Developer ID Application)"
    exit 1
fi

dim "→ signing identity: $SIGN_IDENTITY"

# ------------------------------------------------------------ notary creds

notary_args=()
if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if [ -n "${NOTARY_KEY_P8:-}" ]; then
        : "${NOTARY_KEY_ID:?NOTARY_KEY_P8 set but NOTARY_KEY_ID missing}"
        : "${NOTARY_ISSUER_ID:?NOTARY_KEY_P8 set but NOTARY_ISSUER_ID missing}"
        KEYFILE="$SCRATCH/AuthKey.p8"
        (umask 077; printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$KEYFILE")
        notary_args=(--key "$KEYFILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
        dim "→ notarizing with App Store Connect API key"
    elif [ -n "${NOTARY_APPLE_ID:-}" ]; then
        : "${NOTARY_PASSWORD:?NOTARY_APPLE_ID set but NOTARY_PASSWORD missing}"
        : "${NOTARY_TEAM_ID:?NOTARY_APPLE_ID set but NOTARY_TEAM_ID missing}"
        notary_args=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
        dim "→ notarizing with Apple ID + app-specific password"
    else
        red "no notarization credentials; set NOTARY_KEY_P8 or NOTARY_APPLE_ID"
        red "(or SKIP_NOTARIZE=1 to sign only)"
        exit 1
    fi
fi

# Pull one field out of notarytool's flat JSON without a JSON parser: split on
# structural characters so each key lands on its own line.
json_field() {
    printf '%s' "$2" | tr '{},' '\n\n\n' \
        | sed -nE "s/.*\"$1\" *: *\"([^\"]+)\".*/\1/p" | head -1
}

notarize() {
    local artifact="$1" json status id
    dim "→ submitting $(basename "$artifact") for notarization (minutes, not seconds)..."
    if ! json=$(xcrun notarytool submit "$artifact" "${notary_args[@]}" \
            --wait --output-format json 2>&1); then
        red "✗ notarytool submit failed"
        printf '%s\n' "$json" >&2
        return 1
    fi
    status=$(json_field status "$json")
    id=$(json_field id "$json")
    if [ "$status" != "Accepted" ]; then
        red "✗ notarization returned '${status:-unknown}' for submission ${id:-unknown}"
        [ -n "$id" ] && xcrun notarytool log "$id" "${notary_args[@]}" >&2 || true
        return 1
    fi
    green "  ✓ accepted ($id)"
}

# ------------------------------------------------------------------- sign

# No --deep: SwiftPM links statically, so the bundle holds exactly one Mach-O
# and signing the bundle covers it. --options runtime is what notarization
# requires; --timestamp is what lets the signature outlive the certificate.
dim "→ signing $(basename "$APP")..."
codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP"

codesign --verify --strict --verbose=2 "$APP"
green "✓ signed"

# ---------------------------------------------------------------- notarize

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    red "! SKIP_NOTARIZE=1 — not submitting; this build will not pass Gatekeeper elsewhere"
else
    ZIP="$SCRATCH/Parrot.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"

    dim "→ stapling ticket to the bundle..."
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    green "✓ stapled"

    # The real question is not whether the signature is valid but whether
    # Gatekeeper will launch it, so ask Gatekeeper.
    if spctl -a -vvv -t exec "$APP" 2>&1 | tee "$SCRATCH/spctl.log"; then
        green "✓ $(sed -nE 's/.*source=(.*)/gatekeeper source: \1/p' "$SCRATCH/spctl.log" | head -1)"
    else
        red "✗ Gatekeeper rejected the bundle"
        cat "$SCRATCH/spctl.log" >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------- dmg

DMG="$OUTDIR/Parrot-${VERSION}-arm64.dmg"
DMGROOT="$SCRATCH/dmgroot"
mkdir -p "$DMGROOT"

# ditto rather than cp -R: it preserves the extended attributes the stapled
# notarization ticket lives in, so the copy inside the DMG stays notarized.
ditto "$APP" "$DMGROOT/Parrot.app"
ln -s /Applications "$DMGROOT/Applications"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    xcrun stapler validate "$DMGROOT/Parrot.app" \
        || { red "✗ ticket did not survive the copy into the DMG"; exit 1; }
fi

dim "→ building $(basename "$DMG")..."
rm -f "$DMG"
hdiutil create \
    -volname "Parrot $VERSION" \
    -srcfolder "$DMGROOT" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

# Sign the DMG too, otherwise the disk image itself trips Gatekeeper on
# download even though the app inside is fine.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

green "✓ $DMG"
dim "  $(du -h "$DMG" | cut -f1)"
