#!/usr/bin/env bash
# Assert a built parrot binary actually has the optional features compiled in.
#
# LocalRefiner lives behind `#if canImport(FoundationModels)`. If the build
# runs against an SDK older than macOS 26 the guard silently evaluates false,
# the file compiles to nothing, and `--refine local` fails at runtime with
# "requires macOS 26.0 or later" even for users who are on 26. That is an easy
# regression to ship, so fail the build instead of the user.

set -euo pipefail

BIN="${1:?usage: verify-binary.sh <path-to-parrot>}"

if [ ! -f "$BIN" ]; then
    printf "\033[31mno binary at %s\033[0m\n" "$BIN" >&2
    exit 1
fi

fail=0

check_arch() {
    if ! file "$BIN" | grep -q "arm64"; then
        printf "\033[31m✗ not an arm64 binary:\033[0m %s\n" "$(file "$BIN")" >&2
        fail=1
    else
        printf "\033[32m✓ arm64\033[0m\n"
    fi
}

check_framework() {
    local framework="$1"
    if otool -L "$BIN" | grep -q "${framework}.framework"; then
        printf "\033[32m✓ links %s\033[0m\n" "$framework"
    else
        printf "\033[31m✗ %s is not linked\033[0m\n" "$framework" >&2
        printf "  build against the macOS 26 SDK (runs-on: macos-26)\n" >&2
        fail=1
    fi
}

check_arch
check_framework FoundationModels

if [ "$fail" -ne 0 ]; then
    printf "\033[31mbinary verification failed\033[0m\n" >&2
    exit 1
fi

printf "\033[32mbinary verification passed\033[0m\n"
