#!/usr/bin/env bash
# Cross-compiles on GitHub Actions only. Do not execute on the development Mac.
set -euo pipefail
if [[ "${CI:-}" != true || "${GITHUB_ACTIONS:-}" != true ]]; then
    echo 'Mesa compilation is restricted to GitHub Actions for this project.' >&2
    exit 1
fi
MESA_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$MESA_SCRIPT_DIR/build.py" "$@"
