#!/usr/bin/env bash
# Exercise the production installer before shipping a template. This validates
# gzip/tar integrity, path/type/size limits AND essential prefix files, rather
# than accepting a failed tar|grep pipeline as an empty list of bad links.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:-$ROOT/app/Madeira/prefix-template.tar.gz}"
[[ -f "$ARCHIVE" ]] || { echo "check-prefix-template: no such archive: $ARCHIVE" >&2; exit 1; }
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-prefix-check.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
HOST_CC="${HOST_CC:-clang}"
"$HOST_CC" -std=c11 -Wall -Wextra -Werror -O1 \
    "$ROOT/tests/prefix_extractor_driver.c" "$ROOT/app/Madeira/PrefixExtractor.c" \
    -lz -o "$OUT/check-prefix"
"$OUT/check-prefix" "$ARCHIVE" "$OUT/prefix"
"$OUT/check-prefix" --ready "$OUT/prefix"
echo 'check-prefix-template: OK -- production extraction and readiness checks passed'
