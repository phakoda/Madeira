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
echo 'Portable suites passed.'
