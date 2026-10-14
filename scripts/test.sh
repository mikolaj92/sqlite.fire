#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sqlite-fire-tests.XXXXXX")
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT"
python3 tests/test_constant_namespaces.py
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
    printf 'Mojo test passed: %s\n' "$name"
done
printf 'All SQLite Fire tests passed.\n'
