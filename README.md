# sqlite.fire

Direct access to system SQLite from Mojo through a small C ABI bridge.

The project supports macOS and Linux and uses the system `libsqlite3`. The Mojo
toolchain is managed by **pixi** (`mojo == 1.0.0`). The full test gate also requires `uv` to run `pytest`.

## Status

The library core, extended SQLite API, resource management, contract tests, and native
C ABI bridge are implemented. The main limitations are described in
[Limitations](#limitations); they are not hidden behind unsafe fallbacks
or fake Mojo callbacks.

## Requirements and installation

This is a Mojo library with a C bridge, not a Python distribution or wheel.
Do not use `pip install .` or `uv build` — these paths are not supported.
Use pixi; `make -C native` builds the C bridge, and Mojo imports require `-I src`.

- `pixi` (Mojo **1.0.0** toolchain, `https://conda.modular.com/max` channel)
- `uv` (required by the full test gate)
- system SQLite library (`libsqlite3`)
- macOS or Linux

```sh
pixi install
pixi run test
```

The test runner builds the native library. The smoke task runs the example:

```sh
pixi run smoke
```

The build produces `native/libsqlite_fire.dylib` on macOS and
`native/libsqlite_fire.so` on Linux. The wrapper locates the bridge through a single contract:
`SQLITE_FIRE_LIBRARY` can specify an existing file by its absolute path; without this
variable, the system loader searches for `libsqlite_fire.dylib` or `libsqlite_fire.so`.
The runner sets `SQLITE_FIRE_LIBRARY` automatically. No path depends on
the process's current directory.

## What is implemented

### Core Mojo API

`sqlite_fire` exports:

- `Connection` and `Statement` with explicit, idempotent `close()`;
- `SQLiteError` with a SQLite code and message;
- `OpenOptions` for `sqlite3_open_v2` and VFS selection;
- `SQLiteValue` for SQL `NULL`, INTEGER, REAL, TEXT, and BLOB;
- `Row` as an owned copy of the current row with access by index, name, and
  lookup through `index()`;
- `Row` also provides typed getters `integer()`, `real()`, `text()`, `blob()`, and
  `is_null()` and named variants `integer_by_name()`, `real_by_name()`,
  `text_by_name()`, `blob_by_name()`, and `is_null_by_name()`; a type mismatch raises
  `SQLITE_MISUSE` instead of silently converting;
- prepared statements, positional and named bindings, `bind_value()`/`column_value()`,
  `reset()`, and `clear_bindings()`;
- validated `Savepoint` with `savepoint()`, `rollback_to()`, and `release()`;
- high-level `fetch_all()`, `fetch_one()`, and `fetch_value()` returning owned
  copies of results; a missing row in `fetch_one()` raises `SQLITE_NOTFOUND`;
- access to types, columns, query metadata, and copies of BLOB data;
- transactions (`begin`, `begin_immediate`, `begin_exclusive`, `commit`, `rollback`),
  autocommit, changes, last-insert-rowid, total changes, and busy timeout;
- interrupt, SQLite limits (`limit`/`get_limit`), filename, and table column metadata;
- acceptance of trailing comments and whitespace, while rejecting multiple
  statements in a single `prepare()`;

The public Mojo wrapper covers the listed features; other SQLite capabilities are available
only through the native C ABI or are not supported.

Pass user data through prepared statements and bindings. Interpolating
values into SQL is not supported as a safe mechanism.

`OpenOptions` defaults to `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI`.
`SQLiteValue` preserves the distinction between SQL `NULL`, empty text, and an empty BLOB.
Result codes (`SQLITE_ERROR`, `SQLITE_BUSY`, …) and column type codes (`SQLITE_INTEGER_TYPE`,
`SQLITE_NULL_TYPE`, …) are separate name families. SQLite in C uses the same numbers (`1` and `5`)
in two macro families; compare `error_code()` only with result codes, and `column_type()` / `kind`
only with `SQLITE_*_TYPE`. Do not compare across families. This separates names, not static types:
the constants still have type `Int32`. Existing column type imports (`SQLITE_INTEGER`,
`SQLITE_REAL`, `SQLITE_TEXT`, `SQLITE_BLOB`, `SQLITE_NULL`) must be changed to names
with the `_TYPE` suffix; result code names and the C ABI remain unchanged.
`serialize()` returns copied Mojo data; the `SQLITE_SERIALIZE_NOCOPY` flag is rejected.
Close `PassthroughVFS` only after closing all databases opened with its name.

### Extended API

`sqlite_fire` also exports:

- `AdvancedDatabase` — an owned database or a borrowed view created from `Connection`;
- `IncrementalBlob` — read, write, reopen, size, and idempotent close;
- `Backup` — step, page count, remaining, and idempotent `finish()`;
- database serialization and deserialization with data copied into Mojo memory;
- interrupt and limits at the `AdvancedDatabase` level;
- `PassthroughVFS` — a named VFS delegating to an existing system VFS.

`IncrementalBlob` and `Backup` borrow the database. All dependent resources must be
closed before their owner is closed. `AdvancedDatabase(Connection)` does not close
the connection; the owning `Connection` must remain open for the lifetime of the view
and the resources it creates.

### Native C ABI

`native/sqlite_fire.h` and `native/sqlite_fire.c` provide:

- opening (`sf_open`, `sf_open_options`), diagnostics, database and column metadata,
  interrupt, limits, and all core statement operations;
- incremental BLOB, backup, `sf_serialize`/`sf_serialize_status`, deserialize, and `sf_free`;
- token-based `sf_register_scalar_function`/`sf_register_collation` with a single
  canonical lifecycle through idempotent `sf_callback_token_close`;
- authorizer, progress, trace, update, commit, rollback, WAL, and busy hooks;
- passthrough VFS registration and unregistration;
- `sf_enable_load_extension` and `sf_load_extension` on platforms with a dynamic loader;
- original numeric SQLite result codes without replacing them with a generic error; result codes
  (`sf_errcode`, `sf_step`) are not column type codes (`sf_column_type` /
  `sqlite3_column_type`).

Native callbacks receive synchronous SQLite pointers and are intended for C code.
`userdata` remains owned by the caller and must live for the entire registration;
the bridge does not free this pointer. A callback token deactivates the callback before unregistration,
and its `close` is idempotent. A closed token remains an inactive tombstone and is not
currently freed, so another `close` call is safe.

## Concurrency and resource ownership

The supported concurrency model is **one independently owned `Connection` per worker**.
Each connection has its own SQLite handle. Separate `:memory:` connections are separate databases;
for shared state, use a common file or URI and retain SQLite's
file locking.

`Connection` and `Statement` are mutable resource owners. The wrapper does not add
locks, so sharing a connection or statement requires external
synchronization for every operation and the entire resource lifetime. Callbacks cannot
safely perform reentrant operations on the same database.

In the tested configuration, `sqlite3_close_v2` allows continued use of a statement and
incremental BLOB after closing the owner. This is observed SQLite behavior,
not a general wrapper guarantee — closing dependent resources before the owner is recommended.
Backup must keep both owning connections open until `finish()`.

`close()`/`finish()` are idempotent. The wrapper raises `Error(String(SQLiteError(...)))`;
`error_code(err)` reads the SQLite code from the error text.
An operation on a closed wrapper raises `SQLITE_MISUSE`.

## Limitations

Legend: `[x]` available and documented; `[ ]` missing, disabled, or limited.

- [x] The core Mojo API, extended API, and passthrough VFS are available on macOS and Linux.
- [x] The native C ABI also provides direct serialization with flags (including `NOCOPY`)
  and extension loading; these features are not equivalent to the safe Mojo wrapper.
- [ ] **Mojo → C callbacks.** Verified with Mojo **1.0.0**:
  `def(... ) thin abi("C")` works as the type of a function imported from a library, but
  passing a Mojo function to this type does not work safely. The variant without `thin`
  rejects the conversion at compile time, `escaping` is rejected by the parser, and
  calling an exported function as a callback crashes. Callbacks are therefore
  available only through the native C ABI.
- [ ] **Mojo scalar/window/aggregate functions.** Registering user-defined functions from Mojo
  requires resolving the callback issue in the previous item.
- [ ] **Custom VFS with I/O implemented in Mojo/C.** A passthrough VFS
  delegating to an existing VFS is available; arbitrary `sqlite3_io_methods` implementations are not
  part of the public API.
- [ ] **Extension loading from Mojo.** `enable_load_extension(True)` remains intentionally
  disabled because of a crash in the current Mojo runtime. `False` is safe, and
  `load_extension()` raises `SQLITE_MISUSE` when loading is disabled. Native
  `sf_enable_load_extension`/`sf_load_extension` work on macOS/Linux, but remain
  C-only APIs and are not available as a safe Mojo mechanism.
- [ ] **Full support for other platforms.** The sources and runner support only macOS and Linux;
  other targets do not have a supplied SQLite fire library.
- [ ] **Full native ABI tests.** Strict native tests currently cover callbacks and VFS;
  other C-only operations are covered mainly by Mojo tests or have no separate
  C tests. ASan/UBSan run the same two native tests locally.
- [ ] **Concurrent VFS unregistration.** Unregistration rejects active/in-flight files;
  starting new opens concurrently with unregistration requires external synchronization.
- [ ] **Callback token reclamation.** To keep repeated `close` safe, closed
  tokens remain tombstones; their allocations are not currently reclaimed.

Sharing handles without synchronization and callback reentrancy on the same database
are not library guarantees. Closing the owner before dependent resources is also not
recommended; behavior after `sqlite3_close_v2` is described above as an observation, not a contract.

## Running the example

```sh
pixi run smoke
```

The example explicitly closes statements and the connection.

## Tests

Quick product example:

```sh
pixi run smoke
```

One canonical `test` task runs all Python tests through `pytest`,
the name contract (`SQLITE_BUSY` vs `SQLITE_NULL_TYPE`), strict native tests, and the full Mojo suite:

```sh
pixi run test
```

`[tool.lokay] test` points to the same task. The runner requires `uv` and runs
`uv run --locked --group dev python -m pytest`; failure at any stage stops the gate.

The runner builds each test into a unique temporary directory, sets the correct library
loading path for macOS/Linux, and cleans up artifacts on completion.

Python tests separately:

```sh
uv run --group dev pytest
```

Manual native ABI tests:

```sh
make -C native strict-test
```

Sanitizers are available locally through `make -C native sanitize`.

The Mojo suite covers contracts inspired by CPython `sqlite3`, rusqlite, and go-sqlite3:
transactions and rollback, autocommit, `ROW`/`DONE`, bindings, NULL/TEXT/BLOB, range
and constraint errors, URI, WAL, locking, triggers, foreign keys, statement reuse stress,
dependent resources, independent connections, and the VFS lifecycle. The strict native suite
covers callbacks and passthrough VFS separately.

## Project layout

- `src/sqlite_fire/sqlite.mojo` — core Mojo wrapper;
- `src/sqlite_fire/advanced.mojo` — BLOB, backup, serialization, VFS, and extended API;
- `src/sqlite_fire/__init__.mojo` — public exports;
- `native/sqlite_fire.h` — public C ABI;
- `native/sqlite_fire.c` — bridge implementation for system SQLite;
- `tests/` — Mojo tests and native C tests;
- `examples/basic.mojo` — minimal usage example.
