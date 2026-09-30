from sqlite_fire import (
    Connection,
    SQLITE_BLOB_TYPE,
    SQLITE_BUSY,
    SQLITE_ERROR,
    SQLITE_DONE,
    SQLITE_ROW,
    SQLITE_INTEGER_TYPE,
    SQLITE_NULL_TYPE,
    SQLITE_OK,
    SQLITE_REAL_TYPE,
    SQLITE_TEXT_TYPE,
    error_code,
)


def main() raises:
    # SQLite reuses the integers 1 and 5 across two C macro families. Public Mojo names
    # keep those families apart: result codes vs column datatypes.
    assert Int(SQLITE_ERROR) == 1
    assert Int(SQLITE_INTEGER_TYPE) == 1
    assert Int(SQLITE_REAL_TYPE) == 2
    assert Int(SQLITE_TEXT_TYPE) == 3
    assert Int(SQLITE_BLOB_TYPE) == 4
    assert Int(SQLITE_BUSY) == 5
    assert Int(SQLITE_NULL_TYPE) == 5

    var db = Connection(":memory:\0")
    # A payload equal to BUSY / NULL's numeric code is still an INTEGER value.
    var types = db.query("SELECT 5, NULL, 2.5, 'text', x'01'\0")
    assert types.step_code() == Int(SQLITE_ROW)
    assert types.column_type(0) == Int(SQLITE_INTEGER_TYPE)
    assert types.column_type(1) == Int(SQLITE_NULL_TYPE)
    assert types.column_type(2) == Int(SQLITE_REAL_TYPE)
    assert types.column_type(3) == Int(SQLITE_TEXT_TYPE)
    assert types.column_type(4) == Int(SQLITE_BLOB_TYPE)
    assert types.column_value(0).kind == Int(SQLITE_INTEGER_TYPE)
    assert types.column_value(0).integer_value == 5
    assert not types.column_value(0).is_null()
    assert types.column_value(1).kind == Int(SQLITE_NULL_TYPE)
    assert types.column_value(1).is_null()
    assert types.column_value(2).kind == Int(SQLITE_REAL_TYPE)
    assert types.column_value(3).kind == Int(SQLITE_TEXT_TYPE)
    assert types.column_value(4).kind == Int(SQLITE_BLOB_TYPE)
    # Reading INTEGER / NULL must not set ERROR / BUSY on the connection,
    # despite their shared integer values in SQLite's C API.
    assert db.error_code() == Int(SQLITE_OK)
    assert db.extended_error_code() == Int(SQLITE_OK)
    assert not types.column_null(0)
    assert types.column_null(1)
    assert types.step_code() == Int(SQLITE_DONE)
    types.close()

    var saw_error = False
    try:
        db.execute("NOT SQL\0")
    except e:
        saw_error = True
        assert error_code(e) == Int(SQLITE_ERROR)
        assert db.error_code() == Int(SQLITE_ERROR)
        assert db.extended_error_code() == Int(SQLITE_ERROR)
    assert saw_error

    # A successful prepare after SQLITE_ERROR must still expose INTEGER and
    # NULL as datatypes, while clearing the connection's result-code state.
    var recovered = db.query("SELECT 1, NULL\0")
    assert recovered.step_code() == Int(SQLITE_ROW)
    assert recovered.column_type(0) == Int(SQLITE_INTEGER_TYPE)
    assert recovered.column_type(1) == Int(SQLITE_NULL_TYPE)
    assert recovered.column_value(0).kind == Int(SQLITE_INTEGER_TYPE)
    assert recovered.column_value(0).integer_value == 1
    assert not recovered.column_value(0).is_null()
    assert recovered.column_value(1).kind == Int(SQLITE_NULL_TYPE)
    assert recovered.column_value(1).is_null()
    assert db.error_code() == Int(SQLITE_OK)
    assert db.extended_error_code() == Int(SQLITE_OK)
    assert recovered.step_code() == Int(SQLITE_DONE)
    recovered.close()
    db.close()
