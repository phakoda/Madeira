#!/usr/bin/env bash
# Compiles and executes production C++ memory code. Run in CI, not on the
# development computer while the user's no-local-compilation constraint applies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-guest-memory.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
CXXFLAGS=(-std=c++17 -Wall -Wextra -Werror -g -O1 -pthread)
CFLAGS=(-std=c11 -Wall -Wextra -Werror -g -O1)
if [[ "${SANITIZE:-1}" == 1 ]]; then
    CXXFLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    CFLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
"${CXX:-clang++}" "${CXXFLAGS[@]}" -c "$ROOT/app/Madeira/GuestMemory32.cpp" -o "$OUT/memory.o"
"${CXX:-clang++}" "${CXXFLAGS[@]}" "$ROOT/tests/guest_memory32_test.cpp" "$OUT/memory.o" -o "$OUT/memory-test"
"$OUT/memory-test"
"${CC:-clang}" "${CFLAGS[@]}" -c "$ROOT/tests/guest_memory32_c_test.c" -o "$OUT/c-test.o"
"${CXX:-clang++}" "${CXXFLAGS[@]}" "$OUT/c-test.o" "$OUT/memory.o" -o "$OUT/c-test"
"$OUT/c-test"
