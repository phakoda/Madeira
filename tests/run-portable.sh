#!/usr/bin/env bash
# Linux/macOS tests of production logic. No iOS SDK or network required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
CC="${CC:-clang}"
CFLAGS=(-std=c11 -Wall -Wextra -Werror -g -O1)
if [[ "${SANITIZE:-1}" == 1 ]]; then
    CFLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
"$CC" "${CFLAGS[@]}" -I "$ROOT/research/remote-metal" \
    "$ROOT/research/remote-metal/schema/wire_test.c" -o "$OUT/wire-test"
"$OUT/wire-test"
"$CC" "${CFLAGS[@]}" "$ROOT/tests/input_queue_test.c" -o "$OUT/input-test"
"$OUT/input-test"
"$CC" "${CFLAGS[@]}" "$ROOT/tests/surface_queue_test.c" -o "$OUT/surface-queue-test"
"$OUT/surface-queue-test"
swiftc -warnings-as-errors -o "$OUT/geometry-input-test" \
    "$ROOT/app/Madeira/DisplayGeometry.swift" "$ROOT/app/Madeira/GuestInputState.swift" \
    "$ROOT/tests/swift/GeometryInputTests.swift"
"$OUT/geometry-input-test"
swiftc -frontend -parse "$ROOT/app/Madeira/ContentView.swift"
swiftc -warnings-as-errors -o "$OUT/log-test" \
    "$ROOT/app/Madeira/LogRecord.swift" "$ROOT/app/Madeira/LogLineFramer.swift" \
    "$ROOT/app/Madeira/AppendLogFile.swift" "$ROOT/app/Madeira/LogTail.swift" \
    "$ROOT/app/Madeira/LogPattern.swift" "$ROOT/tests/swift/LogTests.swift"
"$OUT/log-test"
swiftc -frontend -parse "$ROOT/app/Madeira/LogStore.swift"
echo 'Portable suites passed.'
