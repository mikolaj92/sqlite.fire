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

make -C native
uv run mojo run examples/basic.mojo -I src

Test kontraktu:

```sh
uv run mojo run tests/test_sqlite.mojo -I src
```

Alternatywnie z lokalnym `make`:

```sh
make -C native
uv run mojo run examples/basic.mojo -I src
uv run mojo run tests/test_sqlite.mojo -I src
```

Biblioteka ładuje `native/libsqlite_fire.dylib` na macOS. Na Linuxie należy
zbudować `libsqlite_fire.so` i ustawić `LD_LIBRARY_PATH=native`.

`Connection` i `Statement` są właścicielami zasobów. Statement należy zużyć przez
`step()` do końca albo pozwolić mu wyjść poza zakres przed zamknięciem połączenia.
`Connection.close()` pozwala jawnie zamknąć połączenie; destruktor zamyka je
automatycznie. SQLite odracza fizyczne zamknięcie do zwolnienia aktywnych statementów.

API obejmuje `Connection.execute`, `Connection.query`, `Statement.step` oraz
odczyt liczby, tekstu, typu i nazwy kolumn. `NULL` jest raportowany jako typ
`SQLITE_NULL`, a `column_text` zwraca pusty tekst dla wartości NULL.
Parametry zapytań i BLOB-y nie są jeszcze częścią tego małego ABI.

