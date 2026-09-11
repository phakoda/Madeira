#!/usr/bin/env bash
# Rebuild before each run; require an explicitly chosen, authorized Metal host.
# This integration suite needs the pinned DXMT sources and a running macOS daemon.
set -euo pipefail
cd "$(dirname "$0")"
if [[ $# != 1 || -z "$1" ]]; then
    echo "Usage: RMETAL_TOKEN=... $0 <your-metal-host>" >&2
    exit 2
fi
HOST="$1"
CC="${CC:-clang}"
: "${RMETAL_TOKEN:?set RMETAL_TOKEN for your Metal daemon}"
for header in wmt_remote_pack.h wmt_remote_client.h; do
    if [[ ! -f "../dxmt/src/winemetal/unix/$header" ]]; then
        echo "Missing pinned DXMT sources ($header). Initialize the submodule first." >&2
        exit 2
    fi
done
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-remote-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
echo "  protocol: v$(sed -n 's/^#define RM_VERSION \([0-9]*\)u.*/\1/p' protocol.h)"
run_suite() {
    local name="$1" status
    shift
    if "$@" > "$OUT/$name.log" 2>&1; then
        tail -n 1 "$OUT/$name.log" | sed "s/^/  $name: /"
    else
        status=$?
        # Do not hide a failing test behind tail/sed, and keep its full output.
        cat "$OUT/$name.log" >&2
        echo "$name suite failed (exit $status)" >&2
        return "$status"
    fi
}
"$CC" -O1 -w -I. -o "$OUT/wire_test" schema/wire_test.c
run_suite wire "$OUT/wire_test"
"$CC" -O1 -w -fdeclspec -I ../dxmt/src/winemetal -o "$OUT/pack_test" schema/pack_test.c
run_suite pack "$OUT/pack_test"
"$CC" -O1 -w -o "$OUT/rmclient_test" guest/rmclient_test.c
run_suite client env DXMT_REMOTE_METAL="$HOST" "$OUT/rmclient_test"
"$CC" -O1 -w -I. -o "$OUT/rmtest" guest/rmtest.c
run_suite rmtest "$OUT/rmtest" "$HOST"
"$CC" -O1 -w -I. -o "$OUT/rmreplay" guest/rmreplay.c
run_suite replay "$OUT/rmreplay" "$HOST"
