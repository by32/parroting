#!/usr/bin/env bash
# Assemble Parrot.app around an already-built parrot binary.
#
#   scripts/bundle-app.sh <binary> <version> <outdir>
#
# Produces <outdir>/Parrot.app, unsigned. Signing and notarization are a
# separate step (scripts/sign-notarize.sh) so an unsigned build still works
# when no certificate is configured.
#
# Why a bundle at all, when parrot is a single binary: Accessibility grants for
# a bare executable are keyed to its code-signing identity, which for an
# unsigned binary is its cdhash. Every upgrade changes the hash, so the grant
# silently stops applying and dictation dies until the user re-toggles it. A
# signed bundle has a stable identity, so the grant survives upgrades.

set -euo pipefail

BIN="${1:?usage: bundle-app.sh <binary> <version> <outdir>}"
VERSION="${2:?usage: bundle-app.sh <binary> <version> <outdir>}"
OUTDIR="${3:?usage: bundle-app.sh <binary> <version> <outdir>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

if [ ! -f "$BIN" ]; then
    red "no binary at $BIN"
    exit 1
fi

APP="$OUTDIR/Parrot.app"
CONTENTS="$APP/Contents"

dim "→ assembling $APP ($VERSION)..."
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

install -m 0755 "$BIN" "$CONTENTS/MacOS/parrot"

# The bundle version has to agree with the binary, or `parrot --version` and
# the About pane disagree and upgrade checks get confusing.
sed "s/__VERSION__/${VERSION}/g" "$REPO_ROOT/packaging/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Optional: drop packaging/Parrot.icns in and it gets picked up. Without it the
# app shows the generic bundle icon, which is ugly but harmless.
if [ -f "$REPO_ROOT/packaging/Parrot.icns" ]; then
    cp "$REPO_ROOT/packaging/Parrot.icns" "$CONTENTS/Resources/Parrot.icns"
    plutil -replace CFBundleIconFile -string "Parrot" "$CONTENTS/Info.plist"
    dim "  icon: Parrot.icns"
else
    dim "  icon: none (add packaging/Parrot.icns to include one)"
fi

plutil -lint "$CONTENTS/Info.plist" >/dev/null

EMBEDDED=$("$CONTENTS/MacOS/parrot" --version)
if [ "$EMBEDDED" != "$VERSION" ]; then
    red "✗ binary reports $EMBEDDED but bundling as $VERSION"
    red "  bump Version.current in Sources/parrot/Version.swift"
    exit 1
fi

green "✓ $APP"
dim "  version:    $VERSION"
dim "  identifier: $(plutil -extract CFBundleIdentifier raw -o - "$CONTENTS/Info.plist")"
