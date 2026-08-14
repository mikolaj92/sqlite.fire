# Approach plan

<!-- lokay-approach source=deterministic repo=mikolaj92/sqlite.fire issue=5 -->

Repository: `mikolaj92/sqlite.fire`  
Issue: #5 — Pixi/CI pada na nightly Mojo 1.0.0b3.dev; Fala już na stable 1.0.0

## Goal

`pixi.toml` pinuje `mojo = \"==1.0.0b3.dev2026071505\"` na kanale `max-nightly`. CI pada na `setup-pixi` (~7s).

## Files likely touched

- `pixi.toml`
- `pixi.lock`
- `src/sqlite_fire/sqlite.mojo`
- `src/sqlite_fire/advanced.mojo`
- `src/sqlite_fire/__init__.mojo`
- `scripts/test.sh`
- `tests/*.mojo` that inspect `e.code`

## Test plan

- `pixi lock` / `pixi install` to resolve stable `mojo == 1.0.0` from `https://conda.modular.com/max`
- `pixi run mojo --version` (Mojo 1.0.0)
- `pixi run ./scripts/test.sh` (native C tests + full Mojo suite)

## Implementation notes

Changing the pixi pin alone is not enough: nightly FFI types (`thin abi("C")` aliases, cached `_DLCallable` fields, `MutUnsafePointer`, `__del__`) do not compile on stable 1.0.0. Port the wrappers to lookup functions at call time, use `MutPointer`/`Layout`/`__deinit__`, and parse SQLite codes from raised `Error` strings via `error_code()` because typed `raises SQLiteError` cannot call `OwnedDLHandle.get_function`.

## Non-goals

- (none stated)

## Notes

- Trust intentional issue; this plan is evidence for later review, not a human gate.
- Coding agent may refine details but should stay on the stated goal and non-goals.
- Collector boundary: if implementation introduces unbounded collection, ship only a bounded collector patch that starts durably in the background after merge. The coding agent and mill must not populate data or wait for collection to finish.
