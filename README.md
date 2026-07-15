# sqlite.fire

Bezpośredni dostęp do SQLite z Mojo przez mały most C ABI.

Projekt używa `uv` do środowiska i toolchainu Mojo oraz systemowego SQLite.

## Wymagania

- `uv`
- systemowa biblioteka SQLite (`libsqlite3`)
- macOS lub Linux

Instalacja zależności deweloperskich:

```sh
uv sync --dev
```
## Układ

- `src/sqlite_fire/sqlite.mojo` — publiczny wrapper Mojo.
## Uruchomienie

```sh
make -C native
uv run mojo build examples/basic.mojo -I src -o /tmp/sqlite-fire-example \
  -Xlinker -Lnative -Xlinker -lsqlite_fire
DYLD_LIBRARY_PATH=native /tmp/sqlite-fire-example  # macOS
```

Test kontraktu:

```sh
uv run mojo build tests/test_sqlite.mojo -I src -o /tmp/sqlite-fire-test \
  -Xlinker -Lnative -Xlinker -lsqlite_fire
DYLD_LIBRARY_PATH=native /tmp/sqlite-fire-test
```

Biblioteka ładuje `native/libsqlite_fire.dylib` na macOS. Na Linuxie należy
zbudować `libsqlite_fire.so` i ustawić `LD_LIBRARY_PATH=native`.

API obejmuje `Connection.execute`, `Connection.query`, `Statement.step` oraz
odczyt liczby, tekstu, typu i nazwy kolumn. Parametry zapytań i BLOB-y nie są
jeszcze częścią tego małego ABI.

