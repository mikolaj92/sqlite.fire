"""Small, direct SQLite wrapper for Mojo."""
from std.collections import List
from std.ffi import CStringSlice, OwnedDLHandle, c_double, c_int, c_long_long
from std.memory import MutUnsafePointer, alloc
from std.sys import CompilationTarget

comptime SQLITE_ERROR: Int32 = 1
comptime SQLITE_OK: Int32 = 0
comptime SQLITE_INTEGER: Int32 = 1
comptime SQLITE_REAL: Int32 = 2
comptime SQLITE_TEXT: Int32 = 3
comptime SQLITE_BLOB: Int32 = 4
comptime SQLITE_NULL: Int32 = 5
comptime SQLITE_BUSY: Int32 = 5
comptime SQLITE_CONSTRAINT: Int32 = 19
comptime SQLITE_MISUSE: Int32 = 21
comptime SQLITE_RANGE: Int32 = 25
comptime SQLITE_CANTOPEN: Int32 = 14
comptime SQLITE_NOTFOUND: Int32 = 12
comptime SQLITE_READONLY: Int32 = 8
comptime SQLITE_OPEN_READONLY: Int32 = 0x00000001
comptime SQLITE_OPEN_READWRITE: Int32 = 0x00000002
comptime SQLITE_OPEN_CREATE: Int32 = 0x00000004
comptime SQLITE_OPEN_URI: Int32 = 0x00000040
comptime SQLITE_ROW: Int32 = 100
comptime SQLITE_DONE: Int32 = 101
comptime C_INT_MAX: Int = 2147483647

def _checked_c_int(value: Int, message: String, code: Int = Int(SQLITE_RANGE)) raises SQLiteError -> c_int:
    if value < 0 or value > C_INT_MAX:
        raise SQLiteError(code=code, message=message)
    return c_int(value)
def _validate_savepoint_name(name: String) raises SQLiteError:
    if name.byte_length() == 0:
        raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint name must not be empty")
    var bytes = name.as_bytes()
    var pointer = bytes.unsafe_ptr()
    var i = 0
    while i < name.byte_length():
        var value = (pointer + i).load()
        var first = i == 0
        var letter = (value >= 65 and value <= 90) or (value >= 97 and value <= 122) or value == 95
        var digit = value >= 48 and value <= 57
        if value == 0 or (not letter and (first or not digit)):
            raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint name must be an ASCII identifier")
        i += 1

def _savepoint_sql(prefix: String, name: String) raises SQLiteError -> String:
    _validate_savepoint_name(name)
    var sql = prefix
    sql += "\""
    sql += name
    sql += "\""
    return sql

@fieldwise_init
struct OpenOptions(Copyable, Writable):
    var flags: Int
    var vfs: String

    def __init__(out self):
        self.flags = Int(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI)
        self.vfs = ""

@fieldwise_init
struct TableColumnMetadata(Copyable, Writable):
    var declared_type: String
    var collation: String
    var not_null: Bool
    var primary_key: Bool
    var auto_increment: Bool

@fieldwise_init
struct SQLiteValue(Movable, Writable):
    """An owned SQLite scalar value copied from or bound to a statement."""
    var kind: Int
    var integer_value: Int
    var real_value: Float64
    var text_value: String
    var blob_value: List[UInt8]

    @staticmethod
    def null() -> Self:
        return SQLiteValue(kind=Int(SQLITE_NULL), integer_value=0, real_value=0.0, text_value="", blob_value=List[UInt8]())

    @staticmethod
    def integer(value: Int) -> Self:
        return SQLiteValue(kind=Int(SQLITE_INTEGER), integer_value=value, real_value=0.0, text_value="", blob_value=List[UInt8]())

    @staticmethod
    def real(value: Float64) -> Self:
        return SQLiteValue(kind=Int(SQLITE_REAL), integer_value=0, real_value=value, text_value="", blob_value=List[UInt8]())

    @staticmethod
    def text(value: String) -> Self:
        return SQLiteValue(kind=Int(SQLITE_TEXT), integer_value=0, real_value=0.0, text_value=value, blob_value=List[UInt8]())

    @staticmethod
    def blob(value: List[UInt8]) -> Self:
        return SQLiteValue(kind=Int(SQLITE_BLOB), integer_value=0, real_value=0.0, text_value="", blob_value=value.copy())

    def copy(self) -> Self:
        return SQLiteValue(kind=self.kind, integer_value=self.integer_value, real_value=self.real_value, text_value=self.text_value, blob_value=self.blob_value.copy())

    def is_null(self) -> Bool:
        return self.kind == Int(SQLITE_NULL)
struct Row(Movable):
    """An owned snapshot of the current statement row.

    Values and column names are copied, so the row remains valid after the
    statement advances or closes.
    """
    var _values: List[SQLiteValue]
    var _names: List[String]

    def __init__(out self, var values: List[SQLiteValue], var names: List[String]):
        self._values = values^
        self._names = names^

    def count(self) -> Int:
        return len(self._values)
    def name(self, index: Int) raises SQLiteError -> String:
        if index < 0 or index >= self.count():
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column index out of range")
        return self._names[index]
    def value(self, index: Int) raises SQLiteError -> SQLiteValue:
        if index < 0 or index >= self.count():
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column index out of range")
        return self._values[index].copy()
    def value_by_name(self, name: String) raises SQLiteError -> SQLiteValue:
        var i = 0
        while i < self.count():
            if self._names[i] == name:
                return self.value(i)
            i += 1
        raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column name not found")

struct Savepoint(Movable):
    """A validated savepoint token managed by a ``Connection``."""
    var _name: String
    var _active: Bool

    def __init__(out self, name: String) raises SQLiteError:
        _validate_savepoint_name(name)
        self._name = name
        self._active = True

    def name(self) -> String:
        return self._name

    def _ensure_active(self) raises SQLiteError:
        if not self._active:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint is released")
@fieldwise_init
struct SQLiteError(Copyable, Writable):
    var code: Int
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("sqlite.fire: code=", self.code, ": ", self.message)

    def write_repr_to(self, mut writer: Some[Writer]):
        self.write_to(writer)

comptime DbPtr = MutUnsafePointer[UInt8, MutUntrackedOrigin]
comptime StmtPtr = MutUnsafePointer[UInt8, MutUntrackedOrigin]
comptime DbOut = MutUnsafePointer[DbPtr, MutUntrackedOrigin]
comptime StmtOut = MutUnsafePointer[StmtPtr, MutUntrackedOrigin]
comptime CStr = MutUnsafePointer[Int8, MutUntrackedOrigin]
comptime CStrOut = MutUnsafePointer[CStr, MutUntrackedOrigin]
comptime BlobPtr = MutUnsafePointer[UInt8, MutUntrackedOrigin]

comptime OpenFn = def(CStr, DbOut) thin abi("C") -> c_int
comptime CloseFn = def(DbPtr) thin abi("C") -> c_int
comptime ErrorFn = def(DbPtr) thin abi("C") -> CStr
comptime CodeFn = def(DbPtr) thin abi("C") -> c_int
comptime ChangesFn = def(DbPtr) thin abi("C") -> c_int
comptime RowidFn = def(DbPtr) thin abi("C") -> c_long_long
comptime OpenOptionsFn = def(CStr, c_int, CStr, DbOut) thin abi("C") -> c_int
comptime TotalChangesFn = def(DbPtr) thin abi("C") -> c_int
comptime BindParameterIndexFn = def(StmtPtr, CStr) thin abi("C") -> c_int
comptime StmtSqlFn = def(StmtPtr) thin abi("C") -> CStr
comptime StmtReadonlyFn = def(StmtPtr) thin abi("C") -> c_int
comptime DataCountFn = def(StmtPtr) thin abi("C") -> c_int
comptime ColumnMetadataFn = def(StmtPtr, c_int) thin abi("C") -> CStr
comptime InterruptFn = def(DbPtr) thin abi("C")
comptime TableColumnMetadataFn = def(DbPtr, CStr, CStr, CStr, MutUnsafePointer[CStr, MutUntrackedOrigin], MutUnsafePointer[CStr, MutUntrackedOrigin], MutUnsafePointer[c_int, MutUntrackedOrigin], MutUnsafePointer[c_int, MutUntrackedOrigin], MutUnsafePointer[c_int, MutUntrackedOrigin]) thin abi("C") -> c_int
comptime LimitFn = def(DbPtr, c_int, c_int) thin abi("C") -> c_int
comptime ExecFn = def(DbPtr, CStr) thin abi("C") -> c_int
comptime PrepareFn = def(DbPtr, CStr, StmtOut) thin abi("C") -> c_int
comptime BindNullFn = def(StmtPtr, c_int) thin abi("C") -> c_int
comptime BindIntFn = def(StmtPtr, c_int, c_long_long) thin abi("C") -> c_int
comptime BindDoubleFn = def(StmtPtr, c_int, c_double) thin abi("C") -> c_int
comptime BindTextFn = def(StmtPtr, c_int, CStr, c_int) thin abi("C") -> c_int
comptime BindBlobFn = def(StmtPtr, c_int, BlobPtr, c_int) thin abi("C") -> c_int
comptime ParameterCountFn = def(StmtPtr) thin abi("C") -> c_int
comptime ParameterNameFn = def(StmtPtr, c_int) thin abi("C") -> CStr
comptime ResetFn = def(StmtPtr) thin abi("C") -> c_int
comptime ClearBindingsFn = def(StmtPtr) thin abi("C") -> c_int
comptime BusyTimeoutFn = def(DbPtr, c_int) thin abi("C") -> c_int
comptime StepFn = def(StmtPtr) thin abi("C") -> c_int
comptime FinalizeFn = def(StmtPtr) thin abi("C") -> c_int
comptime ColumnCountFn = def(StmtPtr) thin abi("C") -> c_int
comptime ColumnNameFn = def(StmtPtr, c_int) thin abi("C") -> CStr
comptime ColumnTypeFn = def(StmtPtr, c_int) thin abi("C") -> c_int
comptime ColumnIntFn = def(StmtPtr, c_int) thin abi("C") -> c_long_long
comptime ColumnDoubleFn = def(StmtPtr, c_int) thin abi("C") -> c_double
comptime ColumnTextFn = def(StmtPtr, c_int) thin abi("C") -> CStr
comptime ColumnBlobFn = def(StmtPtr, c_int) thin abi("C") -> BlobPtr
comptime ColumnBytesFn = def(StmtPtr, c_int) thin abi("C") -> c_int

comptime LIBRARY_PATH = (
    "native/libsqlite_fire.so" if CompilationTarget.is_linux()
    else "native/libsqlite_fire.dylib" if CompilationTarget.is_macos()
    else ""
)

def _cstring(mut value: String) raises SQLiteError -> CStringSlice[origin_of(value)]:
    if value.byte_length() == 0 or (value.as_bytes().unsafe_ptr() + (value.byte_length() - 1)).load() != 0:
        value += "\0"
    try:
        return CStringSlice(value)
    except e:
        raise SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))
def _string_from_cstr(value: CStr) raises SQLiteError -> String:
    if Int(value) == 0:
        raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: null text pointer")
    return String(unsafe_from_utf8_ptr=value)

struct Connection(Movable):
    var _library: OwnedDLHandle
    var _db: DbPtr
    var _closed: Bool
    var _close: CloseFn
    var _errmsg: ErrorFn
    var _errcode: CodeFn
    var _extended_errcode: CodeFn
    var _changes: ChangesFn
    var _last_insert_rowid: RowidFn
    var _total_changes: TotalChangesFn
    var _interrupt: InterruptFn
    var _limit: LimitFn
    var _autocommit: CodeFn
    var _busy_timeout: BusyTimeoutFn
    var _exec: ExecFn
    var _prepare: PrepareFn

    def __init__(out self, path: String) raises SQLiteError:
        self._closed = True
        self._db = DbPtr(unsafe_from_address=1)
        var open_result: Int32
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            self._close = self._library.get_function[CloseFn]("sf_close")
            self._errmsg = self._library.get_function[ErrorFn]("sf_errmsg")
            self._errcode = self._library.get_function[CodeFn]("sf_errcode")
            self._extended_errcode = self._library.get_function[CodeFn]("sf_extended_errcode")
            self._changes = self._library.get_function[ChangesFn]("sf_changes")
            self._total_changes = self._library.get_function[TotalChangesFn]("sf_total_changes")
            self._interrupt = self._library.get_function[InterruptFn]("sf_interrupt")
            self._limit = self._library.get_function[LimitFn]("sf_limit")
            self._last_insert_rowid = self._library.get_function[RowidFn]("sf_last_insert_rowid")
            self._autocommit = self._library.get_function[CodeFn]("sf_autocommit")
            self._busy_timeout = self._library.get_function[BusyTimeoutFn]("sf_busy_timeout")
            self._exec = self._library.get_function[ExecFn]("sf_exec")
            self._prepare = self._library.get_function[PrepareFn]("sf_prepare")
            var holder = alloc[DbPtr](1)
            var filename = path
            var filename_c = _cstring(filename)
            var result = self._library.get_function[OpenFn]("sf_open")(CStr(unsafe_from_address=Int(filename_c.unsafe_ptr())), DbOut(to=holder[]))
            open_result = Int32(result)
            if result == SQLITE_OK:
                self._db = holder[]
                self._closed = False
            holder.free()
        except e:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))
        if open_result != SQLITE_OK:
            raise SQLiteError(code=Int(open_result), message="sqlite.fire: failed to open database")

    def __init__(out self, path: String, options: OpenOptions) raises SQLiteError:
        self._closed = True
        self._db = DbPtr(unsafe_from_address=1)
        var open_result: Int32
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            self._close = self._library.get_function[CloseFn]("sf_close")
            self._errmsg = self._library.get_function[ErrorFn]("sf_errmsg")
            self._errcode = self._library.get_function[CodeFn]("sf_errcode")
            self._extended_errcode = self._library.get_function[CodeFn]("sf_extended_errcode")
            self._changes = self._library.get_function[ChangesFn]("sf_changes")
            self._total_changes = self._library.get_function[TotalChangesFn]("sf_total_changes")
            self._interrupt = self._library.get_function[InterruptFn]("sf_interrupt")
            self._limit = self._library.get_function[LimitFn]("sf_limit")
            self._last_insert_rowid = self._library.get_function[RowidFn]("sf_last_insert_rowid")
            self._autocommit = self._library.get_function[CodeFn]("sf_autocommit")
            self._busy_timeout = self._library.get_function[BusyTimeoutFn]("sf_busy_timeout")
            self._exec = self._library.get_function[ExecFn]("sf_exec")
            self._prepare = self._library.get_function[PrepareFn]("sf_prepare")
            var holder = alloc[DbPtr](1)
            var filename = path
            var filename_c = _cstring(filename)
            var vfs = options.vfs
            var vfs_c = _cstring(vfs)
            var result = self._library.get_function[OpenOptionsFn]("sf_open_options")(
                CStr(unsafe_from_address=Int(filename_c.unsafe_ptr())),
                _checked_c_int(options.flags, "sqlite.fire: open flags out of range", Int(SQLITE_MISUSE)),
                CStr(unsafe_from_address=Int(vfs_c.unsafe_ptr())),
                DbOut(to=holder[])
            )
            open_result = Int32(result)
            if result == SQLITE_OK:
                self._db = holder[]
                self._closed = False
            holder.free()
        except e:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))
        if open_result != SQLITE_OK:
            raise SQLiteError(code=Int(open_result), message="sqlite.fire: failed to open database")

    def __del__(deinit self):
        if not self._closed:
            _ = self._close(self._db)

    def _ensure_open(self) raises SQLiteError:
        if self._closed:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: connection is closed")
    # Internal interop hook: callers receive a borrowed handle and must keep this
    # Connection alive while using any non-owning advanced view.
    def _raw_db(self) raises SQLiteError -> DbPtr:
        self._ensure_open()
        return self._db

    def close(mut self) raises SQLiteError:
        if self._closed:
            return
        var result = self._close(self._db)
        if result != SQLITE_OK:
            raise SQLiteError(code=Int(result), message="sqlite.fire: failed to close database")
        self._closed = True

    def _error(self) raises SQLiteError -> String:
        self._ensure_open()
        return _string_from_cstr(self._errmsg(self._db))

    def error_code(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._errcode(self._db))

    def extended_error_code(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._extended_errcode(self._db))

    def changes(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._changes(self._db))

    def last_insert_rowid(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._last_insert_rowid(self._db))

    def in_transaction(self) raises SQLiteError -> Bool:
        self._ensure_open()
        return self._autocommit(self._db) == 0

    def busy_timeout(mut self, milliseconds: Int) raises SQLiteError:
        self._ensure_open()
        var result = self._busy_timeout(self._db, _checked_c_int(milliseconds, "sqlite.fire: busy timeout out of range", Int(SQLITE_RANGE)))
        if result != SQLITE_OK:
            raise SQLiteError(code=Int(result), message="sqlite.fire: failed to set busy timeout")

    def total_changes(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._total_changes(self._db))

    def interrupt(self) raises SQLiteError:
        self._ensure_open()
        self._interrupt(self._db)

    def limit(mut self, category: Int, new_value: Int) raises SQLiteError -> Int:
        self._ensure_open()
        var category_c = _checked_c_int(category, "sqlite.fire: invalid limit category")
        if new_value < -1 or new_value > C_INT_MAX:
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: limit value out of range")
        var result = self._limit(self._db, category_c, c_int(new_value))
        if result < 0:
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: invalid limit category")
        return Int(result)

    def get_limit(mut self, category: Int) raises SQLiteError -> Int:
        return self.limit(category, -1)

    def filename(self, schema: String = "main") raises SQLiteError -> String:
        self._ensure_open()
        var value = schema
        var c_schema = _cstring(value)
        var getter = self._library.get_function[def(DbPtr, CStr) thin abi("C") -> CStr]("sf_db_filename")
        return _string_from_cstr(getter(self._db, CStr(unsafe_from_address=Int(c_schema.unsafe_ptr()))))

    def table_column_metadata(self, schema: String, table: String, column: String) raises SQLiteError -> TableColumnMetadata:
        self._ensure_open()
        var schema_value = schema
        var table_value = table
        var column_value = column
        var schema_c = _cstring(schema_value)
        var table_c = _cstring(table_value)
        var column_c = _cstring(column_value)
        var data_type = alloc[CStr](1)
        var collation = alloc[CStr](1)
        var not_null = alloc[c_int](1)
        var primary_key = alloc[c_int](1)
        var auto_increment = alloc[c_int](1)
        var getter = self._library.get_function[TableColumnMetadataFn]("sf_table_column_metadata")
        var result = getter(self._db, CStr(unsafe_from_address=Int(schema_c.unsafe_ptr())), CStr(unsafe_from_address=Int(table_c.unsafe_ptr())), CStr(unsafe_from_address=Int(column_c.unsafe_ptr())), MutUnsafePointer[CStr, MutUntrackedOrigin](to=data_type[]), MutUnsafePointer[CStr, MutUntrackedOrigin](to=collation[]), MutUnsafePointer[c_int, MutUntrackedOrigin](to=not_null[]), MutUnsafePointer[c_int, MutUntrackedOrigin](to=primary_key[]), MutUnsafePointer[c_int, MutUntrackedOrigin](to=auto_increment[]))
        if result != SQLITE_OK:
            data_type.free()
            collation.free()
            not_null.free()
            primary_key.free()
            auto_increment.free()
            raise SQLiteError(code=Int(result), message=self._error())
        var result_value = TableColumnMetadata(declared_type=_string_from_cstr(data_type[]), collation=_string_from_cstr(collation[]), not_null=not_null[] != 0, primary_key=primary_key[] != 0, auto_increment=auto_increment[] != 0)
        data_type.free()
        collation.free()
        not_null.free()
        primary_key.free()
        auto_increment.free()
        return result_value^

    def execute(mut self, sql: String) raises SQLiteError:
        self._ensure_open()
        var statement = sql
        var statement_c = _cstring(statement)
        var result = self._exec(self._db, CStr(unsafe_from_address=Int(statement_c.unsafe_ptr())))
        if result != SQLITE_OK:
            raise SQLiteError(code=Int(result), message=self._error())

    def begin(mut self) raises SQLiteError:
        self.execute("BEGIN")

    def begin_immediate(mut self) raises SQLiteError:
        self.execute("BEGIN IMMEDIATE")

    def begin_exclusive(mut self) raises SQLiteError:
        self.execute("BEGIN EXCLUSIVE")

    def commit(mut self) raises SQLiteError:
        self._ensure_open()
        if not self.in_transaction(): return
        self.execute("COMMIT")

    def rollback(mut self) raises SQLiteError:
        self._ensure_open()
        if not self.in_transaction(): return
        self.execute("ROLLBACK")

    def query(mut self, sql: String) raises SQLiteError -> Statement:
        self._ensure_open()
        var holder = alloc[StmtPtr](1)
        var statement = sql
        var statement_c = _cstring(statement)
        var result = self._prepare(self._db, CStr(unsafe_from_address=Int(statement_c.unsafe_ptr())), StmtOut(to=holder[]))
        if result != SQLITE_OK:
            holder.free()
            raise SQLiteError(code=Int(result), message=self._error())
        var stmt = holder[]
        holder.free()
        return Statement(stmt)
    def fetch_all(mut self, sql: String) raises SQLiteError -> List[Row]:
        """Fetch and own every result row from a query."""
        var statement = self.query(sql)
        var result = List[Row]()
        while statement.step():
            result.append(statement.row())
        statement.close()
        return result^

    def fetch_one(mut self, sql: String) raises SQLiteError -> Row:
        """Fetch one owned result row or raise ``SQLITE_NOTFOUND``."""
        var statement = self.query(sql)
        if not statement.step():
            statement.close()
            raise SQLiteError(code=Int(SQLITE_NOTFOUND), message="sqlite.fire: query returned no rows")
        var result = statement.row()
        statement.close()
        return result^

    def fetch_value(mut self, sql: String) raises SQLiteError -> SQLiteValue:
        """Fetch the first column of one result row."""
        var row = self.fetch_one(sql)
        if row.count() == 0:
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: query returned no columns")
        return row.value(0)
    def savepoint(mut self, name: String) raises SQLiteError -> Savepoint:
        """Create a savepoint after validating its identifier."""
        self.execute(_savepoint_sql("SAVEPOINT ", name))
        return Savepoint(name)

    def rollback_to(mut self, mut point: Savepoint) raises SQLiteError:
        """Roll back changes made after a savepoint without releasing it."""
        point._ensure_active()
        self.execute(_savepoint_sql("ROLLBACK TO ", point._name))

    def release(mut self, mut point: Savepoint) raises SQLiteError:
        """Release a savepoint and make its token unusable."""
        point._ensure_active()
        self.execute(_savepoint_sql("RELEASE ", point._name))
        point._active = False

struct Statement(Movable):
    var _library: OwnedDLHandle
    var _stmt: StmtPtr
    var _closed: Bool
    var _bind_null: BindNullFn
    var _bind_real: BindDoubleFn
    var _bind_int: BindIntFn
    var _bind_text: BindTextFn
    var _bind_blob: BindBlobFn
    var _parameter_count: ParameterCountFn
    var _parameter_name: ParameterNameFn
    var _reset: ResetFn
    var _clear_bindings: ClearBindingsFn
    var _step: StepFn
    var _finalize: FinalizeFn
    var _column_count: ColumnCountFn
    var _column_name: ColumnNameFn
    var _column_type: ColumnTypeFn
    var _column_int: ColumnIntFn
    var _column_double: ColumnDoubleFn
    var _column_text: ColumnTextFn
    var _column_blob: ColumnBlobFn
    var _column_bytes: ColumnBytesFn
    var _bind_parameter_index: BindParameterIndexFn
    var _stmt_sql: StmtSqlFn
    var _stmt_readonly: StmtReadonlyFn
    var _data_count: DataCountFn
    var _column_database_name: ColumnMetadataFn
    var _column_table_name: ColumnMetadataFn
    var _column_origin_name: ColumnMetadataFn
    var _column_decltype: ColumnMetadataFn

    def __init__(out self, stmt: StmtPtr) raises SQLiteError:
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            self._stmt = stmt
            self._closed = False
            self._bind_null = self._library.get_function[BindNullFn]("sf_bind_null")
            self._bind_real = self._library.get_function[BindDoubleFn]("sf_bind_double")
            self._bind_int = self._library.get_function[BindIntFn]("sf_bind_int64")
            self._bind_text = self._library.get_function[BindTextFn]("sf_bind_text")
            self._bind_blob = self._library.get_function[BindBlobFn]("sf_bind_blob")
            self._parameter_count = self._library.get_function[ParameterCountFn]("sf_parameter_count")
            self._parameter_name = self._library.get_function[ParameterNameFn]("sf_parameter_name")
            self._bind_parameter_index = self._library.get_function[BindParameterIndexFn]("sf_bind_parameter_index")
            self._stmt_sql = self._library.get_function[StmtSqlFn]("sf_stmt_sql")
            self._stmt_readonly = self._library.get_function[StmtReadonlyFn]("sf_stmt_readonly")
            self._data_count = self._library.get_function[DataCountFn]("sf_data_count")
            self._column_database_name = self._library.get_function[ColumnMetadataFn]("sf_column_database_name")
            self._column_table_name = self._library.get_function[ColumnMetadataFn]("sf_column_table_name")
            self._column_origin_name = self._library.get_function[ColumnMetadataFn]("sf_column_origin_name")
            self._column_decltype = self._library.get_function[ColumnMetadataFn]("sf_column_decltype")
            self._reset = self._library.get_function[ResetFn]("sf_reset")
            self._clear_bindings = self._library.get_function[ClearBindingsFn]("sf_clear_bindings")
            self._step = self._library.get_function[StepFn]("sf_step")
            self._finalize = self._library.get_function[FinalizeFn]("sf_finalize")
            self._column_count = self._library.get_function[ColumnCountFn]("sf_column_count")
            self._column_name = self._library.get_function[ColumnNameFn]("sf_column_name")
            self._column_type = self._library.get_function[ColumnTypeFn]("sf_column_type")
            self._column_int = self._library.get_function[ColumnIntFn]("sf_column_int64")
            self._column_double = self._library.get_function[ColumnDoubleFn]("sf_column_double")
            self._column_text = self._library.get_function[ColumnTextFn]("sf_column_text")
            self._column_blob = self._library.get_function[ColumnBlobFn]("sf_column_blob")
            self._column_bytes = self._library.get_function[ColumnBytesFn]("sf_column_bytes")
        except e:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))

    def __del__(deinit self):
        if not self._closed:
            _ = self._finalize(self._stmt)

    def _ensure_open(self) raises SQLiteError:
        if self._closed:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: statement is closed")

    def close(mut self) raises SQLiteError:
        if self._closed:
            return
        self._closed = True
        var result = self._finalize(self._stmt)
        if result != SQLITE_OK:
            raise SQLiteError(code=Int(result), message="sqlite.fire: failed to finalize statement")

    def bind_null(mut self, index: Int) raises SQLiteError:
        self._ensure_open()
        var result = self._bind_null(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind null")
    def bind_value(mut self, index: Int, value: SQLiteValue) raises SQLiteError:
        """Bind an owned scalar using SQLite's native type semantics."""
        if value.kind == Int(SQLITE_NULL):
            self.bind_null(index)
        elif value.kind == Int(SQLITE_INTEGER):
            self.bind_int(index, value.integer_value)
        elif value.kind == Int(SQLITE_REAL):
            self.bind_real(index, value.real_value)
        elif value.kind == Int(SQLITE_TEXT):
            self.bind_text(index, value.text_value)
        elif value.kind == Int(SQLITE_BLOB):
            self.bind_blob(index, value.blob_value.copy())
        else:
            raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: unknown SQLiteValue kind")

    def bind(mut self, index: Int, value: SQLiteValue) raises SQLiteError:
        self.bind_value(index, value)

    def column_value(self, index: Int) raises SQLiteError -> SQLiteValue:
        """Copy one result column while retaining SQL NULL/empty distinctions."""
        var kind = self.column_type(index)
        if kind == Int(SQLITE_NULL): return SQLiteValue.null()
        if kind == Int(SQLITE_INTEGER): return SQLiteValue.integer(self.column_int(index))
        if kind == Int(SQLITE_REAL): return SQLiteValue.real(self.column_real(index))
        if kind == Int(SQLITE_TEXT): return SQLiteValue.text(self.column_text(index))
        if kind == Int(SQLITE_BLOB): return SQLiteValue.blob(self.column_blob(index))
        raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: unknown SQLite column type")

    def bind_int(mut self, index: Int, value: Int) raises SQLiteError:
        self._ensure_open()
        var result = self._bind_int(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), c_long_long(value))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind integer")

    def bind_real(mut self, index: Int, value: Float64) raises SQLiteError:
        self._ensure_open()
        var result = self._bind_real(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), c_double(value))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind real")

    def bind_text(mut self, index: Int, value: String) raises SQLiteError:
        self._ensure_open()
        var text_value = value
        var text_ptr = text_value.as_bytes().unsafe_ptr()
        var result = self._bind_text(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), CStr(unsafe_from_address=Int(text_ptr)), _checked_c_int(text_value.byte_length(), "sqlite.fire: text length out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind text")

    def bind_blob(mut self, index: Int, value: List[UInt8]) raises SQLiteError:
        self._ensure_open()
        var length = len(value)
        var pointer = value.unsafe_ptr()
        var result = self._bind_blob(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), BlobPtr(unsafe_from_address=Int(pointer)), _checked_c_int(length, "sqlite.fire: blob length out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind blob")

    def parameter_count(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._parameter_count(self._stmt))

    def parameter_name(self, index: Int) raises SQLiteError -> String:
        self._ensure_open()
        if index < 1 or index > self.parameter_count():
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: parameter index out of range")
        var name = self._parameter_name(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"))
        if Int(name) == 0: return ""
        return _string_from_cstr(name)

    def bind_parameter_index(self, name: String) raises SQLiteError -> Int:
        self._ensure_open()
        var value = name
        var c_name = _cstring(value)
        return Int(self._bind_parameter_index(self._stmt, CStr(unsafe_from_address=Int(c_name.unsafe_ptr()))))

    def sql(self) raises SQLiteError -> String:
        self._ensure_open()
        return _string_from_cstr(self._stmt_sql(self._stmt))

    def readonly(self) raises SQLiteError -> Bool:
        self._ensure_open()
        var result = self._stmt_readonly(self._stmt)
        if result < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: failed to inspect statement")
        return result != 0

    def data_count(self) raises SQLiteError -> Int:
        self._ensure_open()
        var result = self._data_count(self._stmt)
        if result < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: failed to inspect statement")
        return Int(result)

    def _metadata(self, index: Int, getter: ColumnMetadataFn) raises SQLiteError -> String:
        self._check_column(index)
        var result = getter(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range"))
        if Int(result) == 0: return ""
        return _string_from_cstr(result)

    def column_database_name(self, index: Int) raises SQLiteError -> String:
        return self._metadata(index, self._column_database_name)

    def column_table_name(self, index: Int) raises SQLiteError -> String:
        return self._metadata(index, self._column_table_name)

    def column_origin_name(self, index: Int) raises SQLiteError -> String:
        return self._metadata(index, self._column_origin_name)

    def column_decltype(self, index: Int) raises SQLiteError -> String:
        return self._metadata(index, self._column_decltype)

    def column_index(self, name: String) raises SQLiteError -> Int:
        """Return the first result-column index matching ``name``."""
        self._ensure_open()
        var i = 0
        var count = self.column_count()
        while i < count:
            if self.column_name(i) == name:
                return i
            i += 1
        raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: column name not found")

    def row(self) raises SQLiteError -> Row:
        """Copy the current result row and its column names."""
        self._ensure_open()
        var values = List[SQLiteValue]()
        var names = List[String]()
        var i = 0
        var count = self.column_count()
        while i < count:
            names.append(self.column_name(i))
            values.append(self.column_value(i))
            i += 1
        return Row(values^, names^)

    def reset(mut self) raises SQLiteError:
        self._ensure_open()
        var result = self._reset(self._stmt)
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to reset statement")

    def clear_bindings(mut self) raises SQLiteError:
        self._ensure_open()
        var result = self._clear_bindings(self._stmt)
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to clear bindings")

    def step_code(mut self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._step(self._stmt))

    def step(mut self) raises SQLiteError -> Bool:
        var result = self.step_code()
        if result == Int(SQLITE_ROW): return True
        if result == Int(SQLITE_DONE): return False
        raise SQLiteError(code=result, message="sqlite.fire: failed to step query")

    def column_count(self) raises SQLiteError -> Int:
        self._ensure_open()
        return Int(self._column_count(self._stmt))

    def _check_column(self, index: Int) raises SQLiteError:
        if index < 0 or index >= self.column_count():
            raise SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: column index out of range")

    def column_name(self, index: Int) raises SQLiteError -> String:
        self._check_column(index)
        return _string_from_cstr(self._column_name(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_null(self, index: Int) raises SQLiteError -> Bool:
        return self.column_type(index) == Int(SQLITE_NULL)

    def column_type(self, index: Int) raises SQLiteError -> Int:
        self._check_column(index)
        return Int(self._column_type(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_int(self, index: Int) raises SQLiteError -> Int:
        self._check_column(index)
        return Int(self._column_int(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_real(self, index: Int) raises SQLiteError -> Float64:
        self._check_column(index)
        return Float64(self._column_double(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_text(self, index: Int) raises SQLiteError -> String:
        self._check_column(index)
        if self.column_null(index): return ""
        return _string_from_cstr(self._column_text(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_blob(self, index: Int) raises SQLiteError -> List[UInt8]:
        self._check_column(index)
        var result = List[UInt8]()
        if self.column_null(index): return result^
        var index_c = _checked_c_int(index, "sqlite.fire: column index out of range")
        var length = Int(self._column_bytes(self._stmt, index_c))
        if length < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: invalid blob length")
        if length == 0: return result^
        var pointer = self._column_blob(self._stmt, index_c)
        if Int(pointer) == 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: null blob pointer")
        var i = 0
        while i < length:
            result.append((pointer + i).load())
            i += 1
        return result^
