#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sqlite-fire-tests.XXXXXX")
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT HUP INT TERM

# Report the process boundary, not just the last test that started.
stage=setup
finish() {
    status=$?
    cleanup_status=0
    cleanup || cleanup_status=$?
    if [ "$status" -eq 0 ]; then status=$cleanup_status; fi
    printf 'sqlite-fire runner: stage=%s exit=%s cleanup_exit=%s\n' \
        "$stage" "$status" "$cleanup_status" >&2
    exit "$status"
}
trap finish EXIT

cd "$ROOT"
stage=constant_namespaces
python3 tests/test_constant_namespaces.py
stage=native_strict
make -C native strict-test
stage=native_build
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
    stage="build:$name"
    mojo build -I src "$test" -o "$output"
    stage="run:$name"
    "$output"
done
stage=complete
