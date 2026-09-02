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
make -B -C native all

case "$(uname -s)" in
    Darwin)
        export SQLITE_FIRE_LIBRARY="$ROOT/native/libsqlite_fire.dylib"
        ;;
    Linux)
        export SQLITE_FIRE_LIBRARY="$ROOT/native/libsqlite_fire.so"
        ;;
    *)
        echo "unsupported platform: $(uname -s) (supported: macOS, Linux)" >&2
        exit 2
        ;;

esac
for test in tests/*.mojo; do
    name=$(basename "$test" .mojo)
    output="$TMPDIR/$name"
    printf 'Mojo test: %s\n' "$name"
    mojo build -I src "$test" -o "$output"
    "$output"
done
