# sqlite.fire

Bezpośredni dostęp do systemowego SQLite z Mojo przez mały most C ABI.

Projekt wspiera macOS i Linux, korzysta z systemowego `libsqlite3` i używa `uv` do
środowiska deweloperskiego oraz toolchainu Mojo.

## Status

Rdzeń biblioteki, rozszerzone API SQLite, obsługa zasobów, testy kontraktowe i natywny
most C ABI są zaimplementowane. Najważniejsze ograniczenia opisano w sekcji
[TODO i ograniczenia](#todo-i-ograniczenia); nie są one ukrywane za niebezpiecznymi
fallbackami ani fałszywymi callbackami Mojo.

## Wymagania i instalacja

- `uv`
- nightly Mojo 1.0 (`mojo` z `https://whl.modular.com/nightly/simple/`)
- systemowa biblioteka SQLite (`libsqlite3`)
- macOS albo Linux

```sh
uv sync --dev --prerelease allow
make -C native
```

Na macOS biblioteka jest budowana jako `native/libsqlite_fire.dylib`. Na Linuxie należy
zbudować `native/libsqlite_fire.so` i w razie potrzeby ustawić `LD_LIBRARY_PATH=native`.

## Co jest zaimplementowane

### Podstawowe API Mojo

`sqlite_fire` eksportuje:

- `Connection` i `Statement` z jawnym, idempotentnym `close()`;
- `SQLiteError` z kodem SQLite i komunikatem;
- `OpenOptions` dla `sqlite3_open_v2` oraz wyboru VFS;
- `SQLiteValue` dla SQL `NULL`, INTEGER, REAL, TEXT i BLOB;
- prepared statements, bindingi pozycyjne i nazwane, `reset()` oraz
  `clear_bindings()`;
- odczyt typów, kolumn, metadanych zapytania i kopii danych BLOB;
- transakcje, savepointy przez SQL, autocommit, changes, last-insert-rowid,
  total changes i busy timeout;
- interrupt, limity SQLite, nazwę pliku i metadane kolumn tabeli;
- akceptowanie końcowych komentarzy i białych znaków, przy odrzucaniu wielu
  instrukcji w jednym `prepare()`.

Dane użytkownika należy przekazywać przez prepared statements i bindingi. Interpolacja
wartości do SQL nie jest obsługiwana jako bezpieczny mechanizm.

### Rozszerzone API

`sqlite_fire` eksportuje także:

- `AdvancedDatabase` — własność bazy albo pożyczony widok utworzony z `Connection`;
- `IncrementalBlob` — odczyt, zapis, reopen, rozmiar i idempotentne zamknięcie;
- `Backup` — step, page count, remaining i idempotentne `finish()`;
- serializację i deserializację bazy z kopiowaniem danych do pamięci Mojo;
- interrupt i limity na poziomie `AdvancedDatabase`;
- `PassthroughVFS` — nazwany VFS delegujący do istniejącego systemowego VFS.

`IncrementalBlob` i `Backup` pożyczają bazę. Wszystkie zależne zasoby muszą zostać
zamknięte przed zamknięciem ich właściciela. `AdvancedDatabase(Connection)` nie zamyka
połączenia; właścicielski `Connection` musi pozostać otwarty przez cały czas życia widoku
i utworzonych przez niego zasobów.

### Native C ABI

`native/sqlite_fire.h` i `native/sqlite_fire.c` udostępniają dodatkowo:

- diagnostykę i wszystkie podstawowe operacje statementów;
- incremental BLOB, backup, serialize/deserialize i extension API;
- scalar functions oraz collations z tokenami własności i bezpiecznym unregister;
- authorizer, progress, trace, update, commit, rollback, WAL i busy hooks;
- rejestrację i wyrejestrowanie passthrough VFS;
- typed SQLite result codes bez zastępowania ich ogólnym błędem.

Callbacki natywne otrzymują synchroniczne wskaźniki SQLite i są przeznaczone dla kodu C.
Token callbacku dezaktywuje callback przed wyrejestrowaniem, a jego `close` jest
idempotentne.

## Współbieżność i własność zasobów

Wspierany model współbieżności to **jedno niezależnie posiadane `Connection` na worker**.
Każde połączenie ma własny uchwyt SQLite. Osobne połączenia `:memory:` są osobnymi bazami;
dla współdzielonego stanu należy użyć wspólnego pliku albo URI i pozostawić blokowanie
plików SQLite.

`Connection` i `Statement` są mutowalnymi właścicielami zasobów. Wrapper nie dodaje
blokad, więc współdzielenie jednego połączenia lub statementu wymaga zewnętrznej
synchronizacji dla każdej operacji i całego czasu życia zasobu. Statement należy do
połączenia, które go utworzyło.

`close()`/`finish()` są idempotentne. Operacja na zamkniętym wrapperze zgłasza
`SQLiteError` z kodem `SQLITE_MISUSE`. Natywne uchwyty BLOB i backup nie powinny być
używane po zamknięciu właścicielskiej bazy.

## TODO i ograniczenia

Poniższe elementy są świadomie niewystawione albo wymagają dalszej pracy:

1. **Callbacki Mojo → C.** Aktualny toolchain Mojo nie daje zweryfikowanej, bezpiecznej
   konwersji funkcji Mojo do adresu callbacku C. Dlatego callbacki są dostępne przez
   natywny C ABI, ale nie jako fałszywe API Mojo.
2. **Mojo scalar/window/aggregate functions.** Rejestracja funkcji użytkownika z Mojo
   wymaga rozwiązania problemu callbacków z punktu 1.
3. **Własny VFS z implementacją I/O w Mojo/C.** Dostępny jest stabilny passthrough VFS
   delegujący do istniejącego VFS; arbitralne implementacje `sqlite3_io_methods` nie są
   jeszcze częścią publicznego API.
4. **Ładowanie rozszerzeń SQLite.** Na obecnym buildzie SQLite i przez aktualny ABI Mojo
   wywołanie opcjonalnego mechanizmu jest niestabilne. `enable_load_extension(False)`
   zachowuje bezpieczny stan wyłączony, a próba włączenia zgłasza typowany błąd zamiast
   powodować crash.
5. **Portability CI.** Należy dodać stałą walidację Linux oraz ASan/UBSan do CI, gdy
   środowiska tych narzędzi będą dostępne. Lokalnie wykonywane są natywne testy strict
   compilation i testy C; testy sanitizerów nie są obecnie częścią gwarantowanego CI.

Współdzielenie uchwytów bez synchronizacji, reentrancy callbacków na tej samej bazie oraz
zamykanie właściciela przed zależnymi zasobami nie są gwarancjami biblioteki.

## Uruchomienie przykładu

```sh
make -C native
uv run mojo run -I src examples/basic.mojo
```

Przykład jawnie zamyka statementy i połączenie.

## Testy

Pojedynczy test:

```sh
uv run mojo run -I src tests/test_sqlite.mojo
```

Pełna suite Mojo:

```sh
make -B -C native
for f in tests/*.mojo; do
  uv run mojo build -I src "$f" -o "/tmp/$(basename "$f" .mojo)" || exit 1
  "/tmp/$(basename "$f" .mojo)" || exit 1
done
```

Testy natywnego ABI:

```sh
cc -std=c11 -Wall -Wextra -Werror -I native \
  tests/native_callbacks.c native/sqlite_fire.c -lsqlite3 -o /tmp/native_callbacks
/tmp/native_callbacks

cc -std=c11 -Wall -Wextra -Werror -I native \
  tests/native_vfs.c native/sqlite_fire.c -lsqlite3 -o /tmp/native_vfs
/tmp/native_vfs
```

Suite obejmuje kontrakty inspirowane CPython `sqlite3`, rusqlite i go-sqlite3:
transakcje i rollback, autocommit, `ROW`/`DONE`, bindingi, NULL/TEXT/BLOB, błędy zakresu
i constraint, URI, WAL, blokady, triggers, foreign keys, stress reuse statementów,
zasoby zależne, niezależne połączenia, callbacki i lifecycle VFS.

## Układ projektu

- `src/sqlite_fire/sqlite.mojo` — podstawowy wrapper Mojo;
- `src/sqlite_fire/advanced.mojo` — BLOB, backup, serializacja, VFS i rozszerzone API;
- `src/sqlite_fire/__init__.mojo` — publiczne eksporty;
- `native/sqlite_fire.h` — publiczny C ABI;
- `native/sqlite_fire.c` — implementacja mostu do systemowego SQLite;
- `tests/` — testy Mojo i natywne testy C;
- `examples/basic.mojo` — minimalny przykład użycia.
