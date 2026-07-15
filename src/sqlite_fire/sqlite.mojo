"""Small, direct SQLite wrapper for Mojo."""

from std.ffi import CStringSlice, OwnedDLHandle, c_int, c_long_long
from std.memory import MutUnsafePointer, alloc
from std.sys import CompilationTarget

# SQLite return codes and column types.
comptime SQLITE_OK: Int32 = 0
comptime SQLITE_ROW: Int32 = 100
comptime SQLITE_DONE: Int32 = 101
comptime SQLITE_INTEGER: Int32 = 1
comptime SQLITE_TEXT: Int32 = 3

# These are opaque pointers owned by the C bridge. AnyOrigin is used here
# because the address is managed outside Mojo's lifetime system.
comptime DbPtr = MutUnsafePointer[UInt8, AnyOrigin[mut=True]]
comptime StmtPtr = MutUnsafePointer[UInt8, AnyOrigin[mut=True]]
comptime DbOut = MutUnsafePointer[DbPtr, AnyOrigin[mut=True]]
comptime StmtOut = MutUnsafePointer[StmtPtr, AnyOrigin[mut=True]]
comptime CStr = MutUnsafePointer[Int8, AnyOrigin[mut=True]]

comptime OpenFn = fn(CStr, DbOut) -> c_int
comptime CloseFn = fn(DbPtr) -> c_int
comptime ErrorFn = fn(DbPtr) -> CStr
comptime ExecFn = fn(DbPtr, CStr) -> c_int
comptime PrepareFn = fn(DbPtr, CStr, StmtOut) -> c_int
comptime StepFn = fn(StmtPtr) -> c_int
comptime FinalizeFn = fn(StmtPtr) -> c_int
comptime ColumnCountFn = fn(StmtPtr) -> c_int
comptime ColumnNameFn = fn(StmtPtr, c_int) -> CStr
comptime ColumnTypeFn = fn(StmtPtr, c_int) -> c_int
comptime ColumnIntFn = fn(StmtPtr, c_int) -> c_long_long

comptime LIBRARY_PATH = (
    "native/libsqlite_fire.so" if CompilationTarget.is_linux()
    else "native/libsqlite_fire.dylib"
)
comptime ColumnTextFn = fn(StmtPtr, c_int) -> CStr

fn _cstring(value: String) raises -> CStringSlice[origin_of(value)]:
    return CStringSlice(StringSlice(value))

fn _check(result: Int32, operation: String) raises:
    if result != SQLITE_OK:
        raise Error(operation)

struct Connection(Movable):
    """An owned SQLite connection."""

    var _library: OwnedDLHandle
    var _db: DbPtr
    var _close: CloseFn
    var _errmsg: ErrorFn

    fn __init__(out self, path: String) raises:
        self._library = OwnedDLHandle(LIBRARY_PATH)
        self._close = self._library.get_function[CloseFn]("sf_close")
        self._errmsg = self._library.get_function[ErrorFn]("sf_errmsg")

        var holder = alloc[DbPtr](1)
        var filename = _cstring(path)
        var result = self._library.get_function[OpenFn]("sf_open")(
            CStr(unsafe_from_address=Int(filename.unsafe_ptr())),
            DbOut(to=holder[]),
        )
        if result != SQLITE_OK:
            holder.free()
            raise Error("sqlite.fire: failed to open database")
        self._db = holder[]
        holder.free()

    fn __del__(deinit self):
        _ = self._close(self._db)

    fn _error(self) -> String:
        return String(unsafe_from_utf8_ptr=self._errmsg(self._db))

    fn execute(mut self, sql: String) raises:
        var statement = _cstring(sql)
        var result = self._library.get_function[ExecFn]("sf_exec")(
            self._db, CStr(unsafe_from_address=Int(statement.unsafe_ptr()))
        )
        if result != SQLITE_OK:
            raise Error(self._error())

    fn query(mut self, sql: String) raises -> Statement:
        var holder = alloc[StmtPtr](1)
        var statement = _cstring(sql)
        var result = self._library.get_function[PrepareFn]("sf_prepare")(
            self._db,
            CStr(unsafe_from_address=Int(statement.unsafe_ptr())),
            StmtOut(to=holder[]),
        )
        if result != SQLITE_OK:
            holder.free()
            raise Error(self._error())

        var stmt = holder[]
        holder.free()

        return Statement(stmt)

struct Statement(Movable):
    """An owned prepared statement; call `step()` until it returns false."""

    var _library: OwnedDLHandle
    var _stmt: StmtPtr
    var _step: StepFn
    var _finalize: FinalizeFn
    var _column_count: ColumnCountFn
    var _column_name: ColumnNameFn
    var _column_type: ColumnTypeFn
    var _column_int: ColumnIntFn
    var _column_text: ColumnTextFn

    fn __init__(out self, stmt: StmtPtr) raises:
        self._library = OwnedDLHandle(LIBRARY_PATH)
        self._stmt = stmt
        self._step = self._library.get_function[StepFn]("sf_step")
        self._finalize = self._library.get_function[FinalizeFn]("sf_finalize")
        self._column_count = self._library.get_function[ColumnCountFn]("sf_column_count")
        self._column_name = self._library.get_function[ColumnNameFn]("sf_column_name")
        self._column_type = self._library.get_function[ColumnTypeFn]("sf_column_type")
        self._column_int = self._library.get_function[ColumnIntFn]("sf_column_int64")
        self._column_text = self._library.get_function[ColumnTextFn]("sf_column_text")

    fn __del__(deinit self):
        _ = self._finalize(self._stmt)

    fn step(mut self) raises -> Bool:
        var result = self._step(self._stmt)
        if result == SQLITE_ROW:
            return True
        if result == SQLITE_DONE:
            return False
        raise Error("sqlite.fire: failed to step query")

    fn column_count(self) -> Int:
        return Int(self._column_count(self._stmt))

    fn column_name(self, index: Int) -> String:
        var ptr = self._column_name(self._stmt, c_int(index))
        return String(unsafe_from_utf8_ptr=ptr)

    fn column_type(self, index: Int) -> Int:
        return Int(self._column_type(self._stmt, c_int(index)))

    fn column_int(self, index: Int) -> Int:
        return Int(self._column_int(self._stmt, c_int(index)))

    fn column_text(self, index: Int) -> String:
        var ptr = self._column_text(self._stmt, c_int(index))
        return String(unsafe_from_utf8_ptr=ptr)
