#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sqlite-fire-tests.XXXXXX")
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT"
make -C native strict-test

case "$(uname -s)" in
    Darwin)
        export DYLD_LIBRARY_PATH="$ROOT/native${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
        ;;
    Linux)
        export LD_LIBRARY_PATH="$ROOT/native${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ;;
    *)
        echo "unsupported platform: $(uname -s) (supported: macOS, Linux)" >&2
        exit 2
        ;;

esac
for test in tests/*.mojo; do
    name=$(basename "$test" .mojo)
    output="$TMPDIR/$name"
    uv run mojo build -I src "$test" -o "$output"
    "$output"
done
