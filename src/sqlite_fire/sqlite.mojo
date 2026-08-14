"""Small, direct SQLite wrapper for Mojo."""
from std.collections import List
from std.ffi import CStringSlice, OwnedDLHandle, c_double, c_int, c_long_long
from std.memory.alloc import alloc, Layout
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

def _checked_c_int(value: Int, message: String, code: Int = Int(SQLITE_RANGE)) raises -> c_int:
    if value < 0 or value > C_INT_MAX:
        raise Error(String(SQLiteError(code=code, message=message)))
    return c_int(value)
def _validate_savepoint_name(name: String) raises:
    if name.byte_length() == 0:
        raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint name must not be empty")))
    var bytes = name.as_bytes()
    var pointer = bytes.unsafe_ptr()
    var i = 0
    while i < name.byte_length():
        var value = pointer.unsafe_offset(i).unsafe_load()
        var first = i == 0
        var letter = (value >= 65 and value <= 90) or (value >= 97 and value <= 122) or value == 95
        var digit = value >= 48 and value <= 57
        if value == 0 or (not letter and (first or not digit)):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint name must be an ASCII identifier")))
        i += 1

def _savepoint_sql(prefix: String, name: String) raises -> String:
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
    def name(self, index: Int) raises -> String:
        if index < 0 or index >= self.count():
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column index out of range")))
        return self._names[index]
    def index(self, name: String) raises -> Int:
        var i = 0
        while i < self.count():
            if self._names[i] == name:
                return i
            i += 1
        raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column name not found")))
    def value(self, index: Int) raises -> SQLiteValue:
        if index < 0 or index >= self.count():
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column index out of range")))
        return self._values[index].copy()
    def value_by_name(self, name: String) raises -> SQLiteValue:
        var i = 0
        while i < self.count():
            if self._names[i] == name:
                return self.value(i)
            i += 1
        raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: row column name not found")))
    def is_null(self, index: Int) raises -> Bool:
        return self.value(index).is_null()

    def integer(self, index: Int) raises -> Int:
        var item = self.value(index)
        if item.kind != Int(SQLITE_INTEGER):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not INTEGER")))
        return item.integer_value

    def real(self, index: Int) raises -> Float64:
        var item = self.value(index)
        if item.kind != Int(SQLITE_REAL):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not REAL")))
        return item.real_value

    def text(self, index: Int) raises -> String:
        var item = self.value(index)
        if item.kind != Int(SQLITE_TEXT):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not TEXT")))
        return item.text_value

    def blob(self, index: Int) raises -> List[UInt8]:
        var item = self.value(index)
        if item.kind != Int(SQLITE_BLOB):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not BLOB")))
        return item.blob_value.copy()

    def integer_by_name(self, name: String) raises -> Int:
        var item = self.value_by_name(name)
        if item.kind != Int(SQLITE_INTEGER):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not INTEGER")))
        return item.integer_value

    def real_by_name(self, name: String) raises -> Float64:
        var item = self.value_by_name(name)
        if item.kind != Int(SQLITE_REAL):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not REAL")))
        return item.real_value

    def text_by_name(self, name: String) raises -> String:
        var item = self.value_by_name(name)
        if item.kind != Int(SQLITE_TEXT):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not TEXT")))
        return item.text_value

    def blob_by_name(self, name: String) raises -> List[UInt8]:
        var item = self.value_by_name(name)
        if item.kind != Int(SQLITE_BLOB):
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: row value is not BLOB")))
        return item.blob_value.copy()

    def is_null_by_name(self, name: String) raises -> Bool:
        return self.value_by_name(name).is_null()

struct Savepoint(Movable):
    """A validated savepoint token managed by a ``Connection``."""
    var _name: String
    var _active: Bool

    def __init__(out self, name: String) raises:
        _validate_savepoint_name(name)
        self._name = name
        self._active = True

    def name(self) -> String:
        return self._name

    def _ensure_active(self) raises:
        if not self._active:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: savepoint is released")))
@fieldwise_init
struct SQLiteError(Copyable, Writable):
    var code: Int
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("sqlite.fire: code=", self.code, ": ", self.message)

    def write_repr_to(self, mut writer: Some[Writer]):
        self.write_to(writer)

def error_code(err: Error) -> Int:
    """Parse the SQLite result code from a raised ``SQLiteError`` string."""
    var text = String(err)
    var prefix = "sqlite.fire: code="
    if not text.startswith(prefix):
        return -1
    var rest = String(text.removeprefix(prefix))
    var n = 0
    var i = 0
    var seen = False
    while i < rest.byte_length():
        var ch = rest[byte=i]
        var b = ch.as_bytes()[0]
        if b < 48 or b > 57:
            break
        n = n * 10 + Int(b - 48)
        seen = True
        i += 1
    if not seen:
        return -1
    return n

comptime DbPtr = MutPointer[UInt8, MutUntrackedOrigin]
comptime StmtPtr = MutPointer[UInt8, MutUntrackedOrigin]
comptime DbOut = MutPointer[DbPtr, MutUntrackedOrigin]
comptime StmtOut = MutPointer[StmtPtr, MutUntrackedOrigin]
comptime CStr = MutPointer[Int8, MutUntrackedOrigin]
comptime CStrOut = MutPointer[CStr, MutUntrackedOrigin]
comptime BlobPtr = MutPointer[UInt8, MutUntrackedOrigin]


comptime LIBRARY_PATH = (
    "native/libsqlite_fire.so" if CompilationTarget.is_linux()
    else "native/libsqlite_fire.dylib" if CompilationTarget.is_macos()
    else ""
)

def _cstring(mut value: String) raises -> CStringSlice[origin_of(value)]:
    if value.byte_length() == 0 or value.as_bytes().unsafe_ptr().unsafe_offset(value.byte_length() - 1).unsafe_load() != 0:
        value += "\0"
    try:
        return CStringSlice(value)
    except e:
        raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))))
def _string_from_cstr(value: CStr) raises -> String:
    if Int(value) == 0:
        raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: null text pointer")))
    return String(unsafe_from_utf8_ptr=value)

struct Connection(Movable):
    var _library: OwnedDLHandle
    var _db: DbPtr
    var _closed: Bool
    def __init__(out self, path: String) raises:
        self._closed = True
        self._db = DbPtr(unsafe_from_address=1)
        var open_result: Int32
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            var holder = alloc(Layout[DbPtr].single()).into_managed()
            var filename = path
            var filename_c = _cstring(filename)
            var result = self._library.get_function[c_int]("sf_open")(CStr(unsafe_from_address=Int(filename_c.unsafe_ptr())), holder.unsafe_ptr().as_unsafe_any_origin())
            open_result = Int32(result)
            if result == SQLITE_OK:
                self._db = holder.unsafe_ptr()[]
                self._closed = False
        except e:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))))
        if open_result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(open_result), message="sqlite.fire: failed to open database")))

    def __init__(out self, path: String, options: OpenOptions) raises:
        self._closed = True
        self._db = DbPtr(unsafe_from_address=1)
        var open_result: Int32
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            var holder = alloc(Layout[DbPtr].single()).into_managed()
            var filename = path
            var filename_c = _cstring(filename)
            var vfs = options.vfs
            var vfs_c = _cstring(vfs)
            var result = self._library.get_function[c_int]("sf_open_options")(
                CStr(unsafe_from_address=Int(filename_c.unsafe_ptr())),
                _checked_c_int(options.flags, "sqlite.fire: open flags out of range", Int(SQLITE_MISUSE)),
                CStr(unsafe_from_address=Int(vfs_c.unsafe_ptr())),
                holder.unsafe_ptr().as_unsafe_any_origin()
            )
            open_result = Int32(result)
            if result == SQLITE_OK:
                self._db = holder.unsafe_ptr()[]
                self._closed = False
        except e:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))))
        if open_result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(open_result), message="sqlite.fire: failed to open database")))

    def __deinit__(deinit self):
        if not self._closed:
            try:
                _ = self._library.get_function[c_int]("sf_close")(self._db)
            except:
                pass

    def _ensure_open(self) raises:
        if self._closed:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: connection is closed")))
    # Internal interop hook: callers receive a borrowed handle and must keep this
    # Connection alive while using any non-owning advanced view.
    def _raw_db(self) raises -> DbPtr:
        self._ensure_open()
        return self._db

    def close(mut self) raises:
        if self._closed:
            return
        var result = self._library.get_function[c_int]("sf_close")(self._db)
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message="sqlite.fire: failed to close database")))
        self._closed = True

    def _error(self) raises -> String:
        self._ensure_open()
        return _string_from_cstr(self._library.get_function[CStr]("sf_errmsg")(self._db))

    def error_code(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_errcode")(self._db))

    def extended_error_code(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_extended_errcode")(self._db))

    def changes(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_changes")(self._db))

    def last_insert_rowid(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_long_long]("sf_last_insert_rowid")(self._db))

    def in_transaction(self) raises -> Bool:
        self._ensure_open()
        return self._library.get_function[c_int]("sf_autocommit")(self._db) == 0

    def busy_timeout(mut self, milliseconds: Int) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_busy_timeout")(self._db, _checked_c_int(milliseconds, "sqlite.fire: busy timeout out of range", Int(SQLITE_RANGE)))
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message="sqlite.fire: failed to set busy timeout")))

    def total_changes(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_total_changes")(self._db))

    def interrupt(self) raises:
        self._ensure_open()
        self._library.get_function[NoneType]("sf_interrupt")(self._db)

    def limit(mut self, category: Int, new_value: Int) raises -> Int:
        self._ensure_open()
        var category_c = _checked_c_int(category, "sqlite.fire: invalid limit category")
        if new_value < -1 or new_value > C_INT_MAX:
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: limit value out of range")))
        var result = self._library.get_function[c_int]("sf_limit")(self._db, category_c, c_int(new_value))
        if result < 0:
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: invalid limit category")))
        return Int(result)

    def get_limit(mut self, category: Int) raises -> Int:
        return self.limit(category, -1)

    def filename(self, schema: String = "main") raises -> String:
        self._ensure_open()
        var value = schema
        var c_schema = _cstring(value)
        var getter = self._library.get_function[CStr]("sf_db_filename")
        return _string_from_cstr(getter(self._db, CStr(unsafe_from_address=Int(c_schema.unsafe_ptr()))))

    def table_column_metadata(self, schema: String, table: String, column: String) raises -> TableColumnMetadata:
        self._ensure_open()
        var schema_value = schema
        var table_value = table
        var column_value = column
        var schema_c = _cstring(schema_value)
        var table_c = _cstring(table_value)
        var column_c = _cstring(column_value)
        var data_type = alloc(Layout[CStr].single()).into_managed()
        var collation = alloc(Layout[CStr].single()).into_managed()
        var not_null = alloc(Layout[c_int].single()).into_managed()
        var primary_key = alloc(Layout[c_int].single()).into_managed()
        var auto_increment = alloc(Layout[c_int].single()).into_managed()
        var getter = self._library.get_function[c_int]("sf_table_column_metadata")
        var result = getter(self._db, CStr(unsafe_from_address=Int(schema_c.unsafe_ptr())), CStr(unsafe_from_address=Int(table_c.unsafe_ptr())), CStr(unsafe_from_address=Int(column_c.unsafe_ptr())), data_type.unsafe_ptr().as_unsafe_any_origin(), collation.unsafe_ptr().as_unsafe_any_origin(), not_null.unsafe_ptr().as_unsafe_any_origin(), primary_key.unsafe_ptr().as_unsafe_any_origin(), auto_increment.unsafe_ptr().as_unsafe_any_origin())
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message=self._error())))
        var result_value = TableColumnMetadata(declared_type=_string_from_cstr(data_type.unsafe_ptr()[]), collation=_string_from_cstr(collation.unsafe_ptr()[]), not_null=not_null.unsafe_ptr()[] != 0, primary_key=primary_key.unsafe_ptr()[] != 0, auto_increment=auto_increment.unsafe_ptr()[] != 0)
        return result_value^

    def execute(mut self, sql: String) raises:
        self._ensure_open()
        var statement = sql
        var statement_c = _cstring(statement)
        var result = self._library.get_function[c_int]("sf_exec")(self._db, CStr(unsafe_from_address=Int(statement_c.unsafe_ptr())))
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message=self._error())))

    def begin(mut self) raises:
        self.execute("BEGIN")

    def begin_immediate(mut self) raises:
        self.execute("BEGIN IMMEDIATE")

    def begin_exclusive(mut self) raises:
        self.execute("BEGIN EXCLUSIVE")

    def commit(mut self) raises:
        self._ensure_open()
        if not self.in_transaction(): return
        self.execute("COMMIT")

    def rollback(mut self) raises:
        self._ensure_open()
        if not self.in_transaction(): return
        self.execute("ROLLBACK")

    def query(mut self, sql: String) raises -> Statement:
        self._ensure_open()
        var holder = alloc(Layout[StmtPtr].single()).into_managed()
        var statement = sql
        var statement_c = _cstring(statement)
        var result = self._library.get_function[c_int]("sf_prepare")(self._db, CStr(unsafe_from_address=Int(statement_c.unsafe_ptr())), holder.unsafe_ptr().as_unsafe_any_origin())
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message=self._error())))
        var stmt = holder.unsafe_ptr()[]
        return Statement(stmt)
    def fetch_all(mut self, sql: String) raises -> List[Row]:
        """Fetch and own every result row from a query."""
        var statement = self.query(sql)
        var result = List[Row]()
        while statement.step():
            result.append(statement.row())
        statement.close()
        return result^

    def fetch_one(mut self, sql: String) raises -> Row:
        """Fetch one owned result row or raise ``SQLITE_NOTFOUND``."""
        var statement = self.query(sql)
        if not statement.step():
            statement.close()
            raise Error(String(SQLiteError(code=Int(SQLITE_NOTFOUND), message="sqlite.fire: query returned no rows")))
        var result = statement.row()
        statement.close()
        return result^

    def fetch_value(mut self, sql: String) raises -> SQLiteValue:
        """Fetch the first column of one result row."""
        var row = self.fetch_one(sql)
        if row.count() == 0:
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: query returned no columns")))
        return row.value(0)
    def savepoint(mut self, name: String) raises -> Savepoint:
        """Create a savepoint after validating its identifier."""
        self.execute(_savepoint_sql("SAVEPOINT ", name))
        return Savepoint(name)

    def rollback_to(mut self, mut point: Savepoint) raises:
        """Roll back changes made after a savepoint without releasing it."""
        point._ensure_active()
        self.execute(_savepoint_sql("ROLLBACK TO ", point._name))

    def release(mut self, mut point: Savepoint) raises:
        """Release a savepoint and make its token unusable."""
        point._ensure_active()
        self.execute(_savepoint_sql("RELEASE ", point._name))
        point._active = False

struct Statement(Movable):
    var _library: OwnedDLHandle
    var _stmt: StmtPtr
    var _closed: Bool
    def __init__(out self, stmt: StmtPtr) raises:
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
            self._stmt = stmt
            self._closed = False
        except e:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message=String(e))))

    def __deinit__(deinit self):
        if not self._closed:
            try:
                _ = self._library.get_function[c_int]("sf_finalize")(self._stmt)
            except:
                pass

    def _ensure_open(self) raises:
        if self._closed:
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: statement is closed")))

    def close(mut self) raises:
        if self._closed:
            return
        self._closed = True
        var result = self._library.get_function[c_int]("sf_finalize")(self._stmt)
        if result != SQLITE_OK:
            raise Error(String(SQLiteError(code=Int(result), message="sqlite.fire: failed to finalize statement")))

    def bind_null(mut self, index: Int) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_bind_null")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind null")
    def bind_value(mut self, index: Int, value: SQLiteValue) raises:
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
            raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: unknown SQLiteValue kind")))

    def bind(mut self, index: Int, value: SQLiteValue) raises:
        self.bind_value(index, value)

    def column_value(self, index: Int) raises -> SQLiteValue:
        """Copy one result column while retaining SQL NULL/empty distinctions."""
        var kind = self.column_type(index)
        if kind == Int(SQLITE_NULL): return SQLiteValue.null()
        if kind == Int(SQLITE_INTEGER): return SQLiteValue.integer(self.column_int(index))
        if kind == Int(SQLITE_REAL): return SQLiteValue.real(self.column_real(index))
        if kind == Int(SQLITE_TEXT): return SQLiteValue.text(self.column_text(index))
        if kind == Int(SQLITE_BLOB): return SQLiteValue.blob(self.column_blob(index))
        raise Error(String(SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: unknown SQLite column type")))

    def bind_int(mut self, index: Int, value: Int) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_bind_int64")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), c_long_long(value))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind integer")

    def bind_real(mut self, index: Int, value: Float64) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_bind_double")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), c_double(value))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind real")

    def bind_text(mut self, index: Int, value: String) raises:
        self._ensure_open()
        var text_value = value
        var text_ptr = text_value.as_bytes().unsafe_ptr()
        var result = self._library.get_function[c_int]("sf_bind_text")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), CStr(unsafe_from_address=Int(text_ptr)), _checked_c_int(text_value.byte_length(), "sqlite.fire: text length out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind text")

    def bind_blob(mut self, index: Int, value: List[UInt8]) raises:
        self._ensure_open()
        var length = len(value)
        var pointer = value.unsafe_ptr()
        var result = self._library.get_function[c_int]("sf_bind_blob")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"), BlobPtr(unsafe_from_address=Int(pointer)), _checked_c_int(length, "sqlite.fire: blob length out of range"))
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to bind blob")

    def parameter_count(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_parameter_count")(self._stmt))

    def parameter_name(self, index: Int) raises -> String:
        self._ensure_open()
        if index < 1 or index > self.parameter_count():
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: parameter index out of range")))
        var name = self._library.get_function[CStr]("sf_parameter_name")(self._stmt, _checked_c_int(index, "sqlite.fire: parameter index out of range"))
        if Int(name) == 0: return ""
        return _string_from_cstr(name)

    def bind_parameter_index(self, name: String) raises -> Int:
        self._ensure_open()
        var value = name
        var c_name = _cstring(value)
        return Int(self._library.get_function[c_int]("sf_bind_parameter_index")(self._stmt, CStr(unsafe_from_address=Int(c_name.unsafe_ptr()))))

    def sql(self) raises -> String:
        self._ensure_open()
        return _string_from_cstr(self._library.get_function[CStr]("sf_stmt_sql")(self._stmt))

    def readonly(self) raises -> Bool:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_stmt_readonly")(self._stmt)
        if result < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: failed to inspect statement")
        return result != 0

    def data_count(self) raises -> Int:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_data_count")(self._stmt)
        if result < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: failed to inspect statement")
        return Int(result)

    def _metadata(self, index: Int, symbol: String) raises -> String:
        self._check_column(index)
        var result = self._library.get_function[CStr](symbol)(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range"))
        if Int(result) == 0: return ""
        return _string_from_cstr(result)

    def column_database_name(self, index: Int) raises -> String:
        return self._metadata(index, "sf_column_database_name")

    def column_table_name(self, index: Int) raises -> String:
        return self._metadata(index, "sf_column_table_name")

    def column_origin_name(self, index: Int) raises -> String:
        return self._metadata(index, "sf_column_origin_name")

    def column_decltype(self, index: Int) raises -> String:
        return self._metadata(index, "sf_column_decltype")

    def column_index(self, name: String) raises -> Int:
        """Return the first result-column index matching ``name``."""
        self._ensure_open()
        var i = 0
        var count = self.column_count()
        while i < count:
            if self.column_name(i) == name:
                return i
            i += 1
        raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: column name not found")))

    def row(self) raises -> Row:
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

    def reset(mut self) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_reset")(self._stmt)
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to reset statement")

    def clear_bindings(mut self) raises:
        self._ensure_open()
        var result = self._library.get_function[c_int]("sf_clear_bindings")(self._stmt)
        if result != SQLITE_OK: raise SQLiteError(code=Int(result), message="sqlite.fire: failed to clear bindings")

    def step_code(mut self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_step")(self._stmt))

    def step(mut self) raises -> Bool:
        var result = self.step_code()
        if result == Int(SQLITE_ROW): return True
        if result == Int(SQLITE_DONE): return False
        raise Error(String(SQLiteError(code=result, message="sqlite.fire: failed to step query")))

    def column_count(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_column_count")(self._stmt))

    def _check_column(self, index: Int) raises:
        if index < 0 or index >= self.column_count():
            raise Error(String(SQLiteError(code=Int(SQLITE_RANGE), message="sqlite.fire: column index out of range")))

    def column_name(self, index: Int) raises -> String:
        self._check_column(index)
        return _string_from_cstr(self._library.get_function[CStr]("sf_column_name")(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_null(self, index: Int) raises -> Bool:
        return self.column_type(index) == Int(SQLITE_NULL)

    def column_type(self, index: Int) raises -> Int:
        self._check_column(index)
        return Int(self._library.get_function[c_int]("sf_column_type")(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_int(self, index: Int) raises -> Int:
        self._check_column(index)
        return Int(self._library.get_function[c_long_long]("sf_column_int64")(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_real(self, index: Int) raises -> Float64:
        self._check_column(index)
        return Float64(self._library.get_function[c_double]("sf_column_double")(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_text(self, index: Int) raises -> String:
        self._check_column(index)
        if self.column_null(index): return ""
        return _string_from_cstr(self._library.get_function[CStr]("sf_column_text")(self._stmt, _checked_c_int(index, "sqlite.fire: column index out of range")))

    def column_blob(self, index: Int) raises -> List[UInt8]:
        self._check_column(index)
        var result = List[UInt8]()
        if self.column_null(index): return result^
        var index_c = _checked_c_int(index, "sqlite.fire: column index out of range")
        var length = Int(self._library.get_function[c_int]("sf_column_bytes")(self._stmt, index_c))
        if length < 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: invalid blob length")
        if length == 0: return result^
        var pointer = self._library.get_function[BlobPtr]("sf_column_blob")(self._stmt, index_c)
        if Int(pointer) == 0: raise SQLiteError(code=Int(SQLITE_MISUSE), message="sqlite.fire: null blob pointer")
        var i = 0
        while i < length:
            result.append(pointer.unsafe_offset(i).unsafe_load())
            i += 1
        return result^
