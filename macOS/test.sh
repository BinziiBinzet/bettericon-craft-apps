#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:?Usage: test.sh BetterIcon.app [NEW_FIXTURE_DIRECTORY]}"
stage="$(mktemp -d "${TMPDIR:-/tmp}/bettericon-checks.XXXXXXXX")"
trap 'rm -f "$stage/checks"' EXIT
sources=()
for source in "$here"/Sources/*.swift; do
    if [[ "$(basename "$source")" != "main.swift" ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -I "$here/Native" "${sources[@]}" "$here/Tests/Checks.swift" -o "$stage/checks"
"$stage/checks" "$app" "${2:-$stage/fixture}"
