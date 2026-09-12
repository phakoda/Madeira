#!/bin/bash
# This compiles a Foundation-only test executable. Run on GitHub Actions/macOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/madeira-library-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
  "$ROOT/app/Madeira/LibraryModels.swift" \
  "$ROOT/app/Madeira/LaunchPlan.swift" \
  "$ROOT/tests/swift/LibraryTests.swift" \
  -o "$WORK/library-tests"
"$WORK/library-tests"
