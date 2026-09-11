#!/usr/bin/env bash
# Check the real Apple AudioToolbox/Mach declarations without needing Wine's
# generated headers. Does not link libntdll, certify the Wine ABI, or play audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null; then
    echo 'This check requires macOS and full Xcode with the iPhoneOS SDK.' >&2
    exit 2
fi
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -fsyntax-only -std=c11 -Wall -Wextra -Werror \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    "$ROOT/build/ntdll-unix/audio_null_ios.c"
echo 'Apple-SDK audio syntax/typecheck passed; no library was linked or audio played.'
