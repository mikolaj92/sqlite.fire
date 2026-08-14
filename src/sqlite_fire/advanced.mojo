"""Low-level wrappers for SQLite incremental blobs, backups, serialization, limits, and extensions.

``AdvancedDatabase(path)`` owns its database.  ``AdvancedDatabase(connection)``
creates a non-owning view of a ``Connection`` database; keep the Connection alive
and open until the view and any resources it creates are closed.  Closing the view
never closes the Connection-owned handle.
"""

from std.collections import List
from std.ffi import CStringSlice, OwnedDLHandle, c_int, c_long_long
from std.memory.alloc import alloc, Layout
from std.sys import CompilationTarget
from .sqlite import Connection, SQLiteError

comptime SQLITE_OK: Int32 = 0
comptime SQLITE_ERROR: Int32 = 1
comptime SQLITE_MISUSE: Int32 = 21
comptime SQLITE_RANGE: Int32 = 25
comptime SQLITE_NOMEM: Int32 = 7
comptime SQLITE_OPEN_READWRITE: Int32 = 0x00000002
comptime SQLITE_OPEN_CREATE: Int32 = 0x00000004
comptime SQLITE_OPEN_URI: Int32 = 0x00000040
comptime C_INT_MAX: Int = 2147483647

def _checked_c_int(value: Int, message: String, code: Int = Int(SQLITE_RANGE)) raises -> c_int:
    if value < 0 or value > C_INT_MAX:
        raise Error(String(_error(code, message)))
    return c_int(value)

comptime DbPtr = MutPointer[UInt8, MutUntrackedOrigin]
comptime DbOut = MutPointer[DbPtr, MutUntrackedOrigin]
comptime BlobPtr = MutPointer[UInt8, MutUntrackedOrigin]
comptime BlobOut = MutPointer[BlobPtr, MutUntrackedOrigin]
comptime CStr = MutPointer[Int8, MutUntrackedOrigin]
comptime CStrOut = MutPointer[CStr, MutUntrackedOrigin]
comptime SizeOut = MutPointer[UInt, MutUntrackedOrigin]

comptime VfsPtr = MutPointer[UInt8, MutUntrackedOrigin]
comptime VfsOut = MutPointer[VfsPtr, MutUntrackedOrigin]
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

def _error(code: Int, message: String) -> SQLiteError:
    return SQLiteError(code=code, message=message)

def _check(result: c_int, message: String) raises:
    if result != SQLITE_OK:
        raise Error(String(_error(Int(result), message)))
struct PassthroughVFS(Movable):
    """Registered passthrough VFS; close after dependent databases close."""
    var _library: OwnedDLHandle
    var _vfs: VfsPtr
    var _closed: Bool
    def __init__(out self, name: String, base_name: String = "unix", make_default: Bool = False) raises:
        self._closed = True
        self._vfs = VfsPtr(unsafe_from_address=1)
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
        except e:
            raise Error(String(_error(Int(SQLITE_MISUSE), String(e))))
        var name_value = name
        var base_value = base_name
        var name_c = _cstring(name_value)
        var base_c = _cstring(base_value)
        var holder = alloc(Layout[VfsPtr].single()).into_managed()
        var result = self._library.get_function[c_int]("sf_vfs_register_passthrough")(
            CStr(unsafe_from_address=Int(name_c.unsafe_ptr())),
            CStr(unsafe_from_address=Int(base_c.unsafe_ptr())),
            c_int(1 if make_default else 0), holder.unsafe_ptr().as_unsafe_any_origin())
        if result != SQLITE_OK:
            raise Error(String(_error(Int(result), "sqlite.fire: failed to register VFS")))
        self._vfs = holder.unsafe_ptr()[]
        self._closed = False
    def __deinit__(deinit self):
        try:
            if not self._closed: _ = self._library.get_function[c_int]("sf_vfs_unregister")(self._vfs)
        except:
            pass

    def close(mut self) raises:
        if self._closed: return
        var result = self._library.get_function[c_int]("sf_vfs_unregister")(self._vfs)
        if result == SQLITE_OK: self._closed = True
        _check(result, "sqlite.fire: failed to unregister VFS")


@fieldwise_init
struct AdvancedDatabase(Movable):
    """An owned database or a non-owning view over a Connection database."""
    var _library: OwnedDLHandle
    var _db: DbPtr
    var _owns_db: Bool
    var _closed: Bool
    var _extensions_enabled: Bool

    def __init__(out self, path: String) raises:
        self._closed = True
        self._owns_db = True
        self._extensions_enabled = False
        self._db = DbPtr(unsafe_from_address=1)
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
        except e:
            raise Error(String(_error(Int(SQLITE_MISUSE), String(e))))
        var holder = alloc(Layout[DbPtr].single()).into_managed()
        var filename = path
        var filename_c = _cstring(filename)
        var result = self._library.get_function[c_int]("sf_open")(
            CStr(unsafe_from_address=Int(filename_c.unsafe_ptr())), holder.unsafe_ptr().as_unsafe_any_origin()
        )
        if result != SQLITE_OK:
            raise Error(String(_error(Int(result), "sqlite.fire: failed to open database")))
        self._db = holder.unsafe_ptr()[]
        self._closed = False
    # Borrow the sf_db owned by a Connection. The Connection must remain open
    # for this view's entire lifetime; this view never closes that handle.
    def __init__(out self, connection: Connection) raises:
        self._closed = True
        self._owns_db = False
        self._extensions_enabled = False
        self._db = DbPtr(unsafe_from_address=1)
        var db = connection._raw_db()
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
        except e:
            raise Error(String(_error(Int(SQLITE_MISUSE), String(e))))
        self._db = db
        self._closed = False

    # Internal constructor: sf_db ownership remains with the caller.
    def _from_db(mut self, db: DbPtr) raises:
        self._db = db
        self._closed = False

    def __deinit__(deinit self):
        if not self._closed and self._owns_db:
            try:
                _ = self._library.get_function[c_int]("sf_close")(self._db)
            except:
                pass

    def close(mut self) raises:
        if self._closed: return
        var result = SQLITE_OK
        if self._owns_db:
            result = self._library.get_function[c_int]("sf_close")(self._db)
        self._closed = True
        _check(result, "sqlite.fire: failed to close database")


    def _ensure_open(self) raises:
        if self._closed:
            raise Error(String(_error(Int(SQLITE_MISUSE), "sqlite.fire: database is closed")))

    # Internal raw pointer accessor; the pointer is borrowed and never closed
    # by this wrapper. Keep the owning database alive while using it.
    def _raw_db(self) raises -> DbPtr:
        self._ensure_open()
        return self._db
    def interrupt(self) raises:
        self._ensure_open()
        self._library.get_function[NoneType]("sf_interrupt")(self._db)

    def set_limit(mut self, category: Int, new_value: Int) raises -> Int:
        self._ensure_open()
        if new_value < 0 or new_value > C_INT_MAX:
            raise Error(String(_error(Int(SQLITE_RANGE), "sqlite.fire: limit value out of range")))
        return Int(self._library.get_function[c_int]("sf_limit")(self._db, _checked_c_int(category, "sqlite.fire: invalid limit category"), _checked_c_int(new_value, "sqlite.fire: limit value out of range")))

    def limit(self, category: Int) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_limit")(self._db, _checked_c_int(category, "sqlite.fire: invalid limit category"), c_int(-1)))


    def execute(self, sql: String) raises:
        self._ensure_open()
        var exec = self._library.get_function[c_int]("sf_exec")
        var statement = sql
        var statement_c = _cstring(statement)
        var result = exec(self._db, CStr(unsafe_from_address=Int(statement_c.unsafe_ptr())))
        _check(result, "sqlite.fire: failed to execute SQL")

    def open_blob(self, schema: String, table: String, column: String, rowid: Int, writable: Bool = False) raises -> IncrementalBlob:
        self._ensure_open()
        return IncrementalBlob(self._db, schema, table, column, rowid, writable)
    # Starts a backup using two independently owned advanced databases. The
    # returned resource borrows both databases; keep them alive until finish().
    def backup_from(mut self, source: AdvancedDatabase, dest_schema: String = "main", source_schema: String = "main") raises -> Backup:
        self._ensure_open()
        source._ensure_open()
        return Backup(self._db, dest_schema, source._db, source_schema)

    def serialize(self, schema: String = "main", flags: Int = 0) raises -> List[UInt8]:
        self._ensure_open()
        if flags < 0 or flags > 0:
            raise Error(String(_error(Int(SQLITE_MISUSE), "sqlite.fire: SQLITE_SERIALIZE_NOCOPY is unsupported for copied results")))
        return _serialize_copy(self._db, schema, UInt32(flags), self._library)

    def deserialize(mut self, schema: String, data: List[UInt8], reserved: Int = 0, flags: Int = 0) raises:
        self._ensure_open()
        if reserved < 0: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: reserved size must be non-negative")
        var schema_value = schema
        var schema_c = _cstring(schema_value)
        var data_ptr = BlobPtr(unsafe_from_address=1)
        if len(data) != 0: data_ptr = BlobPtr(unsafe_from_address=Int(data.unsafe_ptr()))
        var result = self._library.get_function[c_int]("sf_deserialize")(
            self._db,
            CStr(unsafe_from_address=Int(schema_c.unsafe_ptr())),
            data_ptr, UInt(len(data)), UInt(reserved), UInt32(flags)
        )
        _check(result, "sqlite.fire: failed to deserialize database")

    def enable_load_extension(mut self, enabled: Bool) raises:
        self._ensure_open()
        if not enabled:
            self._extensions_enabled = False
            return
        raise Error(String(_error(Int(SQLITE_ERROR), "sqlite.fire: extension loading is unsupported")))

    def load_extension(mut self, path: String, entrypoint: String = "") raises:
        self._ensure_open()
        if not self._extensions_enabled:
            raise Error(String(_error(Int(SQLITE_MISUSE), "sqlite.fire: extension loading is disabled")))
        var path_value = path
        var path_c = _cstring(path_value)
        var entry_ptr = CStr(unsafe_from_address=1)
        var entry_c: CStringSlice[origin_of(entrypoint)]
        if entrypoint.byte_length() != 0:
            var entry_value = entrypoint
            entry_c = _cstring(entry_value)
            entry_ptr = CStr(unsafe_from_address=Int(entry_c.unsafe_ptr()))
        var error_holder = alloc(Layout[CStr].single()).into_managed()
        error_holder.unsafe_ptr()[] = CStr(unsafe_from_address=1)
        var result = self._library.get_function[c_int]("sf_load_extension")(
            self._db, CStr(unsafe_from_address=Int(path_c.unsafe_ptr())), entry_ptr,
            error_holder.unsafe_ptr().as_unsafe_any_origin()
        )
        var detail = "sqlite.fire: failed to load extension"
        if Int(error_holder.unsafe_ptr()[]) != 0:
            detail = String(unsafe_from_utf8_ptr=error_holder.unsafe_ptr()[])
            self._library.get_function[NoneType]("sf_free")(BlobPtr(unsafe_from_address=Int(error_holder.unsafe_ptr()[])))
        _check(result, detail)

struct IncrementalBlob(Movable):
    """Owned sqlite3_blob handle. close() is idempotent."""
    var _library: OwnedDLHandle
    var _blob: BlobPtr
    var _closed: Bool
    # Internal constructor; use AdvancedDatabase.open_blob for a public API.
    def __init__(out self, db: DbPtr, schema: String, table: String, column: String, rowid: Int, writable: Bool) raises:
        self._closed = True
        self._blob = BlobPtr(unsafe_from_address=1)
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
        except e:
            raise Error(String(_error(Int(SQLITE_MISUSE), String(e))))
        var schema_value = schema
        var table_value = table
        var column_value = column
        var schema_c = _cstring(schema_value)
        var table_c = _cstring(table_value)
        var column_c = _cstring(column_value)
        var holder = alloc(Layout[BlobPtr].single()).into_managed()
        var result = self._library.get_function[c_int]("sf_blob_open")(
            db, CStr(unsafe_from_address=Int(schema_c.unsafe_ptr())),
            CStr(unsafe_from_address=Int(table_c.unsafe_ptr())),
            CStr(unsafe_from_address=Int(column_c.unsafe_ptr())),
            c_long_long(rowid), c_int(1 if writable else 0), holder.unsafe_ptr().as_unsafe_any_origin()
        )
        if result != SQLITE_OK:
            raise Error(String(_error(Int(result), "sqlite.fire: failed to open incremental blob")))
        self._blob = holder.unsafe_ptr()[]
        self._closed = False
    def __deinit__(deinit self):
        try:
            if not self._closed: _ = self._library.get_function[c_int]("sf_blob_close")(self._blob)
        except:
            pass

    def close(mut self) raises:
        if self._closed: return
        self._closed = True
        _check(self._library.get_function[c_int]("sf_blob_close")(self._blob), "sqlite.fire: failed to close incremental blob")

    def _ensure_open(self) raises:
        if self._closed: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: blob is closed")

    def bytes(self) raises -> Int:
        self._ensure_open()
        return Int(self._library.get_function[c_int]("sf_blob_bytes")(self._blob))

    def read(self, offset: Int, length: Int) raises -> List[UInt8]:
        self._ensure_open()
        if offset < 0 or length < 0: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: invalid blob range")
        var result = List[UInt8]()
        if length == 0: return result^
        var buffer = List[UInt8]()
        var i = 0
        while i < length:
            buffer.append(0)
            i += 1
        var result_code = self._library.get_function[c_int]("sf_blob_read")(self._blob, BlobPtr(unsafe_from_address=Int(buffer.unsafe_ptr())), _checked_c_int(length, "sqlite.fire: blob length out of range"), _checked_c_int(offset, "sqlite.fire: blob offset out of range"))
        _check(result_code, "sqlite.fire: failed to read incremental blob")
        i = 0
        while i < length:
            result.append(buffer[i])
            i += 1
        return result^
    def write(mut self, offset: Int, data: List[UInt8]) raises:
        self._ensure_open()
        if offset < 0: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: invalid blob offset")
        var data_ptr = BlobPtr(unsafe_from_address=1)
        if len(data) != 0: data_ptr = BlobPtr(unsafe_from_address=Int(data.unsafe_ptr()))
        _check(self._library.get_function[c_int]("sf_blob_write")(self._blob, data_ptr, _checked_c_int(len(data), "sqlite.fire: blob length out of range"), _checked_c_int(offset, "sqlite.fire: blob offset out of range")), "sqlite.fire: failed to write incremental blob")

    def reopen(mut self, rowid: Int) raises:
        self._ensure_open()
        _check(self._library.get_function[c_int]("sf_blob_reopen")(self._blob, c_long_long(rowid)), "sqlite.fire: failed to reopen incremental blob")

def _serialize_copy(db: DbPtr, schema: String, flags: UInt32, library: OwnedDLHandle) raises -> List[UInt8]:
    if flags != 0:
        raise Error(String(_error(Int(SQLITE_MISUSE), "sqlite.fire: SQLITE_SERIALIZE_NOCOPY is unsupported for copied results")))
    var schema_value = schema
    var schema_c = _cstring(schema_value)
    var size_holder = alloc(Layout[UInt].single()).into_managed()
    var pointer_holder = alloc(Layout[BlobPtr].single()).into_managed()
    pointer_holder.unsafe_ptr()[] = BlobPtr(unsafe_from_address=1)
    var result_code = library.get_function[c_int]("sf_serialize_status")(db, CStr(unsafe_from_address=Int(schema_c.unsafe_ptr())), size_holder.unsafe_ptr().as_unsafe_any_origin(), flags, pointer_holder.unsafe_ptr().as_unsafe_any_origin())
    if result_code != SQLITE_OK:
        raise Error(String(_error(Int(result_code), "sqlite.fire: failed to serialize database")))
    var size = size_holder.unsafe_ptr()[]
    var pointer = pointer_holder.unsafe_ptr()[]
    var result = List[UInt8]()
    var i: UInt = 0
    while i < size:
        result.append(pointer.unsafe_offset(i).unsafe_load())
        i += 1
    if Int(pointer) != 0: library.get_function[NoneType]("sf_free")(pointer)
    return result^
struct Backup(Movable):
    """Owned backup handle. finish() is idempotent and performed by deinit."""
    var _library: OwnedDLHandle
    var _backup: BlobPtr
    var _finished: Bool
    # Internal constructor; db pointers are borrowed and never closed here.
    def __init__(out self, dest: DbPtr, dest_schema: String, source: DbPtr, source_schema: String) raises:
        self._finished = True
        self._backup = BlobPtr(unsafe_from_address=1)
        try:
            self._library = OwnedDLHandle(LIBRARY_PATH)
        except e:
            raise Error(String(_error(Int(SQLITE_MISUSE), String(e))))
        var dest_value = dest_schema
        var source_value = source_schema
        var dest_c = _cstring(dest_value)
        var source_c = _cstring(source_value)
        var holder = alloc(Layout[BlobPtr].single()).into_managed()
        var result = self._library.get_function[c_int]("sf_backup_start")(
            dest, CStr(unsafe_from_address=Int(dest_c.unsafe_ptr())), source,
            CStr(unsafe_from_address=Int(source_c.unsafe_ptr())), holder.unsafe_ptr().as_unsafe_any_origin()
        )
        if result != SQLITE_OK:
            raise Error(String(_error(Int(result), "sqlite.fire: failed to start backup")))
        self._backup = holder.unsafe_ptr()[]
        self._finished = False
    def __deinit__(deinit self):
        try:
            if not self._finished: _ = self._library.get_function[c_int]("sf_backup_finish")(self._backup)
        except:
            pass

    def finish(mut self) raises:
        if self._finished: return
        self._finished = True
        _check(self._library.get_function[c_int]("sf_backup_finish")(self._backup), "sqlite.fire: failed to finish backup")

    def step(mut self, pages: Int = 1) raises -> Int:
        if self._finished: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: backup is finished")
        if pages < 1: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: backup pages must be positive")
        return Int(self._library.get_function[c_int]("sf_backup_step")(self._backup, _checked_c_int(pages, "sqlite.fire: backup pages out of range")))

    def remaining(self) raises -> Int:
        if self._finished: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: backup is finished")
        return Int(self._library.get_function[c_int]("sf_backup_remaining")(self._backup))

    def pagecount(self) raises -> Int:
        if self._finished: raise _error(Int(SQLITE_MISUSE), "sqlite.fire: backup is finished")
        return Int(self._library.get_function[c_int]("sf_backup_pagecount")(self._backup))
