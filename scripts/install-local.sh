#!/usr/bin/env bash
# Build, sign, and install Parrot.app to /Applications in one step.
#
#   scripts/install-local.sh
#
# Signs with the best certificate in the keychain: a Developer ID Application
# cert if there is one (also distributable), otherwise Apple Development (fine
# on this Mac, rejected by Gatekeeper anywhere else). Override with
# SIGN_IDENTITY. Set SKIP_LAUNCH=1 to install without relaunching.
#
# Notarization is deliberately not part of this. It exists so *other* Macs will
# run a downloaded app; it does nothing for an app you signed yourself and run
# locally. scripts/sign-notarize.sh covers the release path.
#
# Why sign at all for local use: macOS ties an Accessibility grant to the app's
# designated requirement. Signed, that requirement is bundle ID + certificate,
# which is identical across rebuilds, so the grant persists. Unsigned, it
# degrades to a hash of the code itself, so every rebuild silently revokes it
# while leaving the checkbox ticked.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DEST="/Applications/Parrot.app"

dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

cd "$REPO_ROOT"

# ------------------------------------------------------------------- build

dim "→ building release..."
swift build -c release
BIN=".build/release/parrot"
./scripts/verify-binary.sh "$BIN" >/dev/null

# The binary is the single source of truth for the version; bundle-app.sh
# cross-checks it against what we pass in.
VERSION="$("$BIN" --version)"

# ---------------------------------------------------------------- identity

find_identity() {
    security find-identity -v -p codesigning \
        | sed -nE "s/.*\"($1: [^\"]+)\".*/\1/p" | head -1
}

IDENTITY_KIND="override"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(find_identity "Developer ID Application")"
    IDENTITY_KIND="developer-id"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(find_identity "Apple Development")"
    IDENTITY_KIND="apple-development"
fi
if [ -z "$SIGN_IDENTITY" ]; then
    red "no usable signing certificate in the keychain"
    red "need a 'Developer ID Application' or 'Apple Development' identity:"
    security find-identity -v -p codesigning | sed -nE 's/.*"([^"]+)".*/  \1/p' >&2
    exit 1
fi

# ------------------------------------------------------------ bundle + sign

./scripts/bundle-app.sh "$BIN" "$VERSION" "$SCRATCH" >/dev/null
APP="$SCRATCH/Parrot.app"

dim "→ signing as $SIGN_IDENTITY"
codesign --force --timestamp --options runtime \
    --entitlements "$REPO_ROOT/packaging/parrot.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP"
codesign --verify --strict "$APP"

# The whole point of signing here is a requirement that does NOT pin the code
# hash. If signing silently fell back to ad-hoc, it would, and the Accessibility
# grant would break on the next rebuild — so fail loudly instead.
#
# codesign comments the line out for an ad-hoc signature ("# designated => ..."),
# so the optional leading "#" is load-bearing: without it this reads as empty and
# the cdhash check below silently passes.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -nE 's/^#? *designated => //p')"
if [ -z "$REQUIREMENT" ]; then
    red "✗ could not read the designated requirement; refusing to install"
    codesign -d -r- "$APP" >&2 2>&1 || true
    exit 1
fi
if printf '%s' "$REQUIREMENT" | grep -q "cdhash"; then
    red "✗ the signature pins a cdhash, so the Accessibility grant would not"
    red "  survive the next rebuild:"
    red "    $REQUIREMENT"
    red "  this is what ad-hoc signing (-) produces; use a real certificate."
    exit 1
fi

# --------------------------------------------------------------- install

SUDO=""
[ -w "$(dirname "$APP_DEST")" ] || SUDO="sudo"

WAS_RUNNING=0
if pgrep -f "$APP_DEST/Contents/MacOS/parrot" >/dev/null 2>&1; then
    WAS_RUNNING=1
    dim "→ quitting the running instance..."
    osascript -e 'quit app "Parrot"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "$APP_DEST/Contents/MacOS/parrot" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pkill -f "$APP_DEST/Contents/MacOS/parrot" 2>/dev/null || true
fi

dim "→ installing to $APP_DEST..."
$SUDO rm -rf "$APP_DEST"
# ditto rather than cp -R: preserves the extended attributes a stapled
# notarization ticket lives in, for when this app came from a notarized build.
$SUDO ditto "$APP" "$APP_DEST"

# ---------------------------------------------------------------- report

green "✓ $APP_DEST ($VERSION)"
dim "  identity:    $SIGN_IDENTITY"
dim "  team:        $(codesign -dv "$APP_DEST" 2>&1 | sed -nE 's/^TeamIdentifier=(.*)/\1/p')"
dim "  cdhash:      $(codesign -dvvv "$APP_DEST" 2>&1 | sed -nE 's/^CDHash=(.*)/\1/p')"
dim "  requirement: $REQUIREMENT"

if [ "$IDENTITY_KIND" = "apple-development" ]; then
    yellow "! signed with an Apple Development cert: fine on this Mac, but it"
    yellow "  expires in about a year and Gatekeeper will reject it elsewhere."
fi

if [ "${SKIP_LAUNCH:-0}" != "1" ]; then
    dim "→ launching..."
    open -a "$APP_DEST"
    # Model load takes a while; give it long enough that an Accessibility
    # failure (which exits) actually shows up as one.
    sleep 12
    if pgrep -f "$APP_DEST/Contents/MacOS/parrot" >/dev/null 2>&1; then
        green "✓ running"
    else
        yellow "! not running yet — it may still be loading the model, or"
        yellow "  Accessibility is not granted for Parrot. Check:"
        yellow "    System Settings › Privacy & Security › Accessibility"
    fi
elif [ "$WAS_RUNNING" = "1" ]; then
    dim "  (was running before; SKIP_LAUNCH=1, so not restarted)"
fi
