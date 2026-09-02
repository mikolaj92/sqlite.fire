#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
make -C "$ROOT/native"
case "$(uname -s)" in
    Darwin) export SQLITE_FIRE_LIBRARY="$ROOT/native/libsqlite_fire.dylib" ;;
    Linux) export SQLITE_FIRE_LIBRARY="$ROOT/native/libsqlite_fire.so" ;;
    *) echo "unsupported platform: $(uname -s) (supported: macOS, Linux)" >&2; exit 2 ;;
esac
mojo run -I "$ROOT/src" "$ROOT/examples/basic.mojo"
