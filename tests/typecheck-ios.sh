#!/usr/bin/env bash
# Apple SDK semantic check of all project Swift + bridge declarations, no link.
# Native Objective-C/C++ compilation and device validation are separate gates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null; then
    echo 'This check requires macOS and full Xcode with the iPhoneOS SDK.' >&2
    exit 2
fi
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 2; }
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "${VERSION%%.*}" -lt 26 ]]; then
    echo 'The existing UI uses iOS 26 SDK APIs; select Xcode with iPhoneOS SDK 26 or newer.' >&2
    exit 2
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-typecheck.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
python3 "$ROOT/tests/check-project.py" --swift-paths > "$OUT/sources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < "$OUT/sources"
xcrun --sdk iphoneos swiftc -typecheck -parse-as-library -swift-version 5 \
    -module-name Madeira -sdk "$SDK" -target arm64-apple-ios17.0 \
    -module-cache-path "$OUT/modules" \
    -import-objc-header "$ROOT/app/Madeira/Madeira-Bridging-Header.h" \
    "${SOURCES[@]}"
echo 'Apple-SDK Swift typecheck passed; no app binary was linked or device-tested.'
