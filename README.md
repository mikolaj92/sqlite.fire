# sqlite.fire

Bezpośredni dostęp do systemowego SQLite z Mojo przez mały most C ABI.

Projekt wspiera macOS i Linux, korzysta z systemowego `libsqlite3` i używa `uv` do
środowiska deweloperskiego oraz toolchainu Mojo.

## Status

Rdzeń biblioteki, rozszerzone API SQLite, obsługa zasobów, testy kontraktowe i natywny
most C ABI są zaimplementowane. Najważniejsze ograniczenia opisano w sekcji
[Ograniczenia](#ograniczenia); nie są one ukrywane za niebezpiecznymi fallbackami
ani fałszywymi callbackami Mojo.

## Wymagania i instalacja

- `uv`
- albo `pixi` (zalecane do powtarzalnego środowiska CI)
- nightly Mojo `1.0.0b3.dev2026071505`
- systemowa biblioteka SQLite (`libsqlite3`)
- macOS albo Linux

`uv`:

```sh
uv sync --dev --prerelease allow
```

`pixi`:

```sh
pixi install
```

Bibliotekę natywną buduje runner testów. Do ręcznego uruchomienia przykładu użyj:

```sh
make -C native
uv run mojo run -I src examples/basic.mojo
```

Na macOS powstaje `native/libsqlite_fire.dylib`, a na Linuxie
`native/libsqlite_fire.so`. Runner ustawia `DYLD_LIBRARY_PATH` albo `LD_LIBRARY_PATH`
automatycznie.

## Co jest zaimplementowane

### Podstawowe API Mojo

`sqlite_fire` eksportuje:

- `Connection` i `Statement` z jawnym, idempotentnym `close()`;
- `SQLiteError` z kodem SQLite i komunikatem;
- `OpenOptions` dla `sqlite3_open_v2` oraz wyboru VFS;
- `SQLiteValue` dla SQL `NULL`, INTEGER, REAL, TEXT i BLOB;
- prepared statements, bindingi pozycyjne i nazwane, `bind_value()`/`column_value()`,
  `reset()` oraz `clear_bindings()`;
- odczyt typów, kolumn, metadanych zapytania i kopii danych BLOB;
- transakcje (`begin`, `begin_immediate`, `begin_exclusive`, `commit`, `rollback`),
  autocommit, changes, last-insert-rowid, total changes i busy timeout;
- interrupt, limity SQLite (`limit`/`get_limit`), nazwę pliku i metadane kolumny tabeli;
- akceptowanie końcowych komentarzy i białych znaków, przy odrzucaniu wielu
  instrukcji w jednym `prepare()`;

Publiczny wrapper Mojo obejmuje wymienione funkcje; pozostałe możliwości SQLite są dostępne
tylko przez natywny C ABI albo nie są obsługiwane.

Dane użytkownika należy przekazywać przez prepared statements i bindingi. Interpolacja
wartości do SQL nie jest obsługiwana jako bezpieczny mechanizm.

`OpenOptions` domyślnie używa `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI`.
`SQLiteValue` zachowuje rozróżnienie między SQL `NULL`, pustym tekstem i pustym BLOB-em.
`serialize()` zwraca skopiowane dane Mojo; flaga `SQLITE_SERIALIZE_NOCOPY` jest odrzucana.
`PassthroughVFS` należy zamknąć dopiero po zamknięciu wszystkich baz otwartych z jego nazwą.

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

`native/sqlite_fire.h` i `native/sqlite_fire.c` udostępniają:

- otwieranie (`sf_open`, `sf_open_options`), diagnostykę, metadane bazy i kolumn,
  interrupt, limity oraz wszystkie podstawowe operacje statementów;
- incremental BLOB, backup, `sf_serialize`/`sf_serialize_status`, deserialize i `sf_free`;
- tokenizowane `sf_register_scalar_function`/`sf_register_collation` oraz starsze
  `sf_create_*`/`sf_remove_*` APIs;
- authorizer, progress, trace, update, commit, rollback, WAL i busy hooks;
- rejestrację i wyrejestrowanie passthrough VFS;
- `sf_enable_load_extension` i `sf_load_extension` na platformach z dynamicznym loaderem;
- typed SQLite result codes bez zastępowania ich ogólnym błędem.

Callbacki natywne otrzymują synchroniczne wskaźniki SQLite i są przeznaczone dla kodu C.
`userdata` pozostaje własnością wywołującego i musi żyć przez cały czas rejestracji;
most nie zwalnia tego wskaźnika. Token callbacku dezaktywuje callback przed wyrejestrowaniem,
a jego `close` jest idempotentne. Zamknięty token pozostaje nieaktywnym tombstone’em i nie
jest obecnie zwalniany, aby kolejne wywołanie `close` było bezpieczne.

## Współbieżność i własność zasobów

Wspierany model współbieżności to **jedno niezależnie posiadane `Connection` na worker**.
Każde połączenie ma własny uchwyt SQLite. Osobne połączenia `:memory:` są osobnymi bazami;
dla współdzielonego stanu należy użyć wspólnego pliku albo URI i pozostawić blokowanie
plików SQLite.

`Connection` i `Statement` są mutowalnymi właścicielami zasobów. Wrapper nie dodaje
blokad, więc współdzielenie jednego połączenia lub statementu wymaga zewnętrznej
synchronizacji dla każdej operacji i całego czasu życia zasobu. Callbacki nie mogą
bezpiecznie wykonywać reentrantnych operacji na tej samej bazie.

`sqlite3_close_v2` pozwala w testowanej konfiguracji dokończyć użycie statementu i
incremental BLOB-a po zamknięciu właściciela. Jest to obserwowane zachowanie SQLite,
nie ogólna gwarancja wrappera — zalecane jest zamykanie zasobów zależnych przed właścicielem.
Backup musi zachować oba właścicielskie połączenia otwarte aż do `finish()`.

`close()`/`finish()` są idempotentne. Operacja na zamkniętym wrapperze zgłasza
`SQLiteError` z kodem `SQLITE_MISUSE`.

## Ograniczenia

Legenda: `[x]` dostępne i opisane; `[ ]` brakujące, wyłączone albo ograniczone.

- [x] Podstawowe API Mojo, rozszerzone API oraz passthrough VFS są dostępne na macOS i Linux.
- [x] Natywny C ABI udostępnia także bezpośrednią serializację z flagami (w tym `NOCOPY`)
  oraz ładowanie rozszerzeń; te funkcje nie są równoważne z bezpiecznym wrapperem Mojo.
- [ ] **Callbacki Mojo → C.** Zweryfikowane z `Mojo 1.0.0b3.dev2026071505` (`236eccec`):
  `def(... ) thin abi("C")` działa jako typ funkcji importowanej z biblioteki, ale
  przekazanie funkcji Mojo do tego typu nie działa bezpiecznie. Wariant bez `thin`
  odrzuca konwersję podczas kompilacji, `escaping` jest odrzucone przez parser, a
  wywołanie funkcji eksportowanej jako callback kończy się crashem. Callbacki są więc
  dostępne tylko przez natywny C ABI.
- [ ] **Mojo scalar/window/aggregate functions.** Rejestracja funkcji użytkownika z Mojo
  wymaga rozwiązania problemu callbacków z poprzedniego punktu.
- [ ] **Własny VFS z implementacją I/O w Mojo/C.** Dostępny jest passthrough VFS
  delegujący do istniejącego VFS; arbitralne implementacje `sqlite3_io_methods` nie są
  częścią publicznego API.
- [ ] **Ładowanie rozszerzeń z Mojo.** `enable_load_extension(True)` pozostaje celowo
  wyłączone z powodu crasha w obecnym runtime Mojo. `False` jest bezpieczne, a
  `load_extension()` zgłasza `SQLITE_MISUSE`, gdy ładowanie jest wyłączone. Natywne
  `sf_enable_load_extension`/`sf_load_extension` działają na macOS/Linux, ale pozostają
  API C-only i nie są dostępne jako bezpieczny mechanizm Mojo.
- [ ] **Pełna obsługa innych platform.** Źródła i runner wspierają wyłącznie macOS i Linux;
  inne targety nie mają dostarczonej biblioteki SQLite fire.
- [ ] **Pełne testy natywnego ABI.** Strict native tests obejmują obecnie callbacki i VFS;
  pozostałe C-only operacje są pokrywane głównie przez testy Mojo lub nie mają osobnych
  testów C. ASan/UBSan uruchamiają te same dwa natywne testy lokalnie i nie są krokiem CI.
- [ ] **Współbieżny unregister VFS.** Wyrejestrowanie odrzuca aktywne/in-flight pliki;
  równoczesne rozpoczynanie nowych otwarć i unregister wymaga zewnętrznej synchronizacji.
- [ ] **Odzyskiwanie tokenów callbacków.** Dla bezpieczeństwa powtórnego `close` zamknięte
  tokeny pozostają tombstone’ami; ich alokacja nie jest obecnie odzyskiwana.

Współdzielenie uchwytów bez synchronizacji oraz reentrancy callbacków na tej samej bazie
nie są gwarancjami biblioteki. Zamykanie właściciela przed zależnymi zasobami również nie
jest zalecane; zachowanie po `sqlite3_close_v2` opisano wyżej jako obserwację, nie kontrakt.

## Uruchomienie przykładu

```sh
make -C native
uv run mojo run -I src examples/basic.mojo
```

Przykład jawnie zamyka statementy i połączenie.

## Testy

Pojedynczy test Mojo:

```sh
uv run mojo run -I src tests/test_sqlite.mojo
```

Równoważne zadania `pixi` (`smoke` i `test`) uruchamiają przykład albo pojedynczy test.
Pełna suite Mojo oraz natywne testy strict:

```sh
./scripts/test.sh
```

Runner buduje każdy test do unikalnego katalogu tymczasowego, ustawia właściwą ścieżkę
ładowania biblioteki dla macOS/Linux i sprząta artefakty po zakończeniu. To jest ta sama
ścieżka wykonywana w CI (`pixi run ./scripts/test.sh`).

Ręczne testy natywnego ABI:

```sh
make -C native strict-test
```

Sanitizery są dostępne lokalnie przez `make -C native sanitize`; nie są obecnie uruchamiane
w CI.

Suite Mojo obejmuje kontrakty inspirowane CPython `sqlite3`, rusqlite i go-sqlite3:
transakcje i rollback, autocommit, `ROW`/`DONE`, bindingi, NULL/TEXT/BLOB, błędy zakresu
i constraint, URI, WAL, blokady, triggers, foreign keys, stress reuse statementów,
zasoby zależne, niezależne połączenia, callbacki i lifecycle VFS. Strict native suite
obejmuje osobno callbacki i passthrough VFS.

## Układ projektu

- `src/sqlite_fire/sqlite.mojo` — podstawowy wrapper Mojo;
- `src/sqlite_fire/advanced.mojo` — BLOB, backup, serializacja, VFS i rozszerzone API;
- `src/sqlite_fire/__init__.mojo` — publiczne eksporty;
- `native/sqlite_fire.h` — publiczny C ABI;
- `native/sqlite_fire.c` — implementacja mostu do systemowego SQLite;
- `tests/` — testy Mojo i natywne testy C;
- `examples/basic.mojo` — minimalny przykład użycia.
