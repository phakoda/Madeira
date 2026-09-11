#!/usr/bin/env bash
# Source from native build scripts after BUILD_DIR is set. Fresh object staging
# prevents failed/removed sources from silently reusing old .o/archive members.
# GPL-3.0-or-later.

madeira_begin_native_build() {
    OBJ_DIR="$(mktemp -d "$BUILD_DIR/.objects.XXXXXX")" || return 1
    echo "Isolated objects and diagnostics: $OBJ_DIR"
    trap 'madeira_finish_native_build "$?"' EXIT
}

madeira_finish_native_build() {
    local status="$1"
    if [[ "$status" == 0 ]]; then
        rm -rf -- "$OBJ_DIR"
    else
        echo "Build failed; objects and compiler diagnostics retained in: $OBJ_DIR" >&2
    fi
    # Do not turn a compilation failure into a successful cleanup result.
    return "$status"
}

# Publish only a readable, nonempty, self-contained archive, via an atomic rename
# in the destination directory. Every failure leaves the previous app artifact
# untouched; even calling this function inside `if` must not mask copy failures.
madeira_publish_archive() (
    local source="$1" destination="$2" members signature temp
    [[ -s "$source" ]] || { echo "Archive missing/empty: $source" >&2; exit 1; }
    signature="$(head -c 8 "$source")" || exit 1
    [[ "$signature" == '!<arch>' ]] || { echo "Not a regular archive: $source" >&2; exit 1; }
    members="$(ar t "$source")" || exit 1
    [[ -n "$members" ]] || { echo "Archive has no members: $source" >&2; exit 1; }
    temp="$(mktemp "$(dirname "$destination")/.$(basename "$destination").publish.XXXXXX")" || exit 1
    trap 'rm -f -- "$temp"' EXIT
    cp "$source" "$temp" || exit 1
    chmod 644 "$temp" || exit 1
    mv -f "$temp" "$destination" || exit 1
)
